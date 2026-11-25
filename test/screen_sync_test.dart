import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/screen_sync.dart';
import 'package:shared_input/settings.dart';

Future<void> eventually(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(until)) fail('Screen policy did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const controllerNative = MethodChannel('test/screen-controller');
  const receiverNative = MethodChannel('test/screen-receiver');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <Map<String, dynamic>>[];
  late LanSession controller, receiver;
  late ScreenSync source, target;
  final lit = <String, dynamic>{
    'displayKnown': true,
    'displayOn': true,
    'locked': false,
    'suspended': false,
    'sessionActive': true,
    'lockSequence': 0,
  };
  var rejectLock = false;

  setUp(() async {
    nativeCalls.clear();
    rejectLock = false;
    messenger.setMockMethodCallHandler(controllerNative, (call) async {
      if (call.method == 'screenCapabilities') {
        return {'controller': true, 'receiver': false};
      }
      if (call.method == 'screenState') return Map.of(lit);
      return null;
    });
    messenger.setMockMethodCallHandler(receiverNative, (call) async {
      if (call.method == 'screenCapabilities') {
        return {'controller': false, 'receiver': true};
      }
      if (call.method == 'screenPolicy') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        nativeCalls.add(args);
        if (rejectLock && args['lock'] == true) {
          throw PlatformException(
            code: 'permission_required',
            message: '需要辅助功能权限',
          );
        }
      }
      return null;
    });
    controller = LanSession();
    receiver = LanSession();
    source = ScreenSync(controller, controllerNative)
      ..configure(true, InputRole.controller);
    target = ScreenSync(receiver, receiverNative)
      ..configure(false, InputRole.receiver);
    await source.initialize();
    await target.initialize();
  });

  Future<void> connect() async {
    await receiver.listen(port: 0, key: 'c' * 32, bindAddress: '127.0.0.1');
    await controller.connect(
      host: '127.0.0.1',
      port: receiver.port,
      key: 'c' * 32,
    );
    await eventually(() => nativeCalls.any((v) => v['keepAwake'] == true));
  }

  tearDown(() async {
    await controller.close();
    await receiver.close();
    source.dispose();
    target.dispose();
    controller.dispose();
    receiver.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(controllerNative, null);
    messenger.setMockMethodCallHandler(receiverNative, null);
  });

  test(
    'awake policy is independent of capture, dim/off and suspend release it',
    () async {
      await connect();
      expect(controller.supportsScreenPolicy, true);
      expect(receiver.supportsScreenPolicy, true);
      expect(controller.capturing, false);
      for (final update in [
        {'displayOn': false},
        {'displayKnown': false},
        {'suspended': true},
        {'sessionActive': false},
      ]) {
        nativeCalls.clear();
        source.onNativeState({...lit, ...update});
        await eventually(() => nativeCalls.isNotEmpty);
        expect(nativeCalls.last, {'keepAwake': false, 'lock': false});
        source.onNativeState(lit);
        await eventually(() => nativeCalls.last['keepAwake'] == true);
      }
    },
  );

  test(
    'each lock releases capture, locks once, and unlock never sends an unlock command',
    () async {
      var ended = false;
      receiver.onBegin = (_) async {};
      receiver.onEndWithReason = (reason) async {
        ended = reason == 'system_lock';
      };
      await connect();
      await controller.beginCapture();
      final locked = {...lit, 'locked': true, 'lockSequence': 1};
      source.onNativeState(locked);
      await eventually(() => nativeCalls.any((v) => v['lock'] == true));
      expect(ended, true);
      expect(receiver.capturing, false);
      expect(nativeCalls.singleWhere((value) => value['lock'] == true), {
        'keepAwake': true,
        'lock': true,
      });
      source.onNativeState(locked);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(nativeCalls.where((v) => v['lock'] == true), hasLength(1));
      nativeCalls.clear();
      source.onNativeState({...lit, 'lockSequence': 1});
      await eventually(() => nativeCalls.isNotEmpty);
      expect(nativeCalls.single, {'keepAwake': true, 'lock': false});
      source.onNativeState({...lit, 'locked': true, 'lockSequence': 2});
      await eventually(() => nativeCalls.any((v) => v['lock'] == true));
    },
  );

  test('disable and connection loss both release keep-awake', () async {
    await connect();
    nativeCalls.clear();
    source.configure(false, InputRole.controller);
    await eventually(() => nativeCalls.isNotEmpty);
    expect(nativeCalls.last, {'keepAwake': false, 'lock': false});
    source.configure(true, InputRole.controller);
    await eventually(() => nativeCalls.last['keepAwake'] == true);
    await controller.close();
    await eventually(() => nativeCalls.last['keepAwake'] == false);
  });

  test(
    'invalid policy is ignored and a receiver cannot send commands to controller',
    () async {
      await connect();
      nativeCalls.clear();
      await controller.sendScreenControl({
        'type': 'screenPolicy',
        'enabled': false,
        'keepAwake': true,
        'locked': true,
        'lockSequence': 1,
      });
      await receiver.sendScreenControl({
        'type': 'screenPolicy',
        'enabled': true,
        'keepAwake': false,
        'locked': true,
        'lockSequence': 1,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(nativeCalls, isEmpty);
      expect(controller.connected, true);
    },
  );

  test(
    'native lock permission error is shown and does not disconnect input',
    () async {
      await connect();
      rejectLock = true;
      source.onNativeState({...lit, 'locked': true, 'lockSequence': 1});
      await eventually(() => source.status == '需要辅助功能权限');
      expect(controller.connected, true);
    },
  );

  test(
    'older peers retain input connection and explain upgrade requirement',
    () async {
      receiver.screenPolicySupported = false;
      await receiver.listen(port: 0, key: 'c' * 32, bindAddress: '127.0.0.1');
      await controller.connect(
        host: '127.0.0.1',
        port: receiver.port,
        key: 'c' * 32,
      );
      expect(controller.supportsScreenPolicy, false);
      expect(source.status, contains('被控端需更新'));
      expect(controller.connected, true);
      expect(nativeCalls, isEmpty);
    },
  );
}
