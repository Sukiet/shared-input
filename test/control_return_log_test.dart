import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/control_return_log.dart';
import 'package:shared_input/settings.dart';

ControlReturnEntry entry(int index, {String reason = 'edge'}) =>
    ControlReturnEntry(
      time: DateTime.utc(2026, 11, 16, 12, 0, index),
      reason: reason,
      mode: ControlMode.background,
      connected: true,
      durationMs: 1000 + index,
    );

class PausedLogStore extends MemorySettingsStore {
  final started = Completer<void>();
  final resume = Completer<void>();
  bool _first = true;
  @override
  Future<void> write(String json) async {
    if (_first) {
      _first = false;
      started.complete();
      await resume.future;
    }
    await super.write(json);
  }
}

void main() {
  test(
    'exit diagnostics preserve native evidence and discard unrelated payloads',
    () {
      final diagnostics = ControlReturnEntry.readDiagnostics({
        'trigger': 'mouse_hook_stale',
        'generation': 7,
        'mouseAgeMs': 250,
        'keyboardAgeMs': -1,
        'pointerAgeMs': 12,
        'heartbeatAgeMs': 19,
        'unrelated': 'discard this',
      });
      final restored = ControlReturnEntry.fromJson({
        ...entry(0, reason: 'hook_lost').toJson(),
        'exitDiagnostics': diagnostics,
      })!;
      expect(restored.exitDiagnostics.containsKey('unrelated'), isFalse);
      expect(restored.exitDiagnostics['mouseAgeMs'], 250);
      expect(restored.diagnosticsSummary, contains('鼠标拦截检查'));
      expect(restored.diagnosticsSummary, contains('鼠标钩子 250 ms'));
      expect(restored.diagnosticsSummary, contains('键盘钩子 未观察'));
      expect(
        ControlReturnEntry.fromJson(restored.toJson())!.exitDiagnostics,
        diagnostics,
      );
    },
  );
  test(
    'normal edge returns and protection timeouts do not imply connection loss',
    () {
      expect(entry(0).type, ControlReturnType.edge);
      expect(entry(0).connectionLabel, '连接仍保持');
      expect(
        entry(0, reason: 'pointer_timeout').type,
        ControlReturnType.protection,
      );
      expect(
        entry(0, reason: 'connection_lost').type,
        ControlReturnType.connection,
      );
      expect(
        entry(0, reason: 'new_native_reason').type,
        ControlReturnType.other,
      );
    },
  );

  test(
    'history is newest first, bounded and restored without losing raw reasons',
    () async {
      final store = MemorySettingsStore();
      final history = ControlReturnHistory(store);
      for (var i = 0; i <= ControlReturnHistory.capacity; i++) {
        await history.add(entry(i, reason: 'unknown_$i'));
      }
      expect(history.entries.length, ControlReturnHistory.capacity);
      expect(history.entries.first.reason, 'unknown_300');
      expect(history.entries.last.reason, 'unknown_1');
      final restored = ControlReturnHistory(store);
      await restored.load();
      expect(
        restored.entries.map((e) => e.toJson()).toList(),
        history.entries.map((e) => e.toJson()).toList(),
      );
      history.dispose();
      restored.dispose();
    },
  );

  test(
    'clear supersedes an in-flight save and stays cleared after restart',
    () async {
      final store = PausedLogStore();
      final history = ControlReturnHistory(store);
      final add = history.add(entry(0));
      await store.started.future;
      final clear = history.clear();
      expect(history.entries, isEmpty);
      store.resume.complete();
      await Future.wait([add, clear]);
      expect(jsonDecode(store.value!), isEmpty);
      final restored = ControlReturnHistory(store);
      await restored.load();
      expect(restored.entries, isEmpty);
      history.dispose();
      restored.dispose();
    },
  );

  test(
    'damaged history and individual invalid entries do not block initialization',
    () async {
      final store = MemorySettingsStore()..value = '{broken';
      final history = ControlReturnHistory(store);
      await history.load();
      expect(history.entries, isEmpty);
      store.value = jsonEncode([
        null,
        {'reason': 'edge'},
        entry(0).toJson(),
      ]);
      await history.load();
      expect(history.entries.single.reason, 'edge');
      history.dispose();
    },
  );
}
