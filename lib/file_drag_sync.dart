import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'edge_drag_preview.dart';
import 'remote/file_transfer_channel.dart';
import 'remote/lan_session.dart';
import 'settings.dart';

class FileDragSync extends ChangeNotifier {
  FileDragSync(this.lan, this.native) {
    lan.addListener(_connectionChanged);
    lan.onFileDragControl = _control;
    files.addListener(_changed);
    files.onProgress = (value) {
      unawaited(
        native
            .invokeMethod<void>('fileDragProgress', value)
            .catchError((Object _) {}),
      );
    };
  }
  final LanSession lan;
  final MethodChannel native;
  final files = FileTransferChannel();
  bool _source = false, _target = false, _disposed = false;
  int _generation = -1;
  bool _connected = false;
  final _requests = <String>{};
  String _error = '';
  String _nativeStatus = '';
  Map<String, dynamic> lastSessionState = {};
  final _failures = <String, Map<String, dynamic>>{};
  Future<void> _work = Future.value();
  String get status => _error.isNotEmpty
      ? _error
      : !lan.connected
      ? '连接后可将 Windows 文件复制到 Mac'
      : !lan.supportsFileDrag
      ? '对端需更新以支持文件拖拽传输'
      : files.error.isNotEmpty
      ? '文件通道已断开，请重新连接；键鼠连接不受影响'
      : !files.connected
      ? '正在建立文件通道'
      : _nativeStatus.isNotEmpty
      ? _nativeStatus
      : '文件拖到 Mac 后松手复制，原文件保留';

