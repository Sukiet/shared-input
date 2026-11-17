import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'display_layout.dart';
import 'edge_drag_preview.dart';
import 'remote/lan_session.dart';

/// Metadata only, on the existing authenticated control connection. The
/// controller owns the layout; no peer-supplied path is ever opened locally.
class DragPreviewLink extends ChangeNotifier {
  static const maxStateBytes = 48 * 1024;
  DragPreviewLink(
    this.session, {
    required this.origin,
    required this.configureReceiver,
    required this.clearLocal,
  }) {
    session.dragPreviewSupported = true;
    session.onDragPreviewControl = _receive;
    session.addListener(_connectionChanged);
    peer = EdgeDragPreview(origin: _other);
    local = EdgeDragPreview(origin: origin);
  }
  final LanSession session;
  final DragOrigin origin;
  final Future<void> Function(bool enabled, String side) configureReceiver;
  final Future<void> Function() clearLocal;
  late EdgeDragPreview local, peer;
  DisplayLayout layout = const DisplayLayout();
  DragOrigin get _other => origin == DragOrigin.controller
      ? DragOrigin.receiver
      : DragOrigin.controller;
  int _generation = -1;
  bool _connected = false, _disposed = false;
  bool get receiverReady =>
      session.connected &&
      session.supportsDragPreview &&
      peer.enabled &&
      peer.side == layout.side.opposite.name;
  Future<void> _work = Future.value();
  String _error = '';
  String get status => _error.isNotEmpty
      ? _error
      : !session.connected
      ? '未连接，仅显示本机事件'
      : !session.supportsDragPreview
      ? '对端需更新后才能显示两端拖拽事件'
      : '两端拖拽事件已同步';

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final generation = session.connectionGeneration;
    _work = _work
        .then((_) async {
          if (!_disposed && generation == session.connectionGeneration) {
            await action();
          }
        })
        .catchError((Object error) {
          if (!_disposed && generation == session.connectionGeneration) {
            _error = '拖拽事件同步失败：$error';
            _changed();
          }
        });
    return _work;
  }

  void _connectionChanged() {
    final connected = session.connected;
    final generation = session.connectionGeneration;
    if (connected == _connected && generation == _generation) return;
    _connected = connected;
    _generation = generation;
    _error = '';
    peer = EdgeDragPreview(origin: _other);
    if (connected && session.supportsDragPreview) {
      _enqueue(() async {
        if (origin == DragOrigin.controller) await _sendConfig();
        await _sendState();
      });
    } else if (!connected && origin == DragOrigin.receiver) {
      _enqueue(() => configureReceiver(false, layout.side.opposite.name));
    }
    _changed();
  }

  void configureLayout(DisplayLayout value) {
    layout = value;
    _changed();
    if (origin == DragOrigin.controller) _enqueue(_sendConfig);
  }

  void publish(EdgeDragPreview value) {
    final configChanged = local.enabled != value.enabled;
    local = value;
    if (session.connected && session.supportsDragPreview) {
      _enqueue(() async {
        if (origin == DragOrigin.controller && configChanged) {
          await _sendConfig();
        }
        await _sendState();
      });
    }
  }

  Future<void> _sendConfig() => session.sendDragPreviewControl({
    'type': 'dragPreviewConfig',
    'enabled': local.enabled,
    'side': layout.side.opposite.name,
  });
  Future<void> _sendState() => session.sendDragPreviewControl({
    'type': 'dragPreviewState',
    'state': wireState(local, origin),
  });
  Future<void> clearBoth() async {
    await clearLocal();
    await session.sendDragPreviewControl({'type': 'dragPreviewClear'});
  }

  Future<void> _receive(Map<String, dynamic> message) async {
    if (message['type'] == 'dragPreviewConfig') {
      if (origin != DragOrigin.receiver || !session.receiving) return;
      final enabled = message['enabled'], side = message['side'];
      if (enabled is! bool ||
          side is! String ||
          !ScreenSide.values.any((v) => v.name == side)) {
        return;
      }
      await _enqueue(() => configureReceiver(enabled, side));
    } else if (message['type'] == 'dragPreviewClear') {
      await _enqueue(clearLocal);
    } else if (message['type'] == 'dragPreviewState') {
      final value = parseWireState(message['state'], _other);
      if (value == null || value.revision <= peer.revision) return;
      peer = value;
      _changed();
    }
  }

  static Map<String, dynamic> wireState(
    EdgeDragPreview value,
    DragOrigin origin,
  ) {
    final output = <String, dynamic>{
      'origin': origin.name,
      'enabled': value.enabled,
      'hitEnabled': value.hitEnabled,
      'revision': value.revision < 0 ? 0 : value.revision,
      'side': _limit(value.side, 16),
      'phase': _limit(value.phase, 32),
      'dragFlow': value.dragFlow,
      'dragStage': _limit(value.dragStage, 32),
      'gestureActive': value.gestureActive,
      'onRemote': value.onRemote,
      'hovering': value.hovering,
      'dragHistory': value.dragHistory
          .take(16)
          .map((v) => _limit(v, 32))
          .toList(),
      'dragReason': _limit(value.dragReason, 1024),
      'message': _limit(value.message, 1024),
      'count': value.count,
      'truncated': value.truncated,
      'formats': value.formats.take(32).map((v) => _limit(v, 256)).toList(),
      'files': <Map<String, dynamic>>[],
    };
    // Bound the entire JSON, including escaped control characters and UTF-8.
    final formats = output['formats'] as List;
    while (formats.isNotEmpty &&
        utf8.encode(jsonEncode(output)).length > maxStateBytes) {
      formats.removeLast();
      output['truncated'] = true;
    }
    final files = output['files'] as List;
    var remaining = maxStateBytes - utf8.encode(jsonEncode(output)).length;
    for (final file in value.files.take(256)) {
      final entry = {
        'name': _limit(file.name, 1024),
        'path': _limit(file.path, 32768),
        'promised': file.promised,
      };
      final bytes =
          utf8.encode(jsonEncode(entry)).length + (files.isEmpty ? 0 : 1);
      if (bytes > remaining) {
        output['truncated'] = true;
        break;
      }
      remaining -= bytes;
      files.add(entry);
    }
    if (files.length < value.files.length) output['truncated'] = true;
    return output;
  }

  static String _limit(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
  static EdgeDragPreview? parseWireState(dynamic raw, DragOrigin expected) {
    try {
      if (raw is! Map ||
          raw['origin'] != expected.name ||
          utf8.encode(jsonEncode(raw)).length > maxStateBytes) {
        return null;
      }
      final value = EdgeDragPreview.fromMap(Map<String, dynamic>.from(raw));
      if (value.revision < 0 ||
          value.dragFlow < 0 ||
          value.count < 0 ||
          value.count > 1000000 ||
          !{
            'idle',
            'gesture',
            'edge',
            'switching',
            'crossed',
            'ended',
            'returned',
            'error',
          }.contains(value.dragStage)) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_connectionChanged);
    session.onDragPreviewControl = null;
    super.dispose();
  }
}
