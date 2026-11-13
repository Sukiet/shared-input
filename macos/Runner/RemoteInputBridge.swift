import Cocoa
import FlutterMacOS
import ApplicationServices

// Network I/O and authenticated framing live in Dart; the native receiver owns
// held state and a watchdog so a stalled Flutter loop cannot leave keys held.
final class RemoteInputBridge {
  private let channel: FlutterMethodChannel
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
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
  }
  deinit { timer?.cancel(); stop() }
  func stop() {
    lock.lock(); defer { lock.unlock() }
    releaseLocked()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize": stop(); result(nil)
    case "heartbeat", "restoreShortcut", "cancelSetup": result(nil)
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
      lock.lock()
      releaseLocked()
      capture = id; sequence = -1; total = .zero
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
        reason: "Receiving keyboard and mouse input")
      position = CGEvent(source: nil)?.location ?? .zero
      lastReceived = ProcessInfo.processInfo.systemUptime
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
      lock.lock(); defer { lock.unlock() }
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
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
  }
  private func constrained(_ point: CGPoint) -> CGPoint {
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
    if let current = CGEvent(source: nil)?.location, hypot(current.x - position.x, current.y - position.y) > 1.5 {
      position = current
    }
    position = constrained(CGPoint(x: position.x + dx, y: position.y + dy))
    let button = heldButtons.contains(0) ? 0 : heldButtons.contains(1) ? 1 : heldButtons.sorted().first ?? 0
    let type: CGEventType = heldButtons.isEmpty ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
    post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
      mouseButton: CGMouseButton(rawValue: UInt32(button))!))
    return true
  }
  private func apply(_ frame: [String: Any]) -> Bool {
    guard motion(frame), let kind = frame["kind"] as? String else { return false }
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
      if frame["horizontal"] as? Bool ?? false { wheelX += raw.doubleValue / 120 * 24 }
      else { wheelY += raw.doubleValue / 120 * 24 }
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
    wheelX = 0; wheelY = 0; caps = false
    if let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
  }
}
