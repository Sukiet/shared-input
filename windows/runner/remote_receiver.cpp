#include "remote_receiver.h"
#include <algorithm>
#include <chrono>
#include <cmath>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
const V* Find(const M& map, const char* key) {
  const auto item = map.find(V(key));
  return item == map.end() ? nullptr : &item->second;
}
int64_t Integer(const M& map, const char* key, int64_t fallback = 0) {
  const auto v = Find(map, key);
  if (!v) return fallback;
  if (const auto n = std::get_if<int32_t>(v)) return *n;
  if (const auto n = std::get_if<int64_t>(v)) return *n;
  return fallback;
}
double Number(const M& map, const char* key) {
  const auto v = Find(map, key);
  if (v) { if (const auto n = std::get_if<double>(v)) return *n; }
  return static_cast<double>(Integer(map, key));
}
bool Boolean(const M& map, const char* key) {
  const auto v = Find(map, key);
  return v && std::get_if<bool>(v) && std::get<bool>(*v);
}
std::string String(const M& map, const char* key) {
  const auto v = Find(map, key);
  return v && std::get_if<std::string>(v) ? std::get<std::string>(*v) : "";
}
INPUT Button(int button, bool down) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  const DWORD flags[][2] = {{MOUSEEVENTF_LEFTUP, MOUSEEVENTF_LEFTDOWN},
      {MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_RIGHTDOWN},
      {MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MIDDLEDOWN},
      {MOUSEEVENTF_XUP, MOUSEEVENTF_XDOWN}, {MOUSEEVENTF_XUP, MOUSEEVENTF_XDOWN}};
  input.mi.dwFlags = flags[button][down ? 1 : 0];
  if (button >= 3) input.mi.mouseData = button == 3 ? XBUTTON1 : XBUTTON2;
  return input;
}
INPUT Key(WORD code, bool extended, bool down) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wScan = code;
  input.ki.dwFlags = KEYEVENTF_SCANCODE | (extended ? KEYEVENTF_EXTENDEDKEY : 0) |
      (down ? 0 : KEYEVENTF_KEYUP);
  return input;
}
}

RemoteReceiver::RemoteReceiver() {
  watchdog_ = std::thread([this] {
    while (!closing_) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      std::lock_guard<std::mutex> lock(mutex_);
      if (!capture_.empty() && GetTickCount64() - last_received_ >= 1500) Release();
    }
  });
}
RemoteReceiver::~RemoteReceiver() {
  closing_ = true;
  if (watchdog_.joinable()) watchdog_.join();
  Stop();
}
bool RemoteReceiver::Begin(const std::string& capture) {
  if (capture.size() != 32) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  Release();
  capture_ = capture;
  last_received_ = GetTickCount64();
  sequence_ = -1;
  total_x_ = total_y_ = 0;
  POINT point{};
  GetCursorPos(&point);
  cursor_x_ = point.x; cursor_y_ = point.y;
  expected_position_ = point;
  return true;
}
bool RemoteReceiver::Heartbeat() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (capture_.empty()) return false;
  last_received_ = GetTickCount64();
  return true;
}
void RemoteReceiver::Stop() {
  std::lock_guard<std::mutex> lock(mutex_);
  Release();
}
void RemoteReceiver::Release() {
  for (const auto& key : keys_) {
    auto input = Key(key.first, key.second, false);
    SendInput(1, &input, sizeof(INPUT));
  }
  for (int button : buttons_) {
    auto input = Button(button, false);
    SendInput(1, &input, sizeof(INPUT));
  }
  keys_.clear(); buttons_.clear(); capture_.clear();
}
bool RemoteReceiver::Motion(const M& frame) {
  const int64_t sequence = Integer(frame, "sequence", -1);
  if (sequence <= sequence_) return true;
  const double x = Number(frame, "x"), y = Number(frame, "y");
  if (!std::isfinite(x) || !std::isfinite(y) || std::abs(x) > 1e12 || std::abs(y) > 1e12) return false;
  const double dx = x - total_x_, dy = y - total_y_;
  sequence_ = sequence; total_x_ = x; total_y_ = y;
  if (dx == 0 && dy == 0) return true;
  POINT current{};
  if (!GetCursorPos(&current)) return false;
  if (current.x != expected_position_.x || current.y != expected_position_.y) {
    cursor_x_ = current.x; cursor_y_ = current.y;
  }
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  cursor_x_ = std::clamp(cursor_x_ + dx, static_cast<double>(left), static_cast<double>(left + width - 1));
  cursor_y_ = std::clamp(cursor_y_ + dy, static_cast<double>(top), static_cast<double>(top + height - 1));
  // Keep fractional accumulation separate from the last real pixel. Comparing
  // hardware position to a fractional value can otherwise reset low-gain motion.
  const int target_x = static_cast<int>(std::lround(cursor_x_));
  const int target_y = static_cast<int>(std::lround(cursor_y_));
  if (!SetCursorPos(target_x, target_y) || !GetCursorPos(&expected_position_)) return false;
  if (expected_position_.x != target_x || expected_position_.y != target_y) {
    cursor_x_ = expected_position_.x; cursor_y_ = expected_position_.y;
  }
  return true;
}
bool RemoteReceiver::Event(const M& frame) {
  const auto kind = String(frame, "kind");
  if (kind == "motion") return true;
  INPUT input{};
  const bool down = Boolean(frame, "down");
  if (kind == "key") {
    const auto code = Integer(frame, "code");
    if (code <= 0 || code > 255) return false;
    const auto key = std::make_pair(static_cast<WORD>(code), Boolean(frame, "extended"));
    if (down) keys_.insert(key); else keys_.erase(key);
    input = Key(key.first, key.second, down);
  } else if (kind == "button") {
    const auto button = Integer(frame, "button", -1);
    if (button < 0 || button > 4) return false;
    if (down) buttons_.insert(static_cast<int>(button)); else buttons_.erase(static_cast<int>(button));
    input = Button(static_cast<int>(button), down);
  } else if (kind == "wheel") {
    const auto delta = Integer(frame, "delta");
    if (std::abs(delta) > 32768) return false;
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = Boolean(frame, "horizontal") ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(delta);
  } else return false;
  return SendInput(1, &input, sizeof(INPUT)) == 1;
}
bool RemoteReceiver::Apply(const M& args) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (capture_.empty() || String(args, "capture") != capture_) return false;
  const auto frames_value = Find(args, "frames");
  const auto frames = frames_value ? std::get_if<flutter::EncodableList>(frames_value) : nullptr;
  if (!frames || frames->size() > 256) return false;
  for (const auto& value : *frames) {
    const auto frame = std::get_if<M>(&value);
    if (!frame || !Motion(*frame) || !Event(*frame)) { Release(); return false; }
  }
  last_received_ = GetTickCount64();
  return true;
}
