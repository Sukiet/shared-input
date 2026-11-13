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
  Check(leave(2, false, 1250), "fresh leftward motion at left boundary returns");
  edge.Motion(-5, 3, 1300);
  Check(leave(2, false, 1300), "continuous motion must tolerate feedback latency");
  Check(!leave(3, false, 1600), "old leftward intent must expire");
  edge.Motion(3, 3, 1500);
  Check(!leave(3, false, 1550), "a direction change cancels return intent");
  Check(shared_input::EdgeFraction(500, 0, 1001) == 0.5, "normalize vertical placement");
  Check(shared_input::EdgeFraction(-50, 0, 1001) == 0, "clamp negative coordinates");
  std::cout << "Edge return policy passed.\n";
}
