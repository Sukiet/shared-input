import Cocoa
import FlutterMacOS
import ApplicationServices

// Network I/O and authenticated framing live in Dart; the native receiver owns
// held state and a watchdog so a stalled Flutter loop cannot leave keys held.
final class RemoteInputBridge {
  private let channel: FlutterMethodChannel
  private let clipboard = ClipboardBridge()
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var motionTimer: DispatchSourceTimer?
  private var interpolator = PointerInterpolator()
  private var smoothingEnabled = true
  private var motionIntervalMs = 4
  private var motionLeewayUs = 500

  private func scheduleMotionLocked() {
    if capture != nil && smoothingEnabled {
      motionTimer?.schedule(deadline: .now(), repeating: .milliseconds(motionIntervalMs),
                            leeway: .microseconds(motionLeewayUs))
    } else {
      motionTimer?.schedule(deadline: .distantFuture)
    }
  }
  private var activity: NSObjectProtocol?
  private var capture: String?
  private var lastReceived = ProcessInfo.processInfo.systemUptime
  private var sequence: Int64 = -1
  private var total = CGPoint.zero
  private var position = CGPoint.zero
  private var heldKeys = Set<CGKeyCode>()
  private var heldButtons = Set<Int>()
  private var caps = false
  private var wheelX = 0.0, wheelY = 0.0
  private var clickButton = -1, clickCount: Int64 = 1
  private var clickTime = 0.0
  private var clickPosition = CGPoint.zero
  private let source = CGEventSource(stateID: .privateState)
  private var diagnosticsEnabled = false
  private var diagnosticStats: [String: Double] = [:]
  private var lastInputTime: UInt64?
  private func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  // Called under lock (except initialize, which runs on the same main queue).
  private func measure(_ name: String, _ started: UInt64) {
    guard diagnosticsEnabled else { return }
    let elapsed = Double(tick() - started) / 1000
    diagnosticStats[name + "Count", default: 0] += 1
    diagnosticStats[name + "TotalUs", default: 0] += elapsed
    diagnosticStats[name + "MaxUs"] = max(diagnosticStats[name + "MaxUs", default: 0], elapsed)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "shared_input/dry_run", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shared-input-watchdog"))
    timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      if self.capture != nil && ProcessInfo.processInfo.systemUptime - self.lastReceived >= 1.5 {
        self.releaseLocked()
      }
    }
    timer.resume()
    self.timer = timer
    // A separate native clock keeps smoothing independent of network bursts
    // and Flutter frames. The watchdog retains its own queue.
    let motionTimer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "shared-input-motion", qos: .userInteractive))
    motionTimer.schedule(deadline: .distantFuture)
    motionTimer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      guard self.capture != nil else { return }
      // Do not emit delayed motion after a stalled connection has timed out.
      let now = ProcessInfo.processInfo.systemUptime
      if now - self.lastReceived >= 1.5 { self.releaseLocked(); return }
      self.emitMotionLocked(self.interpolator.value(at: now))
    }
    motionTimer.resume()
    self.motionTimer = motionTimer
  }
  deinit { motionTimer?.cancel(); timer?.cancel(); clipboard.reset(); stop() }
  func shutdown() { clipboard.reset(); stop() }
  func stop() {
    lock.lock(); defer { lock.unlock() }
    releaseLocked()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if call.method.hasPrefix("clipboard") { clipboard.handle(call, result); return }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize":
      clipboard.reset()
      stop()
      diagnosticsEnabled = args["diagnostics"] as? Bool ?? false
      result(nil)
    case "receiverConfigureSmoothing":
      guard let enabled = args["enabled"] as? Bool,
            let duration = args["durationMs"] as? Int, (1...100).contains(duration),
            let interval = args["intervalMs"] as? Int, (1...16).contains(interval),
            let leeway = args["leewayUs"] as? Int, (0...2000).contains(leeway) else {
        result(FlutterError(code: "invalid_smoothing", message: "平滑参数超出范围。", details: nil)); return
      }
      lock.lock()
      let now = ProcessInfo.processInfo.systemUptime
      if capture != nil {
        emitMotionLocked(enabled ? interpolator.value(at: now) : interpolator.target)
      }
      if interpolator.duration != Double(duration) / 1000 {
        interpolator.setDuration(Double(duration) / 1000, at: now)
      }
      if !enabled || capture == nil { interpolator.reset(position, at: now) }
      smoothingEnabled = enabled
      motionIntervalMs = interval
      motionLeewayUs = leeway
      scheduleMotionLocked()
      lock.unlock()
      result(nil)
    case "receiverDiagnostics":
      lock.lock()
      let snapshot = diagnosticStats
      diagnosticStats.removeAll(keepingCapacity: true)
      let active = capture != nil
      lock.unlock()
      result(["active": active, "timings": snapshot])
    case "heartbeat", "restoreShortcut", "cancelSetup": result(nil)
    case "receiverPointer":
      lock.lock()
      let actual = CGEvent(source: nil)?.location ?? position
      let bounds = CGDisplayBounds(CGMainDisplayID())
      let snapshot: [String: Any] = ["x": actual.x, "y": actual.y,
        "left": bounds.minX, "top": bounds.minY, "width": bounds.width,
        "height": bounds.height, "sequence": sequence]
      lock.unlock()
      result(snapshot)
    case "devices": result([])
    case "permissions": result(CGPreflightPostEventAccess())
    case "requestPermissions":
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      _ = CGRequestPostEventAccess()
      result(CGPreflightPostEventAccess())
    case "receiverBegin":
      guard CGPreflightPostEventAccess(), let id = args["capture"] as? String, id.count == 32 else {
        result(FlutterError(code: "permission_required", message: "请先在系统设置中允许辅助功能访问。", details: nil)); return
      }
      let entry = (args["edgeEntryY"] as? NSNumber)?.doubleValue
      let entrySide = args["edgeEntrySide"] as? String ?? "left"
      if let entry = entry, !entry.isFinite || !(0...1).contains(entry) ||
          !["left", "right", "top", "bottom"].contains(entrySide) {
        result(FlutterError(code: "invalid_layout", message: "显示屏入口无效。", details: nil)); return
      }
      lock.lock()
      releaseLocked()
      capture = id; sequence = -1; total = .zero
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
        reason: "Receiving keyboard and mouse input")
      position = CGEvent(source: nil)?.location ?? .zero
      if let entry = entry {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = bounds.minX + entry * max(0, bounds.width - 1)
        let y = bounds.minY + entry * max(0, bounds.height - 1)
        let insetX = min(24, bounds.width / 2), insetY = min(24, bounds.height / 2)
        let destination: CGPoint
        switch entrySide {
        case "right": destination = CGPoint(x: bounds.maxX - 1 - insetX, y: y)
        case "top": destination = CGPoint(x: x, y: bounds.minY + insetY)
        case "bottom": destination = CGPoint(x: x, y: bounds.maxY - 1 - insetY)
        default: destination = CGPoint(x: bounds.minX + insetX, y: y)
        }
        emitMotionLocked(destination)
      }
      lastReceived = ProcessInfo.processInfo.systemUptime
      interpolator.reset(position, at: lastReceived)
      scheduleMotionLocked()
      lock.unlock()
      result(nil)
    case "receiverHeartbeat":
      lock.lock()
      let active = capture != nil
      if active { lastReceived = ProcessInfo.processInfo.systemUptime }
      lock.unlock()
      if active { result(nil) }
      else { result(FlutterError(code: "receiver_stopped", message: "接收已停止。", details: nil)) }
    case "receiverStop": stop(); result(nil)
    case "receiverInput":
      let entered = tick()
      lock.lock()
      measure("lockWait", entered)
      let started = tick()
      if let previous = lastInputTime { measure("inputGap", previous) }
      lastInputTime = started
      defer { measure("input", started); lock.unlock() }
      guard let id = args["capture"] as? String, id == capture,
            let frames = args["frames"] as? [[String: Any]], frames.count <= 256 else {
        result(FlutterError(code: "invalid_input", message: "输入会话已停止。", details: nil)); return
      }
      for frame in frames {
        guard apply(frame) else {
          releaseLocked()
          result(FlutterError(code: "invalid_input", message: "无效输入，已释放按键。", details: nil)); return
        }
      }
      lastReceived = ProcessInfo.processInfo.systemUptime
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private var flags: CGEventFlags {
    var flags: CGEventFlags = []
    if heldKeys.contains(56) || heldKeys.contains(60) { flags.insert(.maskShift) }
    if heldKeys.contains(59) || heldKeys.contains(62) { flags.insert(.maskControl) }
    if heldKeys.contains(58) || heldKeys.contains(61) { flags.insert(.maskAlternate) }
    if heldKeys.contains(54) || heldKeys.contains(55) { flags.insert(.maskCommand) }
    if caps { flags.insert(.maskAlphaShift) }
    return flags
  }
  private func post(_ event: CGEvent?) {
    let started = tick()
    defer { measure("post", started) }
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
  }
  private func constrained(_ point: CGPoint) -> CGPoint {
    let started = tick()
    defer { measure("displayQuery", started) }
    var displays = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return point }
    let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    if bounds.contains(where: { $0.contains(point) }) { return point }
    return bounds.map { rect in
      CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
    }.min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) ?? point
  }
  private func motion(_ frame: [String: Any]) -> Bool {
    guard let next = frame["sequence"] as? NSNumber,
          let nx = frame["x"] as? NSNumber, let ny = frame["y"] as? NSNumber else { return false }
    let value = CGPoint(x: nx.doubleValue, y: ny.doubleValue)
    guard value.x.isFinite && value.y.isFinite && abs(value.x) <= 1e12 && abs(value.y) <= 1e12 else { return false }
    if next.int64Value <= sequence { return true }
    let dx = value.x - total.x, dy = value.y - total.y
    total = value; sequence = next.int64Value
    if dx == 0 && dy == 0 { return true }
    // Accumulate onto the destination, not the partly interpolated cursor.
    // Reading the hardware position here would mistake our own delayed motion
    // for local input and repeatedly pull the smoothed cursor backwards.
    let target = interpolator.target
    interpolator.retarget(constrained(CGPoint(x: target.x + dx, y: target.y + dy)),
                          at: ProcessInfo.processInfo.systemUptime)
    if !smoothingEnabled {
      emitMotionLocked(interpolator.target)
      interpolator.reset(position, at: ProcessInfo.processInfo.systemUptime)
    }
    return true
  }
  private func emitMotionLocked(_ point: CGPoint) {
    let point = constrained(point)
    guard point != position else { return }
    position = point
    let button = heldButtons.contains(0) ? 0 : heldButtons.contains(1) ? 1 : heldButtons.sorted().first ?? 0
    let type: CGEventType = heldButtons.isEmpty ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
    post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
      mouseButton: CGMouseButton(rawValue: UInt32(button))!))
  }
  private func apply(_ frame: [String: Any]) -> Bool {
    guard motion(frame), let kind = frame["kind"] as? String else { return false }
    if kind != "motion" {
      // Reach this reliable event's location under the previous button/key
      // state, then apply the transition. In particular, finish a drag before
      // button-up; no old interpolation may cross a click or modifier change.
      emitMotionLocked(interpolator.target)
      interpolator.reset(position, at: ProcessInfo.processInfo.systemUptime)
    }
    switch kind {
    case "motion": return true
    case "key":
      guard let raw = frame["code"] as? NSNumber, raw.intValue > 0 && raw.intValue < 256 else { return false }
      let scan = raw.intValue | ((frame["extended"] as? Bool ?? false) ? 0xe000 : 0)
      // Physical mapping: Win -> Command, Ctrl -> Control, Alt -> Option.
      // Never swap modifiers based on old saved settings or peer options.
      guard let key = windowsToMacKeyCode[scan] else { return true }
      let down = frame["down"] as? Bool ?? false
      if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
      if key == 57 && down && !(frame["repeat"] as? Bool ?? false) { caps.toggle() }
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      if [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(key) { event?.type = .flagsChanged }
      event?.setIntegerValueField(.keyboardEventAutorepeat, value: (frame["repeat"] as? Bool ?? false) ? 1 : 0)
      post(event)
    case "button":
      guard let number = frame["button"] as? NSNumber, (0...4).contains(number.intValue) else { return false }
      let button = number.intValue, down = frame["down"] as? Bool ?? false
      if down {
        heldButtons.insert(button)
        let now = ProcessInfo.processInfo.systemUptime
        clickCount = button == clickButton && now - clickTime < NSEvent.doubleClickInterval &&
          hypot(position.x - clickPosition.x, position.y - clickPosition.y) < 4 ? min(clickCount + 1, 3) : 1
        clickButton = button; clickTime = now; clickPosition = position
      } else { heldButtons.remove(button) }
      let type: CGEventType = button == 0 ? (down ? .leftMouseDown : .leftMouseUp) :
        button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
        mouseButton: CGMouseButton(rawValue: UInt32(button))!)
      event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
      post(event)
    case "wheel":
      guard let raw = frame["delta"] as? NSNumber, abs(raw.doubleValue) <= 32768 else { return false }
      let speed: Double
      if let value = frame["scrollSpeed"] {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              (0.01...20).contains(number.doubleValue) else { return false }
        speed = number.doubleValue
      } else {
        speed = 1 // Preserve existing behavior with older controllers.
      }
      let pixels = raw.doubleValue / 120 * 24 * speed
      if frame["horizontal"] as? Bool ?? false { wheelX += pixels }
      else { wheelY += pixels }
      let x = Int32(wheelX.rounded()), y = Int32(wheelY.rounded())
      wheelX -= Double(x); wheelY -= Double(y)
      if x != 0 || y != 0 {
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
      }
    default: return false
    }
    return true
  }
  private func releaseLocked() {
    motionTimer?.schedule(deadline: .distantFuture)
    // Cancel pending movement on stop/disconnect instead of replaying it.
    interpolator.reset(position, at: ProcessInfo.processInfo.systemUptime)
    for key in heldKeys.sorted() {
      heldKeys.remove(key)
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
      if [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(key) { event?.type = .flagsChanged }
      post(event)
    }
    for button in heldButtons.sorted() {
      let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
      post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
        mouseButton: CGMouseButton(rawValue: UInt32(button))!))
    }
    heldButtons.removeAll(); capture = nil; sequence = -1; total = .zero
    lastInputTime = nil
    wheelX = 0; wheelY = 0; caps = false
    if let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
  }
}
