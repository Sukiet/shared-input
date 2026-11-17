#include "../../windows/runner/drag_handoff.h"
#include "../../windows/runner/mouse_routing.h"
#include <cstdlib>
#include <iostream>

void Check(bool value, const char* message) {
  if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
  using namespace shared_input;
  Check(CanBeginWithLocalButtons(false, 0, 0), "normal idle entry works");
  Check(!CanBeginWithLocalButtons(false, 1, 0), "normal entry still rejects held buttons");
  for (unsigned source : {1u, 2u}) {
    Check(CanBeginWithLocalButtons(false, source, source), "source button may stay on Windows");
    Check(!CanBeginWithLocalButtons(true, source, source), "held keyboard cancels handoff");
    Check(!CanBeginWithLocalButtons(false, source | 4, source), "additional held button cancels");
    Check(!CanBeginWithLocalButtons(false, 0, source), "release before native begin cancels");
  }
  Check(!CanBeginWithLocalButtons(false, 3, 3), "two-button source cannot bypass guard");
  Check(!CanBeginWithLocalButtons(false, 4, 4), "middle button cannot bypass guard");
  DragHandoff drag;
  Check(!drag.EdgeReceived() && !drag.Ready(0), "metadata alone cannot create a gesture");
  Check(!drag.Gesture(3), "reject ambiguous buttons");
  Check(drag.Gesture(1), "observe Windows gesture");
  const auto first = drag.Flow();
  Check(!drag.Prepare(first), "no crossing before OLE edge receipt");
  Check(drag.EdgeReceived() && !drag.EdgeReceived(), "edge receipt is idempotent");
  Check(!drag.Prepare(first + 1), "stale flow cannot take control");
  Check(drag.Prepare(first) && drag.Crossed(first), "acknowledged edge crosses");
  Check(drag.Remote() && drag.GestureActive(), "source gesture persists across crossing");
  Check(!drag.Gesture(2), "Mac-origin gestures cannot replace tracked flow");
  Check(drag.EndGesture() && drag.Remote(), "release ends source gesture without returning pointer");
  Check(drag.Returned("edge") && !drag.Remote(), "return is distinct from release");
  Check(drag.History() == std::vector<std::string>({"gesture", "edge", "switching", "crossed", "ended", "returned"}), "complete release then return history");
  Check(drag.Gesture(2), "next Windows gesture starts another flow");
  const auto second = drag.Flow();
  Check(second > first && drag.EdgeReceived() && drag.Prepare(second) && drag.Crossed(second), "right-button source crosses");
  Check(drag.Returned("shortcut") && !drag.GestureActive() && drag.Buttons() == 0,
      "return terminates handoff even if source release has not arrived");
  Check(!drag.EndGesture() && drag.Stage() == "returned", "late release is harmless after terminal return");
  Check(drag.History().back() == "returned", "return is the terminal stage");
  Check(!drag.Ready(second), "returned flow cannot capture again from a stale edge callback");
  Check(drag.Gesture(1) && drag.EdgeReceived(), "start pending flow");
  const auto third = drag.Flow();
  Check(drag.Prepare(third) && drag.EndGesture(), "release during peer begin cancels");
  Check(!drag.Ready(third) && !drag.Crossed(third) && !drag.Failed(third, "late failure"), "late async completion cannot capture or overwrite release");
  Check(drag.Gesture(1) && drag.EdgeReceived(), "start failing flow");
  const auto fourth = drag.Flow();
  Check(drag.Failed(fourth, "peer unavailable") && !drag.Prepare(fourth), "failure requires another gesture to retry");
  drag.EndGesture(); drag.Reset();
  Check(drag.Flow() > fourth && drag.Stage() == "idle" && drag.History().empty(), "clear invalidates all prior flow ids");
  Check(!drag.Ready(fourth), "clear rejects stale work");
  DragHandoff continuous;
  uint64_t previous = 0;
  for (int crossing = 0; crossing < 5; ++crossing) {
    // No EndGesture, Gesture, OLE receipt, or new button-down between cycles.
    Check(continuous.PushEdge(1), "same held source can push the edge again");
    const auto flow = continuous.Flow();
    Check(flow > previous, "each crossing invalidates the previous async attempt");
    Check(!continuous.PushEdge(1), "additional motion does not duplicate an in-flight crossing");
    Check(continuous.Prepare(flow) && continuous.Crossed(flow), "held source crosses without OLE metadata");
    Check(!continuous.PushEdge(1), "remote motion cannot reenter before return");
    Check(continuous.Returned("edge"), "same source returns");
    previous = flow;
  }
  Check(continuous.PushEdge(2), "right-button hold can also push the edge");
  const auto failed = continuous.Flow();
  Check(continuous.Failed(failed, "temporary failure") && continuous.PushEdge(2),
      "next edge push may retry without releasing after a failure");
  Check(continuous.Flow() > failed, "retry does not reuse cancelled flow");
  MouseRouting routing;
  Check(!routing.Remote(0, true, false, false), "Windows-origin down stays local");
  Check(routing.ReconcileCandidates(1, 0, false) == 1, "Windows delivered down can use async release recovery");
  routing.TransferToLocal(1);
  Check(!routing.Remote(0, false, true, true), "Windows source up stays local while controlling Mac");
  Check(routing.Remote(0, true, true, false), "a new press on Mac belongs to Mac");
  Check(routing.ReconcileCandidates(1, 0, false) == 0,
      "return from Mac must not clear a physical hold absent from Windows async state");
  routing.TransferToLocal(1);
  Check(routing.ReconcileCandidates(1, 1, true) == 0,
      "crossing again with that hold must still not invent a Windows async down");
  Check(!routing.Remote(0, false, true, true), "transferred source up stays local");
  Check(routing.Remote(0, true, true, false), "another Mac drag may start");
  Check(routing.Remote(0, false, false, false), "up after returning without recrossing is drained from Windows");
  Check(!routing.Remote(0, true, false, false), "normal Windows click resumes after remote release");
  std::cout << "Drag handoff state and input ownership checks passed\n";
}
