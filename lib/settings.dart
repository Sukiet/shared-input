import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'sensitivity.dart';
import 'scroll_speed.dart';
import 'display_layout.dart';

enum InputRole { controller, receiver }

String randomHex([int bytes = 16]) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class ExitShortcut {
  const ExitShortcut(this.key, {this.shift = false});
  final int key;
  final bool shift;
  bool get isValid =>
      (key >= 0x41 && key <= 0x5a) || (key >= 0x75 && key <= 0x7a);
  String get label =>
      'Ctrl + Alt + ${shift ? 'Shift + ' : ''}${key >= 0x70 ? 'F${key - 0x70 + 1}' : String.fromCharCode(key)}';
  Map<String, dynamic> toJson() => {'key': key, 'shift': shift};
  static ExitShortcut? fromJson(dynamic json) {
    if (json is! Map || json['key'] is! int) return null;
    final shortcut = ExitShortcut(
      json['key'] as int,
      shift: json['shift'] == true,
    );
    return shortcut.isValid ? shortcut : null;
  }
}

class AppSettings {
  InputRole role = InputRole.controller;
  String host = '';
  int port = 45831;
  String peerKey = '';
  String listenKey = randomHex();
  String? keyboardId, mouseId;
  ExitShortcut? shortcut;
  double sensitivity = Sensitivity.defaultValue;
  double scrollSpeed = ScrollSpeed.defaultValue;
  double step = 0.0001;
  int sendHz = 500;
  bool smoothingEnabled = true;
  int smoothingDurationMs = 12;
  int smoothingIntervalMs = 4;
  int smoothingLeewayUs = 500;
  bool statisticsExpanded = false;
  bool edgeSwitchEnabled = false;
  DisplayLayout displayLayout = const DisplayLayout();

  Map<String, dynamic> get smoothingOptions => {
    'enabled': smoothingEnabled,
    'durationMs': smoothingDurationMs,
    'intervalMs': smoothingIntervalMs,
    'leewayUs': smoothingLeewayUs,
  };

  Map<String, dynamic> toJson() => {
    'version': 1,
    'role': role.name,
    'host': host,
    'port': port,
    'peerKey': peerKey,
    'listenKey': listenKey,
    'keyboardId': keyboardId,
    'mouseId': mouseId,
    'shortcut': shortcut?.toJson(),
    'sensitivity': sensitivity,
    'scrollSpeed': scrollSpeed,
    'step': step,
    'sendHz': sendHz,
    'smoothingEnabled': smoothingEnabled,
    'smoothingDurationMs': smoothingDurationMs,
    'smoothingIntervalMs': smoothingIntervalMs,
    'smoothingLeewayUs': smoothingLeewayUs,
    'statisticsExpanded': statisticsExpanded,
    'edgeSwitchEnabled': edgeSwitchEnabled,
    'displayLayout': displayLayout.toJson(),
  };

  static AppSettings fromJson(Map<String, dynamic> json) {
    final result = AppSettings();
    result.role = json['role'] == 'receiver'
        ? InputRole.receiver
        : InputRole.controller;
    if (json['host'] is String) result.host = json['host'] as String;
    if (json['port'] is int &&
        (json['port'] as int) > 0 &&
        (json['port'] as int) <= 65535) {
      result.port = json['port'] as int;
    }
    if (json['peerKey'] is String) result.peerKey = json['peerKey'] as String;
    if (json['listenKey'] is String &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch(json['listenKey'] as String)) {
      result.listenKey = json['listenKey'] as String;
    }
    result.keyboardId = json['keyboardId'] is String
        ? json['keyboardId'] as String
        : null;
    result.mouseId = json['mouseId'] is String
        ? json['mouseId'] as String
        : null;
    result.shortcut = ExitShortcut.fromJson(json['shortcut']);
    final sensitivity = Sensitivity.parse('${json['sensitivity']}');
    if (sensitivity != null) result.sensitivity = sensitivity;
    result.scrollSpeed =
        ScrollSpeed.parse('${json['scrollSpeed']}') ?? ScrollSpeed.defaultValue;
    if ([0.0001, 0.001, 0.01, 0.1].contains(json['step'])) {
      result.step = (json['step'] as num).toDouble();
    }
    if ([125, 250, 500, 1000].contains(json['sendHz'])) {
      result.sendHz = json['sendHz'] as int;
    }
    result.statisticsExpanded = json['statisticsExpanded'] == true;
    result.edgeSwitchEnabled = json['edgeSwitchEnabled'] == true;
    result.displayLayout = DisplayLayout.fromJson(json['displayLayout']);
    if (json['smoothingEnabled'] is bool) {
      result.smoothingEnabled = json['smoothingEnabled'] as bool;
    }
    int validInt(String key, int min, int max, int fallback) {
      final value = json[key];
      return value is int && value >= min && value <= max ? value : fallback;
    }

    result.smoothingDurationMs = validInt('smoothingDurationMs', 1, 100, 12);
    result.smoothingIntervalMs = validInt('smoothingIntervalMs', 1, 16, 4);
    result.smoothingLeewayUs = validInt('smoothingLeewayUs', 0, 2000, 500);
    return result;
  }
}

abstract interface class SettingsStore {
  Future<String?> read();
  Future<void> write(String json);
}

class PreferencesSettingsStore implements SettingsStore {
  final _preferences = SharedPreferencesAsync();
  static const _key = 'shared_input.settings.v1';
  @override
  Future<String?> read() => _preferences.getString(_key);
  @override
  Future<void> write(String json) => _preferences.setString(_key, json);
}

class MemorySettingsStore implements SettingsStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String json) async {
    value = json;
  }
}

class SettingsRepository {
  SettingsRepository(this.store);
  final SettingsStore store;
  bool restored = false;
  String? _pending;
  Future<void>? _writing;

  Future<AppSettings> load() async {
    final value = await store.read();
    if (value == null) return AppSettings();
    try {
      final settings = AppSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
      restored = true;
      return settings;
    } on FormatException {
      return AppSettings();
    } on TypeError {
      return AppSettings();
    }
  }

  // Coalesce rapid slider changes, with one write in flight and a final latest
  // snapshot. Await save/flush before initiating a connection or input capture.
  Future<void> save(AppSettings settings) {
    _pending = jsonEncode(settings.toJson());
    return _writing ??= _drain().whenComplete(() {
      _writing = null;
    });
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final next = _pending!;
      _pending = null;
      await store.write(next);
    }
  }

  Future<void> flush() => _writing ?? Future.value();
}
