#ifndef SHARED_INPUT_EDGE_POLICY_H_
#define SHARED_INPUT_EDGE_POLICY_H_
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "screen_layout.h"

namespace shared_input {
class EdgeReturnPolicy {
 public:
  void Begin(uint64_t now, ScreenEdge edge = ScreenEdge::left) { *this = EdgeReturnPolicy(); started_ = now; edge_ = edge; }
  void Motion(int dx, int64_t sequence, uint64_t now, int dy = 0) {
    const double outward = OutwardMotion(edge_, dx, dy);
    if (outward == 0) return;
    // Feedback trails continuous high-rate motion. Acknowledge the start of
    // this outward gesture, rather than requiring its very latest mouse tick.
    if (outward < 0 || !outward_ || now - moved_ > 250) sequence_ = sequence;
    outward_ = outward > 0; moved_ = now;
  }
  bool Return(double x, double y, double left, double top, double width, double height,
              int64_t sequence, bool held, uint64_t now) const {
    return !held && outward_ && now >= moved_ && now - moved_ <= 250 &&
        now >= started_ && now - started_ >= 200 && sequence >= sequence_ &&
        width > 1 && height > 1 && OnEdge(edge_, x, y, left, top, width, height);
  }
 private:
  bool outward_ = false;
  ScreenEdge edge_ = ScreenEdge::left;
  int64_t sequence_ = -1;
  uint64_t started_ = 0, moved_ = 0;
};
inline double EdgeFraction(double y, double top, double height) {
  return height > 1 ? std::clamp((y - top) / (height - 1), 0.0, 1.0) : 0.5;
}
}  // namespace shared_input
#endif
