#ifndef SHARED_INPUT_DRAG_GESTURE_H_
#define SHARED_INPUT_DRAG_GESTURE_H_
#include <cstdint>
#include <cstdlib>

namespace shared_input {
// Read-only gesture observation. A click never opens an input region; only
// holding left/right and moving past the system drag threshold does.
class DragGesture {
 public:
  void Button(unsigned button, bool down, int x, int y) {
    if (button > 1) return;
    const unsigned mask = 1u << button;
    if (down) {
      if (!buttons_) { x_ = x; y_ = y; active_ = false; }
      buttons_ |= mask;
    } else { buttons_ &= ~mask; if (!buttons_) active_ = false; }
  }
  void Move(int x, int y, int threshold_x, int threshold_y) {
    if (buttons_ && (std::abs(static_cast<int64_t>(x) - x_) >= threshold_x ||
        std::abs(static_cast<int64_t>(y) - y_) >= threshold_y)) active_ = true;
  }
  bool Active() const { return active_; }
 private:
  unsigned buttons_ = 0;
  int x_ = 0, y_ = 0;
  bool active_ = false;
};
}  // namespace shared_input
#endif
