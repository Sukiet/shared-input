#include <windows.h>
#include <fstream>
#include <vector>
#include <thread>
#include "../../windows/runner/keyboard_capture.h"

namespace {
HWND owner = nullptr;
bool lost_focus = false;
bool flags_verified = false;
bool preserved = false;
bool released = false;
bool registration_reset = false;
int step = 0, raw_events = 0, raw_win_events = 0, raw_r_events = 0, win_events = 0, r_events = 0;
UINT sent_keys = 0;

bool Flags(bool capturing) {
  UINT count = 0;
  if (GetRegisteredRawInputDevices(nullptr, &count, sizeof(RAWINPUTDEVICE)) == UINT(-1)) return false;
  std::vector<RAWINPUTDEVICE> devices(count);
  const UINT size = GetRegisteredRawInputDevices(devices.data(), &count, sizeof(RAWINPUTDEVICE));
  if (size == UINT(-1)) return false;
  for (UINT i = 0; i < size; ++i) {
    const auto& d = devices[i];
    if (d.usUsagePage == 1 && d.usUsage == 6) {
      return d.hwndTarget == owner && ((d.dwFlags & RIDEV_NOHOTKEYS) != 0) == capturing &&
          !(d.dwFlags & RIDEV_INPUTSINK);
    }
  }
  return false;
}

void WinKey() {
  INPUT keys[6]{};
  const WORD virtual_keys[] = {VK_LWIN, VK_LWIN, VK_RWIN, 'R', 'R', VK_RWIN};
  const WORD scans[] = {0x5b, 0x5b, 0x5c, 0x13, 0x13, 0x5c};
  for (int i = 0; i < 6; ++i) {
    keys[i].type = INPUT_KEYBOARD;
    keys[i].ki.wVk = virtual_keys[i];
    keys[i].ki.wScan = scans[i];
    keys[i].ki.dwFlags = i == 3 || i == 4 ? 0 : KEYEVENTF_EXTENDEDKEY;
  }
  // Left Win alone, followed by right Win+R (must not open the Run dialog).
  keys[1].ki.dwFlags |= KEYEVENTF_KEYUP;
  keys[4].ki.dwFlags |= KEYEVENTF_KEYUP;
  keys[5].ki.dwFlags |= KEYEVENTF_KEYUP;
  sent_keys = SendInput(6, keys, sizeof(INPUT));
}

LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) lost_focus = true;
  if (message == WM_INPUT) {
    RAWINPUT input{};
    UINT size = sizeof(input);
    if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, &input, &size,
          sizeof(RAWINPUTHEADER)) != UINT(-1) && input.header.dwType == RIM_TYPEKEYBOARD) {
      ++raw_events;
      if (input.data.keyboard.VKey == VK_LWIN || input.data.keyboard.VKey == VK_RWIN) ++raw_win_events;
      if (input.data.keyboard.VKey == 'R') ++raw_r_events;
    }
    return DefWindowProc(window, message, wparam, lparam);
  }
  if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP) {
    if (wparam == VK_LWIN || wparam == VK_RWIN) ++win_events;
    if (wparam == 'R') ++r_events;
    return 0;
  }
  if (message == WM_TIMER) {
    if (step == 0) {
      if (GetForegroundWindow() != owner) {
        std::ofstream("build/win_key_capture_probe.txt") << "foreground_unavailable=1\n";
        shared_input::RegisterKeyboard(owner, false);
        DestroyWindow(owner);
        return 0;
      }
      flags_verified = Flags(true);
      lost_focus = false;
      WinKey();
      step = 1;
    } else {
      preserved = !lost_focus && GetForegroundWindow() == owner;
      released = !(GetAsyncKeyState(VK_LWIN) & 0x8000) && !(GetAsyncKeyState(VK_RWIN) & 0x8000);
      // Match watchdog cleanup: restore from a worker while the GUI is paused.
      std::thread reset_thread([] { shared_input::RegisterKeyboard(owner, false); });
      reset_thread.join();
      const bool reset = Flags(false);
      registration_reset = reset;
      std::ofstream out("build/win_key_capture_probe.txt");
      out << "flags_verified=" << flags_verified << "\nfocus_preserved=" << preserved
          << "\nwin_released=" << released << "\nregistration_reset=" << reset
          << "\nraw_events=" << raw_events << "\nwin_events=" << win_events << '\n';
      out << "sent_keys=" << sent_keys << "\nr_events=" << r_events << '\n';
      out << "raw_win_events=" << raw_win_events << "\nraw_r_events=" << raw_r_events << '\n';
      out.close();
      DestroyWindow(owner);
    }
    return 0;
  }
  if (message == WM_DESTROY && window == owner) { PostQuitMessage(0); return 0; }
  return DefWindowProc(window, message, wparam, lparam);
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  WNDCLASSW wc{};
  wc.hInstance = instance; wc.lpfnWndProc = Proc;
  wc.lpszClassName = L"SharedInputWinKeyProbe";
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&wc);
  owner = CreateWindowW(wc.lpszClassName, L"Shared Input - Win key check", WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, 400, 180, nullptr, nullptr, instance, nullptr);
  if (!owner || !shared_input::RegisterKeyboard(owner, true)) return 2;
  ShowWindow(owner, SW_SHOW);
  // Match production: a native child owns focus, its parent receives WM_INPUT.
  const HWND child = CreateWindowW(wc.lpszClassName, L"", WS_CHILD | WS_VISIBLE,
      20, 40, 1, 1, owner, nullptr, instance, nullptr);
  const DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  const bool attached = foreground_thread != GetCurrentThreadId() &&
      AttachThreadInput(GetCurrentThreadId(), foreground_thread, TRUE) != FALSE;
  BringWindowToTop(owner);
  SetForegroundWindow(owner);
  SetFocus(child);
  if (attached) AttachThreadInput(GetCurrentThreadId(), foreground_thread, FALSE);
  SetTimer(owner, 1, 500, nullptr);
  MSG message{};
  while (GetMessage(&message, nullptr, 0, 0)) {
    TranslateMessage(&message); DispatchMessage(&message);
  }
  return flags_verified && preserved && released && registration_reset && sent_keys == 6 &&
      raw_win_events == 4 && raw_r_events == 2 ? 0 : 1;
}
