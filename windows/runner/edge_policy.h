#ifndef SHARED_INPUT_EDGE_POLICY_H_
#define SHARED_INPUT_EDGE_POLICY_H_
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace shared_input {
class EdgeReturnPolicy {
 public:
  void Begin(uint64_t now) { *this = EdgeReturnPolicy(); started_ = now; }
  void Motion(int dx, int64_t sequence, uint64_t now) {
    if (dx == 0) return;
    // Feedback trails continuous high-rate motion. Acknowledge the start of
    // this leftward gesture, rather than requiring its very latest mouse tick.
    if (dx > 0 || !left_ || now - moved_ > 250) sequence_ = sequence;
    left_ = dx < 0; moved_ = now;
  }
  bool Return(double x, double y, double left, double top, double width, double height,
              int64_t sequence, bool held, uint64_t now) const {
    return !held && left_ && now >= moved_ && now - moved_ <= 250 &&
        now >= started_ && now - started_ >= 200 && sequence >= sequence_ &&
        width > 1 && height > 1 && x >= left - 1 && x <= left + 1 &&
        y >= top && y < top + height;
  }
 private:
  bool left_ = false;
  int64_t sequence_ = -1;
  uint64_t started_ = 0, moved_ = 0;
};
inline double EdgeFraction(double y, double top, double height) {
  return height > 1 ? std::clamp((y - top) / (height - 1), 0.0, 1.0) : 0.5;
}
}  // namespace shared_input
#endif
