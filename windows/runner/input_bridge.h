#ifndef SHARED_INPUT_INPUT_BRIDGE_H_
#define SHARED_INPUT_INPUT_BRIDGE_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>
#include "safety_policy.h"

class InputBridge {
 public:
  InputBridge(HWND owner, HWND view, flutter::BinaryMessenger* messenger);
  ~InputBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  struct Device {
    HANDLE handle;
    std::string id, name, type;
    bool usb;
  };
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  static LRESULT CALLBACK CaptureProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  void OnMethod(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  bool Initialize();
  std::vector<Device> Enumerate();
  void ReadInput(HRAWINPUT input);
  void Start(const Map& args, std::unique_ptr<Result> result);
  void Stop(const std::string& reason, bool notify = true);
  void CancelSetup();
  void Emit(const std::string& method, Map data = {});
  Map Stats() const;
  bool Down(int key) const;
  bool MatchesShortcut(int key) const;
  void Watchdog();
  // Requires cursor_lease_; do not clear confinement installed by another app.
  void ReleaseCursorIfOwned();
  HWND owner_, view_, capture_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  bool initialized_ = false, active_ = false, recording_ = false;
  std::string identifying_;
  uint64_t setup_since_ = 0, started_ = 0;
  HANDLE keyboard_ = nullptr, mouse_ = nullptr;
  int shortcut_key_ = 0;
  bool shortcut_shift_ = false;
  std::string shortcut_label_;
  double speed_ = 0.1, x_ = 300, y_ = 120;
  int keys_ = 0, moves_ = 0, buttons_ = 0, ignored_ = 0, released_ = 0;
  std::map<HANDLE, std::set<int>> physical_keys_;
  std::set<int> held_keys_, held_buttons_;
  std::map<HANDLE, shared_input::ShakeDetector> shakes_;
  std::atomic<bool> closing_{false}, armed_{false};
  std::atomic<uint64_t> watch_started_{0}, heartbeat_{0};
  std::atomic<unsigned> generation_{0};
  std::mutex cursor_lease_;
  RECT owned_clip_{};
  std::thread watchdog_;
};
#endif
