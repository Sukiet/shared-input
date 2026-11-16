#ifndef SHARED_INPUT_AUDIO_PACKET_H_
#define SHARED_INPUT_AUDIO_PACKET_H_
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace shared_input {
constexpr size_t kAudioFrames = 240; // 5 ms at 48 kHz.
constexpr size_t kAudioChannels = 2;
constexpr size_t kAudioPcmBytes = kAudioFrames * kAudioChannels * sizeof(int16_t);
constexpr size_t kAudioHeaderBytes = 16;
constexpr size_t kAudioPacketBytes = kAudioHeaderBytes + kAudioPcmBytes + 16;
using AudioSamples = std::array<int16_t, kAudioFrames * kAudioChannels>;

inline bool AudioHex(const std::string& hex, std::vector<uint8_t>& bytes) {
  if (hex.size() != 64) return false;
  bytes.clear();
  auto digit = [](char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; };
  for (size_t i = 0; i < hex.size(); i += 2) {
    const int high = digit(hex[i]), low = digit(hex[i + 1]);
    if (high < 0 || low < 0) return false;
    bytes.push_back(static_cast<uint8_t>((high << 4) | low));
  }
  return true;
}

class AudioPacketCipher {
 public:
  explicit AudioPacketCipher(const std::string& hex) {
    std::vector<uint8_t> key;
    if (!AudioHex(hex, key)) return;
    if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_AES_ALGORITHM, nullptr, 0) < 0) return;
    if (BCryptSetProperty(algorithm_, BCRYPT_CHAINING_MODE,
        reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),
        sizeof(BCRYPT_CHAIN_MODE_GCM), 0) < 0) return;
    DWORD size = 0, written = 0;
    if (BCryptGetProperty(algorithm_, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&size), sizeof(size), &written, 0) < 0) return;
    object_.resize(size);
    if (BCryptGenerateSymmetricKey(algorithm_, &key_, object_.data(), size,
        key.data(), static_cast<ULONG>(key.size()), 0) < 0) key_ = nullptr;
    SecureZeroMemory(key.data(), key.size());
  }
  ~AudioPacketCipher() {
    if (key_) BCryptDestroyKey(key_);
    if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
    if (!object_.empty()) SecureZeroMemory(object_.data(), object_.size());
  }
  AudioPacketCipher(const AudioPacketCipher&) = delete;
  AudioPacketCipher& operator=(const AudioPacketCipher&) = delete;
  bool Ready() const { return key_ != nullptr; }
  bool Decode(const uint8_t* data, size_t size, uint64_t& sequence, AudioSamples& samples) {
    if (!Ready() || size != kAudioPacketBytes || std::memcmp(data, "SIA1", 4) != 0 ||
        data[12] != 0 || data[13] != 0 || data[14] != 0 || data[15] != kAudioFrames) return false;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = const_cast<PUCHAR>(data); info.cbNonce = 12;
    info.pbAuthData = const_cast<PUCHAR>(data); info.cbAuthData = kAudioHeaderBytes;
    info.pbTag = const_cast<PUCHAR>(data + kAudioHeaderBytes + kAudioPcmBytes); info.cbTag = 16;
    ULONG written = 0;
    if (BCryptDecrypt(key_, const_cast<PUCHAR>(data + kAudioHeaderBytes),
        static_cast<ULONG>(kAudioPcmBytes), &info, nullptr, 0,
        reinterpret_cast<PUCHAR>(samples.data()), static_cast<ULONG>(kAudioPcmBytes), &written, 0) < 0 || written != kAudioPcmBytes) return false;
    sequence = 0;
    for (size_t i = 4; i < 12; ++i) sequence = (sequence << 8) | data[i];
    return sequence != 0;
  }
 private:
  BCRYPT_ALG_HANDLE algorithm_ = nullptr;
  BCRYPT_KEY_HANDLE key_ = nullptr;
  std::vector<uint8_t> object_;
};

// Bounded reorder/pre-roll buffer. Never accumulates seconds of stale audio.
class AudioJitterBuffer {
 public:
  bool Push(uint64_t sequence, AudioSamples samples) {
    if (sequence == 0 || sequence <= consumed_ || queue_.count(sequence)) return false;
    queue_.emplace(sequence, std::move(samples));
    if (queue_.size() > 12) {
      while (queue_.size() > 3) queue_.erase(queue_.begin());
      consumed_ = queue_.begin()->first - 1;
      playing_ = false; offset_ = kAudioFrames;
    }
    return true;
  }
  void Fill(int16_t* target, size_t frames) {
    std::memset(target, 0, frames * kAudioChannels * sizeof(int16_t));
    size_t done = 0;
    while (done < frames) {
      if (!playing_) {
        if (queue_.size() < 3) return;
        next_ = queue_.begin()->first; offset_ = kAudioFrames; playing_ = true;
      }
      if (offset_ == kAudioFrames) {
        if (queue_.empty()) { playing_ = false; return; }
        if (queue_.begin()->first > next_ && queue_.begin()->first - next_ > 12) next_ = queue_.begin()->first;
        auto packet = queue_.find(next_);
        current_.fill(0);
        if (packet != queue_.end()) { current_ = std::move(packet->second); queue_.erase(packet); }
        consumed_ = next_++;
        while (!queue_.empty() && queue_.begin()->first <= consumed_) queue_.erase(queue_.begin());
        offset_ = 0;
      }
      const auto amount = (frames - done < kAudioFrames - offset_) ? frames - done : kAudioFrames - offset_;
      std::memcpy(target + done * kAudioChannels, current_.data() + offset_ * kAudioChannels,
          amount * kAudioChannels * sizeof(int16_t));
      offset_ += amount; done += amount;
    }
  }
  size_t Queued() const { return queue_.size(); }
 private:
  std::map<uint64_t, AudioSamples> queue_;
  AudioSamples current_{};
  uint64_t consumed_ = 0, next_ = 1;
  size_t offset_ = kAudioFrames;
  bool playing_ = false;
};
}  // namespace shared_input
#endif
