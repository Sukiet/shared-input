#include "../../windows/runner/hook_key_state.h"
#include "../../windows/runner/mouse_routing.h"
#include <cstdlib>
#include <iostream>
void Check(bool value, const char* message) {
  if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
  using namespace shared_input;
  HookKeyState keys;
  constexpr unsigned control = 0xa2, letter = 0x41;
  keys.Physical(control, true, 100); keys.Route(control, true, false, false);
  Check(keys.Count() == 1 && keys.LocalHeld(control), "local modifier enters held guard");
  Check(!keys.CanReconcileLocal(control, 199), "do not sample before the Windows state update grace period");
  Check(keys.CanReconcileLocal(control, 200), "stale local down may be reconciled after grace");
  keys.ReconcileLocalUp(control);
  Check(keys.Count() == 0, "missed local up no longer poisons future capture starts");
  keys.Physical(control, true, 300); keys.Route(control, true, true, false);
  Check(!keys.CanReconcileLocal(control, 10000), "async-up cannot erase a physically held remote modifier");
  keys.ReconcileLocalUp(control);
  Check(keys.Count() == 1, "remote hold survives local async sampling");
  Check(keys.RawRelease(control, 400) && keys.Count() == 0, "raw up independently repairs a lost remote hook up");
  Check(keys.ConsumeRecoveredUp(control), "late hook up is drained without duplicate remote delivery");
  Check(!keys.ConsumeRecoveredUp(control), "recovered up is consumed once");
  keys.Physical(control, true, 500);
  Check(!keys.Route(control, true, false, false), "new local press is not swallowed by stale remote ownership");
  Check(!keys.RawRelease(control, 499) && !keys.RawRelease(control, 500), "old or same-tick raw up cannot erase a newer down");
  Check(keys.Count() == 1, "new real hold remains guarded");
  keys.Physical(control, true, 520);
  Check(!keys.RawRelease(control, 510), "repeat down also rejects older queued raw releases");
  keys.Physical(control, false, 530); keys.Route(control, false, false, false);
  keys.Physical(control, false, 531); keys.Route(control, false, false, false);
  Check(keys.Count() == 0, "duplicate up cannot make held count negative");
  keys.Physical(letter, true, 600); keys.Route(letter, true, true, false);
  Check(keys.RawRelease(letter, 700), "recover another remote up");
  keys.Physical(letter, true, 800);
  Check(!keys.ConsumeRecoveredUp(letter) && !keys.Route(letter, true, false, false),
      "fresh down starts new ownership even if the old hook up never arrives");
  keys.ResetFromWindows([=](unsigned key) { return key == control; }, 900);
  Check(keys.Count() == 1 && keys.Down(control) && keys.LocalHeld(control) && !keys.Down(letter),
      "resume clears stale state but seeds genuinely held Windows modifiers");
  keys.ResetFromWindows([](unsigned) { return false; }, 1000);
  Check(keys.Count() == 0, "resume with released hardware is immediately startable");
  keys.Physical(control, true, 0xfffffff0u); keys.Route(control, true, true, false);
  Check(keys.RawRelease(control, 0x10), "timestamp wraparound still accepts a real newer release");
  keys.Physical(control, true, 0x20);
  Check(!keys.RawRelease(control, 0x10), "wrapped older packet cannot release a new press");
  MouseRouting mouse;
  Check(!mouse.Remote(2, true, false, false), "local middle button down is tracked");
  Check(mouse.ReconcileCandidates(4, 0, false) == 4, "middle and side buttons recover even without drag testing");
  mouse.Forget(2);
  Check(mouse.ReconcileCandidates(4, 0, false) == 0, "recovered mouse press leaves no stale ownership");
  Check(mouse.Remote(0, true, true, false), "remote button is routed to Mac");
  Check(mouse.ReconcileCandidates(1, 0, false) == 0, "intercepted mouse hold cannot be cleared from Windows async state");
  Check(mouse.Forget(0), "raw mouse release reports the owner that needs a drained late up");
  Check(!mouse.Remote(0, true, false, false), "new Windows mouse press after recovery stays local");
  std::cout << "Hook input state recovery, paired ownership, timestamps and resume checks passed\n";
}
