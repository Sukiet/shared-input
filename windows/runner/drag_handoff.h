#ifndef SHARED_INPUT_DRAG_HANDOFF_H_
#define SHARED_INPUT_DRAG_HANDOFF_H_
#include <cstdint>
#include <string>
#include <vector>

namespace shared_input {
inline bool CanBeginWithLocalButtons(bool keys_held, unsigned buttons, unsigned local_buttons) {
  return !keys_held && (local_buttons == 0 || local_buttons == 1 || local_buttons == 2) && buttons == local_buttons;
}
// Windows-origin experiment: source button remains owned by Windows. Pointer
// control may cross, but no file or synthetic button-down is delivered to Mac.
class DragHandoff {
 public:
  void Reset() {
    ++flow_; gesture_ = remote_ = false; buttons_ = 0;
    stage_ = "idle"; reason_.clear(); history_.clear();
  }
  bool Gesture(unsigned buttons) {
    if (remote_ || gesture_ || (buttons != 1 && buttons != 2)) return false;
    ++flow_; gesture_ = true; buttons_ = buttons; history_.clear(); reason_.clear();
    Change("gesture"); return true;
  }
  bool EdgeReceived() {
    if (!gesture_ || stage_ != "gesture") return false;
    Change("edge"); return true;
  }
  // Edge motion, rather than a fresh mouse-down or OLE callback, initiates
  // each crossing. The same physical hold may cross repeatedly after return.
  bool PushEdge(unsigned buttons) {
    if (remote_ || (buttons != 1 && buttons != 2) ||
        stage_ == "edge" || stage_ == "switching") return false;
    if (stage_ == "error") { gesture_ = false; buttons_ = 0; }
    if (!gesture_ && !Gesture(buttons)) return false;
    return EdgeReceived();
  }
  bool Ready(uint64_t flow) const {
    return flow != 0 && flow == flow_ && gesture_ && !remote_ && (stage_ == "edge" || stage_ == "switching");
  }
  bool Prepare(uint64_t flow) {
    if (!Ready(flow)) return false;
    if (stage_ != "switching") Change("switching");
    return true;
  }
  bool Crossed(uint64_t flow) {
    if (!Ready(flow) || stage_ != "switching") return false;
    remote_ = true; Change("crossed"); return true;
  }
  bool EndGesture() {
    if (!gesture_) return false;
    gesture_ = false; buttons_ = 0;
    Change("ended");
    return true;
  }
  bool Returned(const std::string& reason) {
    if (!remote_) return false;
    remote_ = gesture_ = false; buttons_ = 0;
    reason_ = reason; Change("returned"); return true;
  }
  bool Failed(uint64_t flow, const std::string& reason) {
    if (!Ready(flow)) return false;
    reason_ = reason; Change("error"); return true;
  }
  uint64_t Flow() const { return flow_; }
  bool GestureActive() const { return gesture_; }
  bool Remote() const { return remote_; }
  unsigned Buttons() const { return buttons_; }
  const std::string& Stage() const { return stage_; }
  const std::string& Reason() const { return reason_; }
  const std::vector<std::string>& History() const { return history_; }
 private:
  void Change(const char* stage) { stage_ = stage; history_.push_back(stage); }
  uint64_t flow_ = 0;
  bool gesture_ = false, remote_ = false;
  unsigned buttons_ = 0;
  std::string stage_ = "idle", reason_;
  std::vector<std::string> history_;
};
}  // namespace shared_input
#endif
