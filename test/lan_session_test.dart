import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/remote/protocol.dart';

Future<void> eventually(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(until)) {
      fail('Timed out waiting for local network state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  const key = '0123456789abcdef0123456789abcdef';
  late LanSession receiver, controller;
  setUp(() {
    receiver = LanSession();
    controller = LanSession();
  });
  tearDown(() async {
    await controller.close();
    await receiver.close();
    controller.dispose();
    receiver.dispose();
  });
  Future<void> connect() async {
    await receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1');
    await controller.connect(host: '127.0.0.1', port: receiver.port, key: key);
  }

  test(
    'authenticated loopback delivers input, preserves latest motion and releases on stop',
    () async {
      final tracker = MotionTracker();
      final held = <int>{};
      var stopped = 0;
      receiver.onBegin = (id) async {
        tracker.begin(id);
      };
      receiver.onInput = (id, frames) async {
        for (final frame in frames) {
          tracker.accept(MotionFrame.fromJson({...frame, 'capture': id}));
          if (frame['kind'] == 'key') {
            if (frame['down'] == true) {
              held.add(frame['code'] as int);
            } else {
              held.remove(frame['code']);
            }
          }
        }
      };
      receiver.onEnd = () async {
        held.clear();
        tracker.end();
        ++stopped;
      };
      await connect();
      expect(controller.connected, isTrue);
      await controller.beginCapture();
      final event = {
        'kind': 'key',
        'code': 30,
        'extended': false,
        'down': true,
        'repeat': false,
        'epoch': 1,
        'sequence': 1,
        'x': 0.0001,
        'y': -0.0017,
      };
      controller.sendInput({
        'sequence': 1,
        'epoch': 1,
        'x': 0.0001,
        'y': -0.0017,
        'events': [event],
      });
      for (var i = 2; i <= 300; i++) {
        controller.sendInput({
          'sequence': i,
          'epoch': 1,
          'x': i * 0.0001,
          'y': -i * 0.0017,
          'events': [],
        });
      }
      await eventually(() => tracker.sequence == 300 && held.contains(30));
      expect(tracker.x, closeTo(0.03, 1e-12));
      expect(tracker.y, closeTo(-0.51, 1e-12));
      await controller.endCapture();
      await eventually(() => stopped == 1);
      expect(held, isEmpty);
      expect(receiver.capturing, isFalse);
    },
  );

  test(
    'edge sessions negotiate capability, carry placement and return pointer feedback',
    () async {
      Map<String, dynamic>? entry, feedback;
      var polls = 0;
      receiver.onBeginWithOptions = (_, options) async {
        entry = options;
      };
      receiver.onPointerInfo = () async {
        ++polls;
        return {
          'x': 24,
          'y': 500,
          'left': 0,
          'top': 0,
          'width': 1920,
          'height': 1080,
          'sequence': 7,
        };
      };
      controller.onPointerFeedback = (pointer) async {
        feedback = pointer;
      };
      await connect();
      expect(controller.supportsEdge, isTrue);
      await controller.beginCapture(edgeEntryY: 0.5);
      await eventually(() => feedback != null);
      expect(entry, {'edgeEntryY': 0.5});
      expect(feedback!['x'], 24);
      expect(feedback!['sequence'], 7);
      await controller.endCapture();
      await eventually(() => !receiver.capturing);
      final stoppedPolls = polls;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(polls, stoppedPolls);
    },
  );

  test(
    'edge mode rejects receivers without position feedback before starting',
    () async {
      var begins = 0;
      receiver.onBegin = (_) async {
        ++begins;
      };
      await connect();
      expect(controller.supportsEdge, isFalse);
      await expectLater(
        controller.beginCapture(edgeEntryY: 0.5),
        throwsStateError,
      );
      expect(begins, 0);
      expect(controller.capturing, isFalse);
      await controller.beginCapture();
      expect(begins, 1);
    },
  );

  test('UDP motion cannot pass a pending reliable button transition', () async {
    final blocked = Completer<void>(), entered = Completer<void>();
    final applied = <String>[];
    receiver.onBegin = (_) async {};
    receiver.onInput = (_, frames) async {
      if (frames.first['kind'] == 'button') {
        entered.complete();
        await blocked.future;
        applied.add('button');
      } else {
        applied.add('motion:${frames.first['x']}');
      }
    };
    await connect();
    await controller.beginCapture();
    controller.sendInput({
      'sequence': 1,
      'epoch': 1,
      'x': 10.0,
      'y': 20.0,
      'events': [
        {
          'kind': 'button',
          'button': 0,
          'down': true,
          'epoch': 1,
          'sequence': 1,
          'x': 10.0,
          'y': 20.0,
        },
      ],
    });
    await entered.future.timeout(const Duration(seconds: 4));
    controller.sendInput({
      'sequence': 2,
      'epoch': 1,
      'x': 99.0,
      'y': 20.0,
      'events': [],
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(applied, isEmpty);
    blocked.complete();
    await eventually(() => applied.contains('motion:99.0'));
    expect(applied.first, 'button');
  });

  test(
    'wrong pairing key cannot begin a session; listener accepts a later valid peer',
    () async {
      var begins = 0;
      receiver.onBegin = (_) async {
        ++begins;
      };
      await receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1');
      await expectLater(
        controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'b' * 32,
        ),
        throwsA(anything),
      );
      expect(begins, 0);
      expect(receiver.connected, isFalse);
      await controller.connect(
        host: '127.0.0.1',
        port: receiver.port,
        key: key,
      );
      await controller.beginCapture();
      expect(begins, 1);
    },
  );

  test('receiver begin rejection is reported without capturing', () async {
    receiver.onBegin = (_) async {
      throw StateError('permission required');
    };
    await connect();
    await expectLater(controller.beginCapture(), throwsStateError);
    expect(controller.capturing, isFalse);
    expect(receiver.capturing, isFalse);
  });

  test('socket disconnect releases active receiver state', () async {
    var released = false;
    receiver.onBegin = (_) async {};
    receiver.onEnd = () async {
      released = true;
    };
    await connect();
    await controller.beginCapture();
    await controller.close();
    await eventually(() => released);
    expect(receiver.listening, isTrue);
    expect(receiver.capturing, isFalse);
  });

  test(
    'receiver can end capture without dropping the paired connection',
    () async {
      var notified = false;
      controller.onCaptureEnded = () {
        notified = true;
      };
      receiver.onBegin = (_) async {};
      await connect();
      await controller.beginCapture();
      await receiver.endCapture();
      await eventually(() => notified);
      expect(controller.connected, isTrue);
      expect(controller.capturing, isFalse);
    },
  );
}
