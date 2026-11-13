#include "input_bridge.h"
#include "pointer_motion.h"

#include <cfgmgr32.h>
#include <setupapi.h>
#include <mmsystem.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <utility>

namespace {
constexpr UINT kWatchdogMessage = WM_APP + 0x142;
constexpr UINT kRestoreFocusMessage = WM_APP + 0x143;
constexpr UINT kStreamMessage = WM_APP + 0x144;
constexpr UINT_PTR kStatsTimer = 0x5349;
constexpr wchar_t kCaptureClass[] = L"SharedInputLocalCapture";
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string output(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      output.data(), length, nullptr, nullptr);
  return output;
}

std::wstring DevicePath(HANDLE device) {
  UINT length = 0;
  if (GetRawInputDeviceInfoW(device, RIDI_DEVICENAME, nullptr, &length) == UINT(-1)) return {};
  std::vector<wchar_t> path(static_cast<size_t>(length) + 1, L'\0');
  if (GetRawInputDeviceInfoW(device, RIDI_DEVICENAME, path.data(), &length) == UINT(-1)) return {};
  return std::wstring(path.data());
}

std::pair<std::string, bool> Describe(const std::wstring& path, bool keyboard) {
  std::string name = keyboard ? "HID Keyboard" : "HID Mouse";
  bool usb = false;
  HDEVINFO info = SetupDiCreateDeviceInfoList(nullptr, nullptr);
  if (info == INVALID_HANDLE_VALUE) return {name, usb};
  SP_DEVICE_INTERFACE_DATA interface_data{};
  interface_data.cbSize = sizeof(interface_data);
  if (SetupDiOpenDeviceInterfaceW(info, path.c_str(), 0, &interface_data)) {
    DWORD bytes = 0;
    SetupDiGetDeviceInterfaceDetailW(info, &interface_data, nullptr, 0, &bytes, nullptr);
    if (bytes >= sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) {
      std::vector<BYTE> storage(bytes);
      auto detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
      detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
      SP_DEVINFO_DATA device{};
      device.cbSize = sizeof(device);
      if (SetupDiGetDeviceInterfaceDetailW(info, &interface_data, detail, bytes, nullptr, &device)) {
        wchar_t label[512]{};
        if (SetupDiGetDeviceRegistryPropertyW(info, &device, SPDRP_FRIENDLYNAME, nullptr,
              reinterpret_cast<PBYTE>(label), sizeof(label), nullptr) ||
            SetupDiGetDeviceRegistryPropertyW(info, &device, SPDRP_DEVICEDESC, nullptr,
              reinterpret_cast<PBYTE>(label), sizeof(label), nullptr)) {
          name = Utf8(label);
        }
        DEVINST node = device.DevInst;
        for (int depth = 0; depth < 12; ++depth) {
          wchar_t id[MAX_DEVICE_ID_LEN]{};
          if (CM_Get_Device_IDW(node, id, MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS &&
              std::wstring(id).rfind(L"USB\\", 0) == 0) {
            usb = true;
            break;
          }
          DEVINST parent = 0;
          if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) break;
          node = parent;
        }
      }
    }
  }
  SetupDiDestroyDeviceInfoList(info);
  return {name, usb};
}

const Value* Find(const Map& map, const char* key) {
  const auto entry = map.find(Value(key));
  return entry == map.end() ? nullptr : &entry->second;
}
std::string StringArg(const Map& map, const char* key) {
  const auto value = Find(map, key);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}
int IntegerArg(const Map& map, const char* key, int fallback = 0) {
  const auto value = Find(map, key);
  if (value) {
    if (const auto number = std::get_if<int32_t>(value)) return *number;
    if (const auto number = std::get_if<int64_t>(value)) return static_cast<int>(*number);
  }
  return fallback;
}
bool BoolArg(const Map& map, const char* key) {
  const auto value = Find(map, key);
  return value && std::get_if<bool>(value) && std::get<bool>(*value);
}

int PhysicalKey(const RAWKEYBOARD& key) {
  if (key.VKey == VK_CONTROL) return key.Flags & RI_KEY_E0 ? VK_RCONTROL : VK_LCONTROL;
  if (key.VKey == VK_MENU) return key.Flags & RI_KEY_E0 ? VK_RMENU : VK_LMENU;
  if (key.VKey == VK_SHIFT) return key.MakeCode == 0x36 ? VK_RSHIFT : VK_LSHIFT;
  return key.VKey;
}
}  // namespace

