import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
  test(
    'file transport preparation lets both motion axes arrive before drag activation',
    () async {
      final receiver = LanSession()
        ..fileDragSupported = true
        ..fileDragTarget = true
        ..fileDragActivationSupported = true;
      final controller = LanSession()
        ..fileDragSupported = true
        ..fileDragSource = true
        ..fileDragActivationSupported = true;
      var prepared = false, appKitActive = false;
      final motions = <Map<String, dynamic>>[];
      receiver.onPointerInfo = () async => {
        'width': 1000.0,
        'height': 800.0,
        'x': 24.0,
        'y': 300.0,
        'left': 0.0,
        'top': 0.0,
        'sequence': 0,
      };
      receiver.onBeginWithOptions = (_, options) async {
        prepared = options['fileDrag'] != null;
        if (options['fileDrag'] != null) expect(options['deferFileDrag'], true);
      };
      receiver.onFileDragControl = (message) async {
        expect(message['type'], 'fileDragActivate');
        appKitActive = true;
      };
      receiver.onInput = (_, frames) async {
        motions.addAll(frames);
      };
      try {
        await receiver.listen(port: 0, key: 'b' * 32, bindAddress: '127.0.0.1');
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'b' * 32,
        );
        await controller
            .beginCapture(
              edgeEntryY: 0.5,
              fileDrag: {
                'drag': 'c' * 32,
                'items': [
                  {
                    'id': 'd' * 32,
                    'name': 'sample.txt',
                    'folder': false,
                    'size': 10,
                  },
                ],
              },
            )
            .timeout(const Duration(seconds: 1));
        expect(prepared, true);
        expect(appKitActive, false);
        expect(controller.capturing, true);
        controller.sendInput({
          'sequence': 1,
          'epoch': 0,
          'x': 37.25,
          'y': -12.5,
        });
        await eventually(() => motions.isNotEmpty);
        expect(motions.last['x'], 37.25);
        expect(motions.last['y'], -12.5);
        expect(appKitActive, false);
        await controller.activateFileDrag();
        await eventually(() => appKitActive);
        // Stale activation must not affect a later capture or survive stop.
        await controller.endCapture();
        await eventually(() => !receiver.capturing);
        appKitActive = false;
        await controller.sendFileDragControl({
          'type': 'fileDragActivate',
          'capture': '0' * 32,
        });
        await controller.beginCapture();
        expect(appKitActive, false);
        expect(receiver.capturing, true);
      } finally {
        await controller.close();
        await receiver.close();
        controller.dispose();
        receiver.dispose();
      }
    },
  );
  test('file drag negotiates source/target roles and accompanies edge begin', () async {
    final receiver = LanSession()..fileDragSupported = true..fileDragTarget = true;
    final controller = LanSession()..fileDragSupported = true..fileDragSource = true;
    Map<String, dynamic>? received;
    receiver.onPointerInfo = () async => {'width': 1000.0, 'height': 800.0,
      'x': 300.0, 'y': 300.0, 'left': 0.0, 'top': 0.0, 'sequence': 0};
    receiver.onBeginWithOptions = (_, options) async { received = options; };
    final offer = {'drag': 'f' * 32, 'items': [{'id': 'e' * 32,
      'name': 'image.png', 'folder': false, 'size': 1234}]};
    try {
      await receiver.listen(port: 0, key: 'a' * 32, bindAddress: '127.0.0.1');
      await controller.connect(host: '127.0.0.1', port: receiver.port, key: 'a' * 32);
      expect(controller.supportsFileDrag, true);
      expect(controller.supportsFileDragActivation, false);
      expect(receiver.supportsFileDrag, true);
      await controller.beginCapture(edgeEntryY: 0.5, fileDrag: offer);
      expect(received?['fileDrag'], offer);
      expect(received!.containsKey('deferFileDrag'), false);
      expect(controller.capturing, true);
    } finally {
      await controller.close(); await receiver.close();
      controller.dispose(); receiver.dispose();
    }
  });
  test('receiver drag leases survive capture end and carry explicit resume identity', () async {
    final receiver = LanSession()..receiverDragHoldSupported = true;
    final controller = LanSession()..receiverDragHoldSupported = true;
    final begins = <Map<String, dynamic>>[];
    final leases = <Map<String, dynamic>>[], notices = <Map<String, dynamic>>[];
    receiver.onBeginWithOptions = (_, options) async { begins.add(options); };
    receiver.onReceiverDragControl = (value) async { leases.add(value); };
    controller.onReceiverDragControl = (value) async { notices.add(value); };
    receiver.onPointerInfo = () async => {
      'x': 0.0, 'y': 200.0, 'left': 0.0, 'top': 0.0,
      'width': 1000.0, 'height': 800.0, 'sequence': 1,
    };
    try {
      await receiver.listen(port: 0, key: 'e' * 32, bindAddress: '127.0.0.1');
      await controller.connect(host: '127.0.0.1', port: receiver.port, key: 'e' * 32);
      expect(controller.supportsReceiverDragHold && receiver.supportsReceiverDragHold, true);
      await controller.beginCapture(edgeEntryY: 0.5);
      expect(begins.single['receiverDragHold'], true);
      await controller.endCapture(reason: 'edge');
      await eventually(() => !receiver.capturing);
      final hold = {'token': 'a' * 32, 'button': 0, 'pressId': 17};
      await receiver.sendReceiverDragControl({'type': 'receiverDragSuspended', ...hold});
      await eventually(() => notices.isNotEmpty);
      await controller.sendReceiverDragControl({'type': 'receiverDragLease', ...hold, 'held': true});
      await eventually(() => leases.isNotEmpty);
      expect(receiver.capturing, false);
      expect(leases.single['held'], true);
      await controller.beginCapture(edgeEntryY: 0.5, receiverDragResume: hold);
      expect(begins.last['receiverDragResume'], hold);
      await controller.sendReceiverDragControl({'type': 'receiverDragResumed', ...hold});
      await eventually(() => leases.length == 2);
      expect(leases.last['type'], 'receiverDragResumed');
    } finally {
      await controller.close(); await receiver.close();
      controller.dispose(); receiver.dispose();
    }
  });
  test('old peer does not receive receiver drag hold messages', () async {
    final receiver = LanSession(), controller = LanSession()..receiverDragHoldSupported = true;
    var received = false;
    receiver.onReceiverDragControl = (_) async { received = true; };
    try {
      await receiver.listen(port: 0, key: 'f' * 32, bindAddress: '127.0.0.1');
      await controller.connect(host: '127.0.0.1', port: receiver.port, key: 'f' * 32);
      expect(controller.supportsReceiverDragHold, false);
      await controller.sendReceiverDragControl({'type': 'receiverDragLease', 'held': true});
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(received, false);
      expect(receiver.connected && controller.connected, true);
    } finally {
      await controller.close(); await receiver.close();
      controller.dispose(); receiver.dispose();
    }
  });
  test('audio capabilities and controls work independently of mouse capture', () async {
    final receiver = LanSession()..audioCaptureSupported = true;
    final controller = LanSession()..audioRenderSupported = true;
    final messages = <Map<String, dynamic>>[];
    receiver.onAudioControl = messages.add;
    try {
      await receiver.listen(port: 0, key: 'd' * 32, bindAddress: '127.0.0.1');
      await controller.connect(host: '127.0.0.1', port: receiver.port, key: 'd' * 32);
      expect(controller.supportsAudio, true);
      expect(receiver.supportsAudio, true);
      expect(controller.capturing, false);
      await controller.sendAudioControl({'type': 'audioStart', 'session': 'e' * 32});
      await eventually(() => messages.isNotEmpty);
      expect(messages.single['type'], 'audioStart');
      expect(controller.connected, true);
    } finally {
      await controller.close(); await receiver.close();
      controller.dispose(); receiver.dispose();
    }
  });
  test(
    'predicted pointer feedback keeps liveness but cannot authorize an edge return',
    () async {
      final receiver = LanSession(), controller = LanSession();
      var predicted = true;
      final feedback = <Map<String, dynamic>>[];
      receiver.onBegin = (_) async {};
      receiver.onPointerInfo = () async => {
        'x': 0.0,
        'y': 200.0,
        'left': 0.0,
        'top': 0.0,
        'width': 1000.0,
        'height': 800.0,
        'sequence': 10,
        'predicted': predicted,
      };
      controller.onPointerFeedback = (value) async {
        feedback.add(value);
      };
      try {
        await receiver.listen(port: 0, key: 'b' * 32, bindAddress: '127.0.0.1');
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'b' * 32,
        );
        await controller.beginCapture(edgeEntryY: 0.5);
        await eventually(() => feedback.isNotEmpty);
        expect(feedback.last['sequence'], -1);
        predicted = false;
        await eventually(() => feedback.last['sequence'] == 10);
      } finally {
        await controller.close();
        await receiver.close();
        controller.dispose();
        receiver.dispose();
      }
    },
  );
  test(
    'prediction peers deliver newer idle status with unchanged motion sequence',
    () async {
      final receiver = LanSession(), controller = LanSession();
      final frames = <Map<String, dynamic>>[];
      receiver.onBegin = (_) async {};
      receiver.onInput = (_, batch) async {
        frames.addAll(batch);
      };
      try {
        await receiver.listen(port: 0, key: 'a' * 32, bindAddress: '127.0.0.1');
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'a' * 32,
        );
        expect(receiver.supportsPrediction, true);
        expect(controller.supportsPrediction, true);
        await controller.beginCapture();
        controller.sendInput({
          'sequence': 1,
          'epoch': 0,
          'x': 10.0,
          'y': 0.0,
          'sampleTimeUs': 10000,
          'moving': true,
        });
        await eventually(() => frames.any((f) => f['sampleTimeUs'] == 10000));
        controller.sendInput({
          'sequence': 1,
          'epoch': 0,
          'x': 10.0,
          'y': 0.0,
          'sampleTimeUs': 26000,
          'moving': false,
        });
        await eventually(() => frames.any((f) => f['sampleTimeUs'] == 26000));
        expect(frames.last['moving'], false);
        expect(frames.last['sequence'], 1);
      } finally {
        await controller.close();
        await receiver.close();
        controller.dispose();
        receiver.dispose();
      }
    },
  );
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
    'scroll speed travels with wheel input without changing signed raw deltas',
    () async {
      final delivered = <Map<String, dynamic>>[];
      receiver.onInput = (_, frames) async {
        delivered.addAll(frames.where((frame) => frame['kind'] != 'motion'));
      };
      await connect();
      await controller.beginCapture();
      var sequence = 0;
      Future<void> send(Map<String, dynamic> event) async {
        ++sequence;
        controller.sendInput({
          'sequence': sequence,
          'epoch': sequence,
          'x': 0.0,
          'y': 0.0,
          'events': [
            {
              ...event,
              'sequence': sequence,
              'epoch': sequence,
              'x': 0.0,
              'y': 0.0,
            },
          ],
        });
        await eventually(() => delivered.length == sequence);
      }

      controller.scrollSpeed = 20;
      await send({'kind': 'wheel', 'delta': -32768, 'horizontal': false});
      expect(delivered.last['delta'], -32768);
      expect(delivered.last['scrollSpeed'], 20);
      controller.scrollSpeed = 0.01;
      await send({'kind': 'wheel', 'delta': 30, 'horizontal': true});
      expect(delivered.last['delta'], 30);
      expect(delivered.last['scrollSpeed'], 0.01);
      expect(delivered.last['horizontal'], isTrue);
      await send({'kind': 'key', 'code': 30, 'down': true, 'extended': false});
      expect(delivered.last.containsKey('scrollSpeed'), isFalse);
    },
  );

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
      expect(controller.supportsLayout, isTrue);
      expect(controller.remoteDisplay, {'width': 1920.0, 'height': 1080.0});
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
      for (final side in ['right', 'top', 'bottom']) {
        await controller.beginCapture(edgeEntryY: 0.25, edgeEntrySide: side);
        expect(entry, {'edgeEntryY': 0.25, 'edgeEntrySide': side});
        await controller.endCapture();
        await eventually(() => !receiver.capturing);
      }
      await controller.close();
      expect(controller.remoteDisplay, isNull);
      expect(controller.supportsLayout, isFalse);
    },
  );

  test(
    'legacy edge receivers reject unsupported entry sides before capture',
    () async {
      var begins = 0;
      receiver.onBegin = (_) async {
        ++begins;
      };
      receiver.onPointerInfo = () async => {'width': 1920, 'height': 1080};
      await connect();
      expect(controller.supportsEdge, isTrue);
      expect(controller.supportsLayout, isFalse);
      await expectLater(
        controller.beginCapture(edgeEntryY: 0.5, edgeEntrySide: 'right'),
        throwsStateError,
      );
      expect(begins, 0);
      expect(controller.capturing, isFalse);
      await controller.beginCapture(edgeEntryY: 0.5);
      expect(begins, 1);
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
    await expectLater(controller.beginCapture(), throwsA(isA<RemoteCaptureException>().having(
      (error) => error.message, 'message', 'permission required')));
    expect(controller.capturing, isFalse);
    expect(receiver.capturing, isFalse);
  });

  test('native startup rejection displays its message without nested exception prefixes', () async {
    receiver.onBegin = (_) async {
      throw PlatformException(code: 'file_drag_failed', message: 'Mac 来源窗口未收到按下事件');
    };
    await connect();
    await expectLater(controller.beginCapture(), throwsA(isA<RemoteCaptureException>().having(
      (error) => error.toString(), 'message', 'Mac 来源窗口未收到按下事件')));
    expect(controller.capturing, false);
    expect(controller.connected, true);
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
