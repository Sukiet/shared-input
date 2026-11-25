import Cocoa
import FlutterMacOS
import ApplicationServices

// Network I/O and authenticated framing live in Dart; the native receiver owns
// held state and a watchdog so a stalled Flutter loop cannot leave keys held.
final class RemoteInputBridge {
  private let channel: FlutterMethodChannel
  private let clipboard = ClipboardBridge()
  private let screenPolicy = ScreenPolicyBridge()
  private let dragProbe = MacEdgeDragProbe()
  private var dragTestEnabled = false // protected by lock, like heldButtons
  private var dragPixelScale: CGFloat = 1
  private lazy var audioCapture = AudioCaptureBridge(channel: channel)
  private let cursorVisibility = ReceiverCursorVisibility()
  private var edgeExit = ReceiverEdgeExit()
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var motionTimer: DispatchSourceTimer?
  private var interpolator = PointerInterpolator()
  private var smoothingEnabled = true
  private var predictionEnabled = false
  private var predictor = PointerPredictor()
  private var predictionOutput = PredictionOutput()
  private var lastPredictionSource: Int64 = 0
  private var motionIntervalMs = 4
  private var motionLeewayUs = 500

  private func scheduleMotionLocked() {
    if capture != nil && (smoothingEnabled || predictionEnabled) {
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
    dragProbe.changed = { [weak self] snapshot in
      self?.channel.invokeMethod("edgeDragProbeChanged", arguments: snapshot)
    }
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
      let point: CGPoint
      if self.predictionEnabled && self.heldButtons.isEmpty && self.lastPredictionSource > 0 {
        point = self.predictionOutput.update(self.constrained(self.predictor.value(at: now)), at: now)
      } else { point = self.interpolator.value(at: now) }
      self.emitMotionLocked(point)
      self.updateExitCursorLocked(at: now)
    }
    motionTimer.resume()
    self.motionTimer = motionTimer
  }
  deinit { motionTimer?.cancel(); timer?.cancel(); clipboard.reset(); dragProbe.shutdown(); stop() }
  func shutdown() { screenPolicy.reset(); clipboard.reset(); stop(); dragProbe.shutdown(); audioCapture.shutdown() }
  func stop(hideCursor: Bool = false) {
    lock.lock(); defer { lock.unlock() }
    releaseLocked(hideCursor: hideCursor)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if call.method == "audioCapabilities" || call.method.hasPrefix("audioCapture") {
      audioCapture.handle(call, result); return
    }
    if call.method.hasPrefix("clipboard") { clipboard.handle(call, result); return }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "screenCapabilities": result(["controller": false, "receiver": true])
    case "screenPolicy":
      if args["lock"] as? Bool == true { stop() }
      screenPolicy.handle(args, result)
    case "initialize":
      screenPolicy.reset()
      clipboard.reset()
      stop()
      dragProbe.configure(enabled: false, side: "left")
      lock.lock(); dragTestEnabled = false; lock.unlock()
      diagnosticsEnabled = args["diagnostics"] as? Bool ?? false
      result(nil)
    case "edgeDragProbe":
      let side = args["side"] as? String ?? dragProbe.side
      guard ["left", "right", "top", "bottom"].contains(side) else {
        result(FlutterError(code: "invalid_layout", message: "拖拽测试边缘无效。", details: nil)); return
      }
      dragProbe.configure(enabled: args["enabled"] as? Bool ?? false, side: side)
      lock.lock(); dragTestEnabled = dragProbe.enabled; dragPixelScale = dragProbe.pixelScale; lock.unlock()
      result(dragProbe.snapshot)
    case "edgeDragProbeClear": dragProbe.clear(); result(dragProbe.snapshot)
    case "receiverConfigureSmoothing":
      guard let enabled = args["enabled"] as? Bool,
            let duration = args["durationMs"] as? Int, (1...100).contains(duration),
            let interval = args["intervalMs"] as? Int, (1...16).contains(interval),
            let leeway = args["leewayUs"] as? Int, (0...2000).contains(leeway) else {
        result(FlutterError(code: "invalid_smoothing", message: "平滑参数超出范围。", details: nil)); return
      }
      let prediction = args["mode"] as? String == "prediction"
      let config = args["prediction"] as? [String: Any] ?? [:]
      let trigger = (config["triggerMs"] as? NSNumber)?.doubleValue ?? 8
      let horizon = (config["horizonMs"] as? NSNumber)?.doubleValue ?? 60
      let decay = (config["decayMs"] as? NSNumber)?.doubleValue ?? 40
      let history = (config["historyMs"] as? NSNumber)?.doubleValue ?? 20
      let distance = (config["maxDistance"] as? NSNumber)?.doubleValue ?? 32
      let outputSmoothing = config["outputSmoothing"] as? Bool ?? true
      let outputDuration = (config["outputDurationMs"] as? NSNumber)?.doubleValue ?? 8
      guard trigger.isFinite, (1...50).contains(trigger), horizon.isFinite, (1...100).contains(horizon),
            decay.isFinite, (1...200).contains(decay), history.isFinite, (4...100).contains(history),
            distance.isFinite, (1...200).contains(distance),
            outputDuration.isFinite, (1...40).contains(outputDuration) else {
        result(FlutterError(code: "invalid_prediction", message: "预测参数超出范围。", details: nil)); return
      }
      lock.lock()
      let now = ProcessInfo.processInfo.systemUptime
      if capture != nil {
        emitMotionLocked(interpolator.target)
      }
      if interpolator.duration != Double(duration) / 1000 {
        interpolator.setDuration(Double(duration) / 1000, at: now)
      }
      if !enabled || capture == nil { interpolator.reset(position, at: now) }
      smoothingEnabled = enabled && !prediction
      predictionEnabled = prediction
      predictor.reset(interpolator.target)
      predictionOutput.configure(enabled: outputSmoothing, duration: outputDuration / 1000,
                                 point: position, at: now)
      predictor.trigger = trigger / 1000; predictor.horizon = horizon / 1000
      predictor.decay = decay / 1000; predictor.history = history / 1000
      predictor.maxDistance = distance
      lastPredictionSource = 0
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
      // System cursor queries can still return a previous predicted post while
      // its correction is in flight. Edge decisions use authoritative samples.
      let usePrediction = predictionEnabled && heldButtons.isEmpty
      let actual = usePrediction ? predictor.confirmed : (CGEvent(source: nil)?.location ?? position)
      let predicted = usePrediction &&
        (predictor.value(at: ProcessInfo.processInfo.systemUptime) != predictor.confirmed || position != predictor.confirmed)
      let bounds = CGDisplayBounds(CGMainDisplayID())
      let snapshot: [String: Any] = ["x": actual.x, "y": actual.y,
        "left": bounds.minX, "top": bounds.minY, "width": bounds.width,
        "height": bounds.height, "sequence": predicted ? -1 : sequence, "predicted": predicted]
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
      if entry != nil { dragProbe.setSide(entrySide) }
      dragProbe.receiverBegan()
      let dragScale = dragProbe.pixelScale
      lock.lock()
      dragPixelScale = dragScale
      releaseLocked()
      capture = id; sequence = -1; total = .zero
      edgeExit = ReceiverEdgeExit(edge: entry == nil ? nil : entrySide,
                                 started: ProcessInfo.processInfo.systemUptime)
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
      predictor.reset(position); lastPredictionSource = 0
      predictionOutput.reset(position, at: lastReceived)
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
    case "receiverStop":
      dragProbe.receiverStopped(reason: args["reason"] as? String)
      stop(hideCursor: true); result(nil)
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
      updateExitCursorLocked(at: lastReceived)
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
    // Do not mistake our queued motion/button releases for local mouse input.
    event?.setIntegerValueField(.eventSourceUserData, value: ReceiverCursorVisibility.remoteEventTag)
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
    let sourceUs = (frame["sampleTimeUs"] as? NSNumber)?.int64Value ?? 0
    if next.int64Value < sequence { return true }
    if next.int64Value == sequence && (sourceUs <= lastPredictionSource || sourceUs == 0) { return true }
    if sourceUs > 0 && sourceUs <= lastPredictionSource { return true }
    let dx = value.x - total.x, dy = value.y - total.y
    total = value; sequence = next.int64Value
    let now = ProcessInfo.processInfo.systemUptime
    edgeExit.motion(dx: dx, dy: dy, at: now)
    let target = interpolator.target
    let confirmed = constrained(CGPoint(x: target.x + dx, y: target.y + dy))
    if predictionEnabled {
      interpolator.reset(confirmed, at: now)
      if sourceUs > 0 {
        lastPredictionSource = sourceUs
        predictor.observe(confirmed, cumulative: value, sourceUs: sourceUs,
          moving: (frame["moving"] as? Bool ?? false) && heldButtons.isEmpty, at: now)
      } else { predictor.reset(confirmed); lastPredictionSource = 0 }
      if sourceUs > 0 && heldButtons.isEmpty {
        emitMotionLocked(predictionOutput.update(confirmed, at: now))
      } else {
        predictionOutput.reset(confirmed, at: now)
        emitMotionLocked(confirmed)
      }
    } else {
      if dx == 0 && dy == 0 { return true }
      interpolator.retarget(confirmed, at: now)
      if !smoothingEnabled {
        emitMotionLocked(interpolator.target)
        interpolator.reset(position, at: now)
      }
    }
    return true
  }
  private func emitMotionLocked(_ point: CGPoint) {
    var point = constrained(point)
    if dragTestEnabled && !heldButtons.isEmpty {
      let bounds = CGDisplayBounds(CGMainDisplayID())
      if bounds.contains(point) {
        point = dragProbeCursor(point, bounds: bounds, side: edgeExit.edge, scale: dragPixelScale)
      }
    }
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
      predictor.reset(interpolator.target)
      // Reach this reliable event's location under the previous button/key
      // state, then apply the transition. In particular, finish a drag before
      // button-up; no old interpolation may cross a click or modifier change.
      emitMotionLocked(interpolator.target)
      interpolator.reset(position, at: ProcessInfo.processInfo.systemUptime)
      predictionOutput.reset(position, at: ProcessInfo.processInfo.systemUptime)
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
  private func releaseLocked(hideCursor: Bool = false) {
    let wasCapturing = capture != nil
    predictor.reset(position); lastPredictionSource = 0
    predictionOutput.reset(position, at: ProcessInfo.processInfo.systemUptime)
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
    edgeExit = ReceiverEdgeExit()
    lastInputTime = nil
    wheelX = 0; wheelY = 0; caps = false
    if let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
    if hideCursor {
      if wasCapturing { cursorVisibility.hide() }
    } else { cursorVisibility.show() }
  }

  private func updateExitCursorLocked(at now: TimeInterval) {
    guard capture != nil, edgeExit.edge != nil else { return }
    let confirmed = predictionEnabled ? predictor.confirmed : interpolator.target
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let held = !heldKeys.isEmpty || (!dragTestEnabled && !heldButtons.isEmpty)
    if edgeExit.shouldHide(rendered: position, confirmed: confirmed, bounds: bounds, held: held, at: now) {
      // Cosmetic anticipation only: keep feedback and input alive until Windows
      // actually ends this capture. Never use a predicted-only edge crossing.
      cursorVisibility.anticipateExit()
    } else if edgeExit.shouldCancel(confirmed: confirmed, bounds: bounds, held: held) {
      cursorVisibility.cancelAnticipation()
    }
  }
}
