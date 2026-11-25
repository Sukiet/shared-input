#ifndef SHARED_INPUT_HOOK_KEY_STATE_H_
#define SHARED_INPUT_HOOK_KEY_STATE_H_
#include <array>
#include <cstdint>
#include "key_routing.h"

namespace shared_input {
// Raw WM_INPUT may be delivered after a newer hook down. Equal timestamps are
// ambiguous, so never let an old/same-tick release clear a newer physical hold.
inline bool InputAfter(uint32_t release, uint32_t down) {
  return static_cast<int32_t>(release - down) > 0;
}
class HookKeyState {
 public:
  bool Down(unsigned key) const { return key < pressed_.size() && pressed_[key]; }
  unsigned Count() const { return count_; }
  void Physical(unsigned key, bool down, uint32_t time) {
    if (key >= pressed_.size()) return;
    if (down && !pressed_[key]) recovered_up_[key] = false;
    if (pressed_[key] != down) { count_ = down ? count_ + 1 : count_ - 1; pressed_[key] = down; }
    if (down) down_at_[key] = time;
  }
  bool Route(unsigned key, bool down, bool capturing, bool local) {
    return routing_.Remote(key, down, capturing, local);
  }
  bool RemoteHeld(unsigned key) const { return routing_.RemoteHeld(key); }
  bool LocalHeld(unsigned key) const { return Down(key) && routing_.LocalHeld(key); }
  bool CanReconcileLocal(unsigned key, uint32_t now) const {
    return LocalHeld(key) && static_cast<int32_t>(now - down_at_[key]) >= 100;
  }
  bool RawRelease(unsigned key, uint32_t time, bool identified = false) {
    if (!Down(key) || !InputAfter(time, down_at_[key])) return false;
    recovered_up_[key] = routing_.RemoteHeld(key) || identified;
    Release(key); return true;
  }
  bool ConsumeRecoveredUp(unsigned key) {
    if (key >= recovered_up_.size()) return false;
    const bool result = recovered_up_[key]; recovered_up_[key] = false; return result;
  }
  void ReconcileLocalUp(unsigned key) { if (LocalHeld(key)) Release(key); }
  template<class IsDown>
  void ResetFromWindows(IsDown is_down, uint32_t time) {
    *this = {};
    for (unsigned key = 8; key < 255; ++key) if (is_down(key)) {
      Physical(key, true, time); Route(key, true, false, false);
    }
  }
 private:
  void Release(unsigned key) { pressed_[key] = false; --count_; routing_.Forget(key); }
  unsigned count_ = 0;
  std::array<bool, 256> pressed_{}, recovered_up_{};
  std::array<uint32_t, 256> down_at_{};
  KeyRouting routing_;
};
}  // namespace shared_input
#endif
