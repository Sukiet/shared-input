#include "background_hooks.h"
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
      HMODULE module = nullptr;
      GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          reinterpret_cast<LPCWSTR>(&Keyboard), &module);
      const auto keyboard = reinterpret_cast<HOOKPROC>(GetProcAddress(module, "SharedKeyboardProc"));
      const auto mouse = reinterpret_cast<HOOKPROC>(GetProcAddress(module, "SharedMouseProc"));
      keyboard_ = SetWindowsHookExW(WH_KEYBOARD_LL, keyboard, module, 0);
      mouse_ = SetWindowsHookExW(WH_MOUSE_LL, mouse, module, 0);
      const bool installed = keyboard_ && mouse_;
      ready.set_value(installed);
      if (installed) {
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
          if (message.message == kBeginMessage) {
            const bool allowed = !HasHeld() && Observed();
            blocked_ = allowed;
            reinterpret_cast<std::promise<bool>*>(message.lParam)->set_value(allowed);
            continue;
          }
          TranslateMessage(&message); DispatchMessageW(&message);
        }
      }
      if (keyboard_) UnhookWindowsHookEx(keyboard_);
      if (mouse_) UnhookWindowsHookEx(mouse_);
      keyboard_ = mouse_ = nullptr;
      current_ = nullptr;
    });
    if (result.get()) return true;
    thread_.join();
    return false;
  }

  bool Begin() {
    if (!thread_.joinable()) return false;
    // Serialize the ownership transition with hook callbacks. A key arriving
    // during start must belong to exactly one machine.
    std::promise<bool> ready;
    auto result = ready.get_future();
    if (!PostThreadMessageW(thread_id_, kBeginMessage, 0, reinterpret_cast<LPARAM>(&ready))) return false;
    return result.get();
  }
  void Release() { blocked_ = false; }
  bool Blocking() const { return blocked_.load(); }
  bool HasHeld() const { return held_.load() != 0 || buttons_.load() != 0; }
  bool Observed() const { return mouse_seen_.load() != 0 || keyboard_seen_.load() != 0; }
  bool MouseFresh(uint64_t now) const { return now - mouse_seen_.load() < 250; }
  bool KeyboardFresh(uint64_t now) const { return now - keyboard_seen_.load() < 250; }
  void Close() {
    Release();
    if (thread_.joinable()) {
      PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
      thread_.join();
    }
    held_ = 0;
    buttons_ = 0;
    mouse_seen_ = keyboard_seen_ = 0;
    pressed_.fill(false); remote_.fill(false); remote_buttons_ = 0;
  }
 public:
  static LRESULT CALLBACK Keyboard(int code, WPARAM message, LPARAM data) {
    auto self = current_.load();
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    self->keyboard_seen_ = GetTickCount64();
    const auto& input = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    const unsigned key = input.vkCode;
    if (key >= 256) return CallNextHookEx(nullptr, code, message, data);
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    if (self->pressed_[key] != down) {
      self->pressed_[key] = down;
      self->held_.fetch_add(down ? 1 : -1);
    }
    const bool remote = self->blocked_ || self->remote_[key];
    self->remote_[key] = remote && down;
    if (self->blocked_ && down && key == static_cast<unsigned>(self->key_.load()) &&
        (self->pressed_[VK_LCONTROL] || self->pressed_[VK_RCONTROL]) &&
        (self->pressed_[VK_LMENU] || self->pressed_[VK_RMENU]) &&
        ((self->pressed_[VK_LSHIFT] || self->pressed_[VK_RSHIFT]) == self->shift_) &&
        !self->pressed_[VK_LWIN] && !self->pressed_[VK_RWIN]) {
      self->Release();
      PostMessageW(self->owner_, self->stop_message_, 1, 0);
    } else if (key != VK_PACKET) {
      // Keyboard capture is exclusively through this hook in background mode.
      // The following private message carries physical scan code, E0, and up/down.
      const LPARAM packed = static_cast<LPARAM>((input.scanCode & 0xff) |
          ((input.flags & LLKHF_EXTENDED) ? 0x100 : 0) | (down ? 0x200 : 0));
      if (!PostMessageW(self->owner_, self->stop_message_ + 1, key, packed)) self->Release();
    }
    // Drain releases belonging to the remote session after emergency exit.
    if (remote) return 1;
    return CallNextHookEx(nullptr, code, message, data);
  }
  static LRESULT CALLBACK Mouse(int code, WPARAM message, LPARAM data) {
    auto self = current_.load();
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    self->mouse_seen_ = GetTickCount64();
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
    bool remote = self->blocked_;
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
  static constexpr UINT kBeginMessage = WM_APP + 0x275;
  inline static std::atomic<HookRuntime*> current_{nullptr};
  HWND owner_ = nullptr;
  UINT stop_message_ = 0;
  std::atomic<int> key_{0}, held_{0};
  std::atomic<unsigned> buttons_{0};
  std::atomic<bool> shift_{false}, blocked_{false};
  std::atomic<uint64_t> mouse_seen_{0}, keyboard_seen_{0};
  std::array<bool, 256> pressed_{}, remote_{};
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
bool SharedHooksBegin() { return runtime.Begin(); }
void SharedHooksRelease() { runtime.Release(); }
bool SharedHooksBlocking() { return runtime.Blocking(); }
bool SharedHooksHasHeld() { return runtime.HasHeld(); }
bool SharedHooksObserved() { return runtime.Observed(); }
bool SharedHooksMouseFresh(uint64_t now) { return runtime.MouseFresh(now); }
bool SharedHooksKeyboardFresh(uint64_t now) { return runtime.KeyboardFresh(now); }
void SharedHooksClose() { runtime.Close(); }
}  // namespace shared_input
