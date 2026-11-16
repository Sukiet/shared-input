import Cocoa

@main
struct ReceiverCursorTests {
  static func main() {
    let bounds = CGRect(x: -200, y: -100, width: 1000, height: 800)
    let center = CGPoint(x: 300, y: 300)
    for (side, dx, dy, point) in [
      ("left", -10.0, 0.0, CGPoint(x: bounds.minX, y: 300)),
      ("right", 10.0, 0.0, CGPoint(x: bounds.maxX - 1, y: 300)),
      ("top", 0.0, -10.0, CGPoint(x: 300, y: bounds.minY)),
      ("bottom", 0.0, 10.0, CGPoint(x: 300, y: bounds.maxY - 1)),
    ] {
      var edge = ReceiverEdgeExit(edge: side, started: 1)
      func hides(_ rendered: CGPoint, _ confirmed: CGPoint, held: Bool = false,
                 at now: TimeInterval = 1.31) -> Bool {
        edge.shouldHide(rendered: rendered, confirmed: confirmed, bounds: bounds, held: held, at: now)
      }
      precondition(!hides(point, point), "edge contact without outward intent")
      edge.motion(dx: dx, dy: dy, at: 1.1)
      precondition(!hides(point, point, at: 1.15), "entry guard")
      precondition(hides(point, point), "hide on configured edge before end notification")
      precondition(!hides(point, point, held: true), "held key/button must prevent anticipation")
      precondition(!hides(point, center), "prediction alone must not hide")
      precondition(!hides(center, point), "wait for rendered pointer to reach edge")
      precondition(!hides(point, point, at: 1.5), "stale intent must not initiate hiding")
      precondition(!edge.shouldCancel(confirmed: point, bounds: bounds, held: false),
                   "a delayed end must not undo an existing hide")
      precondition(edge.shouldCancel(confirmed: center, bounds: bounds, held: false))
      precondition(edge.shouldCancel(confirmed: point, bounds: bounds, held: true))
      edge.motion(dx: -dx, dy: -dy, at: 1.32)
      precondition(!hides(point, point, at: 1.33), "inward motion cancels anticipation")
      precondition(edge.shouldCancel(confirmed: point, bounds: bounds, held: false))
    }
    let manual = ReceiverEdgeExit()
    precondition(!manual.shouldHide(rendered: .zero, confirmed: .zero,
                                   bounds: bounds, held: false, at: 10))

    _ = NSApplication.shared
    let backend = CursorBackend()
    var cursor: ReceiverCursorVisibility? = ReceiverCursorVisibility(setVisible: backend.setVisible)
    func mouse(_ type: CGEventType = .mouseMoved, remote: Bool = false) -> NSEvent {
      let event = CGEvent(mouseEventSource: nil, mouseType: type,
                          mouseCursorPosition: .zero, mouseButton: .left)!
      if remote { event.setIntegerValueField(.eventSourceUserData, value: ReceiverCursorVisibility.remoteEventTag) }
      return NSEvent(cgEvent: event)!
    }
    cursor!.anticipateExit()
    precondition(!backend.visible)
    cursor!.anticipateExit()
    cursor!.hide()
    precondition(backend.hides == 1, "one balanced hide across anticipation and actual end")
    cursor!.localInput(mouse(remote: true))
    precondition(!backend.visible, "queued injected event must not restore cursor")
    cursor!.localInput(mouse())
    precondition(backend.visible)
    cursor!.show() // Fresh capture clears local override.
    cursor!.anticipateExit()
    cursor!.localInput(mouse())
    cursor!.anticipateExit()
    cursor!.hide() // Simulate a one-second-late end after local takeover.
    precondition(backend.visible, "late end must not re-hide after native input")
    cursor!.cancelAnticipation()
    cursor!.anticipateExit()
    precondition(backend.visible, "local takeover persists until a fresh capture")
    cursor!.show()
    cursor!.anticipateExit()
    precondition(!backend.visible)
    cursor!.cancelAnticipation()
    precondition(backend.visible, "continued on-screen control cancels anticipation")
    for type: CGEventType in [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
      cursor!.show()
      cursor!.hide()
      cursor!.localInput(mouse(type))
      precondition(backend.visible, "local movement/button/drag restores cursor")
    }
    cursor!.show()
    cursor!.hide()
    let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                         wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
    cursor!.localInput(NSEvent(cgEvent: scroll)!)
    precondition(backend.visible, "native trackpad/mouse scroll restores cursor")
    cursor!.show()
    cursor!.hide()
    cursor = nil
    precondition(backend.visible && backend.hides == backend.shows, "cleanup must balance hide counts")
    print("Receiver cursor checks passed (four edges, prediction guards, delayed end, native input, cleanup)")
    print("Background cursor support on this Mac: \(ReceiverCursorVisibility.enableBackgroundCursor())")
  }
}

private final class CursorBackend {
  var visible = true
  var hides = 0, shows = 0
  func setVisible(_ visible: Bool) -> Bool {
    self.visible = visible
    if visible { shows += 1 } else { hides += 1 }
    return true
  }
}
