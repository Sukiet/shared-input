import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'clipboard_content.dart';
import 'remote/lan_session.dart';
import 'settings.dart';

/// Coordinates versions on the small control channel; payloads use the bulk
/// isolate. A native revision check also protects copies made during transfer.
class ClipboardSync extends ChangeNotifier {
  ClipboardSync(this.lan, this.native) {
    lan.clipboardSupported = true;
    lan.onClipboardControl = _control;
    lan.clipboard.onPrepared = _prepared;
    lan.clipboard.onPayload = _received;
    lan.addListener(_connection);
    lan.clipboard.addListener(_connection);
  }
  final LanSession lan;
  final MethodChannel native;
  bool enabled = true, _ready = false, _disposed = false;
  bool _peerEnabled = false,
      _running = false,
      _applying = false,
      _draining = false;
  ({ClipboardOffer offer, Uint8List bytes, int epoch})? _pending;
  bool? _stateSent;
  int _session = -1, _epoch = 0, _clock = 0;
  String _actor = '', _error = '';
  String? _revision, _appliedId, _requestedId;
  ClipboardOffer? _winner;
  Timer? _timer;
  Future<void>? _reading;

  String get status {
    if (!enabled) return '已关闭';
    if (!lan.connected) return '连接后双向同步文字和图片';
    if (!lan.supportsClipboard) return '对端需更新以支持剪贴板同步';
    if (_error.isNotEmpty) return _error;
    if (lan.clipboard.error.isNotEmpty) return lan.clipboard.error;
    if (!_peerEnabled) return '对端未开启剪贴板同步';
    if (!lan.clipboard.connected) return '正在连接剪贴板';
    return '文字和图片双向同步';
  }

  void start(bool value) {
    _ready = true;
    enabled = value;
    _connection();
  }

