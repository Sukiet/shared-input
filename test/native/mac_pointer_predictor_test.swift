import Foundation
import CoreGraphics

@main
struct PointerPredictorTests {
  static func near(_ a: Double, _ b: Double) { precondition(abs(a - b) < 1e-7, "\(a) != \(b)") }
  static func trained() -> PointerPredictor {
    var p = PointerPredictor()
    // Packets arrive in a burst: velocity must use 8 ms sender intervals.
    for i in 0...2 {
      let point = CGPoint(x: Double(i * 8), y: 0)
      p.observe(point, cumulative: point, sourceUs: Int64(1_000_000 + i * 8000),
                moving: true, at: Double(i) * 0.002)
    }
    return p
  }
  static func main() {
    var p = trained()
    near(p.value(at: 0.010).x, 16) // below trigger
    near(p.value(at: 0.022).x, 16 + 40 * (1 - exp(-0.25)))
    near(p.value(at: 0.072).x, p.value(at: 100).x) // horizon holds
    near(p.confirmed.x, 16) // prediction never contaminates truth
    p.maxDistance = 5
    near(p.value(at: 1).x, 21)
    // Real recovery replaces predicted travel instead of adding it again.
    p.observe(CGPoint(x: 20, y: 0), cumulative: CGPoint(x: 20, y: 0),
              sourceUs: 1_032_000, moving: true, at: 1)
    near(p.value(at: 1).x, 20)
    p.observe(CGPoint(x: 20, y: 0), cumulative: CGPoint(x: 20, y: 0),
              sourceUs: 1_048_000, moving: false, at: 1.01)
    near(p.value(at: 10).x, 20) // same-sequence idle state stops drift
    p = trained()
    p.observe(CGPoint(x: 8, y: 0), cumulative: CGPoint(x: 8, y: 0),
              sourceUs: 1_024_000, moving: true, at: 0.02)
    near(p.value(at: 1).x, 8) // reversal clears old momentum
    p = trained()
    p.reset(CGPoint(x: 4, y: 3)) // click/mode switch/drag/stop barrier
    near(p.value(at: 10).x, 4)
    near(p.value(at: 10).y, 3)
    p = trained()
    p.observe(CGPoint(x: 30, y: 0), cumulative: CGPoint(x: 30, y: 0),
              sourceUs: 2_000_000, moving: true, at: 1)
    near(p.value(at: 2).x, 30) // long discontinuity discards old velocity
    print("Pointer predictor checks passed")
  }
}