InputBridge::InputBridge(HWND owner, HWND view, flutter::BinaryMessenger* messenger)
    : owner_(owner), view_(view) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "shared_input/dry_run", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethod(call, std::move(result));
  });
  watchdog_ = std::thread([this] { Watchdog(); });
}

InputBridge::~InputBridge() {
  Stop("shutdown", false);
  receiver_.Stop();
  closing_ = true;
  if (watchdog_.joinable()) watchdog_.join();
  KillTimer(owner_, kStatsTimer);
  if (initialized_) {
    RAWINPUTDEVICE devices[] = {{0x01, 0x06, RIDEV_REMOVE, nullptr},
                                {0x01, 0x02, RIDEV_REMOVE, nullptr}};
    RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE));
  }
  channel_->SetMethodCallHandler(nullptr);
  if (capture_) {
    SetWindowLongPtr(capture_, GWLP_USERDATA, 0);
    DestroyWindow(capture_);
  }
}

bool InputBridge::Initialize() {
  if (initialized_) return true;
  // Foreground only: deliberately no INPUTSINK, hooks or RegisterHotKey.
  RAWINPUTDEVICE devices[] = {{0x01, 0x06, RIDEV_DEVNOTIFY, owner_},
                              {0x01, 0x02, RIDEV_DEVNOTIFY, owner_}};
  if (!RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE))) return false;
  WNDCLASSW wc{};
  wc.lpfnWndProc = CaptureProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kCaptureClass;
  RegisterClassW(&wc);
  // A one-pixel native input target keeps legacy typing/clicks away from Flutter
  // controls, while Flutter continues rendering the simulated desktop.
  capture_ = CreateWindowExW(0, kCaptureClass, L"", WS_CHILD,
      0, 0, 1, 1, owner_, nullptr, wc.hInstance, this);
  if (!capture_ || !SetTimer(owner_, kStatsTimer, 100, nullptr)) {
    RAWINPUTDEVICE remove[] = {{0x01, 0x06, RIDEV_REMOVE, nullptr},
                               {0x01, 0x02, RIDEV_REMOVE, nullptr}};
    RegisterRawInputDevices(remove, 2, sizeof(RAWINPUTDEVICE));
    if (capture_) { DestroyWindow(capture_); capture_ = nullptr; }
    return false;
  }
  initialized_ = true;
  heartbeat_ = GetTickCount64();
  return true;
}

std::vector<InputBridge::Device> InputBridge::Enumerate() {
  UINT count = 0;
  if (GetRawInputDeviceList(nullptr, &count, sizeof(RAWINPUTDEVICELIST)) == UINT(-1)) return {};
  std::vector<RAWINPUTDEVICELIST> list(count);
  const UINT read = GetRawInputDeviceList(list.data(), &count, sizeof(RAWINPUTDEVICELIST));
  if (read == UINT(-1)) return {};
  std::vector<Device> devices;
  for (UINT index = 0; index < read; ++index) {
    const auto& item = list[index];
    if (item.dwType != RIM_TYPEKEYBOARD && item.dwType != RIM_TYPEMOUSE) continue;
    const auto path = DevicePath(item.hDevice);
    if (path.empty()) continue;
    const auto description = Describe(path, item.dwType == RIM_TYPEKEYBOARD);
    devices.push_back({item.hDevice, Utf8(path), description.first,
        item.dwType == RIM_TYPEKEYBOARD ? "keyboard" : "mouse", description.second});
  }
  // Distinguish identical names without treating VID/PID as unique identity.
  std::map<std::string, int> counts;
  for (auto& device : devices) device.name += " #" + std::to_string(++counts[device.name]);
  return devices;
}

