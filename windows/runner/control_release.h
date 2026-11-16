#ifndef SHARED_INPUT_CONTROL_RELEASE_H_
#define SHARED_INPUT_CONTROL_RELEASE_H_
#include <atomic>
#include <cstdint>
#include <string_view>

namespace shared_input {
constexpr uint64_t kHookFreshLimitMs = 250;
constexpr uint64_t kPointerFeedbackLimitMs = 1000;

inline bool ElapsedAtLeast(uint64_t now, uint64_t last, uint64_t limit) {
  return now >= last && now - last >= limit;
}
inline bool HookFresh(uint64_t now, uint64_t last) {
  // A callback can publish a newer timestamp after the caller sampled now.
  return last != 0 && !ElapsedAtLeast(now, last, kHookFreshLimitMs);
}
inline bool HookPumpFresh(uint64_t now, uint64_t pump, uint64_t mouse, uint64_t keyboard) {
  // Silence from one input device is not evidence that a hook was removed.
  // Either a pump pulse or a callback proves that the native thread can run.
  const auto input = mouse > keyboard ? mouse : keyboard;
  return HookFresh(now, pump > input ? pump : input);
}
inline int64_t ObservedAgeMs(uint64_t now, uint64_t last) {
  return last == 0 ? -1 : static_cast<int64_t>(now >= last ? now - last : 0);
}

enum class ReleaseCause : uint32_t {
  none, manual, shutdown, shortcut, pointer_timeout, heartbeat, timeout,
  hook_lost, mouse_hook_stale, keyboard_hook_stale, hook_queue_failed,
  edge, focus_lost, window_changed, device_removed, input_overflow,
  hook_thread_timeout, other,
};
inline const char* ReleaseCauseCode(ReleaseCause cause) {
  switch (cause) {
    case ReleaseCause::none: return "none";
    case ReleaseCause::manual: return "manual";
    case ReleaseCause::shutdown: return "shutdown";
    case ReleaseCause::shortcut: return "shortcut";
    case ReleaseCause::pointer_timeout: return "pointer_timeout";
    case ReleaseCause::heartbeat: return "heartbeat";
    case ReleaseCause::timeout: return "timeout";
    case ReleaseCause::hook_lost: return "hook_lost";
    case ReleaseCause::mouse_hook_stale: return "mouse_hook_stale";
    case ReleaseCause::keyboard_hook_stale: return "keyboard_hook_stale";
    case ReleaseCause::hook_queue_failed: return "hook_queue_failed";
    case ReleaseCause::edge: return "edge";
    case ReleaseCause::focus_lost: return "focus_lost";
    case ReleaseCause::window_changed: return "window_changed";
    case ReleaseCause::device_removed: return "device_removed";
    case ReleaseCause::input_overflow: return "input_overflow";
    case ReleaseCause::hook_thread_timeout: return "hook_thread_timeout";
    default: return "other";
  }
}
inline const char* ReleaseReasonCode(ReleaseCause cause) {
  switch (cause) {
    case ReleaseCause::mouse_hook_stale:
    case ReleaseCause::keyboard_hook_stale:
    case ReleaseCause::hook_queue_failed:
    case ReleaseCause::hook_thread_timeout: return "hook_lost";
    default: return ReleaseCauseCode(cause);
  }
}
inline ReleaseCause ReleaseCauseFor(std::string_view code) {
  for (uint32_t i = 1; i < static_cast<uint32_t>(ReleaseCause::other); ++i) {
    const auto cause = static_cast<ReleaseCause>(i);
    if (code == ReleaseCauseCode(cause)) return cause;
  }
  return ReleaseCause::other;
}

// One atomic word publishes generation and first reason together. Hook callbacks
// never wait on a lock held by the platform thread. Reset only before arming.
class CaptureReleaseLatch {
 public:
  struct Ownership { uint32_t generation; bool blocking; };
  Ownership CurrentOwnership() const {
    const auto state = state_.load();
    return {static_cast<uint32_t>(state >> 32), (state & kBlocking) != 0};
  }
  void Begin(uint32_t generation, bool blocking = false) {
    state_.store(Pack(generation, ReleaseCause::none) | (blocking ? kBlocking : 0));
  }
  uint32_t Generation() const { return static_cast<uint32_t>(state_.load() >> 32); }
  bool Blocking() const { return (state_.load() & kBlocking) != 0; }
  bool Record(uint32_t generation, ReleaseCause cause) {
    if (cause == ReleaseCause::none) return false;
    auto expected = state_.load();
    while (static_cast<uint32_t>(expected >> 32) == generation &&
        (expected & kReasonMask) == 0) {
      // Publish the first reason and release blocking in the same operation.
      if (state_.compare_exchange_weak(expected, Pack(generation, cause))) return true;
    }
    return false;
  }
  ReleaseCause Reason(uint32_t generation) const {
    const auto state = state_.load();
    return static_cast<uint32_t>(state >> 32) == generation
        ? static_cast<ReleaseCause>(state & kReasonMask) : ReleaseCause::none;
  }
 private:
  static uint64_t Pack(uint32_t generation, ReleaseCause cause) {
    return (static_cast<uint64_t>(generation) << 32) | static_cast<uint32_t>(cause);
  }
  static constexpr uint64_t kBlocking = uint64_t{1} << 31;
  static constexpr uint64_t kReasonMask = kBlocking - 1;
  std::atomic<uint64_t> state_{0};
};
}  // namespace shared_input
#endif
