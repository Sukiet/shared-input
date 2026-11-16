import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/audio_output_panel.dart';
import 'package:shared_input/audio_sync.dart';
import 'package:shared_input/audio_sync_mode.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/settings.dart';

class AudioLan extends LanSession {
  bool online = true;
  int generation = 1;
  final sent = <Map<String, dynamic>>[];
  @override
  bool get connected => online;
  @override
  int get connectionGeneration => generation;
  @override
  String get remoteHost => '127.0.0.1';
  @override
  Future<void> sendAudioControl(Map<String, dynamic> message) async {
    sent.add(message);
  }

  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('audio-test');
  const speakers = AudioOutputInfo(
    status: 'ready',
    id: 'speaker',
    kind: 'speakers',
  );
  const headphones = AudioOutputInfo(
    status: 'ready',
    id: 'headset',
    kind: 'headphones',
    headphones: true,
  );
  late AudioLan lan;
  late AudioSync sync;
  late List<MethodCall> calls;
  bool receiving = false;
  Completer<Map<String, dynamic>>? pending;

  setUp(() {
    calls = [];
    receiving = false;
    pending = null;
    lan = AudioLan()..supportsAudio = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'audioCapabilities' => {'render': true, 'capture': true},
            'audioPlaybackStart' =>
              pending == null ? {'port': 12345} : await pending!.future,
            'audioPlaybackStatus' => {
              'status': 'ready',
              'receiving': receiving,
            },
            _ => null,
          };
        });
    sync = AudioSync(lan, channel);
  });
  tearDown(() {
    sync.dispose();
    lan.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('all modes persist, legacy and invalid settings stay off', () {
    for (final mode in AudioSyncMode.values) {
      expect(
        AppSettings.fromJson(
          (AppSettings()..audioSyncMode = mode).toJson(),
        ).audioSyncMode,
        mode,
      );
    }
    expect(AppSettings.fromJson({}).audioSyncMode, AudioSyncMode.off);
    expect(
      AppSettings.fromJson({'audioSyncMode': 'invalid'}).audioSyncMode,
      AudioSyncMode.off,
    );
  });

  test(
    'headphone auto mode follows default device, mouse return does not stop audio',
    () async {
      await sync.initialize();
      sync.configure(AudioSyncMode.headphones, InputRole.controller, speakers);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lan.sent, isEmpty);
      sync.configure(
        AudioSyncMode.headphones,
        InputRole.controller,
        headphones,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final start = lan.sent.single;
      expect(start['type'], 'audioStart');
      expect(start['key'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        calls
            .firstWhere((c) => c.method == 'audioPlaybackStart')
            .arguments['device'],
        'headset',
      );
      receiving = true;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(lan.sent.last['type'], 'audioLease');
      expect(sync.status, contains('同步中'));
      lan.changed(); // Capture begin/end notifications keep the same connection.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lan.sent.where((m) => m['type'] == 'audioStop'), isEmpty);
      sync.configure(AudioSyncMode.headphones, InputRole.controller, speakers);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lan.sent.last, {'type': 'audioStop', 'session': start['session']});
      expect(calls.where((c) => c.method == 'audioPlaybackStart').length, 1);
    },
  );

  test(
    'cancel pending start, fresh key on retry and exact-session stops',
    () async {
      await sync.initialize();
      pending = Completer();
      sync.configure(AudioSyncMode.on, InputRole.controller, speakers);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final first = calls.last.arguments as Map;
      sync.configure(AudioSyncMode.off, InputRole.controller, speakers);
      pending!.complete({'port': 12345});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lan.sent.where((m) => m['type'] == 'audioStart'), isEmpty);
      pending = null;
      sync.configure(AudioSyncMode.on, InputRole.controller, speakers);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final current = lan.sent.last;
      expect(current['type'], 'audioStart');
      expect(current['key'], isNot(first['key']));
      sync.onNativeEvent('audioPlaybackState', {
        'session': first['session'],
        'status': 'error',
      });
      expect(sync.failed, false);
      sync.onNativeEvent('audioPlaybackState', {
        'session': current['session'],
        'status': 'error',
        'message': 'device removed',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sync.failed, true);
      expect(lan.connected, true);
      sync.retry();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lan.sent.last['key'], isNot(current['key']));
    },
  );

  test('old peers and unknown output type never auto mute Mac', () async {
    await sync.initialize();
    lan.supportsAudio = false;
    sync.configure(AudioSyncMode.on, InputRole.controller, speakers);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(sync.status, contains('更新'));
    lan.supportsAudio = true;
    sync.configure(
      AudioSyncMode.headphones,
      InputRole.controller,
      const AudioOutputInfo(status: 'ready', id: 'unknown'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(sync.status, contains('类型未知'));
    expect(lan.sent, isEmpty);
  });

  test(
    'receiver disconnect stops native capture, leases are session scoped',
    () async {
      await sync.initialize();
      sync.configure(AudioSyncMode.off, InputRole.receiver, speakers);
      final id = 'a' * 32;
      lan.onAudioControl!({
        'type': 'audioStart',
        'session': id,
        'key': 'b' * 64,
        'port': 12345,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sync.sourceActive, true);
      lan.onAudioControl!({'type': 'audioLease', 'session': id});
      lan.onAudioControl!({'type': 'audioStop', 'session': 'c' * 32});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.last.method, 'audioCaptureHeartbeat');
      expect(sync.sourceActive, true);
      lan.online = false;
      lan.changed();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.last.method, 'audioCaptureStop');
      expect(sync.sourceActive, false);
    },
  );
}
