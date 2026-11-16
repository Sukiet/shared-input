import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings.dart';

enum ControlReturnType {
  edge('边缘切回'),
  shortcut('快捷键'),
  connection('连接中断'),
  protection('安全保护'),
  environment('窗口 / 设备'),
  manual('主动停止'),
  other('其他');

  const ControlReturnType(this.label);
  final String label;

  static ControlReturnType forReason(String reason) => switch (reason) {
    'edge' => edge,
    'shortcut' => shortcut,
    'connection_lost' => connection,
    'pointer_timeout' ||
    'hook_lost' ||
    'heartbeat' ||
    'input_overflow' ||
    'timeout' => protection,
    'focus_lost' || 'window_changed' || 'device_removed' => environment,
    'manual' ||
    'shutdown' ||
    'manual_disconnect' ||
    'role_changed' ||
    'remote_end' => manual,
    _ => other,
  };
}

enum ControlMode {
  background('后台边缘控制'),
  remote('窗口内远程控制'),
  local('本地测试');

  const ControlMode(this.label);
  final String label;
}

class ControlReturnEntry {
  const ControlReturnEntry({
    required this.time,
    required this.reason,
    required this.mode,
    required this.connected,
    required this.durationMs,
    this.nativeReason,
    this.detail,
    this.exitDiagnostics = const {},
  });

  final DateTime time;
  final String reason;
  final String? nativeReason, detail;
  final ControlMode mode;
  final bool connected;
  final int durationMs;
  final Map<String, dynamic> exitDiagnostics;

  static Map<String, dynamic> readDiagnostics(dynamic value) {
    if (value is! Map) return const {};
    final result = <String, dynamic>{};
    final trigger = value['trigger'];
    if (trigger is String && trigger.length <= 64) result['trigger'] = trigger;
    for (final key in const [
      'generation',
      'mouseAgeMs',
      'keyboardAgeMs',
      'pointerAgeMs',
      'heartbeatAgeMs',
      'hookPumpAgeMs',
    ]) {
      final item = value[key];
      if (item is int && item >= -1) result[key] = item;
    }
    return Map.unmodifiable(result);
  }

  String get diagnosticsSummary {
    if (exitDiagnostics.isEmpty) return '';
    final trigger = exitDiagnostics['trigger'];
    final check = switch (trigger) {
      'mouse_hook_stale' => '鼠标拦截检查',
      'keyboard_hook_stale' => '键盘拦截检查',
      'hook_lost' => '拦截状态检查',
      'hook_queue_failed' => '键盘消息投递失败',
      'hook_thread_timeout' => '拦截线程无响应',
      'pointer_timeout' => 'Mac 反馈超时',
      'heartbeat' => '界面心跳超时',
      'shortcut' => '退出快捷键',
      'edge' => '边缘切回',
      _ => trigger ?? '未知',
    };
    final ages = <String>[];
    for (final field in const {
      'mouseAgeMs': '鼠标钩子',
      'keyboardAgeMs': '键盘钩子',
      'hookPumpAgeMs': '拦截线程心跳',
      'pointerAgeMs': 'Mac 反馈',
      'heartbeatAgeMs': '界面心跳',
    }.entries) {
      final age = exitDiagnostics[field.key];
      if (age is int) ages.add('${field.value} ${age < 0 ? '未观察' : '$age ms'}');
    }
    return '检查：$check ($trigger) · 会话 ${exitDiagnostics['generation'] ?? '—'}'
        '${ages.isEmpty ? '' : '\n停止时：${ages.join(' / ')}'}';
  }

