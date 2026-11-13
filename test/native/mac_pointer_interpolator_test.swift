import Foundation
import CoreGraphics

@main
struct PointerInterpolatorTests {
  static func near(_ actual: CGPoint, _ expected: CGPoint) {
    precondition(abs(actual.x - expected.x) < 1e-8 && abs(actual.y - expected.y) < 1e-8,
                 "Unexpected interpolated position: \(actual), expected \(expected)")
  }

  static func main() {
    var pointer = PointerInterpolator()
    pointer.reset(.zero, at: 0)
    pointer.retarget(CGPoint(x: 12, y: -24), at: 1)
    near(pointer.value(at: 1), .zero)
    near(pointer.value(at: 1.006), CGPoint(x: 6, y: -12))
    near(pointer.value(at: 1.012), CGPoint(x: 12, y: -24))
    // No extrapolation or drift during a long network gap.
    near(pointer.value(at: 20), CGPoint(x: 12, y: -24))

    pointer.reset(.zero, at: 0)
    pointer.retarget(CGPoint(x: 12, y: 0), at: 1)
    pointer.retarget(CGPoint(x: 18, y: 12), at: 1.006)
    near(pointer.value(at: 1.006), CGPoint(x: 6, y: 0))
    near(pointer.value(at: 1.012), CGPoint(x: 12, y: 6))
    near(pointer.value(at: 1.018), CGPoint(x: 18, y: 12))

    // A repeated target must not postpone completion.
    pointer.retarget(CGPoint(x: 18, y: 12), at: 1.015)
    near(pointer.value(at: 1.018), CGPoint(x: 18, y: 12))

    // Reliable click/drag barriers settle immediately and erase the old path.
    pointer.retarget(CGPoint(x: 30, y: 24), at: 2)
    pointer.reset(pointer.target, at: 2.001)
    near(pointer.value(at: 2.001), CGPoint(x: 30, y: 24))
    near(pointer.value(at: 3), CGPoint(x: 30, y: 24))

    // Stop/disconnect discards the remaining motion; a new capture starts clean.
    pointer.retarget(CGPoint(x: 80, y: 80), at: 4)
    let stopped = pointer.value(at: 4.004)
    pointer.reset(stopped, at: 4.004)
    near(pointer.value(at: 10), stopped)
    pointer.reset(CGPoint(x: -100, y: 300), at: 11)
    near(pointer.value(at: 11), CGPoint(x: -100, y: 300))
    // Changing duration mid-flight preserves position and uses the new horizon.
    pointer.reset(.zero, at: 20)
    pointer.retarget(CGPoint(x: 12, y: 24), at: 21)
    pointer.setDuration(0.024, at: 21.006)
    near(pointer.value(at: 21.006), CGPoint(x: 6, y: 12))
    near(pointer.value(at: 21.018), CGPoint(x: 9, y: 18))
    near(pointer.value(at: 21.030), CGPoint(x: 12, y: 24))
    print("Pointer interpolation checks passed")
  }
}
