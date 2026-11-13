#include "../../windows/runner/safety_policy.h"
#include "../../windows/runner/pointer_motion.h"
#include <limits>
#include <cstdlib>
#include <iostream>

void Check(bool condition, const char* message) {
  if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

int main() {
  using namespace shared_input;
  Check(ValidSensitivity(0.0001), "minimum sensitivity accepted");
  Check(ValidSensitivity(0.0017), "fine low sensitivity accepted");
  Check(ValidSensitivity(4.0), "maximum sensitivity accepted");
  for (double invalid : {0.0, -1.0, 0.00001, 4.0001,
                        std::numeric_limits<double>::infinity(),
                        std::numeric_limits<double>::quiet_NaN()}) {
    Check(!ValidSensitivity(invalid), "invalid sensitivity rejected");
  }
  double position = 300;
  for (int i = 0; i < 10000; ++i) position = MovePointer(position, 1, 0.0001, 600);
  Check(std::abs(position - 301) < 1e-7, "tiny deltas accumulate without integer truncation");
  Check(MovePointer(0, -100, 0.0001, 600) == 0, "left boundary clamps");
  Check(MovePointer(600, 100, 0.0001, 600) == 600, "right boundary clamps");
  Check(MovePointer(0, 1, 0.0001, 600) == 0.0001, "one raw count retains fractional movement");
  Check(ValidShortcut(0x77, true, true, false), "Ctrl Alt F8 accepted");
  Check(ValidShortcut('Q', true, true, false), "Ctrl Alt letter accepted");
  Check(!ValidShortcut(0x7B, true, true, false), "F12 rejected");
  Check(!ValidShortcut(0x73, true, true, false), "Alt F4 rejected");
  Check(!ValidShortcut('Q', false, true, false), "missing Ctrl rejected");
  Check(!ValidShortcut('Q', true, true, true), "Win chord rejected");
  Check(CheckExpiry(29999, 0, 29000) == Expiry::none, "before duration limit");
  Check(CheckExpiry(30000, 0, 29000) == Expiry::timeout, "exact duration limit");
  Check(CheckExpiry(4000, 1000, 1000) == Expiry::heartbeat, "heartbeat boundary");
  Check(CheckExpiry(3999, 1000, 1000) == Expiry::none, "before heartbeat boundary");
  Check(CheckExpiry(4000, 1000, 4001) == Expiry::none, "concurrent newer heartbeat must not underflow");
  for (bool vertical : {false, true}) {
    ShakeDetector detector;
    bool result = false;
    for (int i = 0; i < 7; ++i) {
      const int delta = i % 2 == 0 ? 800 : -800;
      result = detector.Add(vertical ? 0 : delta, vertical ? delta : 0, 100 + i * 150);
      if (i < 6) Check(!result, "fewer than six reversals rejected even with large motion");
    }
    Check(result, "rapid large shake exits on either axis");
  }
  ShakeDetector monotonic, jitter, slow, old_gesture, moderate_corrections;
  for (int i = 0; i < 50; ++i) {
    Check(!monotonic.Add(100, 0, i * 10), "straight movement is not a shake");
    Check(!jitter.Add(i % 2 ? 4 : -4, 0, i * 10), "small jitter rejected");
    Check(!slow.Add(i % 2 ? 800 : -800, 0, i * 400), "slow reversal rejected");
    Check(!old_gesture.Add(i % 2 ? 140 : -140, 0, i * 50), "previously triggering small gesture is now rejected");
    Check(!moderate_corrections.Add(i % 2 ? 500 : -500, 0, i * 50), "subthreshold rapid corrections rejected");
  }
  ShakeDetector short_travel;
  for (int i = 0; i < 7; ++i) {
    Check(!short_travel.Add(i % 2 ? -680 : 680, 0, 100 + i * 50),
        "six reversals still require sufficient total travel");
  }
  Check(short_travel.Add(40, 0, 450), "total travel threshold is inclusive");
  for (int interval : {200, 201}) {
    ShakeDetector window_boundary;
    bool result = false;
    for (int i = 0; i < 7; ++i) {
      result = window_boundary.Add(i % 2 ? -800 : 800, 0, 100 + i * interval);
    }
    Check(result == (interval == 200), "gesture must finish within the 1200ms window");
  }
  ShakeDetector packetized;
  bool packetized_result = false;
  for (int leg = 0; leg < 7; ++leg) {
    for (int sample = 0; sample < 100; ++sample) {
      packetized_result = packetized.Add(leg % 2 ? -8 : 8, 0,
          100 + leg * 150 + sample);
      if (leg < 6) Check(!packetized_result, "high polling rate must not count extra reversals");
    }
  }
  Check(packetized_result, "deliberate shake also works across many small raw packets");
  ShakeDetector first_mouse, second_mouse;
  for (int i = 0; i < 5; ++i) {
    Check(!first_mouse.Add(800, 0, i * 100), "first mouse stays monotonic");
    Check(!second_mouse.Add(-800, 0, i * 100), "second mouse cannot combine a shake");
  }
  std::cout << "Safety policy checks passed.\n";
}
