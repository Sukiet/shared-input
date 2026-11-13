import 'dart:math' as math;

abstract final class Sensitivity {
  static const minimum = 0.0001;
  static const maximum = 4.0;
  static const defaultValue = 0.1;
  static const precision = 10000;

  static double quantize(double value) =>
      (value.clamp(minimum, maximum) * precision).round() / precision;

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

  // A linear slider would squeeze every gain below 0.01 into <0.25% of its
  // width. Logarithmic spacing gives those low values usable physical travel.
  static double fromSlider(double position) =>
      quantize(minimum * math.pow(maximum / minimum, position.clamp(0.0, 1.0)));

  static double toSlider(double value) =>
      math.log(value.clamp(minimum, maximum) / minimum) /
      math.log(maximum / minimum);
}