void InputBridge::OnMethod(const flutter::MethodCall<Value>& call,
                           std::unique_ptr<Result> result) {
  const auto& method = call.method_name();
  if (method == "initialize") {
    // Hot restart / a new Dart view always starts disarmed.
    Stop("manual", false);
    receiver_.Stop();
    CancelSetup();
    shortcut_key_ = 0;
    shortcut_label_.clear();
    if (Initialize()) result->Success();
    else result->Error("init_failed", "Windows Raw Input 初始化失败。");
    return;
  }
  if (!initialized_) {
    result->Error("not_initialized", "请先初始化原生采集模块。");
    return;
  }
  if (method == "heartbeat") {
    heartbeat_ = GetTickCount64();
    result->Success();
  } else if (method == "permissions" || method == "requestPermissions") {
    result->Success(Value(true));
  } else if (method == "restoreShortcut") {
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const int key = args ? IntegerArg(*args, "key") : 0;
    if (active_ || !shared_input::ValidShortcut(key, true, true, false)) {
      result->Error("invalid_shortcut", "保存的退出快捷键无效。");
    } else {
      shortcut_key_ = key;
      shortcut_shift_ = BoolArg(*args, "shift");
      result->Success();
    }
  } else if (method == "receiverBegin") {
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (active_ || !args || !receiver_.Begin(StringArg(*args, "capture"))) {
      result->Error("receive_failed", "无法开始接收输入。");
    } else result->Success();
  } else if (method == "receiverInput") {
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args || !receiver_.Apply(*args)) result->Error("inject_failed", "输入注入失败或接收已停止。");
    else result->Success();
  } else if (method == "receiverHeartbeat") {
    if (receiver_.Heartbeat()) result->Success();
    else result->Error("receiver_stopped", "接收已因超时停止。");
  } else if (method == "receiverStop") {
    receiver_.Stop();
    result->Success();
  } else if (method == "pointer") {
    // Latest coordinates, pulled by Flutter vsync. No input-event backlog or
    // coupling to the deliberately slower statistics timer.
    result->Success(Value(flutter::EncodableList{Value(x_), Value(y_), Value(active_)}));
  } else if (method == "devices") {
    flutter::EncodableList list;
    for (const auto& device : Enumerate()) {
      list.emplace_back(Map{{Value("id"), Value(device.id)},
          {Value("name"), Value(device.name)}, {Value("type"), Value(device.type)},
          {Value("usb"), Value(device.usb)}});
    }
    result->Success(Value(list));
  } else if (method == "stop") {
    Stop("manual");
    result->Success();
  } else if (method == "cancelSetup") {
    CancelSetup();
    result->Success();
  } else if (method == "recordShortcut" || method == "identify") {
    if (active_ || GetForegroundWindow() != owner_) {
      result->Error("invalid_state", "请在前台窗口的非控制状态下设置。");
      return;
    }
    CancelSetup();
    physical_keys_.clear();
    setup_since_ = GetTickCount64();
    if (method == "recordShortcut") {
      recording_ = true;
    } else {
      const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      identifying_ = args ? StringArg(*args, "type") : "";
      if (identifying_ != "keyboard" && identifying_ != "mouse") {
        identifying_.clear();
        result->Error("invalid_type", "请选择键盘或鼠标。");
        return;
      }
    }
    result->Success();
  } else if (method == "start") {
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args) result->Error("invalid_args", "缺少开始参数。");
    else Start(*args, std::move(result));
  } else {
    result->NotImplemented();
  }
}

