import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/display_layout.dart';
import 'package:shared_input/settings.dart';

void main() {
  test('physical overlap maps bidirectionally on every side', () {
    const base = DisplayLayout();
    expect(base.toRemote(0.5), closeTo(0.5 * 17 / 14, 1e-9));
    expect(base.toRemote(0.95), isNull);
    for (final side in ScreenSide.values) {
      final layout = base.copyWith(side: side, offset: 30);
      final local = (30 + layout.remoteSpan * 0.4) / layout.controllerSpan;
      expect(layout.toRemote(local), closeTo(0.4, 1e-9));
      expect(layout.toController(0.4), closeTo(local, 1e-9));
      expect(layout.toRemote(0), isNull);
    }
  });
  test('drag snaps without overlap, and layout restores', () {
    for (final entry in {
      ScreenSide.left: const Offset(-500, 0),
      ScreenSide.right: const Offset(500, 0),
      ScreenSide.top: const Offset(0, -500),
      ScreenSide.bottom: const Offset(0, 500),
    }.entries) {
      final layout = const DisplayLayout().snapRemote(entry.value);
      expect(layout.side, entry.key);
      expect(layout.controllerRect.overlaps(layout.remoteRect), isFalse);
      expect(layout.overlapEnd - layout.overlapStart, greaterThan(9.99));
      final settings = AppSettings()..displayLayout = layout;
      expect(
        AppSettings.fromJson(settings.toJson()).displayLayout.toJson(),
        layout.toJson(),
      );
    }
    final invalid = DisplayLayout.fromJson({
      'controllerInches': 0,
      'remoteInches': -1,
      'offset': 9999,
    });
    expect(invalid.controllerInches, 17);
    expect(invalid.remoteInches, 14);
    expect(invalid.overlapEnd, greaterThan(invalid.overlapStart));
  });
}
