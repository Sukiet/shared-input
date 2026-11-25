#ifndef SHARED_INPUT_KEY_ROUTING_H_
#define SHARED_INPUT_KEY_ROUTING_H_
#include <array>

namespace shared_input {
inline bool ValidLocalKey(unsigned key) {
  return key >= 8 && key < 255 && key != 0xe5 && key != 0xe7;
}
// Hook-thread only. Ownership is selected on the first down and retained for
// repeats/up, even if capture ends or preferences change while a key is held.
class KeyRouting {
 public:
  bool Remote(unsigned key, bool down, bool capturing, bool local) {
    if (key >= held_.size()) return false;
    const bool remote = held_[key] ? remote_[key] : capturing && !local;
    held_[key] = down;
    remote_[key] = down && remote;
    return remote;
  }
  void Reset() { held_.fill(false); remote_.fill(false); }
  bool LocalHeld(unsigned key) const { return key < held_.size() && held_[key] && !remote_[key]; }
  bool RemoteHeld(unsigned key) const { return key < held_.size() && remote_[key]; }
  void Forget(unsigned key) { if (key < held_.size()) { held_[key] = false; remote_[key] = false; } }
 private:
  std::array<bool, 256> held_{}, remote_{};
};
}  // namespace shared_input
#endif
