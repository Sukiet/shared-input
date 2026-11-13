import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/display_layout.dart';
import 'package:shared_input/settings.dart';

void main() {
  test('physical overlap maps bidirectionally on every side', () {
    const base = DisplayLayout();
    expect(base.toRemote(0.5), closeTo(0.5 * 17 / 14, 1e-9));
    expect(base.toRemote(0.95), 1);
    for (final side in ScreenSide.values) {
      final layout = base.copyWith(side: side, offset: 30);
      final local = (30 + layout.remoteSpan * 0.4) / layout.controllerSpan;
      expect(layout.toRemote(local), closeTo(0.4, 1e-9));
      expect(layout.toController(0.4), closeTo(local, 1e-9));
      expect(layout.toRemote(0), 0);
    }
  });
  test(
    'missing edge segments clamp to the nearest endpoint in both directions',
    () {
      for (final side in ScreenSide.values) {
        final base = const DisplayLayout().copyWith(side: side);
        final positive = base.copyWith(offset: base.controllerSpan / 2);
        expect(positive.toRemote(0), 0);
        expect(positive.toController(1), 1);
        final negative = base.copyWith(offset: -base.remoteSpan / 2);
        expect(negative.toRemote(1), 1);
        expect(negative.toController(0), 0);
        final larger = base.copyWith(remoteInches: 24);
        expect(larger.toController(1), 1);
        expect(larger.toRemote(1), closeTo(17 / 24, 1e-9));
      }
    },
  );
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
