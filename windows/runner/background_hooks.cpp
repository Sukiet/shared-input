#include "background_hooks.h"
#include "key_routing.h"
#include <array>
#include <atomic>
#include <future>
#include <thread>

namespace shared_input {
// Hooks use a dedicated native message loop. Never call Dart, IMM, or the
// network from a hook. The independent watchdog releases input atomically.
class HookRuntime {
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
            // Windows may have silently removed a timed-out hook in an old
            // capture. Start with fresh handles, installing before removing old
            // ones, and keep the same native input ownership transition.
            const bool allowed = !HasHeld() && Observed() && RefreshHooks() && !HasHeld();
            if (allowed) {
              pump_seen_ = GetTickCount64();
              release_.Begin(static_cast<uint32_t>(message.wParam), true);
            }
            else Release();
            reinterpret_cast<std::promise<bool>*>(message.lParam)->set_value(allowed);
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

  bool Begin(uint32_t generation) {
    if (!thread_.joinable()) return false;
    // Serialize the ownership transition with hook callbacks. A key arriving
    // during start must belong to exactly one machine.
    std::promise<bool> ready;
    auto result = ready.get_future();
    if (!PostThreadMessageW(thread_id_, kBeginMessage, generation, reinterpret_cast<LPARAM>(&ready))) return false;
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
  }
  bool Blocking() const { return release_.Blocking(); }
  bool HasHeld() const { return held_.load() != 0 || buttons_.load() != 0; }
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
    mouse_seen_ = keyboard_seen_ = 0;
    pump_seen_ = 0;
    pressed_.fill(false); identify_drain_.fill(false); routing_.Reset(); identify_ = 0; remote_buttons_ = 0;
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
    bool remote = ownership.blocking;
    if (button >= 0) {
      const unsigned mask = 1u << button;
      if (down) self->buttons_.fetch_or(mask);
      else self->buttons_.fetch_and(~mask);
      remote = remote || (self->remote_buttons_ & mask) != 0;
      if (down && remote) self->remote_buttons_ |= mask;
      if (!down) self->remote_buttons_ &= ~mask;
    }
    if (remote) return 1;
    return CallNextHookEx(nullptr, code, message, data);
  }
 private:
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
  std::atomic<bool> shift_{false};
  CaptureReleaseLatch release_;
  std::atomic<uint64_t> mouse_seen_{0}, keyboard_seen_{0}, pump_seen_{0};
  std::array<bool, 256> pressed_{}, identify_drain_{};
  std::array<std::atomic<bool>, 256> local_keys_{};
  std::atomic<uint32_t> identify_{0};
  KeyRouting routing_;
  unsigned remote_buttons_ = 0;
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
bool SharedHooksBegin(uint32_t generation) { return runtime.Begin(generation); }
bool SharedHooksSetLocalKeys(const int* keys, unsigned count) { return runtime.SetLocalKeys(keys, count); }
void SharedHooksIdentifyKey(uint32_t token) { runtime.IdentifyKey(token); }
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
