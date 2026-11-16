#ifndef SHARED_INPUT_AUDIO_PLAYBACK_BRIDGE_H_
#define SHARED_INPUT_AUDIO_PLAYBACK_BRIDGE_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

class AudioPlaybackBridge {
 public:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  static constexpr UINT kResultMessage = WM_APP + 0x14b;
  static constexpr UINT kStateMessage = WM_APP + 0x14c;
  explicit AudioPlaybackBridge(HWND owner);
  ~AudioPlaybackBridge();
  void Start(const Map& args, std::unique_ptr<Result> result);
  void Stop(const std::string& session);
  Map Snapshot() const;
  void Complete();
 private:
  struct Job {
    std::string session, key, peer, device;
    int buffer_ms;
    uint64_t generation;
    std::shared_ptr<Result> result;
  };
  struct Completion { std::shared_ptr<Result> result; Map value; std::string error; };
  void Run();
  void Play(const Job& job);
  void Reply(std::shared_ptr<Result> result, Map value, std::string error = "");
  void Failed(const Job& job, const std::string& message);
  HWND owner_;
  HANDLE commands_ = nullptr;
  std::thread worker_;
  std::atomic<bool> closing_{false};
  std::atomic<uint64_t> generation_{0}, last_packet_{0};
  mutable std::mutex mutex_;
  std::optional<Job> pending_;
  std::deque<Completion> completions_;
  std::string session_, status_ = "stopped", message_;
  int64_t rendered_frames_ = 0, underruns_ = 0, missing_packets_ = 0, overflow_drops_ = 0;
  double buffered_ms_ = 0, rate_ppm_ = 0;
  int target_buffer_ms_ = 40;
};
#endif