  ControlReturnType get type => ControlReturnType.forReason(reason);
  String get title => switch (reason) {
    'edge' => '鼠标从屏幕边缘切回 Windows',
    'shortcut' => '退出快捷键触发',
    'connection_lost' => '远程连接中断，恢复 Windows 输入',
    'pointer_timeout' => 'Mac 指针反馈超时',
    'hook_lost' => '后台输入拦截中断',
    'heartbeat' => '界面心跳超时',
    'input_overflow' => '待发送输入队列溢出',
    'timeout' => '本地测试达到 30 秒上限',
    'focus_lost' => '控制窗口失去焦点',
    'window_changed' => '窗口或显示配置变化',
    'device_removed' => '所选键盘或鼠标断开',
    'remote_end' => '被控端结束控制会话',
    'manual_disconnect' => '手动断开远程连接',
    'role_changed' => '切换控制端 / 被控端角色',
    'shutdown' => '程序关闭，释放输入',
    'manual' => '主动停止控制',
    _ => '控制结束，恢复 Windows 输入',
  };

  String get connectionLabel => connected ? '连接仍保持' : '未连接';
  String get reasonLabel => nativeReason != null && nativeReason != reason
      ? '$reason · 原生上报 $nativeReason'
      : reason;

  Map<String, dynamic> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'reason': reason,
    'nativeReason': nativeReason,
    'detail': detail,
    'mode': mode.name,
    'connected': connected,
    'durationMs': durationMs,
    if (exitDiagnostics.isNotEmpty) 'exitDiagnostics': exitDiagnostics,
  };

  static ControlReturnEntry? fromJson(dynamic value) {
    if (value is! Map) return null;
    final time = value['time'], reason = value['reason'];
    final duration = value['durationMs'];
    if (time is! String ||
        reason is! String ||
        reason.isEmpty ||
        reason.length > 128 ||
        duration is! int ||
        duration < 0 ||
        value['connected'] is! bool) {
      return null;
    }
    final date = DateTime.tryParse(time);
    final modes = ControlMode.values.where((m) => m.name == value['mode']);
    if (date == null || modes.isEmpty) return null;
    return ControlReturnEntry(
      time: date,
      reason: reason,
      mode: modes.first,
      connected: value['connected'] as bool,
      durationMs: duration,
      exitDiagnostics: readDiagnostics(value['exitDiagnostics']),
      nativeReason: value['nativeReason'] is String
          ? (value['nativeReason'] as String).substring(
              0,
              (value['nativeReason'] as String).length.clamp(0, 128),
            )
          : null,
      detail: value['detail'] is String
          ? (value['detail'] as String).substring(
              0,
              (value['detail'] as String).length.clamp(0, 512),
            )
          : null,
    );
  }
}

class PreferencesReturnLogStore implements SettingsStore {
  final _preferences = SharedPreferencesAsync();
  static const _key = 'shared_input.control_returns.v1';
  @override
  Future<String?> read() => _preferences.getString(_key);
  @override
  Future<void> write(String json) => _preferences.setString(_key, json);
}

class ControlReturnHistory extends ChangeNotifier {
  ControlReturnHistory(this.store);
  static const capacity = 300;
  final SettingsStore store;
  final List<ControlReturnEntry> _entries = [];
  List<ControlReturnEntry> get entries => List.unmodifiable(_entries);
  int _revision = 0;
  bool _disposed = false;
  String? _pending;
  Future<void>? _writing;

  Future<void> load() async {
    final revision = _revision;
    final text = await store.read();
    if (_disposed || revision != _revision || text == null) return;
    try {
      final data = jsonDecode(text);
      if (data is! List) return;
      final restored = data.map(ControlReturnEntry.fromJson).nonNulls;
      _entries
        ..clear()
        ..addAll(restored.take(capacity));
      notifyListeners();
    } on FormatException {
      // A damaged history must not prevent emergency controls from starting.
    }
  }

  Future<void> add(ControlReturnEntry entry) {
    ++_revision;
    _entries.insert(0, entry);
    if (_entries.length > capacity) _entries.removeLast();
    notifyListeners();
    return _save();
  }

  Future<void> clear() {
    ++_revision;
    _entries.clear();
    notifyListeners();
    return _save();
  }

  Future<void> _save() {
    _pending = jsonEncode(_entries.map((e) => e.toJson()).toList());
    return _writing ??= _drain().whenComplete(() => _writing = null);
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final next = _pending!;
      _pending = null;
      await store.write(next);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
