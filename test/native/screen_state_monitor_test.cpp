#include "../../windows/runner/screen_state_monitor.h"
#include <wtsapi32.h>
#include <cstdlib>
#include <iostream>

void Check(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}

int main() {
  const HWND owner = CreateWindowExW(0, L"STATIC", L"Screen state test", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandle(nullptr), nullptr);
  Check(owner != nullptr, "hidden message window created");
  {
    ScreenStateMonitor monitor(owner);
    Check(monitor.available(), "display notification registration available");
    struct DisplayNotification {
      GUID guid = {0x2b84c20e, 0xad23, 0x4ddf,
          {0x93, 0xdb, 0x05, 0xff, 0xbd, 0x7e, 0xfc, 0xa5}};
      DWORD length = sizeof(DWORD), value = 1;
    } notice;
    auto display = [&] { return monitor.Handle(WM_POWERBROADCAST, PBT_POWERSETTINGCHANGE,
        reinterpret_cast<LPARAM>(&notice)); };
    Check(!monitor.display_known, "waits for OS observation instead of assuming lit");
    Check(display() && monitor.display_on, "OS on notification enables awake policy");
    notice.value = 2;
    Check(!display() && monitor.display_on, "dim display still counts as on");
    notice.value = 0;
    Check(display() && !monitor.display_on, "off removes awake policy");
    notice.value = 7;
    Check(!display() && !monitor.display_on, "unknown display value ignored");
    notice.value = 1; notice.length = 0;
    Check(!display() && !monitor.display_on, "malformed length ignored");
    notice.length = sizeof(DWORD); display();
    monitor.locked = false;
    Check(monitor.Handle(WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0) && monitor.locked,
        "lock notification recorded without active mouse capture");
    const auto sequence = monitor.lock_sequence;
    monitor.Handle(WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0);
    Check(monitor.lock_sequence == sequence, "repeated lock notification is not a new lock");
    monitor.Handle(WM_WTSSESSION_CHANGE, WTS_SESSION_UNLOCK, 0);
    Check(!monitor.locked && monitor.lock_sequence == sequence, "unlock is only a local state update");
    monitor.Handle(WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0);
    Check(monitor.lock_sequence == sequence + 1, "next lock is distinguishable");
    monitor.Handle(WM_POWERBROADCAST, PBT_APMSUSPEND, 0);
    Check(monitor.suspended, "sleep removes awake policy");
    monitor.Handle(WM_POWERBROADCAST, PBT_APMRESUMEAUTOMATIC, 0);
    Check(!monitor.suspended && !monitor.display_known, "wake requests fresh OS display observation");
    display();
    monitor.Handle(WM_POWERBROADCAST, PBT_APMRESUMESUSPEND, 0);
    Check(monitor.display_known && monitor.display_on, "duplicate resume preserves fresh display observation");
    monitor.Handle(WM_WTSSESSION_CHANGE, WTS_CONSOLE_DISCONNECT, 0);
    Check(!monitor.session_active, "disconnected session cannot keep peer awake");
    monitor.Handle(WM_WTSSESSION_CHANGE, WTS_CONSOLE_CONNECT, 0);
    Check(monitor.session_active, "session reconnect restores observation");
  }
  DestroyWindow(owner);
  std::cout << "screen state monitor passed\n";
}
