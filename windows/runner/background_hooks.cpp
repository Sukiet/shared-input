#include "background_hooks.h"
#include "key_routing.h"
#include "drag_gesture.h"
#include "drag_handoff.h"
#include "mouse_routing.h"
#include "hook_key_state.h"
#include <array>
#include <atomic>
#include <future>
#include <chrono>
#include <memory>
#include <thread>

namespace shared_input {
// Hooks use a dedicated native message loop. Never call Dart, IMM, or the
// network from a hook. The independent watchdog releases input atomically.
class HookRuntime {
  struct Request {
    std::promise<bool> result;
    std::atomic<bool> cancelled{false};
    bool begin = false, reset = false;
    unsigned local_buttons = 0, remote_buttons = 0;
  };
 public:
  ~HookRuntime() { Close(); }
  bool Install(HWND owner, UINT stop_message, int key, bool shift) {
    key_ = key; shift_ = shift;
    if (thread_.joinable() && running_.load()) return true;
    if (thread_.joinable()) Close();
    owner_ = owner; stop_message_ = stop_message;
    std::promise<bool> ready;
    auto result = ready.get_future();
    thread_ = std::thread([this, ready = std::move(ready)]() mutable {
      current_ = this;
      MSG message{};
      PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
      thread_id_ = GetCurrentThreadId();
      const bool hooks_installed = RefreshHooks();
      if (hooks_installed) ReconcileInput(true);
      const UINT_PTR pump_timer = hooks_installed ? SetTimer(nullptr, 0, 50, nullptr) : 0;
      const bool installed = hooks_installed && pump_timer;
      running_ = installed;
      pump_seen_ = GetTickCount64();
      ready.set_value(installed);
      if (installed) {
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
#ifdef SHARED_INPUT_HOOK_TESTING
          if (message.message == kTestMessage) {
            if (message.wParam == 1 || message.wParam == 2) {
              keys_.Physical(VK_F24, true, GetTickCount() - 500);
              keys_.Route(VK_F24, true, message.wParam == 2, false);
              held_ = static_cast<int>(keys_.Count());
            }
            if (message.wParam == 1) {
              if (keyboard_) UnhookWindowsHookEx(keyboard_);
              if (mouse_) UnhookWindowsHookEx(mouse_);
              keyboard_ = mouse_ = nullptr;
            }
            if (message.wParam == 3) Sleep(400);
            if (message.wParam == 4 && mouse_) { UnhookWindowsHookEx(mouse_); mouse_ = nullptr; }
            continue;
          }
#endif
          if (message.message == kBeginMessage) {
            std::unique_ptr<std::shared_ptr<Request>> posted(reinterpret_cast<std::shared_ptr<Request>*>(message.lParam));
            auto request = *posted;
            // Repair first. A stale cached down must not prevent the very
            // hook refresh needed to receive its eventual release.
            bool allowed = !request->cancelled && !Blocking() &&
                RefreshHooks() && ReconcileInput(request->reset);
            if (request->begin) allowed = allowed && CanBeginWithLocalButtons(
                held_.load() != 0, buttons_.load(), request->local_buttons | request->remote_buttons);
            if (allowed && request->begin && !request->cancelled) {
              local_buttons_ = request->local_buttons;
              mouse_routing_.TransferToLocal(request->local_buttons);
              mouse_routing_.TransferToRemote(request->remote_buttons);
              pump_seen_ = GetTickCount64();
              release_.Begin(static_cast<uint32_t>(message.wParam), true);
            }
            if (request->begin && request->cancelled) {
              ReleaseFor(static_cast<uint32_t>(message.wParam), ReleaseCause::hook_thread_timeout);
            }
            request->result.set_value(allowed && !request->cancelled.load());
            continue;
          }
          if (message.message == kRawKeyMessage) {
            const unsigned key = static_cast<unsigned>(message.wParam >> 1);
            if ((message.wParam & 1) && key < 256) {
              const bool remote = keys_.RemoteHeld(key);
              if (keys_.RawRelease(key, static_cast<uint32_t>(message.lParam), identify_drain_[key])) {
                identify_drain_[key] = false; held_ = static_cast<int>(keys_.Count());
                if (remote && Blocking() && key != VK_PACKET) {
                  if (!PostMessageW(owner_, stop_message_ + 1, key, key_scan_[key])) {
                    ReleaseFor(release_.Generation(), ReleaseCause::hook_queue_failed);
                  }
                }
              }
            }
            continue;
          }
          if (message.message == kRawMouseMessage) {
            for (unsigned button = 0; button < 5; ++button) {
              const unsigned mask = 1u << button;
              if ((message.wParam & (2u << (button * 2))) && (buttons_.load() & mask) &&
                  InputAfter(static_cast<uint32_t>(message.lParam), mouse_down_at_[button])) {
                const bool local = (local_buttons_.load() & mask) != 0;
                if (mouse_routing_.Forget(button) && !local) recovered_mouse_up_ |= mask;
                buttons_.fetch_and(~mask); local_buttons_.fetch_and(~mask);
                drag_gesture_.ReconcileButtons(~mask);
              }
            }
            NotifyDrag();
            continue;
          }
          if (message.message == kRepairMessage) {
            const auto now = GetTickCount64();
            if ((message.wParam ? KeyboardFresh(now) : MouseFresh(now))) continue;
            if (Blocking()) {
              const auto generation = release_.Generation();
              ReleaseFor(generation, ReleaseCause::hook_lost);
              PostMessageW(owner_, stop_message_, 1, generation);
            }
            if (RefreshHooks()) ReconcileInput(false);
            continue;
          }
          if (message.message == WM_TIMER && message.wParam == pump_timer) {
            RecordPump();
            continue;
          }
          TranslateMessage(&message); DispatchMessageW(&message);
        }
      }
      if (pump_timer) KillTimer(nullptr, pump_timer);
      if (keyboard_) UnhookWindowsHookEx(keyboard_);
      if (mouse_) UnhookWindowsHookEx(mouse_);
      keyboard_ = mouse_ = nullptr;
      installed_ = running_ = false;
      current_ = nullptr;
    });
    if (result.get()) return true;
    thread_.join();
    return false;
  }

