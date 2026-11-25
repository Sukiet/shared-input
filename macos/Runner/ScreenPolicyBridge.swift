import Cocoa
import FlutterMacOS
import ApplicationServices
import IOKit.pwr_mgt

/// A six-second OS assertion, renewed by the authenticated controller every two
/// seconds. OS expiry also works if the Flutter isolate/main run loop is stalled.
final class ScreenPolicyBridge {
  private var assertion: IOPMAssertionID = 0
  private var wakeActivity: IOPMAssertionID = 0
  private var deadline = 0.0
  private var activity: NSObjectProtocol?
  private var timer: DispatchSourceTimer?

  init() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self = self, self.deadline > 0,
            ProcessInfo.processInfo.systemUptime >= self.deadline else { return }
      self.reset()
    }
    timer.resume()
    self.timer = timer
  }

  deinit { timer?.cancel(); reset() }

  func reset() {
    if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    if wakeActivity != 0 { IOPMAssertionRelease(wakeActivity); wakeActivity = 0 }
    deadline = 0
    if let activity = activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
  }

  func handle(_ args: [String: Any], _ result: FlutterResult) {
    guard let awake = args["keepAwake"] as? Bool, let lock = args["lock"] as? Bool else {
      result(FlutterError(code: "invalid_screen_policy", message: "屏幕策略参数无效", details: nil)); return
    }
    if !awake { reset() }
    if lock {
      // Use the system Lock Screen shortcut, with the same posting permission
      // as input sharing. There is deliberately no unlock or credential path.
      guard CGPreflightPostEventAccess() else {
        result(FlutterError(code: "permission_required", message: "同步锁屏需要允许 Shared Input 辅助功能访问", details: nil)); return
      }
      let source = CGEventSource(stateID: .privateState)
      let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
        (59, true, .maskControl), (55, true, [.maskControl, .maskCommand]),
        (12, true, [.maskControl, .maskCommand]), (12, false, [.maskControl, .maskCommand]),
        (55, false, .maskControl), (59, false, [])
      ]
      var events: [CGEvent] = []
      for (key, down, flags) in steps {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
          result(FlutterError(code: "lock_failed", message: "无法发送 Mac 锁屏指令", details: nil)); return
        }
        event.flags = flags
        events.append(event)
      }
      // Create all events before posting any, so an allocation failure cannot
      // leave a modifier down. Finish with both modifiers explicitly released.
      for event in events { event.post(tap: .cghidEventTap) }
    }
    if awake {
      let now = ProcessInfo.processInfo.systemUptime
      let wasActive = assertion != 0 && now < deadline
      if assertion != 0 {
        // Setting Timeout again restarts the assertion's OS expiration timer.
        let code = IOPMAssertionSetProperty(assertion, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: 6))
        if code != kIOReturnSuccess { IOPMAssertionRelease(assertion); assertion = 0 }
      }
      if assertion == 0 {
        let code = IOPMAssertionCreateWithDescription(
          kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
          "Shared Input screen sync" as CFString, nil, nil, nil, 6,
          kIOPMAssertionTimeoutActionRelease as CFString, &assertion)
        if code != kIOReturnSuccess {
          assertion = 0
          result(FlutterError(code: "display_assertion_failed", message: "Mac 无法保持显示屏亮屏", details: Int(code))); return
        }
      }
      deadline = now + 6
      if activity == nil {
        // Keep background App Nap from delaying leases; this activity does not
        // itself prevent idle sleep. The expiring IOKit assertion owns that.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
          reason: "Following controller screen policy")
      }
      if !wasActive {
        // Wake a display that was already idle when the switch was enabled.
        // This wakes the login display too, but cannot unlock the session.
        if wakeActivity != 0 { IOPMAssertionRelease(wakeActivity); wakeActivity = 0 }
        IOPMAssertionDeclareUserActivity("Shared Input controller display is on" as CFString,
          kIOPMUserActiveLocal, &wakeActivity)
      }
    }
    result(nil)
  }
}
