#include <windows.h>
#include <iostream>
#include <thread>
#include <chrono>
#include "../../windows/runner/background_hooks.h"

namespace {
shared_input::BackgroundHooks* observed_hooks = nullptr;
unsigned raw_moves = 0;
LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_INPUT && observed_hooks) {
    RAWINPUT raw{}; UINT bytes = sizeof(raw);
    if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, &raw,
        &bytes, sizeof(RAWINPUTHEADER)) != UINT(-1) && raw.header.dwType == RIM_TYPEMOUSE) {
      ++raw_moves;
      observed_hooks->RawMouse(raw.data.mouse.usButtonFlags, static_cast<uint32_t>(GetMessageTime()));
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
void Pump(DWORD milliseconds) {
  const auto until = GetTickCount64() + milliseconds;
  while (GetTickCount64() < until) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    Sleep(2);
  }
}
}

// Optional desktop diagnostic, not CTest: two opposite one-pixel moves and an
// intercepted F24 pair, no foreground change or cursor displacement.
int main() {
  WNDCLASSW wc{}; wc.lpfnWndProc = Proc; wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"SharedInputHookRecoveryProbe"; RegisterClassW(&wc);
  HWND owner = CreateWindowExW(0, wc.lpszClassName, L"HookAsyncStateProbe", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  shared_input::BackgroundHooks hooks;
  observed_hooks = &hooks;
  if (!owner || !hooks.Install(owner, WM_APP + 1, VK_F8, false)) return 1;
  RAWINPUTDEVICE device{1, 2, RIDEV_INPUTSINK, owner};
  if (!RegisterRawInputDevices(&device, 1, sizeof(device))) return 1;
  INPUT warm[2]{};
  for (auto& event : warm) { event.type = INPUT_MOUSE; event.mi.dwFlags = MOUSEEVENTF_MOVE; }
  warm[0].mi.dx = 1; warm[1].mi.dx = -1;
  const auto warmed = SendInput(2, warm, sizeof(INPUT));
  Sleep(150);
  if (!hooks.Begin(1)) {
    std::cout << "capture_not_ready observed=" << hooks.Observed() << " held=" << hooks.HasHeld()
        << " warmed=" << warmed << " pump=" << hooks.PumpSeen() << '\n'; return 2;
  }
  std::thread failsafe([&] { Sleep(1000); hooks.Release(); });
  INPUT key{}; key.type = INPUT_KEYBOARD; key.ki.wVk = VK_F24;
  const bool sent_down = SendInput(1, &key, sizeof(key)) == 1;
  Sleep(75);
  const bool tracked_down = hooks.HasHeld();
  const bool async_down = (GetAsyncKeyState(VK_F24) & 0x8000) != 0;
  key.ki.dwFlags = KEYEVENTF_KEYUP;
  const bool sent_up = SendInput(1, &key, sizeof(key)) == 1;
  Sleep(75);
  const bool tracked_up = !hooks.HasHeld();
  hooks.Release(); failsafe.join();
#ifdef SHARED_INPUT_HOOK_TESTING
  shared_input::SharedHooksTestFault(1); // stale local down + silently removed hooks
  const bool recovered_stale = hooks.Prepare() && !hooks.HasHeld();
  shared_input::SharedHooksTestFault(2); // remote held key has no Windows async down
  const bool kept_remote_hold = hooks.Prepare() && hooks.HasHeld();
  hooks.RawKey(VK_F24, true, GetTickCount());
  Sleep(75);
  const bool raw_recovered = hooks.Prepare() && !hooks.HasHeld();
  const bool reset_after_sleep = hooks.Prepare(true) && !hooks.HasHeld();
  shared_input::SharedHooksTestFault(4); // remove mouse hook without updating bookkeeping
  Pump(1100); // previous keyboard repair uses the shared one-second retry limit
  // SendInput reaches LL hooks but does not create a hardware WM_INPUT packet.
  // Model that raw observation at the same production entry point, then prove
  // real callbacks resume without Prepare/Begin or restarting the process.
  hooks.RawMouse(0, GetTickCount()); Pump(150);
  SendInput(2, warm, sizeof(INPUT)); Pump(100);
  const bool automatic_repair = hooks.MouseFresh(GetTickCount64());
  shared_input::SharedHooksTestFault(3); // worker resumes after caller's deadline
  const auto started = std::chrono::steady_clock::now();
  const bool timeout_rejected = !hooks.Begin(2);
  const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started).count();
  Sleep(250);
  const bool late_start_rejected = !hooks.Blocking();
  std::cout << "stale_state_and_removed_hooks_recovered=" << recovered_stale
      << " remote_hold_preserved=" << kept_remote_hold << " raw_up_recovered=" << raw_recovered
      << " resume_reset=" << reset_after_sleep << " bounded_wait=" << (waited < 350)
      << " raw_triggered_hook_repair=" << automatic_repair
      << " cancelled_late_begin=" << (timeout_rejected && late_start_rejected) << '\n';
  const bool recovery_passed = recovered_stale && kept_remote_hold && raw_recovered &&
      reset_after_sleep && automatic_repair && waited < 350 && timeout_rejected && late_start_rejected;
#else
  const bool recovery_passed = true;
#endif
  device.dwFlags = RIDEV_REMOVE; device.hwndTarget = nullptr;
  RegisterRawInputDevices(&device, 1, sizeof(device));
  observed_hooks = nullptr; hooks.Close(); DestroyWindow(owner);
  std::cout << "sent_down=" << sent_down << " tracked_down=" << tracked_down
      << " async_down_while_intercepted=" << async_down << " sent_up=" << sent_up
      << " tracked_up=" << tracked_up << '\n';
  return sent_down && tracked_down && sent_up && tracked_up && recovery_passed ? 0 : 3;
}
