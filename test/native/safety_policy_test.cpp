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
  std::cout << "Safety policy checks passed.\n";
}
