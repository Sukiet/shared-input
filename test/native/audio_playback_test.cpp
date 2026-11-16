#include <winsock2.h>
#include <ws2tcpip.h>
#include "../../windows/runner/audio_playback_bridge.h"
#include "../../windows/runner/audio_output_monitor.h"
#include "../../windows/runner/audio_packet.h"
#include <chrono>
#include <cstdlib>
#include <functional>
#include <iostream>

using Value = AudioPlaybackBridge::Value;
using Map = AudioPlaybackBridge::Map;
void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
struct ReplyState { bool done = false; Map data; std::string error; };
class Reply final : public AudioPlaybackBridge::Result {
 public:
  explicit Reply(ReplyState& state) : state_(state) {}
 protected:
  void SuccessInternal(const Value* value) override { state_.data = std::get<Map>(*value); state_.done = true; }
  void ErrorInternal(const std::string&, const std::string& message, const Value*) override { state_.error = message; state_.done = true; }
  void NotImplementedInternal() override { state_.error = "not implemented"; state_.done = true; }
 private:
  ReplyState& state_;
};
bool Wait(AudioPlaybackBridge& bridge, const std::function<bool()>& ready, int milliseconds = 5000) {
  const auto until = GetTickCount64() + milliseconds;
  while (GetTickCount64() < until) {
    bridge.Complete();
    if (ready()) return true;
    Sleep(5);
  }
  return false;
}
std::vector<uint8_t> Silence(uint64_t sequence) {
  using namespace shared_input;
  std::vector<uint8_t> packet(kAudioPacketBytes, 0);
  std::memcpy(packet.data(), "SIA1", 4);
  for (int i = 11; i >= 4; --i) { packet[i] = static_cast<uint8_t>(sequence); sequence >>= 8; }
  packet[15] = static_cast<uint8_t>(kAudioFrames);
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_KEY_HANDLE key = nullptr;
  Check(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_AES_ALGORITHM, nullptr, 0) >= 0, "AES provider");
  Check(BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)), sizeof(BCRYPT_CHAIN_MODE_GCM), 0) >= 0, "GCM mode");
  std::array<uint8_t, 32> secret{};
  Check(BCryptGenerateSymmetricKey(algorithm, &key, nullptr, 0, secret.data(), static_cast<ULONG>(secret.size()), 0) >= 0, "AES key");
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info; BCRYPT_INIT_AUTH_MODE_INFO(info);
  info.pbNonce = packet.data(); info.cbNonce = 12;
  info.pbAuthData = packet.data(); info.cbAuthData = 16;
  info.pbTag = packet.data() + kAudioHeaderBytes + kAudioPcmBytes; info.cbTag = 16;
  std::array<uint8_t, kAudioPcmBytes> pcm{}; ULONG written = 0;
  Check(BCryptEncrypt(key, pcm.data(), static_cast<ULONG>(pcm.size()), &info, nullptr, 0,
      packet.data() + kAudioHeaderBytes, static_cast<ULONG>(pcm.size()), &written, 0) >= 0, "encrypt silence");
  BCryptDestroyKey(key); BCryptCloseAlgorithmProvider(algorithm, 0);
  return packet;
}
int main() {
  HWND owner = CreateWindowExW(0, L"STATIC", L"AudioPlaybackProbe", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  AudioOutputMonitor monitor(owner);
  for (int i = 0; i < 500 && monitor.Snapshot().status == "loading"; ++i) Sleep(10);
  const auto device = monitor.Snapshot();
  if (device.status != "ready") { std::cout << "SKIP: requires default output endpoint\n"; return 77; }
  {
    AudioPlaybackBridge bridge(owner);
    const std::string session(32, 'a');
    Map args{{Value("session"), Value(session)}, {Value("key"), Value(std::string(64, '0'))},
        {Value("peer"), Value("127.0.0.1")}, {Value("device"), Value(device.id)}};
    ReplyState result;
    bridge.Start(args, std::make_unique<Reply>(result));
    Check(Wait(bridge, [&] { return result.done; }), "async playback start timeout");
    if (!result.error.empty()) { std::cerr << result.error << '\n'; return 1; }
    const auto port = std::get<int32_t>(result.data.at(Value("port")));
    WSADATA data{}; Check(WSAStartup(MAKEWORD(2, 2), &data) == 0, "sockets initialized");
    const auto sender = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in destination{}; destination.sin_family = AF_INET; destination.sin_port = htons(static_cast<u_short>(port));
    InetPtonA(AF_INET, "127.0.0.1", &destination.sin_addr);
    for (uint64_t i = 1; i <= 80; ++i) {
      const auto packet = Silence(i);
      Check(sendto(sender, reinterpret_cast<const char*>(packet.data()), static_cast<int>(packet.size()), 0,
          reinterpret_cast<const sockaddr*>(&destination), sizeof(destination)) == static_cast<int>(packet.size()), "audio packet sent");
      Sleep(5);
    }
    Check(Wait(bridge, [&] { return std::get<bool>(bridge.Snapshot().at(Value("receiving"))); }), "valid UDP reaches native playback");
    Check(Wait(bridge, [&] { return std::get<int64_t>(bridge.Snapshot().at(Value("renderedFrames"))) > 0; }), "WASAPI actually consumes decrypted PCM");
    bridge.Stop(std::string(32, 'b'));
    Check(std::get<std::string>(bridge.Snapshot().at(Value("status"))) == "ready", "stale stop cannot stop active stream");
    Check(Wait(bridge, [&] { return std::get<std::string>(bridge.Snapshot().at(Value("status"))) == "error"; }, 3000), "packet silence expires playback");
    ReplyState restarted;
    args[Value("bufferMs")] = Value(200);
    bridge.Start(args, std::make_unique<Reply>(restarted));
    Check(Wait(bridge, [&] { return restarted.done; }) && restarted.error.empty(), "worker restarts after stream failure");
    Check(std::get<int32_t>(bridge.Snapshot().at(Value("targetBufferMs"))) == 200, "requested playout buffer reaches the native worker");
    bridge.Stop(session);
    Check(std::get<std::string>(bridge.Snapshot().at(Value("status"))) == "stopped", "exact session stops");
    closesocket(sender); WSACleanup();
  }
  DestroyWindow(owner);
  std::cout << "Silent UDP -> decrypt -> WASAPI, timeout, stale stop, restart and shutdown passed.\n";
}
