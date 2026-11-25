#include "../../windows/runner/receiver_drag_press.h"
#include "../../windows/runner/mouse_routing.h"
#include <cassert>
#include <iostream>

int main() {
  shared_input::ReceiverDragPress press;
  assert(!press.Matches(0, 0, 1));
  press.Observe(1);
  const auto first = press.Id(0);
  assert(press.Matches(0, first, 1));
  for (int i = 0; i < 5; ++i) { press.Observe(0); assert(press.Matches(0, first, 1)); }
  assert(!press.Matches(0, first, 3));
  press.Observe(2);
  assert(!press.Matches(0, first, 1));
  press.Observe(1);
  assert(press.Id(0) != first && !press.Matches(0, first, 1));
  assert(press.Matches(0, press.Id(0), 1));
  press.Observe(2 | 4);
  assert(press.Matches(1, press.Id(1), 2));
  const auto right = press.Id(1);
  press.Cancel(); // A short emergency key/lock must survive between lease polls.
  assert(!press.Matches(1, right, 2));
  press.Observe(0);
  assert(!press.Matches(1, right, 2));
  assert(!press.Matches(5, 1, 1));
  shared_input::MouseRouting routing;
  assert(routing.Remote(0, true, true, false));
  routing.TransferToLocal(0);
  assert(routing.ReconcileCandidates(1, 0, false) == 0);
  assert(routing.Remote(0, false, false, false));
  assert(!routing.Remote(0, true, false, false));
  routing.TransferToRemote(1);
  assert(routing.ReconcileCandidates(1, 0, false) == 0);
  assert(routing.Remote(0, false, false, false));
  std::cout << "Receiver drag press identity and remote ownership checks passed\n";
}
