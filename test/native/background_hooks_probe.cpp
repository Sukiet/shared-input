#include <windows.h>
#include <fstream>
#include <thread>
#include "../../windows/runner/background_hooks.h"

namespace {
constexpr UINT kStop = WM_APP + 1;
shared_input::BackgroundHooks hooks;
HWND owner = nullptr, front = nullptr;
int key_events = 0, raw_moves = 0, legacy_keys = 0, legacy_clicks = 0, exits = 0, step = 0, warming = 0;
bool installed = false, captured = false, blocked = false, exited = false, restored = false;
POINT parked{}, original{};
POINT checked{};
int blocked_key_count = 0, blocked_click_count = 0;
std::thread sender;
void Key(WORD key, bool up = false) {
  INPUT input{}; input.type = INPUT_KEYBOARD; input.ki.wVk = key;
  input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(key, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
  SendInput(1, &input, sizeof(input));
}
LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_INPUT) {
    RAWINPUT input{}; UINT bytes = sizeof(input);
    if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, &input,
          &bytes, sizeof(RAWINPUTHEADER)) != UINT(-1) && input.header.dwType == RIM_TYPEMOUSE) ++raw_moves;
    return DefWindowProcW(window, message, wparam, lparam);
  }
  if (window == front && (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
    ++legacy_keys; return 0;
  }
  if (window == front && message == WM_LBUTTONDOWN) { ++legacy_clicks; return 0; }
  if (message == kStop) { ++exits; return 0; }
  if (message == kStop + 1) { ++key_events; return 0; }
  if (message == WM_TIMER) {
    if (step == 0 && !hooks.Observed() && warming++ < 5) {
      sender.join();
      sender = std::thread([] { Sleep(50); Key('B'); Key('B', true); });
      return 0;
    }
    if (step++ == 0) {
      sender.join(); key_events = raw_moves = legacy_keys = legacy_clicks = 0;
      installed = GetForegroundWindow() == front && hooks.Begin();
      GetCursorPos(&parked);
      sender = std::thread([] {
        Sleep(50); Key('B'); Key('B', true);
        INPUT mouse[3]{};
        for (auto& input : mouse) input.type = INPUT_MOUSE;
        mouse[0].mi.dx = -20; mouse[0].mi.dy = 10; mouse[0].mi.dwFlags = MOUSEEVENTF_MOVE;
        mouse[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN; mouse[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        SendInput(3, mouse, sizeof(INPUT));
      });
    } else if (step == 2) {
      sender.join();
      POINT position{}; GetCursorPos(&position);
      checked = position; blocked_key_count = legacy_keys; blocked_click_count = legacy_clicks;
      captured = key_events >= 2 && raw_moves >= 1;
      blocked = legacy_keys == 0 && legacy_clicks == 0 && GetForegroundWindow() == front &&
          position.x == parked.x && position.y == parked.y;
      sender = std::thread([] {
        Sleep(50); Key(VK_LCONTROL); Key(VK_LMENU); Key(VK_F8);
        Key(VK_F8, true); Key(VK_LMENU, true); Key(VK_LCONTROL, true);
      });
    } else if (step == 3) {
      sender.join();
      exited = exits == 1 && !hooks.Blocking() && !hooks.HasHeld();
      // Match watchdog release while the UI does not participate in cleanup.
      const bool restarted = hooks.Begin();
      std::thread release([] { hooks.Release(); }); release.join();
      restored = restarted && !hooks.Blocking();
      legacy_keys = 0;
      sender = std::thread([] { Sleep(50); Key('B'); Key('B', true); });
    } else {
      sender.join(); restored = restored && legacy_keys > 0;
      hooks.Close(); SetCursorPos(original.x, original.y);
      std::ofstream out("build/background_hooks_probe.txt");
      out << "installed=" << installed << "\ninput_captured=" << captured << "\nlocal_input_blocked=" << blocked
          << "\nshortcut_exit=" << exited << "\nwatchdog_release=" << restored
          << "\nkey_events=" << key_events << "\nraw_mouse_events=" << raw_moves << '\n';
      out << "blocked_key_count=" << blocked_key_count << "\nblocked_click_count=" << blocked_click_count
          << "\ncursor_dx=" << checked.x - parked.x << "\ncursor_dy=" << checked.y - parked.y << '\n';
      DestroyWindow(front); DestroyWindow(owner); PostQuitMessage(0);
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  GetCursorPos(&original);
  WNDCLASSW wc{}; wc.hInstance = instance; wc.lpfnWndProc = Proc;
  wc.lpszClassName = L"SharedInputBackgroundProbe";
  RegisterClassW(&wc);
  owner = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPED, 0, 0, 100, 100,
      nullptr, nullptr, instance, nullptr);
  front = CreateWindowW(wc.lpszClassName, L"Shared Input background check", WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, 400, 180, nullptr, nullptr, instance, nullptr);
  // Background keys use the hook, mouse motion retains unaccelerated Raw Input.
  RAWINPUTDEVICE mouse{1, 2, RIDEV_INPUTSINK, owner};
  if (!RegisterRawInputDevices(&mouse, 1, sizeof(mouse)) || !hooks.Install(owner, kStop, VK_F8, false)) return 2;
  ShowWindow(front, SW_SHOW);
  const DWORD foreground = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  const bool attached = foreground != GetCurrentThreadId() &&
      AttachThreadInput(GetCurrentThreadId(), foreground, TRUE) != FALSE;
  SetForegroundWindow(front); SetFocus(front);
  RECT client{}; GetClientRect(front, &client);
  POINT center{client.right / 2, client.bottom / 2}; ClientToScreen(front, &center);
  SetCursorPos(center.x, center.y);
  if (attached) AttachThreadInput(GetCurrentThreadId(), foreground, FALSE);
  sender = std::thread([] { Sleep(50); Key('B'); Key('B', true); });
  SetTimer(owner, 1, 200, nullptr);
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
  return installed && captured && blocked && exited && restored ? 0 : 1;
}
