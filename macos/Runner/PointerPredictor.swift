import Foundation
import CoreGraphics

/// Output-only smoothing. Never feeds rendered positions back into prediction.
struct PredictionOutput {
  private var segment = PointerInterpolator(duration: 0.008)
  private(set) var enabled = true

  mutating func configure(enabled: Bool, duration: TimeInterval, point: CGPoint, at time: TimeInterval) {
    self.enabled = enabled
    segment = PointerInterpolator(duration: duration)
    segment.reset(point, at: time)
  }

  mutating func reset(_ point: CGPoint, at time: TimeInterval) {
    segment.reset(point, at: time)
  }

  mutating func update(_ target: CGPoint, at time: TimeInterval) -> CGPoint {
    guard enabled else { segment.reset(target, at: time); return target }
    segment.retarget(target, at: time)
    return segment.value(at: time)
  }
}

/// Sender-time velocity estimation with bounded, exponentially damped extrapolation.
/// Predictions never enter the sample history or authoritative position.
struct PointerPredictor {
  var trigger: TimeInterval = 0.008
  var horizon: TimeInterval = 0.060
  var decay: TimeInterval = 0.040
  var history: TimeInterval = 0.020
  var maxDistance: Double = 32
  private(set) var confirmed = CGPoint.zero
  private var samples: [(time: Double, point: CGPoint)] = []
  private var velocity = CGPoint.zero
  private var receivedAt: TimeInterval = 0
  private var lastSource: Int64 = 0

  mutating func reset(_ point: CGPoint) {
    confirmed = point
    samples.removeAll(keepingCapacity: true)
    velocity = .zero
    lastSource = 0
    receivedAt = 0
  }

  mutating func observe(_ point: CGPoint, cumulative: CGPoint, sourceUs: Int64,
                        moving: Bool, at time: TimeInterval) {
    confirmed = point
    // TCP heartbeat copies of old motion must not restart prediction.
    guard sourceUs > lastSource else { return }
    let source = Double(sourceUs) / 1_000_000
    if lastSource > 0 && source - Double(lastSource) / 1_000_000 > 0.1 {
      samples.removeAll(keepingCapacity: true)
      velocity = .zero
    }
    lastSource = sourceUs
    receivedAt = time
    guard moving else { samples.removeAll(keepingCapacity: true); velocity = .zero; return }
    if let last = samples.last {
      let step = CGPoint(x: cumulative.x - last.point.x, y: cumulative.y - last.point.y)
      if step.x * velocity.x + step.y * velocity.y < 0 {
        samples.removeAll(keepingCapacity: true)
        velocity = .zero
      }
    }
    samples.append((source, cumulative))
    while samples.count > 2 && source - samples[1].time > history { samples.removeFirst() }
    if samples.count > 128 { samples.removeFirst(samples.count - 128) }
    guard samples.count >= 3, let first = samples.first, source > first.time else { return }
    let dt = source - first.time
    velocity = CGPoint(x: (cumulative.x - first.point.x) / dt,
                       y: (cumulative.y - first.point.y) / dt)
  }

  func value(at time: TimeInterval) -> CGPoint {
    let elapsed = min(max(time - receivedAt - trigger, 0), horizon)
    guard elapsed > 0 else { return confirmed }
    let travel = decay * (1 - exp(-elapsed / decay))
    var dx = velocity.x * travel, dy = velocity.y * travel
    let distance = hypot(dx, dy)
    if distance > maxDistance { dx *= maxDistance / distance; dy *= maxDistance / distance }
    return CGPoint(x: confirmed.x + dx, y: confirmed.y + dy)
  }
}
