#include "screen_state_monitor.h"
#include <wtsapi32.h>
#include <cstring>

namespace {
// GUID_SESSION_DISPLAY_STATUS, scoped to this interactive session.
constexpr GUID kSessionDisplay = {0x2b84c20e, 0xad23, 0x4ddf,
    {0x93, 0xdb, 0x05, 0xff, 0xbd, 0x7e, 0xfc, 0xa5}};
}

ScreenStateMonitor::ScreenStateMonitor(HWND owner) : owner_(owner) {
  notification_ = RegisterPowerSettingNotification(owner, &kSessionDisplay, DEVICE_NOTIFY_WINDOW_HANDLE);
  LPWSTR buffer = nullptr;
  DWORD bytes = 0;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION,
      WTSSessionInfoEx, &buffer, &bytes)) {
    if (bytes >= sizeof(WTSINFOEXW)) {
      const auto info = reinterpret_cast<const WTSINFOEXW*>(buffer);
      if (info->Level == 1) {
        locked = info->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
        session_active = info->Data.WTSInfoExLevel1.SessionState == WTSActive;
      }
    }
    WTSFreeMemory(buffer);
  }
}

ScreenStateMonitor::~ScreenStateMonitor() {
  if (notification_) UnregisterPowerSettingNotification(notification_);
}

bool ScreenStateMonitor::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_POWERSETTINGCHANGE && lparam) {
      const auto setting = reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
      if (!IsEqualGUID(setting->PowerSetting, kSessionDisplay) || setting->DataLength != sizeof(DWORD)) return false;
      DWORD value = 0;
      std::memcpy(&value, setting->Data, sizeof(value));
      if (value > 2) return false;
      const bool changed = !display_known || display_on != (value != 0);
      display_known = true; display_on = value != 0; // Dim still counts as on.
      return changed;
    }
    if (wparam == PBT_APMSUSPEND) { suspended = true; return true; }
    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
      if (suspended) {
        suspended = false;
        // A new registration delivers the current display state even if it did
        // not change during sleep. Do this only once across duplicate resumes.
        display_known = false; display_on = false;
        if (notification_) UnregisterPowerSettingNotification(notification_);
        notification_ = RegisterPowerSettingNotification(owner_, &kSessionDisplay, DEVICE_NOTIFY_WINDOW_HANDLE);
      }
      return true;
    }
  }
  if (message == WM_WTSSESSION_CHANGE) {
    switch (wparam) {
      case WTS_SESSION_LOCK:
        if (!locked) ++lock_sequence;
        locked = true; return true;
      case WTS_SESSION_UNLOCK: locked = false; return true;
      case WTS_CONSOLE_DISCONNECT:
      case WTS_REMOTE_DISCONNECT:
      case WTS_SESSION_LOGOFF: session_active = false; return true;
      case WTS_CONSOLE_CONNECT:
      case WTS_REMOTE_CONNECT: session_active = true; return true;
    }
  }
  return false;
}
