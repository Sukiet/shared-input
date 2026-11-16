#ifndef SHARED_INPUT_SAFETY_POLICY_H_
#define SHARED_INPUT_SAFETY_POLICY_H_
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

}  // namespace shared_input
#endif
