import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/pointer_preview.dart';

void main() {
  testWidgets(
    'retained preview component follows fractional positions without rebuilding',
    (tester) async {
      final position = ValueNotifier(const Offset(123.4567, 67.8912));
      await tester.pumpWidget(
        MaterialApp(home: PointerPreview(position: position)),
      );
      final paint = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is PointerPainter,
      );
      final painter =
          tester.widget<CustomPaint>(paint).painter! as PointerPainter;
      for (var i = 0; i < 4; i++) {
        final next = Offset(123 + i * 0.0001, 67.8912);
        position.value = next;
        await tester.pump(const Duration(milliseconds: 16));
        expect(painter.position.value, next);
        expect(
          identical(tester.widget<CustomPaint>(paint).painter, painter),
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox());
      position.dispose();
    },
  );
}
