#ifndef SHARED_INPUT_EDGE_DRAG_PROBE_H_
#define SHARED_INPUT_EDGE_DRAG_PROBE_H_
#include <windows.h>
#include <oleidl.h>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "screen_layout.h"

struct DragPreviewFile { std::wstring name, path; bool promised = false; };
struct DragPreviewData {
  std::vector<DragPreviewFile> files;
  std::vector<std::wstring> formats;
  unsigned count = 0;
  bool truncated = false;
  std::wstring message;
};
// Reads only file names/paths and offered format names. Never reads contents,
// creates files, or reports a successful copy/move to the source.
DragPreviewData InspectDragObject(IDataObject* object);
RECT DragProbeBounds(RECT screen, shared_input::ScreenEdge edge, int thickness);

class EdgeDragProbe {
 public:
  static constexpr UINT kChangedMessage = WM_APP + 0x14d;
  struct State {
    HWND owner = nullptr, window = nullptr;
    bool enabled = false, hovering = false, hit_enabled = false;
    shared_input::ScreenEdge side = shared_input::ScreenEdge::right;
    std::string phase = "off";
    uint64_t revision = 0, generation = 0;
    uint64_t source_press = 0, metadata_press = 0;
    DragPreviewData data;
    void Changed();
  };
  explicit EdgeDragProbe(HWND owner);
  ~EdgeDragProbe();
  HRESULT Configure(bool enabled, shared_input::ScreenEdge side);
  void Clear();
  void Reposition();
  void SetDragging(bool dragging, uint64_t press = 0);
  void ObservePress(uint64_t press) { state_->source_press = press; }
  void Notify() { state_->Changed(); }
  bool Enabled() const { return state_->enabled; }
  const State& Snapshot() const { return *state_; }
 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  void Disable();
  std::shared_ptr<State> state_;
  IDropTarget* target_ = nullptr;
  HRESULT ole_;
};
IDropTarget* CreateDragPreviewTarget(std::shared_ptr<EdgeDragProbe::State> state);
#endif
