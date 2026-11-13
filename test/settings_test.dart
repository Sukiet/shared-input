import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/settings.dart';

class SlowStore implements SettingsStore {
  final first = Completer<void>();
  final writes = <String>[];
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String json) async {
    writes.add(json);
    if (writes.length == 1) await first.future;
  }
}

void main() {
  test('all settings restore from a newly created repository', () async {
    final store = MemorySettingsStore();
    final saved = AppSettings()
      ..role = InputRole.receiver
      ..host = '192.168.1.8'
      ..port = 45999
      ..peerKey = 'a' * 32
      ..listenKey = 'b' * 32
      ..keyboardId = 'keyboard-path'
      ..mouseId = 'mouse-path'
      ..shortcut = const ExitShortcut(0x77, shift: true)
      ..sensitivity = 0.0017
      ..step = 0.001
      ..sendHz = 1000
      ..statisticsExpanded = true;
    await SettingsRepository(store).save(saved);
    final restored = await SettingsRepository(store).load();
    expect(restored.toJson(), saved.toJson());
    expect(restored.shortcut!.label, 'Ctrl + Alt + Shift + F8');
    expect(restored.toJson().containsKey('active'), isFalse);
    expect(restored.toJson().containsKey('connected'), isFalse);
  });
  test('corrupt and out-of-range settings use valid defaults', () async {
    final store = MemorySettingsStore()..value = '{bad';
    expect((await SettingsRepository(store).load()).sensitivity, 0.1);
    store.value = jsonEncode({
      'sensitivity': -1,
      'port': 999999,
      'sendHz': 7,
      'shortcut': {'key': 0x7b},
      'step': -1,
      'listenKey': 'short',
    });
    final settings = await SettingsRepository(store).load();
    expect(settings.port, 45831);
    expect(settings.sendHz, 500);
    expect(settings.shortcut, isNull);
    expect(settings.sensitivity, 0.1);
    expect(settings.listenKey.length, 32);
  });
  test('legacy Ctrl-to-Command preference is discarded', () {
    final settings = AppSettings.fromJson({'ctrlToCommand': true});
    expect(settings.toJson().containsKey('ctrlToCommand'), isFalse);
  });
  test(
    'rapid writes coalesce and the latest snapshot is durable when awaited',
    () async {
      final store = SlowStore();
      final repository = SettingsRepository(store);
      final settings = AppSettings()..sensitivity = 0.1;
      final pending = repository.save(settings);
      settings.sensitivity = 0.01;
      repository.save(settings);
      settings.sensitivity = 0.0001;
      repository.save(settings);
      store.first.complete();
      await pending;
      await repository.flush();
      expect(store.writes.length, 2);
      expect(jsonDecode(store.writes.last)['sensitivity'], 0.0001);
    },
  );
}