  Future<void> initialize() async {
    try {
      final caps = await native.invokeMapMethod<String, dynamic>(
        'fileDragCapabilities',
      );
      _source = caps?['source'] == true;
      _target = caps?['target'] == true;
      lan.fileDragSupported = _source || _target;
      lan.fileDragSource = _source;
      lan.fileDragTarget = _target;
      lan.fileDragStateSupported = lan.fileDragSupported;
    } on MissingPluginException {
      /* older runner */
    }
    _connectionChanged();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _connectionChanged() {
    if (_disposed ||
        (_generation == lan.connectionGeneration &&
            _connected == lan.connected)) {
      return;
    }
    _generation = lan.connectionGeneration;
    _connected = lan.connected;
    _error = '';
    _nativeStatus = '';
    lastSessionState = {};
    _failures.clear();
    final generation = _generation;
    _work = _work
        .then((_) async {
          await files.close();
          if (_disposed || generation != lan.connectionGeneration) return;
          if (_target) await native.invokeMethod<void>('fileDragReset');
          if (lan.connected &&
              lan.receiving &&
              _target &&
              lan.supportsFileDrag) {
            final key = randomHex();
            final port = await files.listen(key: key, remote: lan.remoteHost!);
            if (generation == lan.connectionGeneration && lan.connected) {
              await lan.sendFileDragControl({
                'type': 'fileDragPort',
                'port': port,
                'key': key,
              });
            }
          }
        })
        .catchError((Object error) {
          if (!_disposed) {
            _error = '文件通道失败：$error';
            _changed();
          }
        });
    _changed();
  }

  Future<void> _control(Map<String, dynamic> message) async {
    if (!lan.receiving && _source && message['type'] == 'fileDragState') {
      _sessionState(message);
      return;
    }
    if (lan.receiving || !_source || message['type'] != 'fileDragPort') return;
    final port = message['port'], key = message['key'];
    if (port is! int ||
        port <= 0 ||
        port > 65535 ||
        key is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(key)) {
      return;
    }
    final generation = lan.connectionGeneration;
    // Do not hold up the input control reader during file-channel handshaking.
    _work = _work
        .then((_) async {
          if (_disposed ||
              generation != lan.connectionGeneration ||
              !lan.connected) {
            return;
          }
          await files.connect(key: key, host: lan.remoteHost!, port: port);
        })
        .catchError((Object error) {
          if (!_disposed) {
            _error = '文件通道失败：$error';
            _changed();
          }
        });
  }

  Future<Map<String, dynamic>?> prepare(
    EdgeDragPreview preview, {
    EdgeDragPreview Function()? current,
  }) async {
    if (!_source || !lan.supportsFileDrag) return null;
    // OLE's DragEnter can arrive a few messages after the raw edge contact.
    // Bind names to the physical press, not the UI's retained previous list.
    if (current != null) {
      final until = DateTime.now().add(const Duration(milliseconds: 180));
      while (preview.gestureActive &&
          (preview.sourcePress == 0 ||
              preview.metadataPress != preview.sourcePress) &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        preview = current();
      }
    }
    if (preview.files.isEmpty ||
        preview.sourcePress == 0 ||
        preview.metadataPress != preview.sourcePress) {
      return null;
    }
    if (preview.truncated ||
        preview.files.length > 128 ||
        preview.files.any((v) => v.promised || v.path.isEmpty)) {
      throw const FormatException('仅支持最多 128 个真实文件或文件夹，暂不支持虚拟附件');
    }
    await _work;
    if (!files.connected) throw StateError('文件通道尚未就绪，请重新拖拽');
    final drag = randomHex();
    final items = await files.offer(
      drag,
      preview.files.map((v) => v.path).toList(),
    );
    // Optional, bounded image previews. Files still travel only after dropping.
    var budget = 20 * 1024;
    for (var i = 0; i < items.length && i < 8 && budget > 0; ++i) {
      if (items[i]['folder'] == true ||
          !RegExp(
            r'\.(png|jpe?g|gif|bmp|webp|tiff?)$',
            caseSensitive: false,
          ).hasMatch(items[i]['name'] as String)) {
        continue;
      }
      try {
        final image = await native.invokeMethod<Uint8List>(
          'fileDragThumbnail',
          {'path': preview.files[i].path},
        );
        if (image != null &&
            image.length <= 16 * 1024 &&
            image.length <= budget) {
          items[i]['thumbnail'] = base64Encode(image);
          budget -= image.length;
        }
      } on PlatformException {
        /* use Mac's image-type icon */
      } on MissingPluginException {
        /* use Mac's image-type icon */
      }
    }
    final offer = {'drag': drag, 'items': items};
    // Begin travels on the bounded input-control channel.
    if (utf8.encode(jsonEncode(offer)).length > 40 * 1024) {
      for (final item in items) {
        item.remove('thumbnail');
      }
    }
    if (utf8.encode(jsonEncode(offer)).length > 48 * 1024) {
      throw const FormatException('拖拽文件名称过长');
    }
    return offer;
  }

  void onNativeEvent(String method, Map<String, dynamic> args) {
    if (!_target || !lan.receiving || !lan.connected) return;
    if (method == 'fileDragSessionState') {
      if (!_sessionState(args)) return;
      if (!lan.supportsFileDragState) return;
      unawaited(
        lan
            .sendFileDragControl({'type': 'fileDragState', ...lastSessionState})
            .catchError((Object _) {}),
      );
      return;
    }
    final request = args['request'];
    if (request is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(request)) {
      return;
    }
    if (method == 'fileDragCancel') {
      files.cancel(request);
      return;
    }
    if (method != 'fileDragRequest' || _requests.contains(request)) return;
    final generation = lan.connectionGeneration;
    _requests.add(request);
    unawaited(
      () async {
        String? error;
        try {
          await files.receive(
            drag: args['drag'] as String,
            item: args['item'] as String,
            request: request,
            destination: args['destination'] as String,
          );
        } catch (failure) {
          error = '$failure';
        } finally {
          _requests.remove(request);
        }
        if (!_disposed && generation == lan.connectionGeneration) {
          await native.invokeMethod<void>('fileDragComplete', {
            'request': request,
            'error': error,
          });
        }
      }().catchError((Object _) {}),
    );
  }

  bool _sessionState(Map<String, dynamic> value) {
    final id = value['drag'], phase = value['phase'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !['awaitingDown', 'starting', 'dragging', 'ended'].contains(phase)) {
      return false;
    }
    final rawError = value['error'];
    final error = rawError is String
        ? (rawError.length > 1024 ? rawError.substring(0, 1024) : rawError)
        : null;
    final state = <String, dynamic>{
      'drag': id,
      'phase': phase,
      'unexpected': value['unexpected'] == true,
      'accepted': value['accepted'] == true,
      'error': ?error,
      if ([
        'idle',
        'awaitingDown',
        'starting',
        'dragging',
        'released',
        'cancelling',
        'ended',
      ].contains(value['startupPhase']))
        'startupPhase': value['startupPhase'],
      for (final field in ['elapsedMs', 'sourceEventNumber', 'operation'])
        if (value[field] is int) field: value[field],
      for (final field in ['combinedLeftDown', 'hidLeftDown'])
        if (value[field] is bool) field: value[field],
    };
    if (value['unexpected'] == true) {
      if (_failures.length >= 8 && !_failures.containsKey(id)) {
        _failures.remove(_failures.keys.first);
      }
      _failures[id] ??= Map.of(state);
      for (final entry in state.entries) {
        _failures[id]!.putIfAbsent(entry.key, () => entry.value);
      }
    }
    lastSessionState = _failures[id] ?? state;
    if (lastSessionState['unexpected'] == true) {
      _nativeStatus =
          lastSessionState['error'] as String? ?? 'Mac 文件拖拽提前结束，已停止鼠标拖拽转发';
      _changed();
      return true;
    }
    if (phase == 'awaitingDown' || phase == 'starting') {
      _nativeStatus = phase == 'awaitingDown'
          ? 'Mac 来源窗口等待按下事件'
          : 'Mac 已收到按下，正在启动文件拖拽';
      _changed();
      return true;
    }
    _nativeStatus = phase == 'dragging'
        ? 'Mac 文件拖拽进行中'
        : value['unexpected'] == true
        ? 'Mac 文件拖拽提前结束，已停止鼠标拖拽转发'
        : value['accepted'] == true
        ? '已放置文件，正在复制'
        : '文件拖拽已取消';
    _changed();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    lan.removeListener(_connectionChanged);
    lan.onFileDragControl = null;
    files.removeListener(_changed);
    files.dispose();
    if (_target) {
      unawaited(
        native.invokeMethod<void>('fileDragReset').catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
