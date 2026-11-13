#ifndef SHARED_INPUT_POINTER_MOTION_H_
#define SHARED_INPUT_POINTER_MOTION_H_
#include <algorithm>
#include <cmath>

namespace shared_input {
constexpr double kMinimumSensitivity = 0.0001;
constexpr double kMaximumSensitivity = 4.0;
inline bool ValidSensitivity(double value) {
  return std::isfinite(value) && value >= kMinimumSensitivity &&
      value <= kMaximumSensitivity;
}
inline double MovePointer(double position, int delta, double sensitivity, double limit) {
  return std::clamp(position + delta * sensitivity, 0.0, limit);
}
}  // namespace shared_input
#endif
