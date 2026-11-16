import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'audio_output_panel.dart';
import 'audio_sync_mode.dart';
import 'remote/lan_session.dart';
import 'settings.dart';

/// Only session control crosses Dart. PCM, encryption, UDP and rendering stay
/// on independent native audio workers, away from the keyboard/mouse isolate.
class AudioSync extends ChangeNotifier {
  AudioSync(this.lan, this.channel) {
    lan.addListener(_reconcile);
    lan.onAudioControl = _control;
    _lease = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _heartbeat(),
    );
  }
  final LanSession lan;
  final MethodChannel channel;
  AudioSyncMode _mode = AudioSyncMode.off;
  InputRole _role = InputRole.controller;
  AudioOutputInfo _output = const AudioOutputInfo();
  String status = '不同步';
  bool failed = false, sourceActive = false;
  bool _disposed = false, _ticking = false;
  int _epoch = 0;
  String? _plan, _player, _source;
  Timer? _lease, _startTimeout;

  Future<void> initialize() async {
    try {
      final capabilities = await channel.invokeMapMethod<String, dynamic>(
        'audioCapabilities',
      );
      lan.audioRenderSupported = capabilities?['render'] == true;
      lan.audioCaptureSupported = capabilities?['capture'] == true;
    } on MissingPluginException {
      // Peers built before audio support retain keyboard/mouse sharing.
    } on PlatformException {
      // Audio is optional and must not disable input initialization.
    }
    _reconcile();
  }

  void configure(AudioSyncMode mode, InputRole role, AudioOutputInfo output) {
    _mode = mode;
    _role = role;
    _output = output;
    _reconcile();
  }

  void retry() {
    _plan = null;
    _reconcile();
  }

  void _status(String text, {bool error = false}) {
    if (_disposed || (status == text && failed == error)) return;
    status = text;
    failed = error;
    notifyListeners();
  }

  void _reconcile() {
    if (_disposed) return;
    if (_role == InputRole.receiver) {
      if (!lan.connected && _source != null) {
        final id = _source;
        _source = null;
        sourceActive = false;
        unawaited(_nativeStop('audioCaptureStop', id));
        _status('等待控制端开启音频回传');
      }
      if (_player == null && _plan == 'receiver') return;
    }
    String? blocked;
    if (_role == InputRole.receiver) {
      blocked = 'receiver';
    } else if (_mode == AudioSyncMode.off) {
      blocked = '不同步';
    } else if (_mode == AudioSyncMode.headphones && !_output.headphones) {
      blocked = _output.status == 'ready' && _output.kind == 'unknown'
          ? '设备类型未知，可选择“同步”手动开启'
          : '等待系统默认输出切换为耳机';
    } else if (!lan.connected) {
      blocked = '连接 Mac 后开始音频同步';
    } else if (!lan.supportsAudio || !lan.audioRenderSupported) {
      blocked = '请更新两端程序以支持音频回传';
    } else if (_output.status != 'ready') {
      blocked = '等待可用的系统音频输出设备';
    }
    final plan =
        blocked ?? '${lan.connectionGeneration}:${_output.id}:${_mode.name}';
    if (_plan == plan) return;
    _plan = plan;
    final epoch = ++_epoch;
    final previous = _player;
    _player = null;
    _startTimeout?.cancel();
    if (previous != null) unawaited(_stopPlayer(previous));
    if (blocked != null) {
      _status(blocked == 'receiver' ? '等待控制端开启音频回传' : blocked);
      return;
    }
    unawaited(_startPlayer(epoch));
  }

  Future<void> _startPlayer(int epoch) async {
    final id = randomHex();
    final key = randomHex(32); // Fresh AES-256 key for every start/retry.
    _player = id;
    _status('正在建立音频回传…');
    try {
      final ready = await channel.invokeMapMethod<String, dynamic>(
        'audioPlaybackStart',
        {
          'session': id,
          'key': key,
          'peer': lan.remoteHost,
          'device': _output.id,
        },
      );
      if (_disposed || epoch != _epoch || _player != id) {
        await _nativeStop('audioPlaybackStop', id);
        return;
      }
      final port = ready?['port'];
      if (port is! int || port < 1 || port > 65535) {
        throw StateError('音频播放端口无效');
      }
      await lan.sendAudioControl({
        'type': 'audioStart',
        'session': id,
        'key': key,
        'port': port,
      });
      if (_player != id) return;
      _startTimeout = Timer(const Duration(seconds: 15), () {
        if (_player == id && !status.startsWith('同步中')) {
          unawaited(_failPlayer(id, '音频启动超时，请在 Mac 允许系统音频录制后重试'));
        }
      });
    } catch (error) {
      if (epoch == _epoch && _player == id) {
        await _failPlayer(id, _message(error));
      }
    }
  }

  String _message(Object error) =>
      error is PlatformException ? error.message ?? error.code : '音频回传失败，请重试';
  Future<void> _nativeStop(String method, String? id) async {
    if (id == null) return;
    try {
      await channel.invokeMethod<void>(method, {'session': id});
    } on PlatformException {
      /* Native watchdog also expires the source lease. */
    } on MissingPluginException {
      /* Older native module. */
    }
  }

  Future<void> _stopPlayer(String id) async {
    await _nativeStop('audioPlaybackStop', id);
    if (lan.connected && lan.supportsAudio) {
      try {
        await lan.sendAudioControl({'type': 'audioStop', 'session': id});
      } catch (_) {
        /* Source releases itself when the lease expires. */
      }
    }
  }

  Future<void> _failPlayer(String id, String message) async {
    if (_player != id) return;
    _player = null;
    ++_epoch;
    _startTimeout?.cancel();
    _status(message, error: true);
    await _stopPlayer(id);
  }

  Future<void> _heartbeat() async {
    final id = _player;
    if (_disposed || _ticking || id == null || !lan.connected) return;
    _ticking = true;
    try {
      final state = await channel.invokeMapMethod<String, dynamic>(
        'audioPlaybackStatus',
        {'session': id},
      );
      if (_player != id || _disposed) return;
      if (state?['status'] == 'error') {
        await _failPlayer(id, state?['message'] as String? ?? '音频播放中断');
      } else if (state?['receiving'] == true) {
        _startTimeout?.cancel();
        await lan.sendAudioControl({'type': 'audioLease', 'session': id});
        _status('同步中 · Mac 本机静音');
      }
    } catch (_) {
      if (_player == id) await _failPlayer(id, '音频回传中断，请重试');
    } finally {
      _ticking = false;
    }
  }

  void _control(Map<String, dynamic> message) {
    unawaited(_handleControl(message).catchError((Object _) {}));
  }

  Future<void> _handleControl(Map<String, dynamic> message) async {
    final id = message['session'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) return;
    switch (message['type']) {
      case 'audioStart':
        if (_role != InputRole.receiver || !lan.audioCaptureSupported) return;
        final key = message['key'], port = message['port'];
        if (key is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
            port is! int ||
            port < 1 ||
            port > 65535) {
          return;
        }
        if (_source == id) {
          return; // Never reset a nonce counter with the same key.
        }
        final previous = _source;
        _source = id;
        sourceActive = false;
        await _nativeStop('audioCaptureStop', previous);
        if (_disposed || _source != id || !lan.connected) return;
        try {
          _status('正在请求系统音频…');
          await channel.invokeMethod<void>('audioCaptureStart', {
            'session': id,
            'key': key,
            'port': port,
            'host': lan.remoteHost,
          });
          if (_disposed || _source != id || !lan.connected) {
            await _nativeStop('audioCaptureStop', id);
            return;
          }
          sourceActive = true;
          _status('音频回传中 · 本机静音');
          await lan.sendAudioControl({'type': 'audioStarted', 'session': id});
        } catch (error) {
          if (_source != id) return;
          _source = null;
          sourceActive = false;
          final text = _message(error);
          _status(text, error: true);
          await _nativeStop('audioCaptureStop', id);
          if (lan.connected) {
            await lan.sendAudioControl({
              'type': 'audioError',
              'session': id,
              'message': text,
            });
          }
        }
      case 'audioStop':
        if (_source == id) {
          _source = null;
          sourceActive = false;
          await _nativeStop('audioCaptureStop', id);
          _status('音频回传已停止，本机输出已恢复');
        }
      case 'audioLease':
        if (_source == id) {
          await channel.invokeMethod<void>('audioCaptureHeartbeat', {
            'session': id,
          });
        }
      case 'audioError':
        if (_player == id) {
          final text = message['message'];
          await _failPlayer(
            id,
            text is String && text.length <= 512 ? text : 'Mac 音频采集中断',
          );
        }
      case 'audioStarted':
        if (_player == id) _status('等待 Mac 音频数据…');
    }
  }

  void onNativeEvent(String method, Map<String, dynamic> data) {
    final id = data['session'];
    if (id is! String) return;
    if (method == 'audioPlaybackState' &&
        id == _player &&
        data['status'] == 'error') {
      unawaited(_failPlayer(id, data['message'] as String? ?? '音频播放中断'));
    }
    if (method == 'audioCaptureState' &&
        id == _source &&
        data['status'] == 'error') {
      _source = null;
      sourceActive = false;
      final message = data['message'] as String? ?? '音频回传已停止，本机输出已恢复';
      _status(message, error: true);
      if (lan.connected) {
        unawaited(
          lan
              .sendAudioControl({
                'type': 'audioError',
                'session': id,
                'message': message,
              })
              .catchError((Object _) {}),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    lan.removeListener(_reconcile);
    lan.onAudioControl = null;
    _lease?.cancel();
    _startTimeout?.cancel();
    final player = _player, source = _source;
    _player = _source = null;
    if (player != null) unawaited(_stopPlayer(player));
    unawaited(_nativeStop('audioCaptureStop', source));
    super.dispose();
  }
}
