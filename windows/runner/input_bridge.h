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
#include "remote_receiver.h"
#include "background_hooks.h"
#include "edge_policy.h"
#include "clipboard_bridge.h"
#include "audio_output_monitor.h"
#include "audio_playback_bridge.h"
#include "edge_drag_probe.h"
#include "drag_handoff.h"
#include "screen_state_monitor.h"
#include "receiver_drag_press.h"

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
  void ProcessInput(const RAWINPUT& input, UINT bytes, bool from_hook = false);
  void EndSourceDragGesture();
  void ResumeBackgroundInput();
  Map EdgeState() const;
  bool ConfigureLayout(const Map& options);
  void RemotePointer(const Map& data);
  void Start(const Map& args, std::unique_ptr<Result> result);
  void Stop(const std::string& reason, bool notify = true);
  void CancelSetup();
  void Emit(const std::string& method, Map data = {});
  Map AudioOutput() const;
  Map ScreenState() const;
  Map DragProbeSnapshot() const;
  Map Stats() const;
  bool Down(int key) const;
  bool MatchesShortcut(int key) const;
  void Watchdog();
  // Requires cursor_lease_; also restores this process's keyboard registration.
  void ReleaseInputCapture(shared_input::ReleaseCause cause);
  static void CALLBACK StreamTick(UINT, UINT, DWORD_PTR user, DWORD_PTR, DWORD_PTR);
  void FlushStream();
  void QueueInput(Map event);
  void StopStream();
  HWND owner_, view_, capture_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::unique_ptr<ClipboardBridge> clipboard_;
  std::unique_ptr<AudioOutputMonitor> audio_output_;
  std::unique_ptr<AudioPlaybackBridge> audio_playback_;
  std::unique_ptr<EdgeDragProbe> drag_probe_;
  bool initialized_ = false, active_ = false, recording_ = false;
  bool session_notifications_ = false;
  std::unique_ptr<ScreenStateMonitor> screen_state_;
  bool identifying_local_key_ = false;
  uint32_t local_key_identify_token_ = 0;
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
  shared_input::ReceiverDragPress receiver_drag_press_;
  std::atomic<bool> closing_{false}, armed_{false};
  std::atomic<uint64_t> watch_started_{0}, heartbeat_{0};
  std::atomic<unsigned> generation_{0};
  std::mutex cursor_lease_;
  RECT owned_clip_{};
  bool keyboard_captured_ = false;
  bool edge_enabled_ = false, background_capture_ = false;
  shared_input::DragHandoff drag_handoff_;
  bool drag_capture_ = false;
  bool receiver_drag_test_ = false;
  unsigned drag_passthrough_buttons_ = 0;
  uint64_t edge_requested_ = 0, edge_cooldown_ = 0;
  double return_fraction_ = 0.5;
  shared_input::BackgroundHooks background_;
  shared_input::EdgeReturnPolicy edge_return_;
  shared_input::ScreenLayout display_layout_;
  std::atomic<uint64_t> pointer_received_{0};
  std::thread watchdog_;
  RemoteReceiver receiver_;
  UINT stream_timer_ = 0;
  bool timer_resolution_ = false;
  std::atomic<bool> stream_posted_{false}, remote_capture_{false};
  int64_t motion_sequence_ = 0, event_epoch_ = 0, flushed_sequence_ = 0, flushed_epoch_ = 0;
  double total_x_ = 0, total_y_ = 0;
  int64_t last_motion_us_ = 0, last_stream_us_ = 0;
  flutter::EncodableList input_events_;
};
#endif