  void setEnabled(bool value) {
    enabled = value;
    _error = '';
    _sendState();
    _refresh();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _connection() {
    if (_disposed) return;
    if (!lan.connected || _session != lan.connectionGeneration) {
      _session = lan.connected ? lan.connectionGeneration : -1;
      _peerEnabled = false;
      _stateSent = null;
      _winner = null;
      _revision = null;
      _appliedId = null;
      _clock = 0;
      _actor = randomHex();
      _error = '';
    }
    _sendState();
    _refresh();
    _notify();
  }

  void _sendState() {
    final state = enabled && _ready && _error.isEmpty;
    if (!lan.connected || !lan.supportsClipboard || _stateSent == state) return;
    _stateSent = state;
    _send({'type': 'clipboardState', 'enabled': state});
  }

  void _send(Map<String, dynamic> value) {
    unawaited(lan.sendClipboardControl(value).catchError((Object _) {}));
  }

  void _refresh() {
    final run =
        _ready &&
        enabled &&
        _error.isEmpty &&
        _peerEnabled &&
        lan.connected &&
        lan.supportsClipboard &&
        lan.clipboard.connected;
    if (run == _running) return;
    _running = run;
    final epoch = ++_epoch;
    _timer?.cancel();
    _timer = null;
    _winner = null;
    _revision = null;
    _appliedId = null;
    _pending = null;
    _requestedId = null;
    lan.clipboard.expect(null);
    unawaited(() async {
      try {
        await native.invokeMethod<void>('clipboardConfigure', {'enabled': run});
        if (_disposed || epoch != _epoch || !run) return;
        _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
          unawaited(_poll());
        });
        await _poll();
      } catch (error) {
        if (epoch == _epoch) _failed(error);
      }
    }());
  }

  void _failed(Object error) {
    if (_disposed) return;
    _error = error is PlatformException
        ? (error.message ?? '剪贴板访问失败，请重新开启同步')
        : '剪贴板同步失败，请重新开启';
    _sendState();
    _refresh();
    _notify();
  }

  void _control(Map<String, dynamic> value) {
    if (_disposed) return;
    try {
      switch (value['type']) {
        case 'clipboardState':
          _peerEnabled = value['enabled'] == true;
          _refresh();
          _notify();
        case 'clipboardOffer':
          if (!_running) return;
          final offer = ClipboardOffer.fromJson(value);
          if (offer.actor == _actor) return;
          _clock = _clock > offer.clock ? _clock : offer.clock;
          if (_winner != null && offer.compareTo(_winner!) <= 0) return;
          _choose(offer);
          unawaited(_poll());
          _requestCurrent();
        case 'clipboardRequest':
          final winner = _winner;
          if (_running &&
              winner != null &&
              winner.actor == _actor &&
              value['id'] == winner.id &&
              winner.kind != 'none') {
            lan.clipboard.send(winner.id);
          }
      }
    } catch (_) {
      _failed(const FormatException('Invalid clipboard metadata'));
    }
  }

  void _choose(ClipboardOffer offer) {
    _winner = offer;
    _requestedId = null;
    lan.clipboard.expect(offer.id);
    // This reaches native code immediately, even if an older image is decoding.
    unawaited(
      native.invokeMethod<void>('clipboardCancel').catchError((Object _) {}),
    );
  }

  Future<void> _poll() {
    if (_disposed || !_running || _applying) return Future.value();
    return _reading ??= _read().whenComplete(() {
      _reading = null;
      _requestCurrent();
    });
  }

  void _requestCurrent() {
    final offer = _winner;
    if (_disposed ||
        !_running ||
        _revision == null ||
        offer == null ||
        offer.actor == _actor ||
        offer.kind == 'none' ||
        _requestedId == offer.id) {
      return;
    }
    _requestedId = offer.id;
    _send({'type': 'clipboardRequest', 'id': offer.id});
  }

  Future<void> _read() async {
    final epoch = _epoch;
    try {
      final value = await native.invokeMapMethod<String, dynamic>(
        'clipboardRead',
        {'after': _revision},
      );
      if (!_running || epoch != _epoch || value == null) return;
      final revision = value['revision'];
      if (revision is! String) return;
      final initial = _revision == null;
      _revision = revision;
      if (value['origin'] != null && value['origin'] == _appliedId) return;
      // The controller seeds a newly established session; the receiver records
      // its initial revision without competing with the controller's snapshot.
      if (initial &&
          (lan.receiving || (_winner != null && _winner!.actor != _actor))) {
        return;
      }
      var kind = value['kind'] as String? ?? 'none';
      Uint8List? data;
      if (kind == 'text' && value['text'] is String) {
        data = Uint8List.fromList(
          utf8.encode((value['text'] as String).replaceAll('\r\n', '\n')),
        );
      } else if (kind == 'png' && value['data'] is Uint8List) {
        data = value['data'] as Uint8List;
      }
      if (data == null || !validClipboardBytes(kind, data)) kind = 'none';
      final offer = ClipboardOffer(
        id: randomHex(),
        actor: _actor,
        clock: ++_clock,
        kind: kind,
      );
      _choose(offer);
      if (kind == 'none') {
        _send(offer.toJson());
      } else {
        lan.clipboard.prepare(offer.id, kind, data!);
      }
    } catch (error) {
      if (epoch == _epoch) _failed(error);
    }
  }

  void _prepared(Map<String, dynamic> value) {
    final current = _winner;
    if (!_running ||
        current == null ||
        current.actor != _actor ||
        current.id != value['id']) {
      return;
    }
    final offer = ClipboardOffer(
      id: current.id,
      actor: _actor,
      clock: current.clock,
      kind: current.kind,
      length: value['length'] as int,
      hash: value['hash'] as String,
    );
    _winner = offer;
    _send(offer.toJson());
  }

  void _received(Map<String, dynamic> metadata, Uint8List bytes) {
    final offer = _winner, epoch = _epoch;
    if (!_running ||
        offer == null ||
        metadata['id'] != offer.id ||
        metadata['kind'] != offer.kind ||
        metadata['hash'] != offer.hash ||
        bytes.length != offer.length ||
        _appliedId == offer.id) {
      return;
    }
    _pending = (offer: offer, bytes: bytes, epoch: epoch);
    if (!_draining) unawaited(_applyPending());
  }

  Future<void> _applyPending() async {
    _draining = true;
    try {
      while (_pending != null) {
        final payload = _pending!;
        _pending = null;
        final offer = payload.offer, epoch = payload.epoch;
        bool current() =>
            _running && epoch == _epoch && _winner?.id == offer.id;
        if (!current()) continue;
        try {
          await _poll();
          if (!current() || _revision == null) continue;
          _applying = true;
          _appliedId = offer.id;
          for (var attempt = 0; attempt < 5 && current(); ++attempt) {
            final result = await native
                .invokeMapMethod<String, dynamic>('clipboardWrite', {
                  'kind': offer.kind,
                  'data': payload.bytes,
                  'origin': offer.id,
                  'expected': _revision,
                });
            // A follow-up poll reads the origin marker. A returned sequence
            // could already belong to another copy and must not be skipped.
            if (!current() || result?['applied'] == true) break;
            _applying = false;
            await _poll();
            _applying = true;
            if (current()) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
        } catch (error) {
          if (epoch == _epoch) _failed(error);
        } finally {
          _applying = false;
        }
        if (_running && epoch == _epoch) await _poll();
      }
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    lan.removeListener(_connection);
    lan.clipboard.removeListener(_connection);
    lan.onClipboardControl = null;
    lan.clipboard.onPrepared = null;
    lan.clipboard.onPayload = null;
    unawaited(
      native
          .invokeMethod<void>('clipboardConfigure', {'enabled': false})
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}