void InputBridge::Start(const Map& args, std::unique_ptr<Result> result) {
  if (active_ || recording_ || !identifying_.empty() || !shortcut_key_) {
    result->Error("not_ready", "必须先选择设备并设置退出快捷键。");
    return;
  }
  if (GetForegroundWindow() != owner_ || IsIconic(owner_)) {
    result->Error("not_foreground", "开始控制前，请先打开并激活本窗口。");
    return;
  }
  // Do not inherit a held modifier or shortcut into the simulated session.
  for (int key = VK_BACK; key < 255; ++key) {
    if (GetAsyncKeyState(key) & 0x8000) {
      result->Error("keys_held", "请松开所有键盘按键，再点击开始控制。");
      return;
    }
  }
  keyboard_ = mouse_ = nullptr;
  for (const auto& device : Enumerate()) {
    if (device.type == "keyboard" && device.id == StringArg(args, "keyboard")) keyboard_ = device.handle;
    if (device.type == "mouse" && device.id == StringArg(args, "mouse")) mouse_ = device.handle;
  }
  if (!keyboard_ || !mouse_) {
    result->Error("missing_device", "所选设备不存在，请刷新并重新选择。");
    return;
  }
  const auto speed = Find(args, "speed");
  const auto number = speed ? std::get_if<double>(speed) : nullptr;
  if (!number || !shared_input::ValidSensitivity(*number)) {
    result->Error("invalid_speed", "灵敏度范围为 0.0001～4。");
    return;
  }
  speed_ = *number;
  remote_capture_ = BoolArg(args, "remote");
  const int hz = IntegerArg(args, "sendHz", 500);
  if (hz != 125 && hz != 250 && hz != 500 && hz != 1000) {
    remote_capture_ = false;
    result->Error("invalid_frequency", "发送频率无效。");
    return;
  }
  motion_sequence_ = event_epoch_ = flushed_sequence_ = flushed_epoch_ = 0;
  total_x_ = total_y_ = 0;
  input_events_.clear();
  keys_ = moves_ = buttons_ = ignored_ = released_ = 0;
  x_ = 300; y_ = 120;
  held_keys_.clear(); held_buttons_.clear(); physical_keys_.clear(); shakes_.clear();
  started_ = GetTickCount64();
  RECT client{};
  GetClientRect(owner_, &client);
  POINT center{(client.right - client.left) / 2, (client.bottom - client.top) / 2};
  SetWindowPos(capture_, HWND_TOP, center.x, center.y, 1, 1, SWP_SHOWWINDOW);
  active_ = true;
  SetFocus(capture_);
  if (GetFocus() != capture_) {
    Stop("focus_lost", false);
    result->Error("focus_failed", "无法取得输入焦点，已取消开始。");
    return;
  }
  ClientToScreen(owner_, &center);
  RECT clip{center.x, center.y, center.x + 1, center.y + 1};
  bool clipped = false;
  {
    std::lock_guard<std::mutex> lock(cursor_lease_);
    ++generation_;
    heartbeat_ = started_;
    watch_started_ = started_;
    owned_clip_ = clip;
    clipped = ClipCursor(&clip) != FALSE;
    armed_ = clipped;
  }
  if (!clipped) {
    Stop("manual", false);
    result->Error("clip_failed", "鼠标限制失败，已取消开始并释放鼠标。");
    return;
  }
  SetCursor(nullptr);
  if (remote_capture_) {
    timer_resolution_ = timeBeginPeriod(1) == TIMERR_NOERROR;
    stream_timer_ = timeSetEvent(static_cast<UINT>(1000 / hz), 1, StreamTick,
        reinterpret_cast<DWORD_PTR>(this), TIME_PERIODIC | TIME_KILL_SYNCHRONOUS);
    if (!stream_timer_) {
      Stop("manual", false);
      result->Error("timer_failed", "高频采集定时器启动失败。");
      return;
    }
  }
  result->Success();
}

void InputBridge::Stop(const std::string& reason, bool notify) {
  const bool was_active = active_;
  // Release first; neither Dart nor a channel response is needed for cleanup.
  {
    std::lock_guard<std::mutex> lock(cursor_lease_);
    ReleaseCursorIfOwned();
  }
  active_ = false;
  if (was_active && remote_capture_) FlushStream();
  StopStream();
  if (!was_active) return;
  released_ = static_cast<int>(held_keys_.size() + held_buttons_.size());
  held_keys_.clear(); held_buttons_.clear(); physical_keys_.clear(); shakes_.clear();
  SetCursor(LoadCursor(nullptr, IDC_ARROW));
  // Stop can run inside WM_KILLFOCUS. Defer window visibility/focus changes
  // until that notification returns to avoid focus reentrancy/deadlocks.
  PostMessage(owner_, kRestoreFocusMessage, 0, generation_.load());
  if (notify) {
    auto stats = Stats();
    stats[Value("reason")] = Value(reason);
    Emit("stopped", std::move(stats));
  }
}

bool InputBridge::Down(int key) const {
  for (const auto& device : physical_keys_) {
    if (device.second.count(key)) return true;
  }
  return false;
}

bool InputBridge::MatchesShortcut(int key) const {
  return key == shortcut_key_ && (Down(VK_LCONTROL) || Down(VK_RCONTROL)) &&
      (Down(VK_LMENU) || Down(VK_RMENU)) &&
      ((Down(VK_LSHIFT) || Down(VK_RSHIFT)) == shortcut_shift_) &&
      !Down(VK_LWIN) && !Down(VK_RWIN);
}

