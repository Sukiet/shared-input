import 'dart:math' as math;

abstract final class ScrollSpeed {
  static const minimum = 0.01;
  static const maximum = 20.0;
  static const defaultValue = 3.0;

  static double quantize(double value) =>
      (value.clamp(minimum, maximum) * 100).round() / 100;

  static double? parse(String text) {
    final value = double.tryParse(text.trim());
    if (value == null ||
        !value.isFinite ||
        value < minimum ||
        value > maximum) {
      return null;
    }
    return quantize(value);
  }

  static double fromSlider(double position) =>
      quantize(minimum * math.pow(maximum / minimum, position.clamp(0.0, 1.0)));

  static double toSlider(double value) =>
      math.log(value.clamp(minimum, maximum) / minimum) /
      math.log(maximum / minimum);
}
