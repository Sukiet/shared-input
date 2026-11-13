import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/sensitivity.dart';

void main() {
  test(
    'accepts very low finite gains and rejects invalid or out of range input',
    () {
      expect(Sensitivity.parse('0.0001'), 0.0001);
      expect(Sensitivity.parse('0.0017'), 0.0017);
      expect(Sensitivity.parse('4'), 4);
      for (final text in [
        '0',
        '-1',
        '0.00001',
        '4.0001',
        'NaN',
        'Infinity',
        '',
      ]) {
        expect(Sensitivity.parse(text), isNull, reason: text);
      }
    },
  );

  test(
    'log slider gives low gains room and preserves precision across range',
    () {
      expect(Sensitivity.fromSlider(0), 0.0001);
      expect(Sensitivity.fromSlider(1), 4);
      expect(Sensitivity.toSlider(0.01), greaterThan(0.4));
      for (final gain in [0.0001, 0.0002, 0.0017, 0.02, 0.1, 1.7, 4.0]) {
        expect(
          Sensitivity.fromSlider(Sensitivity.toSlider(gain)),
          closeTo(gain, 1e-10),
        );
      }
      var previous = 0.0;
      for (var i = 0; i <= 1000; i++) {
        final current = Sensitivity.fromSlider(i / 1000);
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    },
  );
}
