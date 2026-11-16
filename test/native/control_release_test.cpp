#include "../../windows/runner/control_release.h"
#include <cstdlib>
#include <iostream>
#include <thread>
#ifdef _WIN32
#include "../../windows/runner/background_hooks.h"
#endif

void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

int main() {
  using namespace shared_input;
  Check(!HookFresh(10000, 0), "never-observed hook is not fresh");
  Check(HookFresh(10000, 10000), "same-tick hook is fresh");
  Check(HookFresh(10000, 10001), "concurrent newer hook must not underflow");
  Check(HookFresh(10000, 9751), "hook within 250 ms is fresh");
  Check(!HookFresh(10000, 9750), "hook expires exactly at 250 ms");
  Check(!HookFresh(10000, 9749), "genuinely stale hook is rejected");
  Check(!ElapsedAtLeast(10000, 10001, 1000), "concurrent newer pointer is not expired");
  Check(!ElapsedAtLeast(10000, 10000, 1000), "same-tick pointer is not expired");
  Check(!ElapsedAtLeast(10000, 9001, 1000), "pointer just within limit is not expired");
  Check(ElapsedAtLeast(10000, 9000, 1000), "pointer expires exactly at one second");
  Check(ElapsedAtLeast(10000, 8999, 1000), "pointer beyond limit expires");
  Check(ElapsedAtLeast(1000, 0, 1000), "no feedback after start still expires");
  Check(ObservedAgeMs(10000, 10001) == 0, "future snapshot age is zero");
  Check(ObservedAgeMs(10000, 0) == -1, "unobserved snapshot remains explicit");
  Check(HookPumpFresh(10000, 9990, 0, 0), "quiet devices do not invalidate a responsive pump");
  Check(HookPumpFresh(10000, 9990, 100, 100), "old callbacks and fresh pump are healthy");
  Check(HookPumpFresh(10000, 100, 9990, 0), "active callback proves a busy pump is alive");
  Check(HookPumpFresh(10000, 100, 0, 9990), "keyboard activity proves pump liveness");
  Check(HookPumpFresh(10000, 10001, 0, 0), "concurrent pump update must not underflow");
  Check(!HookPumpFresh(10000, 9750, 0, 0), "actual pump stall expires at 250 ms");
  Check(!HookPumpFresh(10000, 0, 0, 0), "unstarted pump is not healthy");

  CaptureReleaseLatch latch;
  for (auto first : {ReleaseCause::pointer_timeout, ReleaseCause::heartbeat, ReleaseCause::shortcut}) {
    latch.Begin(41, true);
    Check(latch.Blocking(), "capture starts blocked");
    Check(latch.Record(41, first), "watchdog or shortcut wins first release");
    Check(!latch.Blocking(), "release requires no UI message processing");
    Check(!latch.Record(41, ReleaseCause::hook_lost), "stats timer cannot overwrite cause");
    Check(latch.Reason(41) == first, "first reason survives reordered messages");
    latch.Begin(42, true);
    Check(!latch.Record(41, first), "old generation cannot publish a reason");
    Check(latch.Blocking(), "old timeout cannot unblock new capture");
    Check(latch.Reason(42) == ReleaseCause::none, "new generation starts clean");
  }
  latch.Begin(43); // Foreground capture does not use the background block bit.
  Check(latch.Record(43, ReleaseCause::focus_lost), "foreground release also records once");
  Check(latch.Reason(43) == ReleaseCause::focus_lost, "foreground reason retained");

  // Both outcomes are valid; the loser must not overwrite the first publisher.
  for (uint32_t i = 0; i < 300; ++i) {
    latch.Begin(i, true);
    bool pointer_won = false, shortcut_won = false;
    std::thread pointer([&] { pointer_won = latch.Record(i, ReleaseCause::pointer_timeout); });
    std::thread shortcut([&] { shortcut_won = latch.Record(i, ReleaseCause::shortcut); });
    pointer.join(); shortcut.join();
    Check(pointer_won != shortcut_won, "exactly one concurrent release wins");
    Check(latch.Reason(i) == (pointer_won ? ReleaseCause::pointer_timeout : ReleaseCause::shortcut),
        "reason and unblock are published consistently");
    Check(!latch.Blocking(), "concurrent release unblocks");
  }
#ifdef _WIN32
  // Exercise the production DLL facade without installing hooks, capturing
  // input, or synthesizing events on the interactive desktop.
  BackgroundHooks hooks;
  hooks.ResetRelease(100);
  Check(!hooks.MouseFresh(10000), "unobserved DLL mouse hook is not fresh");
  Check(!hooks.KeyboardFresh(10000), "unobserved DLL keyboard hook is not fresh");
  Check(!hooks.Healthy(10000), "unstarted DLL pump is not healthy");
  hooks.ReleaseFor(99, ReleaseCause::heartbeat);
  Check(hooks.ReleaseReason(100) == ReleaseCause::none, "DLL rejects old generation");
  hooks.ReleaseFor(100, ReleaseCause::pointer_timeout);
  hooks.ReleaseFor(100, ReleaseCause::hook_lost);
  Check(hooks.ReleaseReason(100) == ReleaseCause::pointer_timeout, "DLL retains first cause");
  hooks.ResetRelease(101);
  hooks.ReleaseFor(100, ReleaseCause::shortcut);
  Check(hooks.ReleaseReason(101) == ReleaseCause::none, "new DLL capture stays clean");
#endif
  std::cout << "Control release checks passed.\n";
}
