#ifndef SHARED_INPUT_BACKGROUND_HOOKS_H_
#define SHARED_INPUT_BACKGROUND_HOOKS_H_
#include <windows.h>
#include <cstdint>
#include "control_release.h"

#ifdef SHARED_INPUT_HOOKS_EXPORTS
#define SHARED_HOOK_API __declspec(dllexport)
#else
#define SHARED_HOOK_API __declspec(dllimport)
#endif

namespace shared_input {
extern "C" {
SHARED_HOOK_API bool SharedHooksInstall(HWND owner, UINT message, int key, bool shift);
SHARED_HOOK_API bool SharedHooksBegin(uint32_t generation, uint32_t local_buttons = 0);
SHARED_HOOK_API bool SharedHooksHasRemoteHeld(bool ignore_mouse = false);
SHARED_HOOK_API unsigned SharedHooksPhysicalButtons();
SHARED_HOOK_API bool SharedHooksSetLocalKeys(const int* keys, unsigned count);
SHARED_HOOK_API void SharedHooksIdentifyKey(uint32_t token);
SHARED_HOOK_API void SharedHooksObserveDrag(uint32_t token);
SHARED_HOOK_API void SharedHooksRelease();
SHARED_HOOK_API void SharedHooksResetRelease(uint32_t generation);
SHARED_HOOK_API void SharedHooksReleaseFor(uint32_t generation, ReleaseCause cause);
SHARED_HOOK_API ReleaseCause SharedHooksReleaseReason(uint32_t generation);
SHARED_HOOK_API uint64_t SharedHooksMouseSeen();
SHARED_HOOK_API uint64_t SharedHooksKeyboardSeen();
SHARED_HOOK_API uint64_t SharedHooksPumpSeen();
SHARED_HOOK_API bool SharedHooksHealthy(uint64_t now);
SHARED_HOOK_API bool SharedHooksBlocking();
SHARED_HOOK_API bool SharedHooksHasHeld();
SHARED_HOOK_API bool SharedHooksObserved();
SHARED_HOOK_API bool SharedHooksMouseFresh(uint64_t now);
SHARED_HOOK_API bool SharedHooksKeyboardFresh(uint64_t now);
SHARED_HOOK_API void SharedHooksClose();
}

// One controller per process. The DLL owns the callbacks and a dedicated native pump;
// this facade never exposes STL objects across the DLL boundary.
class BackgroundHooks {
 public:
  ~BackgroundHooks() { Close(); }
  bool Install(HWND owner, UINT message, int key, bool shift) { return SharedHooksInstall(owner, message, key, shift); }
  bool Begin(uint32_t generation = 0, uint32_t local_buttons = 0) { return SharedHooksBegin(generation, local_buttons); }
  bool HasRemoteHeld(bool ignore_mouse = false) const { return SharedHooksHasRemoteHeld(ignore_mouse); }
  unsigned PhysicalButtons() const { return SharedHooksPhysicalButtons(); }
  bool SetLocalKeys(const int* keys, unsigned count) { return SharedHooksSetLocalKeys(keys, count); }
  void IdentifyKey(uint32_t token) { SharedHooksIdentifyKey(token); }
  void ObserveDrag(uint32_t token) { SharedHooksObserveDrag(token); }
  void Release() { SharedHooksRelease(); }
  void ResetRelease(uint32_t generation) { SharedHooksResetRelease(generation); }
  void ReleaseFor(uint32_t generation, ReleaseCause cause) { SharedHooksReleaseFor(generation, cause); }
  ReleaseCause ReleaseReason(uint32_t generation) const { return SharedHooksReleaseReason(generation); }
  uint64_t MouseSeen() const { return SharedHooksMouseSeen(); }
  uint64_t KeyboardSeen() const { return SharedHooksKeyboardSeen(); }
  uint64_t PumpSeen() const { return SharedHooksPumpSeen(); }
  bool Healthy(uint64_t now) const { return SharedHooksHealthy(now); }
  bool Blocking() const { return SharedHooksBlocking(); }
  bool HasHeld() const { return SharedHooksHasHeld(); }
  bool Observed() const { return SharedHooksObserved(); }
  bool MouseFresh(uint64_t now) const { return SharedHooksMouseFresh(now); }
  bool KeyboardFresh(uint64_t now) const { return SharedHooksKeyboardFresh(now); }
  void Close() { SharedHooksClose(); }
};
}  // namespace shared_input
#endif
