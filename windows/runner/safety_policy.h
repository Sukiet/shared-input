#ifndef SHARED_INPUT_SAFETY_POLICY_H_
#define SHARED_INPUT_SAFETY_POLICY_H_
#include <cmath>
#include <cstdint>

namespace shared_input {
constexpr uint64_t kSessionLimitMs = 30000;
constexpr uint64_t kHeartbeatLimitMs = 3000;
enum class Expiry { none, timeout, heartbeat };
inline Expiry CheckExpiry(uint64_t now, uint64_t started, uint64_t heartbeat) {
  if (now >= started && now - started >= kSessionLimitMs) return Expiry::timeout;
  if (now >= heartbeat && now - heartbeat >= kHeartbeatLimitMs) return Expiry::heartbeat;
  return Expiry::none;
}
inline bool ValidShortcut(int key, bool ctrl, bool alt, bool win) {
  return ctrl && alt && !win &&
         ((key >= 0x41 && key <= 0x5A) || (key >= 0x75 && key <= 0x7A));
}

// Deliberate emergency gesture; independent of the simulated pointer gain.
// Keep all thresholds together so ordinary aiming corrections stay excluded.
struct ShakePolicy {
  static constexpr uint64_t window_ms = 1200;
  static constexpr double reversal_distance = 600;
  static constexpr int minimum_reversals = 6;
  static constexpr double minimum_travel = 4800;
};

// Per-axis hysteresis rejects tiny direction changes. Per-device instances
// prevent movement from two different mice combining into an emergency gesture.
class ShakeAxis {
 public:
  bool Add(int delta, uint64_t now) {
    if (delta == 0) return false;
    if (!started_ || now - since_ > ShakePolicy::window_ms) {
      *this = ShakeAxis();
      started_ = true;
      since_ = now;
    }
    position_ += static_cast<double>(delta);
    if (direction_ == 0) direction_ = delta > 0 ? 1 : -1;
    if ((position_ - extreme_) * direction_ >= 0) {
      extreme_ = position_;
    } else if ((extreme_ - position_) * direction_ >= ShakePolicy::reversal_distance) {
      travel_ += std::abs(extreme_ - anchor_);
      anchor_ = extreme_;
      extreme_ = position_;
      direction_ = -direction_;
      ++reversals_;
    }
    return reversals_ >= ShakePolicy::minimum_reversals &&
        travel_ + std::abs(extreme_ - anchor_) >= ShakePolicy::minimum_travel;
  }
 private:
  bool started_ = false;
  uint64_t since_ = 0;
  double position_ = 0, anchor_ = 0, extreme_ = 0, travel_ = 0;
  int direction_ = 0, reversals_ = 0;
};
class ShakeDetector {
 public:
  bool Add(int dx, int dy, uint64_t now) {
    const bool x = x_.Add(dx, now);
    const bool y = y_.Add(dy, now);
    return x || y;
  }
 private:
  ShakeAxis x_, y_;
};
}  // namespace shared_input
#endif
