#include "../../windows/runner/edge_drag_probe.h"
#include "../../windows/runner/drag_gesture.h"
#include <ole2.h>
#include <shlobj.h>
#include <shellapi.h>
#include <cstdlib>
#include <cstring>
#include <iostream>

void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
class DataObject final : public IDataObject {
 public:
  CLIPFORMAT format = CF_HDROP;
  std::vector<BYTE> bytes;
  int reads = 0, writes = 0;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (id != __uuidof(IUnknown) && id != __uuidof(IDataObject)) return E_NOINTERFACE;
    *value = static_cast<IDataObject*>(this); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* request, STGMEDIUM* result) override {
    Check(request->cfFormat == format, "only offered metadata format may be read");
    ++reads; *result = {};
    result->tymed = TYMED_HGLOBAL;
    result->hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.size());
    if (!result->hGlobal) return E_OUTOFMEMORY;
    auto target = GlobalLock(result->hGlobal);
    std::memcpy(target, bytes.data(), bytes.size()); GlobalUnlock(result->hGlobal);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* request) override { return request->cfFormat == format && request->tymed == TYMED_HGLOBAL ? S_OK : DV_E_FORMATETC; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* value) override { value->ptd = nullptr; return DATA_S_SAMEFORMATETC; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { ++writes; return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
  void Paths(const std::vector<std::wstring>& paths) {
    format = CF_HDROP;
    std::wstring joined;
    for (const auto& path : paths) { joined += path; joined.push_back(0); }
    joined.push_back(0);
    DROPFILES header{}; header.pFiles = sizeof(header); header.fWide = TRUE;
    bytes.resize(sizeof(header) + joined.size() * sizeof(wchar_t));
    std::memcpy(bytes.data(), &header, sizeof(header));
    std::memcpy(bytes.data() + sizeof(header), joined.data(), joined.size() * sizeof(wchar_t));
  }
};
int main() {
  SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  shared_input::DragGesture gesture;
  gesture.Move(1000, 1000, 4, 4); Check(!gesture.Active(), "ordinary movement remains click-through");
  gesture.Button(0, true, 10, 10); gesture.Move(11, 11, 4, 4);
  Check(!gesture.Active(), "clicks and small hand jitter never open the hit region");
  gesture.Button(0, false, 11, 11); Check(!gesture.Active(), "ordinary click release remains click-through");
  gesture.Button(0, true, 10, 10); gesture.Move(14, 10, 4, 4);
  Check(gesture.Active(), "actual drag opens edge region after the threshold");
  gesture.Button(0, false, 14, 10); Check(!gesture.Active(), "release immediately closes drag eligibility");
  gesture.Button(2, true, 10, 10); gesture.Move(1000, 1000, 4, 4);
  Check(!gesture.Active(), "middle-button panning is not treated as file drag");
  gesture.Button(1, true, 10, 10); gesture.Move(10, 15, 4, 4);
  Check(gesture.Active(), "right-button drag is supported");
  DataObject source;
  source.Paths({L"C:\\照片\\图像.png", L"D:\\工作文件夹"});
  auto data = InspectDragObject(&source);
  Check(data.count == 2 && data.files.size() == 2, "Unicode and multiple paths extracted without disk access");
  Check(data.files[0].name == L"图像.png" && data.files[1].path == L"D:\\工作文件夹", "names and full paths preserved");
  Check(source.reads == 1 && source.writes == 0, "metadata read once, source never written");
  std::vector<std::wstring> many(300, L"C:\\大量文件.txt"); source.Paths(many);
  data = InspectDragObject(&source);
  Check(data.count == 300 && data.files.size() == 256 && data.truncated, "large lists bounded with actual item count retained");
  source.Paths({L"C:\\file.txt"});
  DROPFILES malformed{}; malformed.pFiles = 0xffffffff; malformed.fWide = TRUE;
  std::memcpy(source.bytes.data(), &malformed, sizeof(malformed));
  data = InspectDragObject(&source);
  Check(data.files.empty() && !data.message.empty(), "invalid metadata offsets rejected");
  source.format = static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"FileGroupDescriptorW"));
  FILEGROUPDESCRIPTORW group{}; group.cItems = 1;
  std::memcpy(group.fgd[0].cFileName, L"附件.txt", sizeof(L"附件.txt"));
  source.bytes.resize(sizeof(group)); std::memcpy(source.bytes.data(), &group, sizeof(group));
  data = InspectDragObject(&source);
  Check(data.count == 1 && data.files.front().promised && data.files.front().path.empty(), "file promise names recognized without reading contents");
  group.cItems = 0xffffffff; std::memcpy(source.bytes.data(), &group, sizeof(group));
  Check(InspectDragObject(&source).files.empty(), "invalid promise count rejected");
  source.Paths({L"C:\\file.txt"});
  auto state = std::make_shared<EdgeDragProbe::State>(); state->enabled = true;
  auto target = CreateDragPreviewTarget(state);
  DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
  Check(target->DragEnter(&source, MK_LBUTTON, POINTL{}, &effect) == S_OK && effect == DROPEFFECT_NONE,
      "DragEnter previews while refusing copy and move");
  Check(state->data.files.size() == 1 && state->phase == "enter", "OLE callback publishes file list");
  effect = DROPEFFECT_COPY;
  target->DragOver(MK_LBUTTON, POINTL{}, &effect);
  Check(effect == DROPEFFECT_NONE, "DragOver never accepts a transfer");
  target->DragLeave(); Check(state->data.files.size() == 1 && state->phase == "leave", "preview retained on leave");
  effect = DROPEFFECT_MOVE;
  target->Drop(&source, 0, POINTL{}, &effect);
  Check(effect == DROPEFFECT_NONE && source.writes == 0, "Drop cannot acknowledge move or alter source");
  target->Release();
  const RECT screen{-100, 20, 1820, 1100};
  const auto right = DragProbeBounds(screen, shared_input::ScreenEdge::right, 1);
  const auto bottom = DragProbeBounds(screen, shared_input::ScreenEdge::bottom, 1);
  Check(right.left == 1819 && right.top == 20 && right.bottom == 1100 && bottom.top == 1099, "one-pixel edge geometry respects screen origin");
  HWND owner = CreateWindowExW(0, L"STATIC", L"DragProbeTestOwner", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  {
    EdgeDragProbe probe(owner);
    const auto foreground = GetForegroundWindow();
    const auto result = probe.Configure(true, shared_input::ScreenEdge::right);
    Check(SUCCEEDED(result) && IsWindow(probe.Snapshot().window), "real OLE target registers successfully");
    Check(GetForegroundWindow() == foreground, "edge preview does not steal focus");
    const auto window = probe.Snapshot().window;
    Check((GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_NOACTIVATE) != 0, "preview remains nonactivating");
    Check((GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_NOREDIRECTIONBITMAP) != 0, "preview has no visual redirection surface");
    RECT bounds{}; GetWindowRect(window, &bounds);
    Check(bounds.right - bounds.left == 1, "receiver occupies exactly one physical pixel");
    const auto region = CreateRectRgn(0, 0, 0, 0);
    Check(GetWindowRgn(window, region) == NULLREGION, "idle receiver has an empty, click-through region");
    const auto initial_revision = probe.Snapshot().revision;
    probe.SetDragging(true);
    Check(GetWindowRgn(window, region) == SIMPLEREGION, "dragging enables only the one-pixel region");
    Check(probe.Snapshot().hit_enabled && probe.Snapshot().revision > initial_revision,
        "actual region opening publishes new UI state");
    const auto opened_revision = probe.Snapshot().revision;
    probe.SetDragging(true);
    Check(probe.Snapshot().revision == opened_revision, "unchanged hit state does not flood the UI");
    probe.SetDragging(false);
    Check(GetWindowRgn(window, region) == NULLREGION, "ending drag restores click-through region");
    Check(!probe.Snapshot().hit_enabled && probe.Snapshot().revision > opened_revision,
        "actual region closing publishes new UI state");
    DeleteObject(region);
    probe.Configure(false, shared_input::ScreenEdge::right);
    Check(!probe.Enabled() && !IsWindow(window), "disabling revokes and destroys edge receiver");
  }
  DestroyWindow(owner);
  std::cout << "OLE file metadata, bounded parsing, preview-only effects, edge registration and cleanup passed.\n";
}
