#include "clipboard_bridge.h"
#include "clipboard_image.h"
#include <algorithm>
#include <cstring>
#include <future>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kJobMessage = WM_APP + 0x24a;
const Value* Find(const Map& args, const char* key) {
  auto it = args.find(Value(key)); return it == args.end() ? nullptr : &it->second;
}
std::string Text(const Map& args, const char* key) {
  const auto value = Find(args, key);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}
bool Flag(const Map& args, const char* key) {
  const auto value = Find(args, key);
  return value && std::get_if<bool>(value) && std::get<bool>(*value);
}
std::string Revision() { return std::to_string(GetClipboardSequenceNumber()); }
UINT OriginFormat() { return RegisterClipboardFormatW(L"SharedInput.ClipboardOrigin.v1"); }
UINT PngFormat() { return RegisterClipboardFormatW(L"PNG"); }
std::vector<uint8_t> CopyGlobal(UINT format, size_t limit) {
  const HANDLE memory = GetClipboardData(format);
  const size_t size = memory ? GlobalSize(memory) : 0;
  if (!size || size > limit) return {};
  const auto data = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!data) return {};
  std::vector<uint8_t> result(data, data + size);
  GlobalUnlock(memory);
  return result;
}
HGLOBAL Memory(const void* data, size_t length) {
  if (!length) return nullptr;
  const HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, length);
  if (!memory) return nullptr;
  const auto target = GlobalLock(memory);
  if (!target) { GlobalFree(memory); return nullptr; }
  std::memcpy(target, data, length); GlobalUnlock(memory);
  return memory;
}
struct OwnedMemory {
  HGLOBAL value = nullptr;
  ~OwnedMemory() { if (value) GlobalFree(value); }
  bool Set(UINT format) {
    if (!value || !SetClipboardData(format, value)) return false;
    value = nullptr; return true;
  }
};
bool Open(HWND window) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (OpenClipboard(window)) return true;
    Sleep(10);
  }
  return false;
}
}

