#ifndef SHARED_INPUT_CAPTURE_IME_H_
#define SHARED_INPUT_CAPTURE_IME_H_
#include <windows.h>
#include <imm.h>
#include <optional>

namespace shared_input {
// Only the dedicated capture child is detached. The Flutter view keeps its
// context and the user's input language/open state are never changed.
inline bool DisableCaptureIme(HWND capture) {
  if (!capture || !ImmAssociateContextEx(capture, nullptr, 0)) return false;
  const HIMC context = ImmGetContext(capture);
  if (!context) return true;
  ImmReleaseContext(capture, context);
  return false;
}

inline std::optional<LRESULT> HandleCaptureImeMessage(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_IME_SETCONTEXT:
      // Keep default activation/cleanup, without candidate/composition UI.
      return DefWindowProcW(window, message, wparam, 0);
    case WM_INPUTLANGCHANGE: {
      const LRESULT result = DefWindowProcW(window, message, wparam, lparam);
      // Input language changes must not reattach an IME to this raw-key target.
      DisableCaptureIme(window);
      return result;
    }
    case WM_IME_STARTCOMPOSITION:
    case WM_IME_COMPOSITION:
    case WM_IME_ENDCOMPOSITION:
    case WM_IME_CHAR:
    case WM_IME_NOTIFY:
    case WM_IME_REQUEST:
    case WM_IME_KEYDOWN:
    case WM_IME_KEYUP:
      return 0;
    default:
      return std::nullopt;
  }
}
}  // namespace shared_input
#endif
