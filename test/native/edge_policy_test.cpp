#include "../../windows/runner/edge_policy.h"
#include <cstdlib>
#include <iostream>
void Check(bool value, const char* description) {
  if (!value) { std::cerr << description << '\n'; std::exit(1); }
}
int main() {
  shared_input::EdgeReturnPolicy edge;
  edge.Begin(1000);
  auto leave = [&](int64_t sequence, bool held, uint64_t now) {
    return edge.Return(-1920, 500, -1920, 0, 1920, 1080, sequence, held, now);
  };
  Check(!leave(0, false, 1300), "position alone must not transfer ownership");
  edge.Motion(5, 1, 1100);
  Check(!leave(1, false, 1300), "entering from left must not bounce back");
  edge.Motion(-5, 2, 1150);
  Check(!leave(2, false, 1150), "entry cooldown prevents immediate bounce");
  Check(!leave(1, false, 1250), "old position feedback cannot complete a new motion");
  Check(!leave(2, true, 1250), "held buttons or keys defer switching");
  Check(!leave(-1, false, 1250), "predicted feedback must not switch screens");
  Check(leave(2, false, 1250), "fresh leftward motion at left boundary returns");
  edge.Motion(-5, 3, 1300);
  Check(leave(2, false, 1300), "continuous motion must tolerate feedback latency");
  Check(!leave(3, false, 1600), "old leftward intent must expire");
  edge.Motion(3, 3, 1500);
  Check(!leave(3, false, 1550), "a direction change cancels return intent");
  Check(shared_input::EdgeFraction(500, 0, 1001) == 0.5, "normalize vertical placement");
  Check(shared_input::EdgeFraction(-50, 0, 1001) == 0, "clamp negative coordinates");
  std::cout << "Edge return policy passed.\n";
  for (const auto side : {shared_input::ScreenEdge::left, shared_input::ScreenEdge::right,
      shared_input::ScreenEdge::top, shared_input::ScreenEdge::bottom}) {
    shared_input::ScreenLayout layout;
    layout.side = side; layout.controller_width = 340; layout.controller_height = 220;
    layout.remote_width = 280; layout.remote_height = 180; layout.offset = 25;
    Check(layout.Valid(), "offset physical layout is valid");
    const double fraction = (25 + layout.RemoteSpan() * 0.4) / layout.ControllerSpan();
    const double remote = layout.ToRemote(fraction);
    Check(std::abs(remote - 0.4) < 1e-9, "physical entry mapping");
    Check(std::abs(layout.ToController(remote) - fraction) < 1e-9, "physical return mapping");
    Check(layout.ToRemote(0) == 0, "unshared entry maps to nearest endpoint");
    layout.offset = layout.ControllerSpan() / 2;
    Check(layout.Valid() && layout.ToRemote(0) == 0 && layout.ToController(1) == 1,
        "positive offset clamps entry and return to nearest endpoints");
    layout.offset = -layout.RemoteSpan() / 2;
    Check(layout.Valid() && layout.ToRemote(1) == 1 && layout.ToController(0) == 0,
        "negative offset clamps entry and return to nearest endpoints");
    shared_input::EdgeReturnPolicy vertical;
    vertical.Begin(1000, side);
    int dx = side == shared_input::ScreenEdge::left ? -10 : side == shared_input::ScreenEdge::right ? 10 : 0;
    int dy = side == shared_input::ScreenEdge::top ? -10 : side == shared_input::ScreenEdge::bottom ? 10 : 0;
    vertical.Motion(dx, 1, 1300, dy);
    const double x = side == shared_input::ScreenEdge::left ? 0 : side == shared_input::ScreenEdge::right ? 999 : 500;
    const double y = side == shared_input::ScreenEdge::top ? 0 : side == shared_input::ScreenEdge::bottom ? 799 : 400;
    Check(vertical.Return(x, y, 0, 0, 1000, 800, 1, false, 1350), "return on configured edge");
  }
}
