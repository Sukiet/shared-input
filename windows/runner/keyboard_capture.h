#ifndef SHARED_INPUT_KEYBOARD_CAPTURE_H_
#define SHARED_INPUT_KEYBOARD_CAPTURE_H_
#include <windows.h>

namespace shared_input {
// Foreground-only capture. Shell Win shortcuts must not preempt WM_INPUT;
// keeping this in Raw Input preserves the physical device handle for filtering.
inline bool RegisterKeyboard(HWND target, bool capture) {
  RAWINPUTDEVICE keyboard{0x01, 0x06,
      static_cast<DWORD>(RIDEV_DEVNOTIFY | (capture ? RIDEV_NOHOTKEYS : 0)), target};
  return RegisterRawInputDevices(&keyboard, 1, sizeof(keyboard)) != FALSE;
}

struct KeyboardScanCode {
  USHORT code;
  bool extended;
  int HeldId() const { return code | (extended ? RI_KEY_E0 << 16 : 0); }
};

inline KeyboardScanCode NormalizeKeyboardScanCode(const RAWKEYBOARD& input) {
  // These physical keys must reach the Mac as E0-5B/E0-5C, even if a device
  // omitted its make code or E0 prefix. The VKs already encode left/right.
  if (input.VKey == VK_LWIN) return {0x5b, true};
  if (input.VKey == VK_RWIN) return {0x5c, true};
  if (input.MakeCode) return {input.MakeCode, (input.Flags & RI_KEY_E0) != 0};
  const UINT mapped = MapVirtualKeyW(input.VKey, MAPVK_VK_TO_VSC_EX);
  return {static_cast<USHORT>(mapped & 0xff),
      (input.Flags & RI_KEY_E0) != 0 || (mapped & 0xff00) == 0xe000};
}
}  // namespace shared_input
#endif