void InputBridge::ReadInput(HRAWINPUT handle) {
  if (GetForegroundWindow() != owner_) return;
  UINT bytes = 0;
  if (GetRawInputData(handle, RID_INPUT, nullptr, &bytes, sizeof(RAWINPUTHEADER)) == UINT(-1)) return;
  if (bytes < sizeof(RAWINPUTHEADER) || bytes > 65536) return;
  std::vector<BYTE> data(bytes);
  if (GetRawInputData(handle, RID_INPUT, data.data(), &bytes, sizeof(RAWINPUTHEADER)) != bytes) return;
  const auto& raw = *reinterpret_cast<const RAWINPUT*>(data.data());
  const auto now = GetTickCount64();
  if (raw.header.dwType == RIM_TYPEKEYBOARD && bytes >= sizeof(RAWINPUTHEADER) + sizeof(RAWKEYBOARD)) {
    const auto& keyboard = raw.data.keyboard;
    if (keyboard.VKey == 255 || !raw.header.hDevice) return;
    const int key = PhysicalKey(keyboard);
    const bool up = (keyboard.Flags & RI_KEY_BREAK) != 0;
    auto& physical = physical_keys_[raw.header.hDevice];
    if (up) physical.erase(key); else physical.insert(key);
    if (recording_ && !up) {
      if (key == VK_ESCAPE) { CancelSetup(); return; }
      if (shared_input::ValidShortcut(key,
            Down(VK_LCONTROL) || Down(VK_RCONTROL),
            Down(VK_LMENU) || Down(VK_RMENU), Down(VK_LWIN) || Down(VK_RWIN))) {
        shortcut_key_ = key;
        shortcut_shift_ = Down(VK_LSHIFT) || Down(VK_RSHIFT);
        shortcut_label_ = "Ctrl + Alt + ";
        if (shortcut_shift_) shortcut_label_ += "Shift + ";
        shortcut_label_ += key >= VK_F1 ? "F" + std::to_string(key - VK_F1 + 1) : std::string(1, static_cast<char>(key));
        recording_ = false;
        Emit("shortcut", {{Value("label"), Value(shortcut_label_)},
            {Value("key"), Value(shortcut_key_)}, {Value("shift"), Value(shortcut_shift_)}});
      }
      return;
    }
    if (identifying_ == "keyboard" && !up) {
      const auto path = Utf8(DevicePath(raw.header.hDevice));
      if (!path.empty()) {
        identifying_.clear();
        Emit("identified", {{Value("type"), Value("keyboard")}, {Value("id"), Value(path)}});
      }
      return;
    }
    if (!active_) return;
    // Emergency shortcut precedes the selected-device filter.
    if (!up && MatchesShortcut(key)) { Stop("shortcut"); return; }
    if (raw.header.hDevice != keyboard_) { ++ignored_; return; }
    ++keys_;
    const int physical_id = keyboard.MakeCode | ((keyboard.Flags & (RI_KEY_E0 | RI_KEY_E1)) << 16);
    const bool repeat = !up && held_keys_.count(physical_id) != 0;
    if (up) held_keys_.erase(physical_id); else held_keys_.insert(physical_id);
    QueueInput({{Value("kind"), Value("key")}, {Value("code"), Value(static_cast<int>(keyboard.MakeCode))},
        {Value("extended"), Value((keyboard.Flags & RI_KEY_E0) != 0)},
        {Value("down"), Value(!up)}, {Value("repeat"), Value(repeat)}});
  } else if (raw.header.dwType == RIM_TYPEMOUSE && bytes >= sizeof(RAWINPUTHEADER) + sizeof(RAWMOUSE)) {
    const auto& mouse = raw.data.mouse;
    if (identifying_ == "mouse" && (mouse.lLastX || mouse.lLastY || mouse.usButtonFlags)) {
      const auto path = Utf8(DevicePath(raw.header.hDevice));
      if (!path.empty()) {
        identifying_.clear();
        Emit("identified", {{Value("type"), Value("mouse")}, {Value("id"), Value(path)}});
      }
      return;
    }
    if (!active_) return;
    // Absolute devices (some touchpads) are not interpreted as relative counts.
    const bool relative = (mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0;
    if (relative && shakes_[raw.header.hDevice].Add(mouse.lLastX, mouse.lLastY, now)) {
      Stop("shake"); return;
    }
    if (raw.header.hDevice != mouse_) { ++ignored_; return; }
    if (relative && (mouse.lLastX || mouse.lLastY)) {
      ++moves_;
      x_ = shared_input::MovePointer(x_, mouse.lLastX, speed_, 600.0);
      y_ = shared_input::MovePointer(y_, mouse.lLastY, speed_, 240.0);
      total_x_ += mouse.lLastX * speed_;
      total_y_ += mouse.lLastY * speed_;
      ++motion_sequence_;
    }
    if (mouse.usButtonFlags) ++buttons_;
    for (int button = 0; button < 5; ++button) {
      if (mouse.usButtonFlags & (1 << (button * 2))) {
        held_buttons_.insert(button);
        QueueInput({{Value("kind"), Value("button")}, {Value("button"), Value(button)}, {Value("down"), Value(true)}});
      }
      if (mouse.usButtonFlags & (2 << (button * 2))) {
        held_buttons_.erase(button);
        QueueInput({{Value("kind"), Value("button")}, {Value("button"), Value(button)}, {Value("down"), Value(false)}});
      }
    }
    if (mouse.usButtonFlags & (RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL)) {
      QueueInput({{Value("kind"), Value("wheel")},
          {Value("delta"), Value(static_cast<int>(static_cast<SHORT>(mouse.usButtonData)))},
          {Value("horizontal"), Value((mouse.usButtonFlags & RI_MOUSE_HWHEEL) != 0)}});
    }
  }
}

InputBridge::Map InputBridge::Stats() const {
  const auto elapsed = GetTickCount64() - started_;
  return {{Value("x"), Value(x_)}, {Value("y"), Value(y_)},
      {Value("keys"), Value(keys_)}, {Value("moves"), Value(moves_)},
      {Value("buttons"), Value(buttons_)}, {Value("ignored"), Value(ignored_)},
      {Value("held"), Value(static_cast<int>(held_keys_.size() + held_buttons_.size()))},
      {Value("released"), Value(released_)},
      {Value("remainingMs"), Value(static_cast<int64_t>(elapsed >= shared_input::kSessionLimitMs ? 0 : shared_input::kSessionLimitMs - elapsed))}};
}

void InputBridge::Emit(const std::string& method, Map data) {
  channel_->InvokeMethod(method, std::make_unique<Value>(std::move(data)));
}

void InputBridge::CancelSetup() {
  if (recording_) { recording_ = false; Emit("recordingCancelled"); }
  if (!identifying_.empty()) { identifying_.clear(); Emit("identificationCancelled"); }
}

std::optional<LRESULT> InputBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case kStreamMessage:
      stream_posted_ = false;
      if (static_cast<unsigned>(wparam) == generation_.load() && active_ && remote_capture_) FlushStream();
      return 0;
    case WM_INPUT:
      ReadInput(reinterpret_cast<HRAWINPUT>(lparam));
      // Foreground raw input requires DefWindowProc cleanup.
      return DefWindowProc(owner_, message, wparam, lparam);
    case WM_INPUT_DEVICE_CHANGE:
      if (wparam == GIDC_REMOVAL) {
        const auto device = reinterpret_cast<HANDLE>(lparam);
        physical_keys_.erase(device);
        shakes_.erase(device);
        if (active_ && (device == keyboard_ || device == mouse_)) Stop("device_removed");
      }
      Emit("devicesChanged");
      return 0;
    case WM_ACTIVATEAPP:
      if (!wparam) { Stop("focus_lost"); CancelSetup(); physical_keys_.clear(); }
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) { Stop("focus_lost"); CancelSetup(); }
      break;
    case WM_ENTERSIZEMOVE:
    case WM_SIZE:
    case WM_MOVE:
    case WM_DPICHANGED:
      Stop("window_changed");
      break;
    case WM_CLOSE:
    case WM_DESTROY:
    case WM_QUERYENDSESSION:
      Stop("shutdown");
      receiver_.Stop();
      CancelSetup();
      break;
    case WM_TIMER:
      if (wparam == kStatsTimer) {
        if ((recording_ || !identifying_.empty()) && GetTickCount64() - setup_since_ >= 10000) CancelSetup();
        if (active_) {
          if (GetForegroundWindow() != owner_ || GetFocus() != capture_) Stop("focus_lost");
          else Emit("stats", Stats());
        }
        return 0;
      }
      break;
    case kWatchdogMessage:
      if (static_cast<unsigned>(lparam) == generation_.load()) {
        Stop(wparam == 1 ? "timeout" : "heartbeat");
      }
      return 0;
    case kRestoreFocusMessage:
      if (!active_ && static_cast<unsigned>(lparam) == generation_.load()) {
        const bool had_focus = GetFocus() == capture_;
        ShowWindow(capture_, SW_HIDE);
        if (had_focus && GetForegroundWindow() == owner_) SetFocus(view_);
      }
      return 0;
  }
  return std::nullopt;
}

