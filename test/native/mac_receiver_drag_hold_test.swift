import Cocoa

@main
struct ReceiverDragHoldChecks {
  static func main() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let late = CGPoint(x: 20, y: 300)
    precondition(dragProbeAnchor(late, bounds: bounds, side: "left", scale: 2).x == 0.25)
    precondition(dragProbeAnchor(late, bounds: bounds, side: "right", scale: 2).x == 999.75)
    precondition(dragProbeAnchor(late, bounds: bounds, side: "top", scale: 2).y == 0.25)
    precondition(dragProbeAnchor(late, bounds: bounds, side: "bottom", scale: 2).y == 799.75)
    var state = ReceiverDragState()
    precondition(!state.prepareSuspension(distance: 1), "an edge click alone is not a drag")
    precondition(state.prepareSuspension(distance: 4), "late AppKit metadata must not cancel a genuine drag")
    let preparedFlow = state.flow
    precondition(state.prepareSuspension(distance: 5) && state.flow == preparedFlow)
    state.reset()
    state.begin()
    let flow = state.flow
    for _ in 0..<5 {
      state.edge(); state.crossed()
      precondition(state.active && state.onController)
      state.returned(continuing: true)
      precondition(state.active && !state.onController && state.flow == flow)
    }
    state.end()
    precondition(!state.active)
    state.begin(); state.crossed(); state.returned()
    precondition(!state.active, "legacy capture return keeps its original behavior")
    var hold = ReceiverDragLease(token: String(repeating: "a", count: 32), button: 0,
      pressId: 17, flow: flow, started: 10, renewed: 10)
    precondition(hold.matches(hold.snapshot))
    var wrong = hold.snapshot
    wrong["pressId"] = 18
    precondition(!hold.matches(wrong))
    wrong = hold.snapshot; wrong["token"] = String(repeating: "b", count: 32)
    precondition(!hold.matches(wrong))
    precondition(!hold.expired(at: 11.49) && hold.expired(at: 11.5))
    hold.renewed = 11.4
    precondition(!hold.expired(at: 12.8))
    hold.renewed = 69.9
    precondition(hold.expired(at: 70), "leases must not hold a button indefinitely")
    precondition(hold.expired(at: 69), "invalid backwards time fails closed")
    print("Mac receiver drag hold checks passed (five round trips, identity, lease timeout, hard limit)")
  }
}
