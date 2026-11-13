#ifndef SHARED_INPUT_REMOTE_RECEIVER_H_
#define SHARED_INPUT_REMOTE_RECEIVER_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <atomic>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>

class RemoteReceiver {
 public:
  RemoteReceiver();
  ~RemoteReceiver();
  bool Begin(const std::string& capture);
  bool Apply(const flutter::EncodableMap& args);
  bool Heartbeat();
  void Stop();
 private:
  void Release();
  bool Motion(const flutter::EncodableMap& frame);
  bool Event(const flutter::EncodableMap& frame);
  std::mutex mutex_;
  std::string capture_;
  uint64_t last_received_ = 0;
  int64_t sequence_ = -1;
  double total_x_ = 0, total_y_ = 0, cursor_x_ = 0, cursor_y_ = 0;
  POINT expected_position_{};
  std::set<std::pair<WORD, bool>> keys_;
  std::set<int> buttons_;
  std::atomic<bool> closing_{false};
  std::thread watchdog_;
};
#endif
