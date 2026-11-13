#ifndef SHARED_INPUT_BACKGROUND_HOOKS_H_
#define SHARED_INPUT_BACKGROUND_HOOKS_H_
#include <windows.h>
#include <cstdint>

#ifdef SHARED_INPUT_HOOKS_EXPORTS
#define SHARED_HOOK_API __declspec(dllexport)
#else
#define SHARED_HOOK_API __declspec(dllimport)
#endif

namespace shared_input {
extern "C" {
SHARED_HOOK_API bool SharedHooksInstall(HWND owner, UINT message, int key, bool shift);
SHARED_HOOK_API bool SharedHooksBegin();
SHARED_HOOK_API void SharedHooksRelease();
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
  bool Begin() { return SharedHooksBegin(); }
  void Release() { SharedHooksRelease(); }
  bool Blocking() const { return SharedHooksBlocking(); }
  bool HasHeld() const { return SharedHooksHasHeld(); }
  bool Observed() const { return SharedHooksObserved(); }
  bool MouseFresh(uint64_t now) const { return SharedHooksMouseFresh(now); }
  bool KeyboardFresh(uint64_t now) const { return SharedHooksKeyboardFresh(now); }
  void Close() { SharedHooksClose(); }
};
}  // namespace shared_input
#endif
