// Pure state policy, independent of AppKit so the ordering can be tested.
struct IncomingDragLifecycle {
  enum Phase: String { case idle, awaitingDown, starting, dragging, released, cancelling, ended }
  private(set) var phase: Phase = .idle
  private(set) var userReleased = false
  private(set) var cancelled = false
  // AppKit may need the first Dragged event to finish starting. Movement may
  // bootstrap only after the source view consumed the real down; it must not
  // depend on willBegin, which would create a circular startup dependency.
  var motionAllowed: Bool { phase == .starting || phase == .dragging }
  var canWritePromise: Bool { userReleased && !cancelled }
  mutating func prepare() { phase = .awaitingDown; userReleased = false; cancelled = false }
  mutating func sourceMouseDown() -> Bool {
    guard phase == .awaitingDown else { return false }
    phase = .starting; return true
  }
  mutating func willBegin() -> Bool {
    guard phase == .starting, !cancelled else { return false }
    phase = .dragging; return true
  }
  mutating func release() -> Bool {
    guard phase == .dragging, !cancelled else { _ = cancel(); return false }
    userReleased = true; phase = .released; return true
  }
  mutating func cancel() -> Bool {
    guard phase != .idle, phase != .ended, phase != .cancelling else { return false }
    let sendEscape = phase == .starting || phase == .dragging
    cancelled = true; phase = .cancelling; return sendEscape
  }
  mutating func ended(copy: Bool) -> (unexpected: Bool, accepted: Bool) {
    let unexpected = !userReleased && !cancelled
    let accepted = copy && canWritePromise
    phase = .ended
    return (unexpected, accepted)
  }
}
