import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Opt-in aggregate timings; never records keys, coordinates, or pairing data.
class InputDiagnostics {
  static const enabled = bool.fromEnvironment('INPUT_DIAGNOSTICS');
  final clock = Stopwatch()..start();
  final Map<String, int> _counts = {};
  final Map<String, List<int>> _timings = {};
  final Map<String, int> _last = {};
  Timer? _timer;
  IOSink? _sink;
  bool _polling = false;
  int _ticks = 0, _previousTick = 0, _highestCounter = 0;
  Future<Map<String, dynamic>?> Function()? native;

  int get now => clock.elapsedMicroseconds;
  void count(String name, [int amount = 1]) {
    if (enabled) {
      _counts.update(name, (n) => n + amount, ifAbsent: () => amount);
    }
  }

  void timing(String name, int microseconds) {
    if (!enabled) return;
    final samples = _timings.putIfAbsent(name, () => []);
    // A bounded window even if the event loop or file consumer stalls.
    if (samples.length < 8192) samples.add(microseconds);
  }

  void gap(String name) {
    if (!enabled) return;
    final time = now;
    final previous = _last[name];
    if (previous != null) timing(name, time - previous);
    _last[name] = time;
  }

  void udpCounter(int counter) {
    if (!enabled) return;
    if (_highestCounter > 0 && counter > _highestCounter + 1) {
      count('udpCounterForwardGaps', counter - _highestCounter - 1);
    }
    if (counter <= _highestCounter) count('udpCounterLateOrDuplicate');
    if (counter > _highestCounter) _highestCounter = counter;
  }

  Future<void> start() async {
    if (!enabled) return;
    stop();
    final folder = Directory(
      '${Platform.environment['HOME'] ?? Directory.systemTemp.path}/Library/Logs/SharedInput',
    );
    try {
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/diagnostics-${DateTime.now().millisecondsSinceEpoch}.jsonl',
      );
      final sink = file.openWrite();
      _sink = sink;
      unawaited(sink.done.catchError((Object _) {}));
      _counts.clear();
      _timings.clear();
      _last.clear();
      _highestCounter = _ticks = 0;
      _previousTick = now;
      sink.writeln(
        jsonEncode({
          'type': 'start',
          'at': DateTime.now().toIso8601String(),
          'note':
              'gaps include sender idle; counter gaps include reorder, not proven packet loss; durations in microseconds',
        }),
      );
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final time = now;
        timing(
          'eventLoopLateUs',
          (time - _previousTick - 100000).clamp(0, 1 << 53),
        );
        _previousTick = time;
        if (++_ticks % 10 == 0) unawaited(_write());
      });
    } catch (_) {
      // Diagnostics must never break input delivery.
    }
  }

  Future<void> _write() async {
    if (_polling || _sink == null) return;
    _polling = true;
    final sink = _sink!;
    final summary = <String, dynamic>{};
    for (final entry in _timings.entries) {
      final values = entry.value..sort();
      if (values.isEmpty) continue;
      summary[entry.key] = {
        'n': values.length,
        'p50': values[values.length ~/ 2],
        'p95': values[((values.length - 1) * .95).round()],
        'max': values.last,
      };
    }
    final row = <String, dynamic>{
      'at': DateTime.now().toIso8601String(),
      'counts': Map.of(_counts),
      'timingsUs': summary,
    };
    _counts.clear();
    _timings.clear();
    try {
      final started = now;
      row['native'] = await native?.call().timeout(const Duration(seconds: 2));
      row['nativePollRoundTripUs'] = now - started;
      if (identical(sink, _sink)) sink.writeln(jsonEncode(row));
    } catch (_) {
      if (identical(sink, _sink)) {
        sink.writeln(jsonEncode({...row, 'nativePollFailed': true}));
      }
    } finally {
      _polling = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final sink = _sink;
    _sink = null;
    if (sink != null) unawaited(sink.close().catchError((Object _) {}));
  }
}
