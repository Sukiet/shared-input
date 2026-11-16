#ifndef SHARED_INPUT_AUDIO_PACKET_H_
#define SHARED_INPUT_AUDIO_PACKET_H_
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <algorithm>
#include <cmath>
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

// Elastic playout: reserve audio beyond the current device write, then make
// tiny continuous rate adjustments for independent sender/receiver clocks.
class AudioJitterBuffer {
 public:
  static constexpr int kDefaultBufferMs = 40;
  explicit AudioJitterBuffer(int buffer_ms = kDefaultBufferMs)
      : target_frames_(static_cast<size_t>(std::clamp(buffer_ms, 10, 200)) * 48),
        max_packets_(target_frames_ / kAudioFrames + 24),
        retain_packets_(target_frames_ / kAudioFrames + 4), depth_(static_cast<double>(target_frames_)) {}
  int TargetMs() const { return static_cast<int>(target_frames_ / 48); }
  bool Push(uint64_t sequence, AudioSamples samples) {
    if (sequence == 0 || sequence <= consumed_ || queue_.count(sequence)) return false;
    queue_.emplace(sequence, std::move(samples));
    if (queue_.size() > max_packets_) {
      while (queue_.size() > retain_packets_) { queue_.erase(queue_.begin()); ++overflow_drops_; }
      consumed_ = queue_.begin()->first - 1;
      playing_ = false; offset_ = kAudioFrames; primed_ = false;
    }
    return true;
  }
  void Fill(int16_t* target, size_t frames) {
    if (!frames) return;
    std::memset(target, 0, frames * kAudioChannels * sizeof(int16_t));
    if (!playing_) {
      // A device may request 10-20 ms at once. That write must not consume
      // the entire pre-roll before the next Mac capture burst arrives.
      if (queue_.size() * kAudioFrames < target_frames_ + frames + 2) return;
      next_ = queue_.begin()->first; offset_ = kAudioFrames;
      playing_ = true; primed_ = false; phase_ = 0; fade_ = 0;
      depth_ = static_cast<double>(target_frames_); integral_ = 0; ratio_ = 1;
    }
    const double seconds = static_cast<double>(frames) / 48000;
    const double after = static_cast<double>(BufferedFrames()) - static_cast<double>(frames);
    depth_ += (after - depth_) * (1 - std::exp(-seconds / 0.5));
    const double error = (depth_ - target_frames_) / 48000;
    integral_ = std::clamp(integral_ + error * seconds * 0.005, -0.002, 0.002);
    ratio_ = 1 + std::clamp(error * 0.05 + integral_, -0.003, 0.003);
    for (size_t frame = 0; frame < frames; ++frame) {
      if (!primed_) {
        if (!ReadFrame(left_) || !ReadFrame(right_)) { Underrun(target, frame, frames); return; }
        primed_ = true;
      }
      fade_ = std::min(1.0, fade_ + 1.0 / 240); // 5 ms fade after initial/rebuffer start.
      for (size_t channel = 0; channel < kAudioChannels; ++channel) {
        const double sample = (left_[channel] + (right_[channel] - left_[channel]) * phase_) * fade_;
        last_output_[channel] = static_cast<int16_t>(std::lround(sample));
        target[frame * kAudioChannels + channel] = last_output_[channel];
      }
      ++rendered_frames_;
      phase_ += ratio_;
      while (phase_ >= 1) {
        phase_ -= 1; left_ = right_;
        if (!ReadFrame(right_)) { Underrun(target, frame + 1, frames); return; }
      }
    }
  }
  size_t Queued() const { return queue_.size(); }
  size_t BufferedFrames() const {
    return queue_.size() * kAudioFrames + (kAudioFrames - offset_) + (primed_ ? 2 : 0);
  }
  uint64_t Underruns() const { return underruns_; }
  uint64_t MissingPackets() const { return missing_packets_; }
  uint64_t OverflowDrops() const { return overflow_drops_; }
  uint64_t RenderedFrames() const { return rendered_frames_; }
  double RatePpm() const { return (ratio_ - 1) * 1000000; }
 private:
  bool ReadFrame(std::array<int16_t, 2>& value) {
    if (offset_ == kAudioFrames) {
      if (queue_.empty()) return false;
      if (queue_.begin()->first > next_ && queue_.begin()->first - next_ > max_packets_) {
        next_ = queue_.begin()->first;
      }
      const auto packet = queue_.find(next_);
      current_.fill(0);
      if (packet != queue_.end()) {
        current_ = std::move(packet->second); queue_.erase(packet);
      } else { ++missing_packets_; }
      consumed_ = next_++;
      while (!queue_.empty() && queue_.begin()->first <= consumed_) queue_.erase(queue_.begin());
      offset_ = 0;
    }
    for (size_t channel = 0; channel < kAudioChannels; ++channel)
      value[channel] = current_[offset_ * kAudioChannels + channel];
    ++offset_;
    return true;
  }
  void Underrun(int16_t* target, size_t start, size_t frames) {
    ++underruns_; playing_ = false; primed_ = false; offset_ = kAudioFrames;
    for (size_t frame = start; frame < frames; ++frame) {
      const double gain = std::max(0.0, 1 - static_cast<double>(frame - start + 1) / 240);
      for (size_t channel = 0; channel < kAudioChannels; ++channel)
        target[frame * kAudioChannels + channel] = static_cast<int16_t>(std::lround(last_output_[channel] * gain));
    }
  }
  const size_t target_frames_, max_packets_, retain_packets_;
  std::map<uint64_t, AudioSamples> queue_;
  AudioSamples current_{};
  std::array<int16_t, 2> left_{}, right_{}, last_output_{};
  uint64_t consumed_ = 0, next_ = 1;
  uint64_t underruns_ = 0, missing_packets_ = 0, overflow_drops_ = 0, rendered_frames_ = 0;
  size_t offset_ = kAudioFrames;
  bool playing_ = false, primed_ = false;
  double phase_ = 0, fade_ = 0, depth_, integral_ = 0, ratio_ = 1;
};
}  // namespace shared_input
#endif
