#include "../../windows/runner/capture_ime.h"
#include <cstdlib>
#include <iostream>

namespace {
void Check(bool condition, const char* description) {
  if (!condition) { std::cerr << description << '\n'; std::exit(1); }
}

HIMC Context(HWND window) {
  const HIMC context = ImmGetContext(window);
  if (context) ImmReleaseContext(window, context);
  return context;
}

LRESULT CALLBACK CaptureProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  const auto result = shared_input::HandleCaptureImeMessage(window, message, wparam, lparam);
  return result ? *result : DefWindowProcW(window, message, wparam, lparam);
}
}

int main() {
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = CaptureProc;
  wc.hInstance = instance;
  wc.lpszClassName = L"SharedInputCaptureImeTest";
  Check(RegisterClassW(&wc) != 0, "register test window");
  // Hidden windows exercise real IMM associations without taking user focus.
  const HWND owner = CreateWindowW(L"STATIC", L"", WS_OVERLAPPED, 0, 0, 10, 10,
      nullptr, nullptr, instance, nullptr);
  const HWND view = CreateWindowW(L"EDIT", L"", WS_CHILD, 0, 0, 1, 1,
      owner, nullptr, instance, nullptr);
  const HWND capture = CreateWindowW(wc.lpszClassName, L"", WS_CHILD, 0, 0, 1, 1,
      owner, nullptr, instance, nullptr);
  Check(owner && view && capture, "create isolated test windows");
  const HIMC view_context = ImmCreateContext();
  const HIMC capture_context = ImmCreateContext();
  Check(view_context && capture_context, "create IME contexts");
  const HIMC previous_view = ImmAssociateContext(view, view_context);
  const HIMC previous_capture = ImmAssociateContext(capture, capture_context);
  const HIMC owner_context = Context(owner);
  const HKL language = GetKeyboardLayout(0);
  const BOOL open = ImmGetOpenStatus(view_context);
  Check(Context(capture) == capture_context, "test capture begins IME-enabled");
  Check(shared_input::DisableCaptureIme(capture), "disable capture IME");
  Check(Context(capture) == nullptr, "capture no longer has an IME context");
  Check(Context(view) == view_context && Context(owner) == owner_context,
      "Flutter view and owner contexts remain unchanged");
  Check(ImmGetOpenStatus(view_context) == open && GetKeyboardLayout(0) == language,
      "user input language and IME open state remain unchanged");

  // A later language change must detach even an externally reattached context.
  ImmAssociateContext(capture, capture_context);
  SendMessageW(capture, WM_INPUTLANGCHANGE, 0, reinterpret_cast<LPARAM>(language));
  Check(Context(capture) == nullptr, "input language changes keep capture IME-disabled");
  Check(shared_input::DisableCaptureIme(capture), "repeated capture starts are safe");
  Check(Context(view) == view_context, "view still supports IME after repeated captures");
  Check(!shared_input::DisableCaptureIme(nullptr), "invalid capture cannot silently succeed");

  ImmAssociateContext(capture, previous_capture);
  ImmAssociateContext(view, previous_view);
  Check(ImmDestroyContext(capture_context) && ImmDestroyContext(view_context), "release test contexts");
  DestroyWindow(owner);
  UnregisterClassW(wc.lpszClassName, instance);
  std::cout << "Capture IME isolation passed.\n";
}
