#include <winsock2.h>
#include <ws2tcpip.h>
#include "audio_playback_bridge.h"
#include "audio_packet.h"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <array>
#include <cstdio>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
using Map = AudioPlaybackBridge::Map;
using Value = AudioPlaybackBridge::Value;
std::string Text(const Map& data, const char* key) {
  const auto it = data.find(Value(key));
  if (it == data.end()) return {};
  const auto value = std::get_if<std::string>(&it->second);
  return value ? *value : "";
}
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring value(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), value.data(), length);
  return value;
}
std::string Error(HRESULT result) {
  char code[24]{};
  std::snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(result));
  return std::string("无法启动系统音频播放（") + code + "）";
}
struct Handle {
  HANDLE value = nullptr;
  ~Handle() { if (value) CloseHandle(value); }
};
struct Network {
  SOCKET socket = INVALID_SOCKET;
  WSAEVENT event = WSA_INVALID_EVENT;
  ~Network() {
    if (socket != INVALID_SOCKET) closesocket(socket);
    if (event != WSA_INVALID_EVENT) WSACloseEvent(event);
  }
};
struct EngineStop {
  IAudioClient* client = nullptr;
  ~EngineStop() { if (client) client->Stop(); }
};
}  // namespace

AudioPlaybackBridge::AudioPlaybackBridge(HWND owner) : owner_(owner) {
  commands_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (commands_) worker_ = std::thread([this] { Run(); });
}
AudioPlaybackBridge::~AudioPlaybackBridge() {
  closing_ = true; ++generation_;
  if (commands_) SetEvent(commands_);
  if (worker_.joinable()) worker_.join();
  if (pending_) Reply(pending_->result, {}, "音频播放已停止");
  Complete();
  if (commands_) CloseHandle(commands_);
}
void AudioPlaybackBridge::Start(const Map& args, std::unique_ptr<Result> result) {
  Job job{Text(args, "session"), Text(args, "key"), Text(args, "peer"), Text(args, "device"), 0,
      std::shared_ptr<Result>(std::move(result))};
  std::vector<uint8_t> key;
  if (!commands_ || job.session.size() != 32 || job.device.empty() || !shared_input::AudioHex(job.key, key)) {
    job.result->Error("audio_start_failed", "音频设备或会话参数无效"); return;
  }
  std::optional<Job> old;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    job.generation = ++generation_;
    old = std::move(pending_);
    session_ = job.session; status_ = "starting"; message_.clear(); last_packet_ = 0;
    pending_ = std::move(job);
    SetEvent(commands_);
  }
  if (old) Reply(old->result, {}, "音频启动已取消");
}
void AudioPlaybackBridge::Stop(const std::string& session) {
  std::optional<Job> old;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (session_ != session) return;
    ++generation_; old = std::move(pending_); pending_.reset();
    status_ = "stopped"; last_packet_ = 0;
    SetEvent(commands_);
  }
  if (old) Reply(old->result, {}, "音频启动已取消");
}
AudioPlaybackBridge::Map AudioPlaybackBridge::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto last = last_packet_.load(), now = GetTickCount64();
  return {{Value("session"), Value(session_)}, {Value("status"), Value(status_)},
      {Value("message"), Value(message_)},
      {Value("receiving"), Value(status_ == "ready" && last != 0 && (now < last || now - last < 1000))}};
}
void AudioPlaybackBridge::Reply(std::shared_ptr<Result> result, Map value, std::string error) {
  { std::lock_guard<std::mutex> lock(mutex_); completions_.push_back({std::move(result), std::move(value), std::move(error)}); }
  if (!closing_) PostMessageW(owner_, kResultMessage, 0, 0);
}
void AudioPlaybackBridge::Complete() {
  std::deque<Completion> replies;
  { std::lock_guard<std::mutex> lock(mutex_); replies.swap(completions_); }
  for (auto& reply : replies) {
    if (reply.error.empty()) reply.result->Success(Value(std::move(reply.value)));
    else reply.result->Error("audio_start_failed", reply.error);
  }
}
void AudioPlaybackBridge::Failed(const Job& job, const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (job.generation != generation_ || session_ != job.session) return;
    status_ = "error"; message_ = message;
  }
  if (!closing_) PostMessageW(owner_, kStateMessage, 0, 0);
}
void AudioPlaybackBridge::Run() {
  WSADATA data{};
  const auto sockets = WSAStartup(MAKEWORD(2, 2), &data);
  const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  while (!closing_) {
    std::optional<Job> job;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      job = std::move(pending_); pending_.reset();
      if (job) ResetEvent(commands_);
    }
    if (!job) {
      if (WaitForSingleObject(commands_, INFINITE) != WAIT_OBJECT_0) break;
      continue;
    }
    if (sockets != 0 || FAILED(com)) { Reply(job->result, {}, "无法初始化系统音频播放"); Failed(*job, "无法初始化系统音频播放"); continue; }
    Play(*job);
  }
  if (SUCCEEDED(com)) CoUninitialize();
  if (sockets == 0) WSACleanup();
}
void AudioPlaybackBridge::Play(const Job& job) {
  bool replied = false;
  auto failure = [&](const std::string& message) {
    if (!replied) { Reply(job.result, {}, message); replied = true; }
    Failed(job, message);
  };
  Network network;
  network.socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  network.event = WSACreateEvent();
  sockaddr_in bind_address{}; bind_address.sin_family = AF_INET;
  in_addr peer{};
  if (network.socket == INVALID_SOCKET || network.event == WSA_INVALID_EVENT ||
      InetPtonA(AF_INET, job.peer.c_str(), &peer) != 1 ||
      bind(network.socket, reinterpret_cast<sockaddr*>(&bind_address), sizeof(bind_address)) != 0 ||
      WSAEventSelect(network.socket, network.event, FD_READ) != 0) {
    failure("无法建立音频 UDP 通道"); return;
  }
  int length = sizeof(bind_address);
  if (getsockname(network.socket, reinterpret_cast<sockaddr*>(&bind_address), &length) != 0) {
    failure("无法取得音频接收端口"); return;
  }
  shared_input::AudioPacketCipher cipher(job.key);
  if (!cipher.Ready()) { failure("无法初始化音频加密"); return; }
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioRenderClient> render;
  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator));
  const auto device_id = Wide(job.device);
  if (SUCCEEDED(result)) result = enumerator->GetDevice(device_id.c_str(), &device);
  if (SUCCEEDED(result)) result = device->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr, &client);
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 2; format.nSamplesPerSec = 48000;
  format.wBitsPerSample = 16; format.nBlockAlign = 4; format.nAvgBytesPerSec = 192000;
  if (SUCCEEDED(result)) result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      200000, 0, &format, nullptr);
  Handle ready; ready.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (SUCCEEDED(result) && !ready.value) result = HRESULT_FROM_WIN32(GetLastError());
  if (SUCCEEDED(result)) result = client->SetEventHandle(ready.value);
  if (SUCCEEDED(result)) result = client->GetService(IID_PPV_ARGS(&render));
  UINT32 buffer_frames = 0;
  if (SUCCEEDED(result)) result = client->GetBufferSize(&buffer_frames);
  BYTE* bytes = nullptr;
  if (SUCCEEDED(result)) result = render->GetBuffer(buffer_frames, &bytes);
  if (SUCCEEDED(result)) result = render->ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT);
  if (SUCCEEDED(result)) result = client->Start();
  if (FAILED(result)) { failure(Error(result)); return; }
  EngineStop stop{client.Get()};
  if (job.generation != generation_ || closing_) { failure("音频启动已取消"); return; }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (job.generation == generation_) { last_packet_ = 0; status_ = "ready"; }
  }
  Reply(job.result, {{Value("port"), Value(static_cast<int>(ntohs(bind_address.sin_port)))}});
  replied = true;
  shared_input::AudioJitterBuffer jitter;
  std::array<uint8_t, shared_input::kAudioPacketBytes + 1> packet{};
  const auto started = GetTickCount64();
  HANDLE events[] = {commands_, network.event, ready.value};
  while (!closing_ && job.generation == generation_) {
    const auto event = WaitForMultipleObjects(3, events, FALSE, 50);
    if (event == WAIT_OBJECT_0) break;
    if (event == WAIT_FAILED) { failure("音频播放事件中断"); break; }
    if (event == WAIT_OBJECT_0 + 1) {
      WSANETWORKEVENTS network_events{};
      WSAEnumNetworkEvents(network.socket, network.event, &network_events);
      for (int count = 0; count < 64; ++count) {
        sockaddr_in from{}; int from_size = sizeof(from);
        const int received = recvfrom(network.socket, reinterpret_cast<char*>(packet.data()),
            static_cast<int>(packet.size()), 0, reinterpret_cast<sockaddr*>(&from), &from_size);
        if (received == SOCKET_ERROR) break;
        if (from.sin_addr.s_addr != peer.s_addr) continue;
        uint64_t sequence = 0; shared_input::AudioSamples samples{};
        if (cipher.Decode(packet.data(), static_cast<size_t>(received), sequence, samples) && jitter.Push(sequence, std::move(samples))) {
          last_packet_ = GetTickCount64();
        }
      }
    }
    if (event == WAIT_OBJECT_0 + 2) {
      UINT32 padding = 0;
      result = client->GetCurrentPadding(&padding);
      if (FAILED(result)) { failure(Error(result)); break; }
      const UINT32 available = padding < buffer_frames ? buffer_frames - padding : 0;
      if (available) {
        result = render->GetBuffer(available, &bytes);
        if (FAILED(result)) { failure(Error(result)); break; }
        jitter.Fill(reinterpret_cast<int16_t*>(bytes), available);
        result = render->ReleaseBuffer(available, 0);
        if (FAILED(result)) { failure(Error(result)); break; }
      }
    }
    const auto last = last_packet_.load(), now = GetTickCount64();
    if ((last && now >= last && now - last >= 1200) || (!last && now - started >= 20000)) {
      failure("未收到有效音频数据，已停止音频回传"); break;
    }
  }
}
