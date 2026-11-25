import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/receiver_drag_hold.dart';
import 'package:shared_input/remote/lan_session.dart';

class HoldLan extends LanSession {
  Future<void> Function(Map<String, dynamic>?)? begin;
  final begins = <Map<String, dynamic>?>[];
  @override
  Future<void> beginCapture({
    double? edgeEntryY,
    String edgeEntrySide = 'left',
    Map<String, dynamic>? receiverDragResume,
  }) async {
    begins.add(receiverDragResume);
    await begin?.call(receiverDragResume);
  }

  bool online = true, receiver = false;
  int generation = 1;
  final sent = <Map<String, dynamic>>[];
  @override
  bool get connected => online;
  @override
  bool get receiving => receiver;
  @override
  int get connectionGeneration => generation;
  @override
  Future<void> sendReceiverDragControl(Map<String, dynamic> message) async {
    sent.add(message);
  }

  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('receiver-drag-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final hold = {'token': 'a' * 32, 'button': 0, 'pressId': 17};
  late HoldLan lan;
  late ReceiverDragHold link;
  late List<MethodCall> calls;
  late Map<String, dynamic> physical;
  Completer<Map<String, dynamic>>? pending;
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  Future<void> receive(
    String type, [
    Map<String, dynamic> fields = const {},
  ]) async {
    await lan.onReceiverDragControl!({'type': type, ...hold, ...fields});
    await settle();
  }

  setUp(() {
    calls = [];
    physical = {
      'healthy': true,
      'buttons': 1,
      'leftPress': 17,
      'rightPress': 0,
    };
    pending = null;
    lan = HoldLan()..supportsReceiverDragHold = true;
    link = ReceiverDragHold(lan, channel, supported: true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'receiverDragButtons')
        return pending?.future ?? Future.value(physical);
      return null;
    });
  });
  tearDown(() {
    link.dispose();
    lan.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('same press is leased and can resume without a new down', () async {
    await receive('receiverDragSuspended');
    expect(lan.sent.last, {'type': 'receiverDragLease', ...hold, 'held': true});
    expect(await link.prepareResume(), hold);
    await link.confirmResume(hold);
    expect(lan.sent.last, {'type': 'receiverDragResumed', ...hold});
  });
  test(
    'fast return retries once after the suspension notice beats rejection',
    () async {
      lan.begin = (resume) async {
        if (resume == null) {
          await receive('receiverDragSuspended');
          throw StateError('drag_resume_required');
        }
      };
      expect(await link.beginCapture(allowResume: true), hold);
      expect(lan.begins, [null, hold]);
    },
  );
  test('a failed resumed Begin does not loop indefinitely', () async {
    lan.begin = (_) async {
      await receive('receiverDragSuspended');
      throw StateError('native rejection');
    };
    await expectLater(link.beginCapture(allowResume: true), throwsStateError);
    expect(lan.begins.length, 2);
  });
  test('release or repress cannot resume the original drag', () async {
    await receive('receiverDragSuspended');
    physical['leftPress'] = 18;
    expect(await link.prepareResume(), isNull);
    expect(lan.sent.last['held'], false);
    physical['leftPress'] = 17;
    expect(await link.prepareResume(), isNull);
  });
  test('hook loss and an extra button fail closed', () async {
    physical['healthy'] = false;
    await receive('receiverDragSuspended');
    expect(lan.sent.last['held'], false);
    physical['healthy'] = true;
    physical['buttons'] = 3;
    await receive('receiverDragSuspended');
    expect(lan.sent.last['held'], false);
  });
  test('release is observed while pointer capture is inactive', () async {
    await receive('receiverDragSuspended');
    expect(lan.capturing, false);
    physical['buttons'] = 0;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(lan.sent.last['held'], false);
    expect(await link.prepareResume(), isNull);
  });
  test('old native query cannot renew a different connection', () async {
    pending = Completer<Map<String, dynamic>>();
    await receive('receiverDragSuspended');
    lan.generation++;
    lan.changed();
    pending!.complete(physical);
    await settle();
    expect(lan.sent, isEmpty);
  });
  test(
    'receiver leases match identity and reject reverse-role commands',
    () async {
      lan.receiver = true;
      await link.nativeStopped({'suspended': hold}, lan.generation);
      expect(lan.sent.last['type'], 'receiverDragSuspended');
      await receive(
        'receiverDragSuspended',
      ); // Wrong role must not query Windows.
      await receive('receiverDragLease', {'token': 'b' * 32, 'held': false});
      expect(calls, isEmpty);
      await receive('receiverDragLease', {'held': true});
      expect(calls.single.method, 'receiverDragLease');
      await receive('receiverDragLease', {'held': false});
      expect((calls.last.arguments as Map)['held'], false);
      await link.nativeEnded(hold['token'] as String);
      expect(lan.sent.last['type'], 'receiverDragEnded');
    },
  );
  test('disconnect cancels only the saved receiver token', () async {
    lan.receiver = true;
    await link.nativeStopped({'suspended': hold}, lan.generation);
    lan.online = false;
    lan.generation++;
    lan.changed();
    await settle();
    expect(calls.last.method, 'receiverDragCancel');
    expect(calls.last.arguments, hold);
  });
  test('old stop callback cannot create a hold after reconnect', () async {
    lan.receiver = true;
    await link.nativeStopped({'suspended': hold}, lan.generation - 1);
    expect(lan.sent, isEmpty);
    expect(calls.last.method, 'receiverDragCancel');
  });
  test(
    'resume completion clears controller lease without cancelling Mac drag',
    () async {
      lan.receiver = true;
      await link.nativeStopped({'suspended': hold}, lan.generation);
      link.nativeBegan();
      await settle();
      expect(lan.sent.last, {
        'type': 'receiverDragEnded',
        'token': hold['token'],
      });
      expect(calls, isEmpty);
    },
  );
  test('malformed identities are rejected', () {
    expect(ReceiverDragHold.parse({...hold, 'button': 2}), isNull);
    expect(ReceiverDragHold.parse({...hold, 'pressId': 0}), isNull);
    expect(ReceiverDragHold.parse({...hold, 'token': '../file'}), isNull);
    expect(ReceiverDragHold.parse(null), isNull);
  });
  test(
    'receiver accepts commit after preparation cleared its suspended token',
    () async {
      lan.receiver = true;
      await link.nativeStopped({'suspended': hold}, lan.generation);
      link.nativeBegan();
      await receive('receiverDragResumed');
      expect(calls.last.method, 'receiverDragResumed');
      expect(calls.last.arguments, hold);
    },
  );
}
