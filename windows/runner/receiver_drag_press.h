#ifndef SHARED_INPUT_RECEIVER_DRAG_PRESS_H_
#define SHARED_INPUT_RECEIVER_DRAG_PRESS_H_
#include <array>
#include <cstdint>

namespace shared_input {
// Platform-thread raw button identity survives individual capture sessions.
// A release/repress of the same button must never resume an old Mac drag.
class ReceiverDragPress {
 public:
  void Observe(unsigned flags) {
    for (unsigned button = 0; button < 5; ++button) {
      if (flags & (1u << (button * 2))) { ids_[button] = ++serial_; held_ |= 1u << button; }
      if (flags & (2u << (button * 2))) held_ &= ~(1u << button);
    }
  }
  uint64_t Id(unsigned button) const { return button < 5 ? ids_[button] : 0; }
  void Cancel() { held_ = 0; }
  bool Matches(unsigned button, uint64_t id, unsigned physical) const {
    return button < 2 && id != 0 && Id(button) == id &&
        physical == (1u << button) && (held_ & (1u << button)) != 0;
  }
 private:
  uint64_t serial_ = 0;
  unsigned held_ = 0;
  std::array<uint64_t, 5> ids_{};
};
}  // namespace shared_input
#endif
