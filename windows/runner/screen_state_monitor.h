#ifndef SHARED_INPUT_SCREEN_STATE_MONITOR_H_
#define SHARED_INPUT_SCREEN_STATE_MONITOR_H_
#include <windows.h>

// Receives OS notifications on the runner thread; never changes local power policy.
class ScreenStateMonitor {
 public:
  explicit ScreenStateMonitor(HWND owner);
  ~ScreenStateMonitor();
  bool Handle(UINT message, WPARAM wparam, LPARAM lparam);
  bool available() const { return notification_ != nullptr; }
  bool display_known = false, display_on = false;
  bool locked = false, suspended = false, session_active = true;
  unsigned lock_sequence = 0;
 private:
  HWND owner_;
  HPOWERNOTIFY notification_ = nullptr;
};
#endif