LRESULT CALLBACK InputBridge::CaptureProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(
        reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams));
  }
  auto self = reinterpret_cast<InputBridge*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (self) {
    if (message == WM_KILLFOCUS && self->active_) self->Stop("focus_lost");
    if (message == WM_SETCURSOR && self->active_) { SetCursor(nullptr); return TRUE; }
    // Independent legacy-message fallback for the exit chord, including
    // keyboards that do not provide a usable Raw Input device handle.
    if (self->active_ && (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) &&
        static_cast<int>(wparam) == self->shortcut_key_ &&
        (GetKeyState(VK_CONTROL) & 0x8000) && (GetKeyState(VK_MENU) & 0x8000) &&
        (((GetKeyState(VK_SHIFT) & 0x8000) != 0) == self->shortcut_shift_) &&
        !(GetKeyState(VK_LWIN) & 0x8000) && !(GetKeyState(VK_RWIN) & 0x8000)) {
      self->Stop("shortcut");
      return 0;
    }
    // Consume legacy input inside this focused native child, not globally.
    if ((message >= WM_KEYFIRST && message <= WM_KEYLAST) ||
        (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST)) return 0;
    if (message == WM_GETDLGCODE) return DLGC_WANTALLKEYS;
    if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      BeginPaint(window, &paint); EndPaint(window, &paint); return 0;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void InputBridge::Watchdog() {
  while (!closing_) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    std::lock_guard<std::mutex> lock(cursor_lease_);
    if (!armed_) continue;
    const auto now = GetTickCount64();
    const auto heartbeat = heartbeat_.load();
    const auto expiry = remote_capture_
        ? (now >= heartbeat && now - heartbeat >= shared_input::kHeartbeatLimitMs
            ? shared_input::Expiry::heartbeat : shared_input::Expiry::none)
        : shared_input::CheckExpiry(now, watch_started_, heartbeat);
    if (expiry == shared_input::Expiry::none) continue;
    // This thread releases confinement even if Flutter/the platform loop stalls.
    // Session generations prevent a queued old timeout stopping a new session.
    ReleaseCursorIfOwned();
    PostMessage(owner_, kWatchdogMessage,
        expiry == shared_input::Expiry::timeout ? 1 : 2, generation_.load());
  }
}

