#ifndef SHARED_INPUT_AUDIO_OUTPUT_MONITOR_H_
#define SHARED_INPUT_AUDIO_OUTPUT_MONITOR_H_
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

// Read-only Core Audio discovery. Device queries run outside the platform and
// input-hook threads; the window only reads a small cached snapshot.
class AudioOutputMonitor {
 public:
  static constexpr UINT kChangedMessage = WM_APP + 0x14a;
  struct State {
    std::string status = "loading";
    std::string id, name, error;
    bool automatic = false;
    bool headphones = false;
    std::string kind = "unknown";
    int64_t revision = 0;
  };
  explicit AudioOutputMonitor(HWND owner);
  ~AudioOutputMonitor();
  void Refresh();
  State Snapshot() const;
 private:
  void Run();
  void Publish(State state);
  HWND owner_;
  HANDLE wake_ = nullptr;
  std::atomic<bool> closing_{false};
  std::thread worker_;
  mutable std::mutex mutex_;
  State state_;
};
#endif
