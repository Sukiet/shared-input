#include "edge_drag_probe.h"
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <algorithm>
#include <atomic>
#include <cstring>

namespace {
constexpr size_t kMaxMetadata = 16 * 1024 * 1024, kMaxFiles = 256;
constexpr wchar_t kWindowClass[] = L"SharedInputEdgeDragProbe";
struct Medium {
  STGMEDIUM value{};
  ~Medium() { if (value.tymed != TYMED_NULL) ReleaseStgMedium(&value); }
};
struct GlobalView {
  HGLOBAL handle;
  const BYTE* bytes;
  size_t size;
  explicit GlobalView(HGLOBAL value) : handle(value), bytes(nullptr), size(GlobalSize(value)) {
    if (size && size <= kMaxMetadata) bytes = static_cast<const BYTE*>(GlobalLock(value));
  }
  ~GlobalView() { if (bytes) GlobalUnlock(handle); }
};
std::wstring BaseName(const std::wstring& path) {
  const auto end = path.find_last_not_of(L"\\/");
  if (end == std::wstring::npos) return path;
  const auto begin = path.find_last_of(L"\\/", end);
  return path.substr(begin == std::wstring::npos ? 0 : begin + 1, end - (begin == std::wstring::npos ? 0 : begin + 1) + 1);
}
bool ReadPaths(HGLOBAL global, DragPreviewData& output) {
  GlobalView view(global);
  if (!view.bytes || view.size < sizeof(DROPFILES)) return false;
  DROPFILES header{}; std::memcpy(&header, view.bytes, sizeof(header));
  if (header.pFiles < sizeof(header) || header.pFiles >= view.size) return false;
  const size_t unit = header.fWide ? sizeof(wchar_t) : 1;
  const size_t available = view.size - header.pFiles;
  if (available < unit * 2 || (header.fWide && (header.pFiles % unit || available % unit))) return false;
  size_t offset = header.pFiles;
  auto character = [&](size_t at) {
    wchar_t value = 0;
    if (header.fWide) std::memcpy(&value, view.bytes + at, sizeof(value));
    else value = view.bytes[at];
    return value;
  };
  while (offset + unit <= view.size) {
    const auto begin = offset;
    while (offset + unit <= view.size && character(offset)) offset += unit;
    if (offset + unit > view.size) return false;
    if (offset == begin) return true; // Double-null terminator (or empty list).
    if ((offset - begin) / unit > 32768) return false;
    std::wstring path;
    if (header.fWide) {
      path.resize((offset - begin) / unit);
      std::memcpy(path.data(), view.bytes + begin, offset - begin);
    } else {
      const auto length = static_cast<int>(offset - begin);
      const auto text = reinterpret_cast<const char*>(view.bytes + begin);
      const int count = MultiByteToWideChar(CP_ACP, 0, text, length, nullptr, 0);
      if (count <= 0) return false;
      path.resize(count); MultiByteToWideChar(CP_ACP, 0, text, length, path.data(), count);
    }
    ++output.count;
    if (output.files.size() < kMaxFiles) output.files.push_back({BaseName(path), std::move(path), false});
    else output.truncated = true;
    offset += unit;
  }
  return false;
}
bool ReadPromises(HGLOBAL global, DragPreviewData& output) {
  GlobalView view(global);
  if (!view.bytes || view.size < offsetof(FILEGROUPDESCRIPTORW, fgd)) return false;
  UINT count = 0; std::memcpy(&count, view.bytes, sizeof(count));
  if (count > (view.size - offsetof(FILEGROUPDESCRIPTORW, fgd)) / sizeof(FILEDESCRIPTORW)) return false;
  output.count = count; output.truncated = count > kMaxFiles;
  for (size_t i = 0; i < std::min<size_t>(count, kMaxFiles); ++i) {
    FILEDESCRIPTORW descriptor{};
    std::memcpy(&descriptor, view.bytes + offsetof(FILEGROUPDESCRIPTORW, fgd) + i * sizeof(descriptor), sizeof(descriptor));
    const auto end = std::find(std::begin(descriptor.cFileName), std::end(descriptor.cFileName), L'\0');
    if (end == std::end(descriptor.cFileName) || end == std::begin(descriptor.cFileName)) return false;
    output.files.push_back({std::wstring(descriptor.cFileName, end), L"", true});
  }
  return true;
}
void ReadFormats(IDataObject* object, DragPreviewData& output) {
  IEnumFORMATETC* formats = nullptr;
  if (FAILED(object->EnumFormatEtc(DATADIR_GET, &formats)) || !formats) return;
  FORMATETC value{};
  for (int i = 0; i < 32 && formats->Next(1, &value, nullptr) == S_OK; ++i) {
    wchar_t name[256]{};
    if (value.cfFormat == CF_HDROP) output.formats.emplace_back(L"CF_HDROP");
    else if (GetClipboardFormatNameW(value.cfFormat, name, 256)) output.formats.emplace_back(name);
    else output.formats.emplace_back(L"格式 " + std::to_wstring(value.cfFormat));
    if (value.ptd) CoTaskMemFree(value.ptd);
    value = {};
  }
  formats->Release();
}
class PreviewTarget final : public IDropTarget {
 public:
  explicit PreviewTarget(std::shared_ptr<EdgeDragProbe::State> state) : state_(std::move(state)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (id != __uuidof(IUnknown) && id != __uuidof(IDropTarget)) return E_NOINTERFACE;
    *result = static_cast<IDropTarget*>(this); AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { const auto count = --references_; if (!count) delete this; return count; }
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* object, DWORD, POINTL, DWORD* effect) override {
    if (!effect) return E_POINTER;
    *effect = DROPEFFECT_NONE;
    const auto generation = state_->generation;
    auto data = InspectDragObject(object);
    if (state_->enabled && generation == state_->generation) {
      state_->data = std::move(data); state_->hovering = true;
      state_->metadata_press = state_->source_press;
      state_->phase = state_->data.count ? "enter" : "unsupported"; state_->Changed();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    if (!effect) return E_POINTER;
    *effect = DROPEFFECT_NONE; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (state_->enabled) { state_->hovering = false; state_->phase = "leave"; state_->Changed(); }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD* effect) override {
    if (!effect) return E_POINTER;
    *effect = DROPEFFECT_NONE; // Never acknowledge receipt, copy or move.
    if (state_->enabled) { state_->hovering = false; state_->phase = "drop"; state_->Changed(); }
    return S_OK;
  }
 private:
  std::atomic<ULONG> references_{1};
  std::shared_ptr<EdgeDragProbe::State> state_;
};
}  // namespace

IDropTarget* CreateDragPreviewTarget(std::shared_ptr<EdgeDragProbe::State> state) {
  return new PreviewTarget(std::move(state));
}

DragPreviewData InspectDragObject(IDataObject* object) {
  DragPreviewData output;
  if (!object) { output.message = L"没有拖拽数据对象"; return output; }
  ReadFormats(object, output);
  for (const auto format : {static_cast<CLIPFORMAT>(CF_HDROP), static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"FileGroupDescriptorW"))}) {
    FORMATETC request{format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    if (object->QueryGetData(&request) != S_OK) continue;
    Medium medium;
    if (FAILED(object->GetData(&request, &medium.value)) || medium.value.tymed != TYMED_HGLOBAL || !medium.value.hGlobal) continue;
    DragPreviewData data;
    const bool valid = format == CF_HDROP ? ReadPaths(medium.value.hGlobal, data) : ReadPromises(medium.value.hGlobal, data);
    if (valid) {
      data.formats = std::move(output.formats); return data;
    }
    output.message = L"文件列表格式无效，未读取文件内容";
  }
  if (output.message.empty()) output.message = L"该对象没有可识别的文件列表";
  return output;
}
RECT DragProbeBounds(RECT screen, shared_input::ScreenEdge side, int thickness) {
  const LONG width = screen.right - screen.left, height = screen.bottom - screen.top;
  const LONG band = std::max<LONG>(1, thickness);
  switch (side) {
    case shared_input::ScreenEdge::right: screen.left = screen.right - std::min(width, band); break;
    case shared_input::ScreenEdge::left: screen.right = screen.left + std::min(width, band); break;
    case shared_input::ScreenEdge::top: screen.bottom = screen.top + std::min(height, band); break;
    case shared_input::ScreenEdge::bottom: screen.top = screen.bottom - std::min(height, band); break;
  }
  return screen;
}
void EdgeDragProbe::State::Changed() {
  ++revision;
  if (owner && IsWindow(owner)) PostMessageW(owner, kChangedMessage, 0, 0);
}
EdgeDragProbe::EdgeDragProbe(HWND owner) : state_(std::make_shared<State>()), ole_(OleInitialize(nullptr)) {
  state_->owner = owner;
}
EdgeDragProbe::~EdgeDragProbe() {
  state_->owner = nullptr; Disable();
  if (SUCCEEDED(ole_)) OleUninitialize();
}
void EdgeDragProbe::Disable() {
  state_->enabled = false; state_->hovering = false; state_->hit_enabled = false; ++state_->generation;
  if (target_) {
    RevokeDragDrop(state_->window); target_->Release(); target_ = nullptr;
  }
  if (state_->window) DestroyWindow(state_->window);
  state_->window = nullptr; state_->phase = "off";
}
HRESULT EdgeDragProbe::Configure(bool enabled, shared_input::ScreenEdge side) {
  state_->side = side;
  if (!enabled) { Disable(); state_->Changed(); return S_OK; }
  if (FAILED(ole_)) return ole_;
  if (state_->enabled) { Reposition(); state_->Changed(); return S_OK; }
  WNDCLASSW existing{};
  const auto instance = GetModuleHandleW(nullptr);
  if (!GetClassInfoW(instance, kWindowClass, &existing)) {
    WNDCLASSW definition{}; definition.hInstance = instance; definition.lpfnWndProc = WindowProc;
    definition.lpszClassName = kWindowClass; definition.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    if (!RegisterClassW(&definition)) return HRESULT_FROM_WIN32(GetLastError());
  }
  state_->window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP,
      kWindowClass, L"Shared Input - Edge Drag Preview", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, instance, state_.get());
  if (!state_->window) return HRESULT_FROM_WIN32(GetLastError());
  auto target = CreateDragPreviewTarget(state_);
  const auto result = RegisterDragDrop(state_->window, target);
  if (FAILED(result)) { target->Release(); Disable(); return result; }
  target_ = target;
  state_->enabled = true; state_->hit_enabled = false; state_->phase = "waiting"; ++state_->generation;
  Reposition(); state_->Changed(); return S_OK;
}
void EdgeDragProbe::Clear() { state_->data = {}; state_->phase = state_->enabled ? "waiting" : "off"; state_->Changed(); }
void EdgeDragProbe::Reposition() {
  if (!state_->enabled || !state_->window) return;
  MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY), &monitor)) return;
  const auto bounds = DragProbeBounds(monitor.rcMonitor, state_->side, 1);
  SetWindowPos(state_->window, HWND_TOPMOST, bounds.left, bounds.top, bounds.right - bounds.left,
      bounds.bottom - bounds.top, SWP_NOACTIVATE);
  SetDragging(state_->hit_enabled);
  ShowWindow(state_->window, SW_SHOWNOACTIVATE);
}
void EdgeDragProbe::SetDragging(bool dragging, uint64_t press) {
  if (press != 0) state_->source_press = press;
  if (!state_->enabled || !state_->window) return;
  RECT bounds{};
  if (dragging) GetClientRect(state_->window, &bounds);
  // Empty regions are ignored by mouse hit testing across processes. A real
  // drag opens only the last physical pixel; no synthetic forwarding is used.
  const auto region = CreateRectRgn(bounds.left, bounds.top, bounds.right, bounds.bottom);
  if (!region) return;
  if (SetWindowRgn(state_->window, region, FALSE)) {
    if (state_->hit_enabled != dragging) {
      state_->hit_enabled = dragging;
      state_->Changed();
    }
  } else DeleteObject(region);
}
LRESULT CALLBACK EdgeDragProbe::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) SetWindowLongPtrW(window, GWLP_USERDATA,
      reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams));
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_ERASEBKGND) return 1;
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{}; BeginPaint(window, &paint); EndPaint(window, &paint); return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