void InputBridge::ReleaseCursorIfOwned() {
  if (!armed_.exchange(false)) return;
  RECT current{};
  if (GetClipCursor(&current) && EqualRect(&current, &owned_clip_)) {
    ClipCursor(nullptr);
  }
}

void CALLBACK InputBridge::StreamTick(UINT, UINT, DWORD_PTR user, DWORD_PTR, DWORD_PTR) {
  auto self = reinterpret_cast<InputBridge*>(user);
  if (self->armed_ && !self->closing_ && !self->stream_posted_.exchange(true)) {
    PostMessage(self->owner_, kStreamMessage, self->generation_.load(), 0);
  }
}
void InputBridge::QueueInput(Map event) {
  if (!remote_capture_) return;
  if (input_events_.size() >= 256) { Stop("input_overflow"); return; }
  event[Value("epoch")] = Value(++event_epoch_);
  event[Value("sequence")] = Value(motion_sequence_);
  event[Value("x")] = Value(total_x_);
  event[Value("y")] = Value(total_y_);
  input_events_.emplace_back(std::move(event));
}
void InputBridge::FlushStream() {
  if (motion_sequence_ == flushed_sequence_ && event_epoch_ == flushed_epoch_) return;
  Emit("inputFrame", {{Value("sequence"), Value(motion_sequence_)}, {Value("epoch"), Value(event_epoch_)},
      {Value("x"), Value(total_x_)}, {Value("y"), Value(total_y_)}, {Value("events"), Value(std::move(input_events_))}});
  input_events_.clear();
  flushed_sequence_ = motion_sequence_;
  flushed_epoch_ = event_epoch_;
}
void InputBridge::StopStream() {
  if (stream_timer_) { timeKillEvent(stream_timer_); stream_timer_ = 0; }
  if (timer_resolution_) { timeEndPeriod(1); timer_resolution_ = false; }
  remote_capture_ = false;
  stream_posted_ = false;
  input_events_.clear();
}