  bool Begin(uint32_t generation, unsigned local_buttons, unsigned remote_buttons) {
    return Execute(true, generation, local_buttons, false, remote_buttons);
  }
  bool Prepare(bool reset_state) {
    if (reset_state) reset_requested_ = true;
    return Execute(false, 0, 0, reset_state);
  }
  bool Installed() const { return installed_.load() && running_.load(); }
#ifdef SHARED_INPUT_HOOK_TESTING
  bool TestFault(unsigned mode) { return running_.load() && PostThreadMessageW(thread_id_, kTestMessage, mode, 0); }
#endif
  void RawKey(unsigned key, bool up, uint32_t time) {
    if (!running_.load() || key >= 255) return;
    PostThreadMessageW(thread_id_, kRawKeyMessage, (key << 1) | (up ? 1 : 0), time);
    RequestRepair(true);
  }
  void RawMouse(unsigned flags, uint32_t time) {
    if (!running_.load()) return;
    if (flags & 0x2aa) PostThreadMessageW(thread_id_, kRawMouseMessage, flags, time);
    RequestRepair(false);
  }
  void ResetRelease(uint32_t generation) { release_.Begin(generation); }
  bool SetLocalKeys(const int* keys, unsigned count) {
    if (Blocking() || count > 254 || (count && !keys)) return false;
    std::array<bool, 256> next{};
    for (unsigned i = 0; i < count; ++i) {
      if (!ValidLocalKey(static_cast<unsigned>(keys[i]))) return false;
      next[keys[i]] = true;
    }
    for (size_t i = 0; i < next.size(); ++i) local_keys_[i] = next[i];
    return true;
  }
  void IdentifyKey(uint32_t token) { identify_ = token; }
  void ObserveDrag(uint32_t token) {
    const auto x = GetSystemMetrics(SM_CXDRAG), y = GetSystemMetrics(SM_CYDRAG);
    drag_threshold_x_ = x > 0 ? x : 4;
    drag_threshold_y_ = y > 0 ? y : 4;
    drag_observer_ = token;
  }
  void ReleaseFor(uint32_t generation, ReleaseCause cause) {
    // One CAS preserves the first cause, unblocks, and rejects old generations.
    release_.Record(generation, cause);
  }
  void Release() { ReleaseFor(release_.Generation(), ReleaseCause::manual); }
  ReleaseCause ReleaseReason(uint32_t generation) const { return release_.Reason(generation); }
  uint64_t MouseSeen() const { return mouse_seen_.load(); }
  uint64_t KeyboardSeen() const { return keyboard_seen_.load(); }
  uint64_t PumpSeen() const { return pump_seen_.load(); }
  bool Healthy(uint64_t now) const { return HookPumpFresh(now, PumpSeen(), MouseSeen(), KeyboardSeen()); }
  void RecordPump() {
    const auto now = GetTickCount64();
    const auto ownership = release_.CurrentOwnership();
    // If the pump resumes after an actual stall, retain the failure rather than
    // making a late heartbeat conceal it before the independent watchdog runs.
    if (ownership.blocking && !Healthy(now)) {
      ReleaseFor(ownership.generation, ReleaseCause::hook_thread_timeout);
      PostMessageW(owner_, stop_message_, 1, ownership.generation);
    }
    pump_seen_ = now;
    if (held_.load() != 0 || buttons_.load() != 0 || needs_reset_ || reset_requested_) ReconcileInput(false);
  }
  bool Blocking() const { return release_.Blocking(); }
  bool HasHeld() const { return held_.load() != 0 || buttons_.load() != 0; }
  bool HasRemoteHeld(bool ignore_mouse) const { return held_.load() != 0 ||
      (!ignore_mouse && (buttons_.load() & ~local_buttons_.load()) != 0); }
  unsigned PhysicalButtons() const { return buttons_.load(); }
  bool Observed() const { return mouse_seen_.load() != 0 || keyboard_seen_.load() != 0; }
  bool MouseFresh(uint64_t now) const { return HookFresh(now, MouseSeen()); }
  bool KeyboardFresh(uint64_t now) const { return HookFresh(now, KeyboardSeen()); }
  void Close() {
    Release();
    if (thread_.joinable()) {
      PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
      thread_.join();
    }
    held_ = 0;
    buttons_ = 0;
    local_buttons_ = 0;
    mouse_seen_ = keyboard_seen_ = 0;
    pump_seen_ = 0;
    keys_ = {}; identify_drain_.fill(false); key_scan_.fill(0); identify_ = 0; mouse_routing_ = {};
    mouse_down_at_.fill(0); recovered_mouse_up_ = 0; needs_reset_ = false;
    last_repair_request_ = 0;
    reset_requested_ = false;
    drag_observer_ = 0; drag_observed_ = 0; drag_gesture_ = DragGesture(); drag_notified_ = false;
  }
 public:
  static LRESULT CALLBACK Keyboard(int code, WPARAM message, LPARAM data) {
    auto self = current_.load();
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    self->keyboard_seen_ = GetTickCount64();
    const auto ownership = self->release_.CurrentOwnership();
    const auto& input = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    const unsigned key = input.vkCode;
    if (key >= 255) return CallNextHookEx(nullptr, code, message, data);
    if (key < VK_BACK || key == VK_PACKET || key == VK_PROCESSKEY) {
      return ownership.blocking ? 1 : CallNextHookEx(nullptr, code, message, data);
    }
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    const bool was_down = self->keys_.Down(key);
    const bool recovered_up = !down && self->keys_.ConsumeRecoveredUp(key);
    self->keys_.Physical(key, down, input.time);
    self->held_ = static_cast<int>(self->keys_.Count());
    if (down) self->key_scan_[key] = static_cast<LPARAM>((input.scanCode & 0xff) |
        ((input.flags & LLKHF_EXTENDED) ? 0x100 : 0));
    const bool shortcut = ownership.blocking && down && key == static_cast<unsigned>(self->key_.load()) &&
        (self->keys_.Down(VK_LCONTROL) || self->keys_.Down(VK_RCONTROL)) &&
        (self->keys_.Down(VK_LMENU) || self->keys_.Down(VK_RMENU)) &&
        ((self->keys_.Down(VK_LSHIFT) || self->keys_.Down(VK_RSHIFT)) == self->shift_) &&
        !self->keys_.Down(VK_LWIN) && !self->keys_.Down(VK_RWIN);
    const bool remote = self->keys_.Route(key, down, ownership.blocking, !shortcut && self->local_keys_[key]);
    if (recovered_up) return 1; // Raw input already delivered the remote up.
    if (self->identify_.load() != 0 && !ownership.blocking && down && !was_down &&
        ValidLocalKey(key) && GetForegroundWindow() == self->owner_) {
      const auto token = self->identify_.exchange(0);
      if (token) {
        const LPARAM packed = static_cast<LPARAM>(key | ((input.scanCode & 0xff) << 8) |
            ((input.flags & LLKHF_EXTENDED) ? 0x10000 : 0));
        if (PostMessageW(self->owner_, self->stop_message_ + 2, token, packed)) self->identify_drain_[key] = true;
      }
    }
    if (self->identify_drain_[key]) {
      if (!down) self->identify_drain_[key] = false;
      return 1;
    }
    if (shortcut) {
      self->ReleaseFor(ownership.generation, ReleaseCause::shortcut);
      PostMessageW(self->owner_, self->stop_message_, 1, ownership.generation);
    } else if (key != VK_PACKET && ownership.blocking && remote) {
      // Keyboard capture is exclusively through this hook in background mode.
      // The following private message carries physical scan code, E0, and up/down.
      const LPARAM packed = static_cast<LPARAM>((input.scanCode & 0xff) |
          ((input.flags & LLKHF_EXTENDED) ? 0x100 : 0) | (down ? 0x200 : 0));
      if (!PostMessageW(self->owner_, self->stop_message_ + 1, key, packed)) {
        self->ReleaseFor(ownership.generation, ReleaseCause::hook_queue_failed);
      }
    }
    // Drain releases belonging to the remote session after emergency exit.
    if (remote) return 1;
    return CallNextHookEx(nullptr, code, message, data);
  }
  static LRESULT CALLBACK Mouse(int code, WPARAM message, LPARAM data) {
    auto self = current_.load();
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    self->mouse_seen_ = GetTickCount64();
    const auto ownership = self->release_.CurrentOwnership();
    const auto& input = *reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    int button = -1;
    bool down = false;
    switch (message) {
      case WM_LBUTTONDOWN: down = true; [[fallthrough]];
      case WM_LBUTTONUP: button = 0; break;
      case WM_RBUTTONDOWN: down = true; [[fallthrough]];
      case WM_RBUTTONUP: button = 1; break;
      case WM_MBUTTONDOWN: down = true; [[fallthrough]];
      case WM_MBUTTONUP: button = 2; break;
      case WM_XBUTTONDOWN: down = true; [[fallthrough]];
      case WM_XBUTTONUP: button = HIWORD(input.mouseData) == XBUTTON1 ? 3 : 4; break;
    }
    const auto observer = self->drag_observer_.load();
    if (observer) {
      if (observer != self->drag_observed_) {
        self->drag_observed_ = observer; self->drag_gesture_ = DragGesture(); self->drag_notified_ = false;
      }
      if (button >= 0 && button < 2) self->drag_gesture_.Button(static_cast<unsigned>(button), down, input.pt.x, input.pt.y);
      if (message == WM_MOUSEMOVE) self->drag_gesture_.Move(input.pt.x, input.pt.y,
          self->drag_threshold_x_.load(), self->drag_threshold_y_.load());
      self->NotifyDrag();
    }
    bool remote = ownership.blocking;
    if (button >= 0) {
      const unsigned mask = 1u << button;
      const bool local = (self->local_buttons_.load() & mask) != 0;
      const bool recovered_up = !down && (self->recovered_mouse_up_ & mask) != 0;
      self->recovered_mouse_up_ &= ~mask;
      if (down) self->mouse_down_at_[button] = input.time;
      if (down) self->buttons_.fetch_or(mask);
      else self->buttons_.fetch_and(~mask);
      remote = self->mouse_routing_.Remote(static_cast<unsigned>(button), down, remote, local);
      remote = remote || recovered_up;
      if (!down && local) self->local_buttons_.fetch_and(~mask);
    }
    if (remote) return 1;
    return CallNextHookEx(nullptr, code, message, data);
  }
 private:
  bool Execute(bool begin, uint32_t generation, unsigned local_buttons, bool reset, unsigned remote_buttons = 0) {
    if (!running_.load()) return false;
    auto request = std::make_shared<Request>();
    request->begin = begin; request->reset = reset; request->local_buttons = local_buttons; request->remote_buttons = remote_buttons;
    auto result = request->result.get_future();
    auto* posted = new std::shared_ptr<Request>(request);
    if (!PostThreadMessageW(thread_id_, kBeginMessage, generation, reinterpret_cast<LPARAM>(posted))) {
      delete posted; return false;
    }
    if (result.wait_for(std::chrono::milliseconds(250)) == std::future_status::ready) return result.get();
    request->cancelled = true;
    if (begin) ReleaseFor(generation, ReleaseCause::hook_thread_timeout);
    return false;
  }
  void RequestRepair(bool keyboard) {
    const auto now = GetTickCount64();
    if (keyboard ? KeyboardFresh(now) : MouseFresh(now)) return;
    auto last = last_repair_request_.load();
    if (last != 0 && !ElapsedAtLeast(now, last, 1000)) return;
    if (last_repair_request_.compare_exchange_strong(last, now)) {
      PostThreadMessageW(thread_id_, kRepairMessage, keyboard ? 1 : 0, 0);
    }
  }
  static bool InputDesktopActive() {
    const HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) return false;
    wchar_t current_name[256]{}, input_name[256]{};
    DWORD needed = 0;
    const bool same = GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
        current_name, sizeof(current_name), &needed) &&
        GetUserObjectInformationW(input, UOI_NAME, input_name, sizeof(input_name), &needed) &&
        wcscmp(current_name, input_name) == 0;
    CloseDesktop(input); return same;
  }
  static unsigned WindowsMouseButtons() {
    const bool swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
    const int codes[] = {swapped ? VK_RBUTTON : VK_LBUTTON,
        swapped ? VK_LBUTTON : VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2};
    unsigned buttons = 0;
    for (unsigned button = 0; button < 5; ++button) {
      if (GetAsyncKeyState(codes[button]) & 0x8000) buttons |= 1u << button;
    }
    return buttons;
  }
  bool ReconcileInput(bool reset) {
    if (!InputDesktopActive()) {
      needs_reset_ = true;
      if (Blocking()) {
        const auto generation = release_.Generation();
        ReleaseFor(generation, ReleaseCause::hook_lost);
        PostMessageW(owner_, stop_message_, 1, generation);
      }
      return false;
    }
    if (reset || needs_reset_ || reset_requested_) {
      if (Blocking()) return false;
      keys_.ResetFromWindows([](unsigned key) {
        return key != VK_PACKET && key != VK_PROCESSKEY && (GetAsyncKeyState(static_cast<int>(key)) & 0x8000) != 0;
      }, GetTickCount());
      identify_drain_.fill(false); key_scan_.fill(0);
      buttons_ = WindowsMouseButtons(); local_buttons_ = 0;
      mouse_routing_ = {}; recovered_mouse_up_ = 0; mouse_down_at_.fill(GetTickCount());
      for (unsigned button = 0; button < 5; ++button) if (buttons_.load() & (1u << button)) {
        mouse_routing_.Remote(button, true, false, false);
      }
      drag_gesture_ = {}; needs_reset_ = false; reset_requested_ = false;
    } else {
      // Only Windows-owned downs have meaningful async state. Remote-owned
      // presses remain guarded until an actual hook/raw up proves release.
      if (held_.load() != 0) for (unsigned key = 8; key < 255; ++key) {
        if (keys_.CanReconcileLocal(key, GetTickCount()) && !identify_drain_[key] &&
            !(GetAsyncKeyState(static_cast<int>(key)) & 0x8000)) {
          keys_.ReconcileLocalUp(key);
        }
      }
      unsigned candidates = mouse_routing_.ReconcileCandidates(
          buttons_.load(), local_buttons_.load(), Blocking());
      for (unsigned button = 0; button < 5; ++button) {
        if (static_cast<int32_t>(GetTickCount() - mouse_down_at_[button]) < 100) candidates &= ~(1u << button);
      }
      if (candidates) {
        const unsigned released = candidates & ~WindowsMouseButtons();
        buttons_.fetch_and(~released); local_buttons_.fetch_and(~released);
        drag_gesture_.ReconcileButtons(~released);
        for (unsigned button = 0; button < 5; ++button) if (released & (1u << button)) mouse_routing_.Forget(button);
      }
    }
    held_ = static_cast<int>(keys_.Count()); NotifyDrag(); return true;
  }
  void NotifyDrag() {
    const bool dragging = drag_gesture_.Active();
    const auto observer = drag_observer_.load();
    if (observer && dragging != drag_notified_ &&
        PostMessageW(owner_, stop_message_ + 3, drag_gesture_.SourceButtons(), observer)) {
      drag_notified_ = dragging;
    }
  }
  bool RefreshHooks() {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&Keyboard), &module)) return false;
    const auto keyboard = reinterpret_cast<HOOKPROC>(GetProcAddress(module, "SharedKeyboardProc"));
    const auto mouse = reinterpret_cast<HOOKPROC>(GetProcAddress(module, "SharedMouseProc"));
    if (!keyboard || !mouse) { installed_ = false; return false; }
    const auto next_keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, keyboard, module, 0);
    const auto next_mouse = SetWindowsHookExW(WH_MOUSE_LL, mouse, module, 0);
    if (!next_keyboard || !next_mouse) {
      if (next_keyboard) UnhookWindowsHookEx(next_keyboard);
      if (next_mouse) UnhookWindowsHookEx(next_mouse);
      installed_ = false;
      return false;
    }
    const auto old_keyboard = keyboard_;
    const auto old_mouse = mouse_;
    keyboard_ = next_keyboard; mouse_ = next_mouse;
    if (old_keyboard) UnhookWindowsHookEx(old_keyboard);
    if (old_mouse) UnhookWindowsHookEx(old_mouse);
    installed_ = true;
    return true;
  }
  static constexpr UINT kBeginMessage = WM_APP + 0x275;
  static constexpr UINT kRawKeyMessage = WM_APP + 0x276;
  static constexpr UINT kRawMouseMessage = WM_APP + 0x277;
  static constexpr UINT kRepairMessage = WM_APP + 0x278;
