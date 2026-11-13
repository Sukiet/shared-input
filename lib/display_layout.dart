import 'dart:math' as math;
import 'dart:ui';

enum ScreenSide {
  right,
  left,
  top,
  bottom;

  ScreenSide get opposite => switch (this) {
    right => left,
    left => right,
    top => bottom,
    bottom => top,
  };
  bool get horizontal => this == right || this == left;
  String get label => switch (this) {
    right => '右侧',
    left => '左侧',
    top => '上方',
    bottom => '下方',
  };
}

/// Physical millimetres keep edge positions independent of resolution and DPI.
class DisplayLayout {
  const DisplayLayout({
    this.controllerInches = 17,
    this.remoteInches = 14,
    this.controllerAspect = 1.6,
    this.remoteAspect = 1.6,
    this.side = ScreenSide.right,
    this.offset = 0,
  });

  final double controllerInches, remoteInches;
  final double controllerAspect, remoteAspect;
  final ScreenSide side;
  final double offset;

  static Size physicalSize(double inches, double aspect) {
    final height = inches * 25.4 / math.sqrt(1 + aspect * aspect);
    return Size(height * aspect, height);
  }

  Size get controllerSize => physicalSize(controllerInches, controllerAspect);
  Size get remoteSize => physicalSize(remoteInches, remoteAspect);
  Rect get controllerRect => Offset.zero & controllerSize;
  Rect get remoteRect =>
      (switch (side) {
        ScreenSide.right => Offset(controllerSize.width, offset),
        ScreenSide.left => Offset(-remoteSize.width, offset),
        ScreenSide.top => Offset(offset, -remoteSize.height),
        ScreenSide.bottom => Offset(offset, controllerSize.height),
      }) &
      remoteSize;

  double get controllerSpan =>
      side.horizontal ? controllerSize.height : controllerSize.width;
  double get remoteSpan =>
      side.horizontal ? remoteSize.height : remoteSize.width;
  double get overlapStart => math.max(0, offset);
  double get overlapEnd => math.min(controllerSpan, offset + remoteSpan);

  DisplayLayout copyWith({
    double? controllerInches,
    double? remoteInches,
    double? controllerAspect,
    double? remoteAspect,
    ScreenSide? side,
    double? offset,
  }) {
    final result = DisplayLayout(
      controllerInches: controllerInches ?? this.controllerInches,
      remoteInches: remoteInches ?? this.remoteInches,
      controllerAspect: controllerAspect ?? this.controllerAspect,
      remoteAspect: remoteAspect ?? this.remoteAspect,
      side: side ?? this.side,
      offset: offset ?? this.offset,
    );
    final minimumOverlap = math.min(
      10.0,
      math.min(result.controllerSpan, result.remoteSpan) / 2,
    );
    return DisplayLayout(
      controllerInches: result.controllerInches,
      remoteInches: result.remoteInches,
      controllerAspect: result.controllerAspect,
      remoteAspect: result.remoteAspect,
      side: result.side,
      offset: result.offset.clamp(
        -result.remoteSpan + minimumOverlap,
        result.controllerSpan - minimumOverlap,
      ),
    );
  }

  DisplayLayout snapRemote(Offset topLeft) {
    final delta =
        topLeft +
        remoteSize.center(Offset.zero) -
        controllerSize.center(Offset.zero);
    final x = delta.dx / ((controllerSize.width + remoteSize.width) / 2);
    final y = delta.dy / ((controllerSize.height + remoteSize.height) / 2);
    final nextSide = x.abs() >= y.abs()
        ? (x >= 0 ? ScreenSide.right : ScreenSide.left)
        : (y >= 0 ? ScreenSide.bottom : ScreenSide.top);
    return copyWith(
      side: nextSide,
      offset: nextSide.horizontal ? topLeft.dy : topLeft.dx,
    );
  }

  double? toRemote(double localFraction) {
    final position = localFraction * controllerSpan;
    if (position < overlapStart || position > overlapEnd) return null;
    return ((position - offset) / remoteSpan).clamp(0.0, 1.0);
  }

  double? toController(double remoteFraction) {
    final position = offset + remoteFraction * remoteSpan;
    if (position < 0 || position > controllerSpan) return null;
    return (position / controllerSpan).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'controllerInches': controllerInches,
    'remoteInches': remoteInches,
    'controllerAspect': controllerAspect,
    'remoteAspect': remoteAspect,
    'side': side.name,
    'offset': offset,
  };
  Map<String, dynamic> get nativeOptions => {
    'side': side.name,
    'offset': offset,
    'controllerWidth': controllerSize.width,
    'controllerHeight': controllerSize.height,
    'remoteWidth': remoteSize.width,
    'remoteHeight': remoteSize.height,
  };

  static DisplayLayout fromJson(dynamic value) {
    if (value is! Map) return const DisplayLayout();
    double number(String key, double fallback, double min, double max) {
      final n = value[key];
      return n is num && n.isFinite && n >= min && n <= max
          ? n.toDouble()
          : fallback;
    }

    return DisplayLayout(
      controllerInches: number('controllerInches', 17, 5, 100),
      remoteInches: number('remoteInches', 14, 5, 100),
      controllerAspect: number('controllerAspect', 1.6, 0.2, 5),
      remoteAspect: number('remoteAspect', 1.6, 0.2, 5),
      side:
          ScreenSide.values.where((s) => s.name == value['side']).firstOrNull ??
          ScreenSide.right,
      offset: number('offset', 0, -10000, 10000),
    ).copyWith();
  }
}
