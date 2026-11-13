#ifndef SHARED_INPUT_CLIPBOARD_BRIDGE_H_
#define SHARED_INPUT_CLIPBOARD_BRIDGE_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <string>
#include <cstdint>

class ClipboardBridge {
 public:
  static constexpr UINT kResultMessage = WM_APP + 0x149;
  explicit ClipboardBridge(HWND owner);
  ~ClipboardBridge();
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Complete();
  void Reset() { enabled_ = false; ++generation_; }
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  struct Job {
    std::string method;
    Map arguments;
    std::shared_ptr<Result> result;
    uint64_t generation;
  };
  struct Completion {
    std::shared_ptr<Result> result;
    Value value;
    std::string error;
  };
  void Run();
  void Process(Job job, HWND clipboard);
  void Reply(std::shared_ptr<Result> result, Value value, std::string error = "");
  Value Read(const Map& args, HWND clipboard, uint64_t generation);
  Value Write(const Map& args, HWND clipboard, uint64_t generation);
  HWND owner_;
  std::thread worker_;
  DWORD thread_id_ = 0;
  std::atomic<bool> enabled_{false}, closing_{false};
  std::atomic<uint64_t> generation_{0};
  std::mutex mutex_;
  std::deque<Job> jobs_;
  std::deque<Completion> completions_;
};
#endif