#ifdef SHARED_INPUT_HOOK_TESTING
  static constexpr UINT kTestMessage = WM_APP + 0x279;
#endif
  inline static std::atomic<HookRuntime*> current_{nullptr};
  HWND owner_ = nullptr;
  UINT stop_message_ = 0;
  std::atomic<int> key_{0}, held_{0};
  std::atomic<unsigned> buttons_{0};
  std::atomic<unsigned> local_buttons_{0};
  std::atomic<bool> shift_{false};
  std::atomic<bool> installed_{false}, running_{false};
  CaptureReleaseLatch release_;
  std::atomic<uint64_t> mouse_seen_{0}, keyboard_seen_{0}, pump_seen_{0};
  std::array<bool, 256> identify_drain_{};
  std::array<LPARAM, 256> key_scan_{};
  HookKeyState keys_;
  std::array<std::atomic<bool>, 256> local_keys_{};
  std::atomic<uint32_t> identify_{0};
  std::array<uint32_t, 5> mouse_down_at_{};
  unsigned recovered_mouse_up_ = 0;
  bool needs_reset_ = false;
  std::atomic<bool> reset_requested_{false};
  std::atomic<uint64_t> last_repair_request_{0};
  std::atomic<uint32_t> drag_observer_{0};
  std::atomic<int> drag_threshold_x_{4}, drag_threshold_y_{4};
  uint32_t drag_observed_ = 0;
  DragGesture drag_gesture_;
  bool drag_notified_ = false;
  MouseRouting mouse_routing_;
  HHOOK keyboard_ = nullptr, mouse_ = nullptr;
  DWORD thread_id_ = 0;
  std::thread thread_;
};
namespace { HookRuntime runtime; }
extern "C" __declspec(dllexport) LRESULT CALLBACK SharedKeyboardProc(int c, WPARAM w, LPARAM l) {
  return HookRuntime::Keyboard(c, w, l);
}
extern "C" __declspec(dllexport) LRESULT CALLBACK SharedMouseProc(int c, WPARAM w, LPARAM l) {
  return HookRuntime::Mouse(c, w, l);
}
bool SharedHooksInstall(HWND owner, UINT message, int key, bool shift) { return runtime.Install(owner, message, key, shift); }
bool SharedHooksBegin(uint32_t generation, uint32_t local_buttons) { return runtime.Begin(generation, local_buttons, 0); }
bool SharedHooksBeginWithRemote(uint32_t generation, uint32_t local_buttons, uint32_t remote_buttons) { return runtime.Begin(generation, local_buttons, remote_buttons); }
bool SharedHooksPrepare(bool reset_state) { return runtime.Prepare(reset_state); }
bool SharedHooksInstalled() { return runtime.Installed(); }
void SharedHooksRawKey(unsigned key, bool up, uint32_t time) { runtime.RawKey(key, up, time); }
void SharedHooksRawMouse(unsigned flags, uint32_t time) { runtime.RawMouse(flags, time); }
bool SharedHooksHasRemoteHeld(bool ignore_mouse) { return runtime.HasRemoteHeld(ignore_mouse); }
unsigned SharedHooksPhysicalButtons() { return runtime.PhysicalButtons(); }
bool SharedHooksSetLocalKeys(const int* keys, unsigned count) { return runtime.SetLocalKeys(keys, count); }
void SharedHooksIdentifyKey(uint32_t token) { runtime.IdentifyKey(token); }
void SharedHooksObserveDrag(uint32_t token) { runtime.ObserveDrag(token); }
void SharedHooksRelease() { runtime.Release(); }
void SharedHooksResetRelease(uint32_t generation) { runtime.ResetRelease(generation); }
void SharedHooksReleaseFor(uint32_t generation, ReleaseCause cause) { runtime.ReleaseFor(generation, cause); }
ReleaseCause SharedHooksReleaseReason(uint32_t generation) { return runtime.ReleaseReason(generation); }
uint64_t SharedHooksMouseSeen() { return runtime.MouseSeen(); }
uint64_t SharedHooksKeyboardSeen() { return runtime.KeyboardSeen(); }
uint64_t SharedHooksPumpSeen() { return runtime.PumpSeen(); }
bool SharedHooksHealthy(uint64_t now) { return runtime.Healthy(now); }
bool SharedHooksBlocking() { return runtime.Blocking(); }
bool SharedHooksHasHeld() { return runtime.HasHeld(); }
bool SharedHooksObserved() { return runtime.Observed(); }
bool SharedHooksMouseFresh(uint64_t now) { return runtime.MouseFresh(now); }
bool SharedHooksKeyboardFresh(uint64_t now) { return runtime.KeyboardFresh(now); }
void SharedHooksClose() { runtime.Close(); }
#ifdef SHARED_INPUT_HOOK_TESTING
bool SharedHooksTestFault(unsigned mode) { return runtime.TestFault(mode); }
#endif
}  // namespace shared_input
