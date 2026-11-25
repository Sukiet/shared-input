@main
struct IncomingDragLifecycleTest {
  static func check(_ value: Bool, _ message: String) {
    precondition(value, message)
  }
  static func main() {
    var state = IncomingDragLifecycle()
    state.prepare()
    check(!state.motionAllowed && !state.willBegin(), "no drag or motion before a real source down")
    check(state.sourceMouseDown(), "real source event starts once")
    check(!state.sourceMouseDown(), "second down cannot replace current drag")
    check(state.motionAllowed, "first Dragged can bootstrap AppKit after real source down")
    check(state.willBegin() && state.motionAllowed, "AppKit willBegin enables forwarding")
    check(!state.canWritePromise, "holding is never a completed drop")
    let premature = state.ended(copy: false)
    check(premature.unexpected && !premature.accepted, "native session loss while held must fail closed")
    check(!state.motionAllowed, "failed session cannot fall through to desktop dragging")

    state.prepare(); check(state.sourceMouseDown() && state.willBegin(), "next session starts")
    check(state.release() && state.canWritePromise, "only actual release authorizes promise writing")
    let dropped = state.ended(copy: true)
    check(!dropped.unexpected && dropped.accepted, "accepted copy survives session cleanup")

    state.prepare(); check(!state.release(), "release before startup is cancellation, never a drop")
    check(!state.sourceMouseDown() && !state.willBegin(), "late queued down/begin cannot revive cancelled drag")
    let early = state.ended(copy: true)
    check(!early.unexpected && !early.accepted, "even a copy operation cannot authorize cancelled startup")

    state.prepare(); check(state.sourceMouseDown() && state.willBegin(), "cancel test starts")
    check(state.cancel() && !state.cancel(), "Escape is requested once for active tracking")
    check(!state.release() && !state.canWritePromise, "safety MouseUp cannot become a user drop")
    check(!state.ended(copy: false).unexpected, "explicit cancellation is not native session loss")
    print("Incoming drag event ordering, cancellation and premature-end policy passed")
  }
}