ClipboardBridge::ClipboardBridge(HWND owner) : owner_(owner) {
  std::promise<DWORD> started;
  auto ready = started.get_future();
  worker_ = std::thread([this, &started] {
    MSG message{};
    PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
    started.set_value(GetCurrentThreadId());
    Run();
  });
  thread_id_ = ready.get();
}
ClipboardBridge::~ClipboardBridge() {
  enabled_ = false; closing_ = true; ++generation_;
  PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
  if (worker_.joinable()) worker_.join();
  Complete();
}
void ClipboardBridge::Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
  const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (call.method_name() == "clipboardConfigure") {
    enabled_ = args && Flag(*args, "enabled"); ++generation_;
    result->Success(); return;
  }
  if (call.method_name() == "clipboardCancel") {
    ++generation_; result->Success(); return;
  }
  const bool thumbnail = call.method_name() == "fileDragThumbnail";
  if ((!enabled_ && !thumbnail) || closing_) { result->Success(); return; }
  if (!thumbnail && call.method_name() != "clipboardRead" && call.method_name() != "clipboardWrite") {
    result->NotImplemented(); return;
  }
  std::shared_ptr<Result> shared = std::move(result);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    jobs_.push_back(Job{call.method_name(), args ? *args : Map{}, shared, generation_.load()});
  }
  PostThreadMessageW(thread_id_, kJobMessage, 0, 0);
}
void ClipboardBridge::Run() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const HWND clipboard = CreateWindowExW(0, L"STATIC", L"Shared Input Clipboard", 0,
    0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (clipboard) AddClipboardFormatListener(clipboard);
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (message.message == kJobMessage) {
      std::optional<Job> job;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!jobs_.empty()) { job = std::move(jobs_.front()); jobs_.pop_front(); }
      }
      if (job) Process(std::move(*job), clipboard);
    } else { TranslateMessage(&message); DispatchMessageW(&message); }
  }
  std::deque<Job> remaining;
  { std::lock_guard<std::mutex> lock(mutex_); remaining.swap(jobs_); }
  for (auto& job : remaining) Reply(std::move(job.result), Value());
  if (clipboard) { RemoveClipboardFormatListener(clipboard); DestroyWindow(clipboard); }
  if (SUCCEEDED(initialized)) CoUninitialize();
}
void ClipboardBridge::Process(Job job, HWND clipboard) {
  if (job.method == "fileDragThumbnail") {
    const auto path = Text(job.arguments, "path");
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()), nullptr, 0);
    std::wstring wide(count > 0 ? count : 0, L'\0');
    if (count > 0) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()), wide.data(), count);
    const auto png = !closing_ && count > 0 ? shared_input::FileDragThumbnail(wide) : std::vector<uint8_t>{};
    Reply(std::move(job.result), png.empty() ? Value() : Value(png)); return;
  }
  if (!clipboard || !enabled_ || closing_ || job.generation != generation_) {
    Reply(std::move(job.result), Value()); return;
  }
  auto value = job.method == "clipboardRead"
    ? Read(job.arguments, clipboard, job.generation) : Write(job.arguments, clipboard, job.generation);
  Reply(std::move(job.result), std::move(value));
}
void ClipboardBridge::Reply(std::shared_ptr<Result> result, Value value, std::string error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    completions_.push_back(Completion{std::move(result), std::move(value), std::move(error)});
  }
  PostMessageW(owner_, kResultMessage, 0, 0);
}
void ClipboardBridge::Complete() {
  std::deque<Completion> values;
  { std::lock_guard<std::mutex> lock(mutex_); values.swap(completions_); }
  for (auto& value : values) {
    if (value.error.empty()) value.result->Success(value.value);
    else value.result->Error("clipboard_error", value.error);
  }
}
ClipboardBridge::Value ClipboardBridge::Read(const Map& args, HWND clipboard, uint64_t generation) {
  if (Text(args, "after") == Revision() || !Open(clipboard)) return Value();
  auto revision = Revision();
  std::string kind = "none", text, origin;
  std::vector<uint8_t> png;
  shared_input::ClipboardPixels pixels;
  auto marker = CopyGlobal(OriginFormat(), 128);
  if (!marker.empty()) {
    const auto end = std::find(marker.begin(), marker.end(), 0);
    origin.assign(marker.begin(), end);
  }
  if (!IsClipboardFormatAvailable(CF_HDROP)) {
    if (IsClipboardFormatAvailable(PngFormat())) {
      png = CopyGlobal(PngFormat(), shared_input::kClipboardImageLimit);
      if (!png.empty()) kind = "png";
    }
    if (kind == "none" && (IsClipboardFormatAvailable(CF_DIBV5) ||
        IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP)) &&
        shared_input::ReadClipboardPixels(pixels)) kind = "png";
    if (kind == "none" && IsClipboardFormatAvailable(CF_UNICODETEXT)) {
      const auto memory = GetClipboardData(CF_UNICODETEXT);
      const size_t size = memory ? GlobalSize(memory) : 0;
      if (size >= sizeof(wchar_t) && size <= (shared_input::kClipboardTextLimit + 1) * 2) {
        const auto data = static_cast<const wchar_t*>(GlobalLock(memory));
        if (data) {
          const auto end = std::find(data, data + size / sizeof(wchar_t), L'\0');
          if (end != data + size / sizeof(wchar_t)) {
            const int count = static_cast<int>(end - data);
            const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data, count,
              nullptr, 0, nullptr, nullptr);
            if ((count == 0 || length > 0) && length <= static_cast<int>(shared_input::kClipboardTextLimit)) {
              text.resize(length);
              if (length) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data, count,
                text.data(), length, nullptr, nullptr);
              kind = "text";
            }
          }
          GlobalUnlock(memory);
        }
      }
    }
  }
  revision = Revision();
  CloseClipboard();
  if (kind == "png") {
    if ((!png.empty() && !shared_input::DecodeClipboardImage(png, pixels)) ||
        !shared_input::EncodeClipboardPng(pixels, png)) {
      kind = "none"; png.clear();
    }
  }
  if (!enabled_ || closing_ || generation != generation_ || revision != Revision()) return Value();
  Map value{{Value("revision"), Value(revision)}, {Value("kind"), Value(kind)}};
  if (!origin.empty()) value[Value("origin")] = Value(origin);
  if (kind == "text") value[Value("text")] = Value(text);
  if (kind == "png") value[Value("data")] = Value(std::move(png));
  return Value(std::move(value));
}
ClipboardBridge::Value ClipboardBridge::Write(const Map& args, HWND clipboard, uint64_t generation) {
  const auto kind = Text(args, "kind"), origin = Text(args, "origin"), expected = Text(args, "expected");
  const auto value = Find(args, "data");
  const auto bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
  auto rejected = [] { return Value(Map{{Value("applied"), Value(false)}}); };
  if (!bytes || origin.size() != 32 || origin.find_first_not_of("0123456789abcdef") != std::string::npos) return rejected();
  OwnedMemory primary, png, marker;
  UINT format = 0;
  if (kind == "text") {
    if (bytes->size() > shared_input::kClipboardTextLimit ||
        std::find(bytes->begin(), bytes->end(), 0) != bytes->end()) return rejected();
    const auto chars = reinterpret_cast<const char*>(bytes->data());
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, chars,
      static_cast<int>(bytes->size()), nullptr, 0);
    if (!bytes->empty() && length <= 0) return rejected();
    std::wstring text(static_cast<size_t>(length), L'\0');
    if (length) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, chars,
      static_cast<int>(bytes->size()), text.data(), length);
    std::wstring native;
    native.reserve(text.size() + 1);
    for (size_t i = 0; i < text.size(); ++i) {
      if (text[i] == L'\n' && (i == 0 || text[i - 1] != L'\r')) native += L'\r';
      native += text[i];
    }
    primary.value = Memory(native.c_str(), (native.size() + 1) * sizeof(wchar_t));
    format = CF_UNICODETEXT;
  } else if (kind == "png") {
    shared_input::ClipboardPixels pixels;
    if (!shared_input::DecodeClipboardImage(*bytes, pixels)) return rejected();
    const auto dib = shared_input::ClipboardDibV5(pixels);
    primary.value = Memory(dib.data(), dib.size()); format = CF_DIBV5;
    png.value = Memory(bytes->data(), bytes->size());
    if (!png.value) return rejected();
  } else return rejected();
  marker.value = Memory(origin.c_str(), origin.size() + 1);
  if (!primary.value || !marker.value || !enabled_ || generation != generation_ || closing_ ||
      !Open(clipboard)) return rejected();
  if (Revision() != expected || !enabled_ || generation != generation_ || closing_) {
    CloseClipboard(); return rejected();
  }
  const bool applied = EmptyClipboard() && primary.Set(format);
  if (applied) { if (png.value) png.Set(PngFormat()); marker.Set(OriginFormat()); }
  CloseClipboard();
  return Value(Map{{Value("applied"), Value(applied)}});
}
