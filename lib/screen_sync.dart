import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'remote/lan_session.dart';
import 'settings.dart';

/// The authenticated connection owns the policy, independently of mouse capture.
/// Native display assertions expire without leases even if Dart stops running.
class ScreenSync extends ChangeNotifier {
  ScreenSync(this.lan, this.channel) {
    lan.addListener(_connectionChanged);
    lan.onScreenControl = _receive;
  }

  final LanSession lan;
  final MethodChannel channel;
  bool _controller = false, _receiver = false, _enabled = false;
  bool _disposed = false, _following = false;
  InputRole _role = InputRole.controller;
  Map<String, dynamic> _state = {};
  Timer? _lease;
  int _generation = -1, _lastLock = -1;
  Future<void> _nativeWork = Future.value();
  String _error = '';
  String get status {
    if (_error.isNotEmpty) return _error;
    if (!_enabled) return '主控亮屏时保持被控端亮屏；主控锁屏时同步锁屏，不同步解锁';
    if (!_controller) return '当前系统无法读取屏幕和锁屏状态';
    if (!lan.connected) return '连接后生效，不同步解锁';
    if (!lan.supportsScreenPolicy) return '被控端需更新以支持屏幕与锁屏同步';
    if (_state['locked'] == true) return '主控已锁屏，被控端保持锁定';
    if (!_keepAwake) return '主控已熄屏或暂停，被控端使用自身休眠设置';
    return '正在保持被控端亮屏，主控锁屏时同步锁屏';
  }

  bool get _keepAwake =>
      _enabled &&
      _state['displayKnown'] == true &&
      _state['displayOn'] == true &&
      _state['suspended'] != true &&
      _state['sessionActive'] == true;

  Future<void> initialize() async {
    try {
      final caps = await channel.invokeMapMethod<String, dynamic>(
        'screenCapabilities',
      );
      _controller = caps?['controller'] == true;
      _receiver = caps?['receiver'] == true;
      lan.screenPolicySupported = _controller || _receiver;
      if (_controller) {
        _state =
            await channel.invokeMapMethod<String, dynamic>('screenState') ?? {};
      }
    } on MissingPluginException {
      // Old native runners can still share input.
    } on PlatformException catch (error) {
      _error = error.message ?? '无法读取屏幕状态';
    }
    _lease = Timer.periodic(const Duration(seconds: 2), (_) => _send());
    _connectionChanged();
  }

  void configure(bool enabled, InputRole role) {
    _enabled = enabled;
    _role = role;
    _error = '';
    _connectionChanged();
  }

  void onNativeState(Map<String, dynamic> state) {
    _state = Map.of(state);
    _send(); // Snapshot every lock transition, even if an unlock follows quickly.
    _changed();
  }

  void _connectionChanged() {
    if (_disposed) return;
    if (_generation != lan.connectionGeneration) {
      _generation = lan.connectionGeneration;
      _lastLock = -1;
      _error = '';
    }
    if (_following &&
        (!lan.connected || !lan.receiving || _role != InputRole.receiver)) {
      _following = false;
      _queueRelease();
    }
    _send();
    _changed();
  }

  void _send() {
    if (_disposed ||
        !_controller ||
        _role != InputRole.controller ||
        lan.receiving ||
        !lan.connected ||
        !lan.supportsScreenPolicy) {
      return;
    }
    final generation = lan.connectionGeneration;
    unawaited(
      lan
          .sendScreenControl({
            'type': 'screenPolicy',
            'enabled': _enabled,
            'keepAwake': _keepAwake,
            'locked': _enabled && _state['locked'] == true,
            'lockSequence': _state['lockSequence'] as int? ?? 0,
          })
          .catchError((Object _) {
            if (!_disposed && generation == lan.connectionGeneration) {
              _error = '屏幕策略发送失败，等待连接恢复';
              _changed();
            }
          }),
    );
  }

  Future<void> _receive(Map<String, dynamic> message) async {
    if (_disposed) return;
    if (message['type'] == 'screenPolicyStatus') {
      if (lan.receiving || _role != InputRole.controller) return;
      _error = message['error'] is String ? (message['error'] as String) : '';
      _changed();
      return;
    }
    if (!_receiver || !lan.receiving || _role != InputRole.receiver) return;
    final enabled = message['enabled'], awake = message['keepAwake'];
    final locked = message['locked'], sequence = message['lockSequence'];
    if (enabled is! bool ||
        awake is! bool ||
        locked is! bool ||
        sequence is! int ||
        sequence < 0 ||
        sequence > 0xffffffff ||
        (!enabled && (awake || locked))) {
      return;
    }
    final generation = lan.connectionGeneration;
    final lock = enabled && locked && _lastLock != sequence;
    _following = enabled;
    _nativeWork = _nativeWork
        .then((_) async {
          if (_disposed ||
              generation != lan.connectionGeneration ||
              !lan.connected) {
            return;
          }
          String error = '';
          try {
            if (lock) await lan.endCapture(reason: 'system_lock');
            if (_disposed ||
                generation != lan.connectionGeneration ||
                !lan.connected) {
              return;
            }
            await channel.invokeMethod<void>('screenPolicy', {
              'keepAwake': enabled && awake,
              'lock': lock,
            });
            if (lock) _lastLock = sequence;
          } on PlatformException catch (failure) {
            error = failure.message ?? '被控端无法应用屏幕策略';
          } on MissingPluginException {
            error = '被控端需更新以支持屏幕与锁屏同步';
          }
          if (!_disposed &&
              generation == lan.connectionGeneration &&
              lan.connected) {
            await lan.sendScreenControl({
              'type': 'screenPolicyStatus',
              'error': error,
            });
          }
        })
        .catchError((Object _) {});
    await _nativeWork;
  }

  void _queueRelease() {
    _nativeWork = _nativeWork
        .then((_) async {
          await channel.invokeMethod<void>('screenPolicy', {
            'keepAwake': false,
            'lock': false,
          });
        })
        .catchError((Object _) {});
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lease?.cancel();
    lan.removeListener(_connectionChanged);
    lan.onScreenControl = null;
    if (_receiver) _queueRelease();
    super.dispose();
  }
}
