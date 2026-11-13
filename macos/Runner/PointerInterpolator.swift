import Foundation
import CoreGraphics

/// Retarget a short linear segment from its current value. Constant storage,
/// no queued paths, no extrapolation beyond the most recent received position.
struct PointerInterpolator {
  private(set) var duration: TimeInterval
  private var start = CGPoint.zero
  private(set) var target = CGPoint.zero
  private var startedAt: TimeInterval = 0

  init(duration: TimeInterval = 0.012) {
    precondition(duration > 0 && duration.isFinite)
    self.duration = duration
  }

  func value(at time: TimeInterval) -> CGPoint {
    let fraction = min(max((time - startedAt) / duration, 0), 1)
    if fraction == 1 { return target }
    return CGPoint(x: start.x + (target.x - start.x) * fraction,
                   y: start.y + (target.y - start.y) * fraction)
  }

  mutating func retarget(_ point: CGPoint, at time: TimeInterval) {
    // Identical heartbeats must not extend the settling time.
    guard point != target else { return }
    start = value(at: time)
    target = point
    startedAt = time
  }

  mutating func reset(_ point: CGPoint, at time: TimeInterval) {
    start = point
    target = point
    startedAt = time
  }

  mutating func setDuration(_ duration: TimeInterval, at time: TimeInterval) {
    precondition(duration > 0 && duration.isFinite)
    start = value(at: time)
    startedAt = time
    self.duration = duration
  }
}
