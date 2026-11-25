import Cocoa
import Darwin

enum ReceiverCursorParking {
  static func destination(for point: CGPoint, displays: [CGRect], fallback: CGRect) -> CGPoint {
    let screen = displays.first { $0.contains(point) } ?? fallback
    // Quartz display coordinates have their origin at the upper-left corner.
    return CGPoint(x: screen.minX, y: screen.minY)
  }
}

// Mirrors the intent/edge guards of the controller for visual anticipation only.
// It never ends a capture or changes the pointer feedback sent to Windows.
struct ReceiverEdgeExit {
  var edge: String?
  var started: TimeInterval = 0
  private var moved: TimeInterval?
  private var outward = false

  init(edge: String? = nil, started: TimeInterval = 0) {
    self.edge = edge
    self.started = started
  }

  mutating func motion(dx: Double, dy: Double, at now: TimeInterval) {
    let direction: Double
    switch edge {
    case "left": direction = -dx
    case "right": direction = dx
    case "top": direction = -dy
    case "bottom": direction = dy
    default: return
    }
    guard direction != 0 else { return }
    outward = direction > 0
    moved = now
  }

  func shouldHide(rendered: CGPoint, confirmed: CGPoint, bounds: CGRect,
                  held: Bool, at now: TimeInterval) -> Bool {
    guard !held, outward, let moved = moved, now >= moved, now - moved <= 0.25,
          now >= started, now - started >= 0.2 else { return false }
    return onEdge(rendered, bounds: bounds) && onEdge(confirmed, bounds: bounds)
  }

  func shouldCancel(confirmed: CGPoint, bounds: CGRect, held: Bool) -> Bool {
    // Silence alone must not show the cursor again while the end message is
    // delayed. Positive evidence of continued on-screen control cancels hiding.
    held || !outward || !onEdge(confirmed, bounds: bounds)
  }

  private func onEdge(_ point: CGPoint, bounds: CGRect) -> Bool {
    guard bounds.width > 1, bounds.height > 1 else { return false }
    switch edge {
    case "left":
      return point.x >= bounds.minX - 1 && point.x <= bounds.minX + 1 &&
        point.y >= bounds.minY && point.y < bounds.maxY
    case "right":
      return point.x >= bounds.maxX - 2 && point.x <= bounds.maxX &&
        point.y >= bounds.minY && point.y < bounds.maxY
    case "top":
      return point.y >= bounds.minY - 1 && point.y <= bounds.minY + 1 &&
        point.x >= bounds.minX && point.x < bounds.maxX
    case "bottom":
      return point.y >= bounds.maxY - 2 && point.y <= bounds.maxY &&
        point.x >= bounds.minX && point.x < bounds.maxX
    default: return false
    }
  }
}

// Balanced process-owned hiding, with local and global event monitors so input
// in either this app or another app can restore the cursor without consuming it.
final class ReceiverCursorVisibility {
  static let remoteEventTag: Int64 = 0x5348494D4143 // SHIMAC
  private let lock = NSLock()
  private var hidden = false
  private var anticipating = false
  private var localOverride = false
  private var exitStartedAt: TimeInterval?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private let setVisible: (Bool) -> Bool

  var canParkOnExit: Bool {
    lock.lock(); defer { lock.unlock() }
    return !localOverride
  }

  init(setVisible: @escaping (Bool) -> Bool = { visible in
    // Reassert on each transition, including after foreground/Space changes.
    _ = ReceiverCursorVisibility.enableBackgroundCursor()
    let display = CGMainDisplayID()
    return (visible ? CGDisplayShowCursor(display) : CGDisplayHideCursor(display)) == .success
  }) {
    self.setVisible = setVisible
    let events: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp, .scrollWheel,
      .gesture, .magnify, .swipe, .rotate, .beginGesture, .endGesture,
    ]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      self?.localInput(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      self?.localInput(event)
      return event
    }
  }

  deinit {
    if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    show()
  }

  func localInput(_ event: NSEvent) {
    guard let source = event.cgEvent,
          source.getIntegerValueField(.eventSourceUserData) != Self.remoteEventTag,
          source.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
          source.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.privateState.rawValue) else { return }
    lock.lock(); defer { lock.unlock() }
    // AppKit may deliver older events after hiding. Only fresh local input may
    // override an exit; untagged events from our own process are still remote.
    guard let started = exitStartedAt, event.timestamp >= started else { return }
    if hidden || anticipating { localOverride = true }
    restoreLocked()
  }

  func anticipateExit() {
    lock.lock(); defer { lock.unlock() }
    if !anticipating && !hidden { exitStartedAt = ProcessInfo.processInfo.systemUptime }
    anticipating = true
    if !localOverride { hideLocked() }
  }

  func cancelAnticipation() {
    lock.lock(); defer { lock.unlock() }
    guard anticipating else { return }
    anticipating = false
    // A local takeover remains authoritative until a fresh capture begins.
    restoreLocked()
    exitStartedAt = nil
  }

  func hide() {
    lock.lock(); defer { lock.unlock() }
    anticipating = false
    // A delayed end must not undo local input after an anticipated handoff.
    if !localOverride { hideLocked() }
  }

  func show() {
    lock.lock(); defer { lock.unlock() }
    anticipating = false
    localOverride = false
    exitStartedAt = nil
    restoreLocked()
  }

  private func hideLocked() {
    // Keep local recovery available even if monitor installation fails.
    guard !hidden, globalMonitor != nil, localMonitor != nil else { return }
    if exitStartedAt == nil { exitStartedAt = ProcessInfo.processInfo.systemUptime }
    if setVisible(false) { hidden = true }
  }

  private func restoreLocked() {
    guard hidden else { return }
    if setVisible(true) { hidden = false }
  }

  @discardableResult
  static func enableBackgroundCursor() -> Bool {
    // Public Quartz hiding alone is normally limited to the foreground app.
    // Resolve the WindowServer opt-in dynamically; unsupported OS versions keep
    // the public behavior rather than failing to launch or stealing focus.
    typealias Connection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let image = dlopen(nil, RTLD_NOW) else { return false }
    defer { dlclose(image) }
    guard let connectionSymbol = dlsym(image, "CGSMainConnectionID"),
          let propertySymbol = dlsym(image, "CGSSetConnectionProperty") else { return false }
    let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
    let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
    return setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                       kCFBooleanTrue) == CGError.success.rawValue
  }
}
