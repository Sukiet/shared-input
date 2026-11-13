import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PointerPreview extends StatelessWidget {
  const PointerPreview({super.key, required this.position});
  final ValueListenable<Offset> position;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: ColoredBox(
        color: const Color(0xff0c0e11),
        child: CustomPaint(
          painter: PointerPainter(position),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

class PointerPainter extends CustomPainter {
  PointerPainter(this.position) : super(repaint: position);
  final ValueListenable<Offset> position;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 600.0;
    const height = 240.0;
    final scale = math.min(size.width / width, size.height / height);
    final origin = Offset(
      (size.width - width * scale) / 2,
      (size.height - height * scale) / 2,
    );
    final tip = origin + position.value * scale;
    // Position is applied directly: no tween, interpolation or integer rounding.
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 20)
      ..lineTo(5, 15)
      ..lineTo(9, 23)
      ..lineTo(12, 21.5)
      ..lineTo(8, 14)
      ..lineTo(15, 14)
      ..close();
    canvas.drawPath(
      arrow,
      Paint()
        ..color = const Color(0xff0c0e11)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(arrow, Paint()..color = const Color(0xfff1f3f5));
    canvas.restore();
  }

  @override
  bool shouldRepaint(PointerPainter oldDelegate) =>
      oldDelegate.position != position;
}
