#include "background_hooks.h"
#include "key_routing.h"
#include "drag_gesture.h"
#include "drag_handoff.h"
#include "mouse_routing.h"
#include <array>
#include <atomic>
#include <future>
#include <thread>

namespace shared_input {
// Hooks use a dedicated native message loop. Never call Dart, IMM, or the
// network from a hook. The independent watchdog releases input atomically.
class HookRuntime {
  struct BeginRequest { std::promise<bool> result; unsigned local_buttons; };
 public:
  ~HookRuntime() { Close(); }
  bool Install(HWND owner, UINT stop_message, int key, bool shift) {
    key_ = key; shift_ = shift;
    if (thread_.joinable()) return true;
    owner_ = owner; stop_message_ = stop_message;
    std::promise<bool> ready;
    auto result = ready.get_future();
    thread_ = std::thread([this, ready = std::move(ready)]() mutable {
      current_ = this;
      MSG message{};
      PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
      thread_id_ = GetCurrentThreadId();
      const bool hooks_installed = RefreshHooks();
      const UINT_PTR pump_timer = hooks_installed ? SetTimer(nullptr, 0, 50, nullptr) : 0;
      const bool installed = hooks_installed && pump_timer;
      pump_seen_ = GetTickCount64();
      ready.set_value(installed);
      if (installed) {
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
          if (message.message == kBeginMessage) {
            auto& request = *reinterpret_cast<BeginRequest*>(message.lParam);
            // Windows may have silently removed a timed-out hook in an old
            // capture. Start with fresh handles, installing before removing old
            // ones, and keep the same native input ownership transition.
            auto inputs_ready = [&] { return CanBeginWithLocalButtons(held_.load() != 0, buttons_.load(), request.local_buttons); };
            const bool allowed = inputs_ready() && Observed() && RefreshHooks() && inputs_ready();
            if (allowed) {
              local_buttons_ = request.local_buttons;
              mouse_routing_.TransferToLocal(request.local_buttons);
              pump_seen_ = GetTickCount64();
              release_.Begin(static_cast<uint32_t>(message.wParam), true);
            }
            else Release();
            request.result.set_value(allowed);
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
      current_ = nullptr;
    });
    if (result.get()) return true;
    thread_.join();
    return false;
  }

  bool Begin(uint32_t generation, unsigned local_buttons) {
    if (!thread_.joinable()) return false;
    // Serialize the ownership transition with hook callbacks. A key arriving
    // during start must belong to exactly one machine.
    BeginRequest request; request.local_buttons = local_buttons;
    auto result = request.result.get_future();
    if (!PostThreadMessageW(thread_id_, kBeginMessage, generation, reinterpret_cast<LPARAM>(&request))) return false;
    return result.get();
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
    // Reuse the existing 50 ms pump only while observing a held source button.
    // GetAsyncKeyState is intentionally outside the hook, where Windows has
    // already applied the event. It can recover a missed up, never invent a down.
    if (drag_observer_.load()) {
      const unsigned candidates = mouse_routing_.ReconcileCandidates(
          buttons_.load(), local_buttons_.load(), Blocking());
      if (candidates) {
        const unsigned physical = ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) ? 1u : 0u) |
            ((GetAsyncKeyState(VK_RBUTTON) & 0x8000) ? 2u : 0u);
        const unsigned released = candidates & ~physical;
        if (released) {
          buttons_.fetch_and(~released); local_buttons_.fetch_and(~released);
          drag_gesture_.ReconcileButtons(~released);
        }
      }
      NotifyDrag();
    }
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
    pressed_.fill(false); identify_drain_.fill(false); routing_.Reset(); identify_ = 0; mouse_routing_ = {};
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
    if (key >= 256) return CallNextHookEx(nullptr, code, message, data);
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    const bool was_down = self->pressed_[key];
    if (self->pressed_[key] != down) {
      self->pressed_[key] = down;
      self->held_.fetch_add(down ? 1 : -1);
    }
    const bool shortcut = ownership.blocking && down && key == static_cast<unsigned>(self->key_.load()) &&
        (self->pressed_[VK_LCONTROL] || self->pressed_[VK_RCONTROL]) &&
        (self->pressed_[VK_LMENU] || self->pressed_[VK_RMENU]) &&
        ((self->pressed_[VK_LSHIFT] || self->pressed_[VK_RSHIFT]) == self->shift_) &&
        !self->pressed_[VK_LWIN] && !self->pressed_[VK_RWIN];
    const bool remote = self->routing_.Remote(key, down, ownership.blocking, !shortcut && self->local_keys_[key]);
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
      if (down) self->buttons_.fetch_or(mask);
      else self->buttons_.fetch_and(~mask);
      remote = self->mouse_routing_.Remote(static_cast<unsigned>(button), down, remote, local);
      if (!down && local) self->local_buttons_.fetch_and(~mask);
    }
    if (remote) return 1;
    return CallNextHookEx(nullptr, code, message, data);
  }
 private:
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
    if (!keyboard || !mouse) return false;
    const auto next_keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, keyboard, module, 0);
    const auto next_mouse = SetWindowsHookExW(WH_MOUSE_LL, mouse, module, 0);
    if (!next_keyboard || !next_mouse) {
      if (next_keyboard) UnhookWindowsHookEx(next_keyboard);
      if (next_mouse) UnhookWindowsHookEx(next_mouse);
      return false;
    }
    const auto old_keyboard = keyboard_;
    const auto old_mouse = mouse_;
    keyboard_ = next_keyboard; mouse_ = next_mouse;
    if (old_keyboard) UnhookWindowsHookEx(old_keyboard);
    if (old_mouse) UnhookWindowsHookEx(old_mouse);
    return true;
  }
  static constexpr UINT kBeginMessage = WM_APP + 0x275;
  inline static std::atomic<HookRuntime*> current_{nullptr};
  HWND owner_ = nullptr;
  UINT stop_message_ = 0;
  std::atomic<int> key_{0}, held_{0};
  std::atomic<unsigned> buttons_{0};
  std::atomic<unsigned> local_buttons_{0};
  std::atomic<bool> shift_{false};
  CaptureReleaseLatch release_;
  std::atomic<uint64_t> mouse_seen_{0}, keyboard_seen_{0}, pump_seen_{0};
  std::array<bool, 256> pressed_{}, identify_drain_{};
  std::array<std::atomic<bool>, 256> local_keys_{};
  std::atomic<uint32_t> identify_{0};
  KeyRouting routing_;
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
bool SharedHooksBegin(uint32_t generation, uint32_t local_buttons) { return runtime.Begin(generation, local_buttons); }
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
}  // namespace shared_input
