import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'display_layout.dart';

class DisplayLayoutDialog extends StatefulWidget {
  const DisplayLayoutDialog({super.key, required this.layout});
  final DisplayLayout layout;
  @override
  State<DisplayLayoutDialog> createState() => _DisplayLayoutDialogState();
}

class _DisplayLayoutDialogState extends State<DisplayLayoutDialog> {
  late DisplayLayout _layout = widget.layout;
  late final _controllerSize = TextEditingController(
    text: _layout.controllerInches.toStringAsFixed(1),
  );
  late final _remoteSize = TextEditingController(
    text: _layout.remoteInches.toStringAsFixed(1),
  );
  String? _controllerError, _remoteError;
  Offset? _dragPosition;
  double? _dragScale;
  Offset? _dragOrigin;

  @override
  void dispose() {
    _controllerSize.dispose();
    _remoteSize.dispose();
    super.dispose();
  }

  Widget _sizeField(bool controller) {
    final size = controller ? _layout.controllerSize : _layout.remoteSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: Key(controller ? 'controller-inches' : 'remote-inches'),
          controller: controller ? _controllerSize : _remoteSize,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: controller ? '控制端（英寸）' : 'Mac（英寸）',
            errorText: controller ? _controllerError : _remoteError,
          ),
          onChanged: (text) {
            final n = double.tryParse(text);
            final valid = n != null && n.isFinite && n >= 5 && n <= 100;
            setState(() {
              if (controller) {
                _controllerError = valid ? null : '范围 5～100';
              } else {
                _remoteError = valid ? null : '范围 5～100';
              }
              if (valid) {
                _layout = controller
                    ? _layout.copyWith(controllerInches: n)
                    : _layout.copyWith(remoteInches: n);
              }
            });
          },
        ),
        const SizedBox(height: 6),
        Text(
          '${(size.width / 10).toStringAsFixed(1)} × ${(size.height / 10).toStringAsFixed(1)} cm',
          style: const TextStyle(fontSize: 11, color: Color(0xff929aa6)),
        ),
      ],
    );
  }

  Widget _canvas() => LayoutBuilder(
    builder: (context, constraints) {
      final bounds = _layout.controllerRect.expandToInclude(_layout.remoteRect);
      final scale =
          _dragScale ??
          math.min(
            (constraints.maxWidth - 48) / bounds.width,
            (constraints.maxHeight - 48) / bounds.height,
          );
      final origin =
          _dragOrigin ??
          Offset(
            (constraints.maxWidth - bounds.width * scale) / 2 -
                bounds.left * scale,
            (constraints.maxHeight - bounds.height * scale) / 2 -
                bounds.top * scale,
          );
      Rect transform(Rect rect) => Rect.fromLTWH(
        origin.dx + rect.left * scale,
        origin.dy + rect.top * scale,
        rect.width * scale,
        rect.height * scale,
      );
      final remote = transform(
        (_dragPosition ?? _layout.remoteRect.topLeft) & _layout.remoteSize,
      );
      Widget screen(Rect rect, bool controller) => Positioned.fromRect(
        rect: rect,
        child: Container(
          key: Key(controller ? 'controller-screen' : 'remote-screen-rect'),
          decoration: BoxDecoration(
            color: controller
                ? const Color(0xffaa47bd)
                : const Color(0xff303030),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: controller
                  ? const Color(0xffcb83dc)
                  : const Color(0xff555555),
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  controller ? '1' : '2',
                  style: TextStyle(
                    fontSize: rect.height < 85 ? 24 : 36,
                    color: Colors.white,
                  ),
                ),
                Text(
                  controller
                      ? '控制端 · ${_layout.controllerInches.toStringAsFixed(1)}″'
                      : 'Mac · ${_layout.remoteInches.toStringAsFixed(1)}″',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xff171717),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ClipRect(
          child: Stack(
            children: [
              screen(transform(_layout.controllerRect), true),
              Positioned.fromRect(
                rect: remote,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    key: const Key('remote-screen'),
                    onPanStart: (_) => setState(() {
                      _dragPosition = _layout.remoteRect.topLeft;
                      _dragScale = scale;
                      _dragOrigin = origin;
                    }),
                    onPanUpdate: (event) => setState(
                      () =>
                          _dragPosition = _dragPosition! + event.delta / scale,
                    ),
                    onPanEnd: (_) => setState(() {
                      _layout = _layout.snapRemote(_dragPosition!);
                      _dragPosition = null;
                      _dragScale = null;
                      _dragOrigin = null;
                    }),
                    onPanCancel: () => setState(() {
                      _dragPosition = null;
                      _dragScale = null;
                      _dragOrigin = null;
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xff303030),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: _dragPosition == null
                              ? const Color(0xff555555)
                              : const Color(0xffcb83dc),
                        ),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '2',
                              style: TextStyle(
                                fontSize: remote.height < 85 ? 24 : 36,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              'Mac · ${_layout.remoteInches.toStringAsFixed(1)}″',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '显示屏设置',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            SizedBox(height: 280, child: _canvas()),
            const SizedBox(height: 10),
            Text(
              'Mac 在${_layout.side.label} · 拖动 2 调整位置',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              '控制端固定；相邻的边缘区域用于跨屏映射。',
              style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _sizeField(true)),
                const SizedBox(width: 16),
                Expanded(child: _sizeField(false)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '宽高比按两端主屏读取，未连接时先用 16:10 示意。',
              style: TextStyle(fontSize: 11, color: Color(0xff929aa6)),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _layout = DisplayLayout(
                      controllerAspect: _layout.controllerAspect,
                      remoteAspect: _layout.remoteAspect,
                    );
                    _controllerSize.text = '17.0';
                    _remoteSize.text = '14.0';
                    _controllerError = _remoteError = null;
                  }),
                  child: const Text('恢复默认'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('save-display-layout'),
                  onPressed:
                      _controllerError == null &&
                          _remoteError == null &&
                          _dragPosition == null
                      ? () => Navigator.pop(context, _layout)
                      : null,
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
