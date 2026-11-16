import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/main.dart';
import 'package:shared_input/pointer_preview.dart';
import 'package:shared_input/control_return_log.dart';
import 'package:shared_input/control_return_log_panel.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/settings.dart';
import 'package:shared_input/scroll_speed.dart';
import 'package:shared_input/audio_sync_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shared_input/dry_run');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var devices = <Map<String, dynamic>>[];
  var rejectStart = false;
  String? stopDuringStart;
  Completer<Object?>? pendingAudioOutput;

  void windowsTest(String description, WidgetTesterCallback callback) {
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  Future<void> native(
    String method, [
    Map<String, dynamic> data = const {},
  ]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, data)),
      (_) {},
    );
  }

  setUp(() {
    calls.clear();
    devices = [
      {
        'id': 'keyboard-1',
        'name': 'Test keyboard',
        'type': 'keyboard',
        'usb': true,
      },
      {'id': 'mouse-1', 'name': 'Test mouse', 'type': 'mouse', 'usb': true},
    ];
    rejectStart = false;
    stopDuringStart = null;
    pendingAudioOutput = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'devices') return devices;
      if (call.method == 'audioOutput') {
        return pendingAudioOutput?.future ?? {
          'status': 'ready', 'name': 'Speakers (Test Audio)', 'id': 'render-test',
          'automatic': true, 'revision': 1,
        };
      }
      if (call.method == 'edgeState') {
        return {'atEdge': true, 'entryY': 0.25, 'ready': true};
      }
      if (call.method == 'pointer') {
        return [123.4567, 67.8912, true];
      }
      if (call.method == 'start' && stopDuringStart != null) {
        await native('stopped', {'reason': stopDuringStart});
      }
      if (call.method == 'start' && rejectStart) {
        throw PlatformException(
          code: 'keys_held',
          message: '请松开所有键盘按键，再点击开始控制。',
        );
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> open(
    WidgetTester tester, {
    double width = 1100,
    SettingsStore? store,
    SettingsStore? returnLogStore,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SharedInputApp(store: store, returnLogStore: returnLogStore));
    await tester.pumpAndSettle();
  }

  FilledButton start(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('start-control')));
  ControlReturnHistory history(WidgetTester tester) => tester
      .widget<ControlReturnLogPanel>(find.byType(ControlReturnLogPanel)).history;

  Future<void> selectDevices(WidgetTester tester) async {
    await native('identified', {'type': 'keyboard', 'id': 'keyboard-1'});
    await native('identified', {'type': 'mouse', 'id': 'mouse-1'});
    await tester.pumpAndSettle();
  }

  Future<void> configure(WidgetTester tester) async {
    await selectDevices(tester);
    await tester.tap(find.text('设置退出快捷键'));
    await tester.pumpAndSettle();
    await native('shortcut', {
      'label': 'Ctrl + Alt + F8',
      'key': 0x77,
      'shift': false,
    });
    await tester.pumpAndSettle();
  }

  windowsTest(
    'current default audio output is between clipboard and return logs and updates live',
    (tester) async {
      await open(tester);
      expect(find.text('Speakers (Test Audio)'), findsOneWidget);
      final clipboardY = tester
          .getTopLeft(find.byKey(const Key('clipboard-sync')))
          .dy;
      final audioY = tester
          .getTopLeft(find.byKey(const Key('audio-output-panel')))
          .dy;
      final logsY = tester.getTopLeft(find.text('断联日志')).dy;
      expect(audioY, greaterThan(clipboardY));
      expect(audioY, lessThan(logsY));
      await native('audioOutputChanged', {
        'status': 'ready',
        'name': 'USB Headphones',
        'id': 'render-usb',
        'automatic': true,
        'revision': 2,
      });
      await tester.pumpAndSettle();
      expect(find.text('USB Headphones'), findsOneWidget);
      await native('audioOutputChanged', {
        'status': 'none',
        'revision': 3,
        'automatic': true,
      });
      await tester.pumpAndSettle();
      expect(find.text('未检测到音频输出设备'), findsOneWidget);
      await native('audioOutputChanged', {
        'status': 'error',
        'error': '0x80004005',
        'revision': 4,
      });
      await tester.pumpAndSettle();
      expect(find.text('无法读取音频输出设备'), findsOneWidget);
      expect(find.textContaining('0x80004005'), findsOneWidget);
      final previousReads = calls
          .where((c) => c.method == 'audioOutput')
          .length;
      await tester.tap(find.byKey(const Key('refresh-audio-output')));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'audioOutput').length,
        previousReads + 1,
      );
      expect(
        find.text('Speakers (Test Audio)'),
        findsNothing,
      ); // older cached revision is ignored
      await tester.tap(find.text('被控端'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-output-panel')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest('late audio read cannot overwrite a newer device notification', (
    tester,
  ) async {
    pendingAudioOutput = Completer<Object?>();
    await open(tester);
    expect(find.text('正在识别输出设备…'), findsOneWidget);
    await native('audioOutputChanged', {
      'status': 'ready',
      'name': 'Bluetooth Headphones',
      'id': 'render-bluetooth',
      'automatic': true,
      'revision': 5,
    });
    await tester.pumpAndSettle();
    pendingAudioOutput!.complete({
      'status': 'ready',
      'name': 'Old speakers',
      'revision': 1,
    });
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth Headphones'), findsOneWidget);
    expect(find.text('Old speakers'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await native('audioOutputChanged', {'status': 'none', 'revision': 6});
    expect(tester.takeException(), isNull);
  });

  windowsTest('audio mode selector persists through role switch and restart', (tester) async {
    final store = MemorySettingsStore();
    await open(tester, store: store);
    final selector = find.byKey(const Key('audio-sync-mode'));
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('耳机插入时自动同步').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(store.value!)['audioSyncMode'], 'headphones');
    final bufferSlider = find.byKey(const Key('audio-buffer-slider'));
    await tester.ensureVisible(bufferSlider);
    expect(tester.widget<Slider>(bufferSlider).value, 40);
    expect(tester.widget<Slider>(bufferSlider).divisions, 190);
    await tester.drag(bufferSlider, const Offset(60, 0));
    await tester.pumpAndSettle();
    final selectedBuffer = tester.widget<Slider>(bufferSlider).value.round();
    expect(selectedBuffer, isNot(40));
    expect(jsonDecode(store.value!)['audioBufferMs'], selectedBuffer);
    await tester.ensureVisible(find.text('被控端'));
    await tester.tap(find.text('被控端'));
    await tester.pumpAndSettle();
    expect(selector, findsNothing);
    await tester.tap(find.text('控制端'));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<AudioSyncMode>>(selector).initialValue, AudioSyncMode.headphones);
    expect(tester.widget<Slider>(bufferSlider).value, selectedBuffer);
    await tester.pumpWidget(const SizedBox());
    await open(tester, store: store);
    expect(tester.widget<DropdownButtonFormField<AudioSyncMode>>(selector).initialValue, AudioSyncMode.headphones);
    expect(tester.widget<Slider>(bufferSlider).value, selectedBuffer);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'prediction mode excludes interpolation and saves live parameters',
    (tester) async {
      final store = MemorySettingsStore()
        ..value = jsonEncode(
          (AppSettings()..role = InputRole.receiver).toJson(),
        );
      await open(tester, width: 600, store: store);
      Map<dynamic, dynamic> applied() =>
          calls
                  .lastWhere((c) => c.method == 'receiverConfigureSmoothing')
                  .arguments
              as Map;
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('pointer-mode-interpolation')),
          )
          .onChanged!('prediction');
      await tester.pumpAndSettle();
      expect(applied()['mode'], 'prediction');
      expect(applied()['enabled'], false);
      expect(find.byKey(const Key('smoothing-duration')), findsNothing);
      tester
          .widget<Slider>(find.byKey(const Key('prediction-horizon')))
          .onChanged!(80);
      await tester.pumpAndSettle();
      expect((applied()['prediction'] as Map)['horizonMs'], 80);
      expect((applied()['prediction'] as Map)['outputSmoothing'], true);
      tester
          .widget<Slider>(find.byKey(const Key('prediction-output-duration')))
          .onChanged!(16);
      await tester.pumpAndSettle();
      expect((applied()['prediction'] as Map)['outputDurationMs'], 16);
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('prediction-output-smoothing')),
          )
          .onChanged!(false);
      await tester.pumpAndSettle();
      expect((applied()['prediction'] as Map)['outputSmoothing'], false);
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('prediction-output-duration')))
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, width: 600, store: store);
      expect(applied()['mode'], 'prediction');
      expect((applied()['prediction'] as Map)['horizonMs'], 80);
      expect((applied()['prediction'] as Map)['outputSmoothing'], false);
      expect((applied()['prediction'] as Map)['outputDurationMs'], 16);
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('pointer-mode-prediction')),
          )
          .onChanged!('direct');
      await tester.pumpAndSettle();
      expect(applied()['enabled'], false);
      expect(applied().containsKey('mode'), false);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('Mac receiver smoothing applies live, persists and resets', (
    tester,
  ) async {
    final settings = AppSettings()
      ..role = InputRole.receiver
      ..smoothingDurationMs = 25
      ..smoothingIntervalMs = 8
      ..smoothingLeewayUs = 1000;
    final store = MemorySettingsStore()..value = jsonEncode(settings.toJson());
    await open(tester, width: 600, store: store);
    Map<dynamic, dynamic> applied() =>
        calls
                .lastWhere((c) => c.method == 'receiverConfigureSmoothing')
                .arguments
            as Map;
    expect(applied()['durationMs'], 25);
    expect(applied()['intervalMs'], 8);
    expect(applied()['leewayUs'], 1000);
    expect(find.text('鼠标平滑设置'), findsOneWidget);
    for (final entry in {
      'smoothing-duration': 40.0,
      'smoothing-interval': 2.0,
      'smoothing-leeway': 200.0,
    }.entries) {
      tester.widget<Slider>(find.byKey(Key(entry.key))).onChanged!(entry.value);
      await tester.pumpAndSettle();
    }
    expect(applied(), {
      'enabled': true,
      'durationMs': 40,
      'intervalMs': 2,
      'leewayUs': 200,
    });
    await tester.tap(find.byKey(const Key('smoothing-enabled')));
    await tester.pumpAndSettle();
    expect(applied()['enabled'], false);
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('smoothing-duration')))
          .onChanged,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, width: 600, store: store);
    expect(applied(), {
      'enabled': false,
      'durationMs': 40,
      'intervalMs': 2,
      'leewayUs': 200,
    });
    await tester.tap(find.byKey(const Key('reset-smoothing')));
    await tester.pumpAndSettle();
    expect(applied(), {
      'enabled': true,
      'durationMs': 12,
      'intervalMs': 4,
      'leewayUs': 500,
    });
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  windowsTest(
    'devices and a recorded exit are required; configuration never starts capture',
    (tester) async {
      await open(tester);
      expect(start(tester).onPressed, isNull);
      await selectDevices(tester);
      expect(start(tester).onPressed, isNull);
      await tester.tap(find.text('设置退出快捷键'));
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNull);
      await native('shortcut', {
        'label': 'Ctrl + Alt + F8',
        'key': 0x77,
        'shift': false,
      });
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNotNull);
      expect(calls.any((call) => call.method == 'start'), isFalse);
      expect(find.textContaining('DRY RUN'), findsNothing);
      expect(find.textContaining('先把退出做可靠'), findsNothing);
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'gain can be entered and stepped at 0.0001 precision; native receives it',
    (tester) async {
      await open(tester);
      await configure(tester);
      await tester.enterText(find.byKey(const Key('sensitivity')), '0.0001');
      await tester.pump();
      await tester.tap(find.byKey(const Key('increase-sensitivity')));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('sensitivity')),
      );
      expect(field.controller!.text, '0.0002');
      await tester.tap(find.byKey(const Key('decrease-sensitivity')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('decrease-sensitivity')));
      await tester.pump();
      expect(field.controller!.text, '0.0001');
      await tester.tap(find.byKey(const Key('start-control')));
      await tester.pump();
      final args =
          calls.singleWhere((call) => call.method == 'start').arguments as Map;
      expect(args['speed'], 0.0001);
      await native('stopped', {'reason': 'shortcut', 'held': 0});
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'scroll speed slider and exact input persist independently of pointer gain',
    (tester) async {
      final saved = AppSettings()
        ..keyboardId = 'keyboard-1'
        ..mouseId = 'mouse-1'
        ..shortcut = const ExitShortcut(0x77)
        ..sensitivity = 0.0017;
      final store = MemorySettingsStore()..value = jsonEncode(saved.toJson());
      await open(tester, store: store);
      TextField field() =>
          tester.widget<TextField>(find.byKey(const Key('scroll-speed')));
      expect(field().controller!.text, '3.00');
      tester
          .widget<Slider>(find.byKey(const Key('scroll-speed-slider')))
          .onChanged!(ScrollSpeed.toSlider(12.34));
      await tester.pumpAndSettle();
      expect(field().controller!.text, '12.34');
      expect(jsonDecode(store.value!)['scrollSpeed'], 12.34);
      expect(jsonDecode(store.value!)['sensitivity'], 0.0017);
      await tester.enterText(find.byKey(const Key('scroll-speed')), '0.01');
      await tester.pumpAndSettle();
      expect(jsonDecode(store.value!)['scrollSpeed'], 0.01);
      await tester.enterText(find.byKey(const Key('scroll-speed')), '0');
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNull);
      tester
          .widget<Slider>(find.byKey(const Key('scroll-speed-slider')))
          .onChanged!(1);
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNotNull);
      expect(jsonDecode(store.value!)['scrollSpeed'], 20.0);
      await tester.pumpWidget(const SizedBox());
      await open(tester, store: store);
      expect(field().controller!.text, '20.00');
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('scroll-speed-slider')))
            .value,
        1,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest('invalid gain disables start until corrected', (tester) async {
    await open(tester);
    await configure(tester);
    for (final value in ['0', 'NaN', '0.00001']) {
      await tester.enterText(find.byKey(const Key('sensitivity')), value);
      await tester.pump();
      expect(start(tester).onPressed, isNull);
    }
    await tester.enterText(find.byKey(const Key('sensitivity')), '0.0017');
    await tester.pump();
    expect(start(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest(
    'return logs replace preview, deduplicate, filter, clear and restore',
    (tester) async {
      final logStore = MemorySettingsStore();
      await open(tester, returnLogStore: logStore);
      await configure(tester);
      expect(find.byType(PointerPreview), findsNothing);
      expect(find.text('断联日志'), findsOneWidget);
      expect(find.text('暂无返回记录'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('clear-return-logs')))
            .onPressed,
        isNull,
      );
      await native('stopped', {'reason': 'shortcut'});
      expect(history(tester).entries, isEmpty);
      for (final reason in ['shortcut', 'input_overflow', 'future_exit']) {
        await tester.tap(find.byKey(const Key('start-control')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        await native('stopped', {'reason': reason});
        await native('stopped', {'reason': reason});
        await tester.pumpAndSettle();
      }
      expect(history(tester).entries.length, 3);
      expect(history(tester).entries.first.type, ControlReturnType.other);
      expect(history(tester).entries.first.connected, isFalse);
      expect(history(tester).entries.first.mode, ControlMode.local);
      expect(calls.where((c) => c.method == 'pointer'), isEmpty);
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('return-log-filter')),
          )
          .onChanged!('protection');
      await tester.pumpAndSettle();
      expect(find.text('待发送输入队列溢出'), findsOneWidget);
      expect(find.text('退出快捷键触发'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await open(tester, returnLogStore: logStore);
      expect(history(tester).entries.length, 3);
      await tester.tap(find.byKey(const Key('clear-return-logs')));
      await tester.pumpAndSettle();
      expect(history(tester).entries, isEmpty);
      expect(jsonDecode(logStore.value!), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await open(tester, returnLogStore: logStore);
      expect(history(tester).entries, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'native exit before the start reply is recorded without reactivating',
    (tester) async {
      await open(tester);
      await configure(tester);
      stopDuringStart = 'heartbeat';
      await tester.tap(find.byKey(const Key('start-control')));
      await tester.pumpAndSettle();
      expect(history(tester).entries.single.reason, 'heartbeat');
      expect(start(tester).onPressed, isNotNull);
      expect(find.text('界面心跳超时'), findsOneWidget);
      expect(find.text('控制中'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'native rejection remains disarmed and device removal disables start',
    (tester) async {
      await open(tester);
      await configure(tester);
      rejectStart = true;
      await tester.tap(find.byKey(const Key('start-control')));
      await tester.pumpAndSettle();
      expect(find.text('请松开所有键盘按键，再点击开始控制。'), findsOneWidget);
      expect(history(tester).entries, isEmpty);
      expect(start(tester).onPressed, isNotNull);
      devices = [];
      await native('devicesChanged');
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest('display arrangement drags and persists sizes', (tester) async {
    final store = MemorySettingsStore();
    await open(tester, store: store);
    await tester.tap(find.byKey(const Key('display-layout-settings')));
    await tester.pumpAndSettle();
    final local = tester.getRect(find.byKey(const Key('controller-screen')));
    final remote = tester.getRect(find.byKey(const Key('remote-screen')));
    expect(local.width, greaterThan(remote.width));
    await tester.drag(
      find.byKey(const Key('remote-screen')),
      Offset(local.left - remote.right - 50, 0),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Mac 在左侧'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('remote-inches')), '14.2');
    await tester.tap(find.byKey(const Key('save-display-layout')));
    await tester.pumpAndSettle();
    final layout = jsonDecode(store.value!)['displayLayout'] as Map;
    expect(layout['side'], 'left');
    expect(layout['remoteInches'], 14.2);
    await tester.pumpWidget(const SizedBox());
    await open(tester, width: 420, store: store);
    await tester.tap(find.byKey(const Key('display-layout-settings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mac 在左侧'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest('clipboard toggle persists across role changes and restart', (
    tester,
  ) async {
    final store = MemorySettingsStore();
    await open(tester, store: store);
    final toggle = find.byKey(const Key('clipboard-sync'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(
      find.descendant(of: toggle, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(jsonDecode(store.value!)['clipboardEnabled'], isFalse);
    await tester.ensureVisible(find.text('被控端'));
    await tester.tap(find.text('被控端'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.pumpWidget(const SizedBox());
    await open(tester, store: store);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest('compact window scrolls without overflow', (tester) async {
    await open(tester, width: 420);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest(
    'edge switching retains shortcut exit and edge return',
    (tester) async {
      const key = '0123456789abcdef0123456789abcdef';
      final receiver = LanSession();
      Map<String, dynamic>? options;
      var ended = 0;
      receiver.onBeginWithOptions = (_, entry) async {
        options = entry;
      };
      receiver.onEnd = () async {
        ++ended;
      };
      receiver.onPointerInfo = () async => {
        'x': 24,
        'y': 270,
        'left': 0,
        'top': 0,
        'width': 1920,
        'height': 1080,
        'sequence': 0,
      };
      addTearDown(() async {
        await receiver.close();
        receiver.dispose();
      });
      await tester.runAsync(
        () => receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1'),
      );
      final saved = AppSettings()
        ..edgeSwitchEnabled = true
        ..shortcut = const ExitShortcut(0x77)
        ..host = '127.0.0.1'
        ..port = receiver.port
        ..peerKey = key;
      final store = MemorySettingsStore()..value = jsonEncode(saved.toJson());
      await open(tester, store: store);
      expect(start(tester).onPressed, isNotNull);
      expect(
        calls.any(
          (call) =>
              call.method == 'configureEdge' &&
              (call.arguments as Map)['enabled'] == true,
        ),
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      var starts = 0;
      for (final reason in ['shortcut', 'edge', 'pointer_timeout']) {
        ++starts;
        await tester.runAsync(() async {
          await native('edgeEnter', {'entryY': 0.25});
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (calls.where((call) => call.method == 'start').length <
              starts) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Edge did not start background capture');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pump();
        final args =
            calls.lastWhere((call) => call.method == 'start').arguments as Map;
        expect(args['background'], isTrue);
        expect(args['remote'], isTrue);
        expect(args['edgeTriggered'], isTrue);
        expect(options, {'edgeEntryY': 0.25});
        await tester.runAsync(() async {
          await native('stopped', {'reason': reason});
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (ended < starts) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Emergency exit did not end receiver capture');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
        expect(start(tester).onPressed, isNotNull);
        expect(jsonDecode(store.value!)['edgeSwitchEnabled'], isTrue);
        expect(history(tester).entries.length, starts);
        expect(history(tester).entries.first.reason, reason);
        expect(history(tester).entries.first.connected, isTrue);
        expect(history(tester).entries.first.mode, ControlMode.background);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final remoteEnd in [true, false]) {
    windowsTest(
      remoteEnd
          ? 'remote end is distinct from a lost connection in return logs'
          : 'lost LAN connection records its cause once after native recovery',
      (tester) async {
        const key = '0123456789abcdef0123456789abcdef';
        final receiver = LanSession();
        receiver.onPointerInfo = () async => {
          'x': 200,
          'y': 300,
          'left': 0,
          'top': 0,
          'width': 1920,
          'height': 1080,
          'sequence': 0,
        };
        addTearDown(() async {
          await receiver.close();
          receiver.dispose();
        });
        await tester.runAsync(
          () => receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1'),
        );
        final saved = AppSettings()
          ..edgeSwitchEnabled = true
          ..shortcut = const ExitShortcut(0x77)
          ..host = '127.0.0.1'
          ..port = receiver.port
          ..peerKey = key;
        await open(
          tester,
          store: MemorySettingsStore()..value = jsonEncode(saved.toJson()),
        );
        Future<void> waitForCall(String method) async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!calls.any((c) => c.method == method)) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Missing native $method');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        await tester.runAsync(() async {
          await native('edgeEnter');
          await waitForCall('start');
        });
        await tester.pump();
        await tester.runAsync(() async {
          if (remoteEnd) {
            await receiver.endCapture();
          } else {
            await receiver.close();
          }
          await waitForCall('stop');
          await native('stopped', {'reason': 'manual'});
          await native('stopped', {'reason': 'manual'});
        });
        await tester.pumpAndSettle();
        final log = history(tester).entries.single;
        expect(log.reason, remoteEnd ? 'remote_end' : 'connection_lost');
        expect(log.nativeReason, 'manual');
        expect(log.connected, remoteEnd);
        expect(log.mode, ControlMode.background);
        if (!remoteEnd) expect(log.detail, '连接已断开');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  windowsTest('space connects then starts remotely on release and can resume', (
    tester,
  ) async {
    const key = '0123456789abcdef0123456789abcdef';
    final receiver = LanSession();
    var begins = 0;
    receiver.onBegin = (_) async => ++begins;
    addTearDown(() async {
      await receiver.close();
      receiver.dispose();
    });
    await tester.runAsync(
      () => receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1'),
    );
    final saved = AppSettings()
      ..keyboardId = 'keyboard-1'
      ..mouseId = 'mouse-1'
      ..shortcut = const ExitShortcut(0x77)
      ..host = '127.0.0.1'
      ..port = receiver.port
      ..peerKey = key;
    await open(
      tester,
      store: MemorySettingsStore()..value = jsonEncode(saved.toJson()),
    );
    Future<void> releaseAndWait(int starts) async {
      await tester.runAsync(() async {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (calls.where((call) => call.method == 'start').length < starts) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Space did not start remote capture');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pump();
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(receiver.connected, isFalse);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    await releaseAndWait(1);
    final arguments =
        calls.singleWhere((call) => call.method == 'start').arguments as Map;
    expect(arguments['remote'], isTrue);
    expect(begins, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(calls.where((call) => call.method == 'start').length, 1);
    await tester.runAsync(() => native('stopped', {'reason': 'shortcut'}));
    await tester.pumpAndSettle();

    // A focused connection button must not consume Space and disconnect.
    final buttonFocus = FocusManager.instance.rootScope.descendants.firstWhere(
      (node) =>
          node.canRequestFocus &&
          node.context?.findAncestorWidgetOfExactType<FilledButton>()?.key ==
              const Key('connection-action'),
    );
    buttonFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await releaseAndWait(2);
    expect(begins, 2);
    await tester.runAsync(() => native('stopped', {'reason': 'shortcut'}));
    await tester.pumpAndSettle();

    // Losing the window during receiver authorization cancels automatic start,
    // even if focus returns before the authorization finishes.
    final authorization = Completer<void>();
    receiver.onBegin = (_) async {
      ++begins;
      await authorization.future;
    };
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.runAsync(() async {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (begins < 3) {
        if (DateTime.now().isAfter(deadline)) fail('No receiver authorization');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() async {
      authorization.complete();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (receiver.capturing) {
        if (DateTime.now().isAfter(deadline)) fail('Capture was not cancelled');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'start').length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest('space respects setup, text editing and connection failures', (
    tester,
  ) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    await configure(tester);
    for (final key in [
      'remote-host',
      'peer-key',
      'remote-port',
      'sensitivity',
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入被控端 IP'), findsNothing);
      expect(calls.where((call) => call.method == 'start'), isEmpty);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入被控端 IP'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入被控端 IP'), findsOneWidget);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    await tester.tap(find.text('被控端'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('开始接收'), findsOneWidget);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest(
    'private fields reveal only by eye and hide on blur or app exit',
    (tester) async {
      final saved = AppSettings()
        ..host = '192.168.1.9'
        ..peerKey = 'c' * 32;
      final store = MemorySettingsStore()..value = jsonEncode(saved.toJson());
      await open(tester, store: store);
      TextField field(String key) =>
          tester.widget<TextField>(find.byKey(Key(key)));
      expect(field('remote-host').obscureText, isTrue);
      expect(field('peer-key').obscureText, isTrue);

      await tester.tap(find.byKey(const Key('remote-host')));
      await tester.pumpAndSettle();
      expect(field('remote-host').obscureText, isTrue);
      await tester.tap(find.byTooltip('显示被控端 IP'));
      await tester.pumpAndSettle();
      expect(field('remote-host').obscureText, isFalse);
      expect(field('remote-host').focusNode!.hasFocus, isTrue);
      await tester.tap(find.byTooltip('隐藏被控端 IP'));
      await tester.pumpAndSettle();
      expect(field('remote-host').obscureText, isTrue);
      await tester.tap(find.byTooltip('显示被控端 IP'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remote-port')));
      await tester.pumpAndSettle();
      expect(field('remote-host').obscureText, isTrue);

      await tester.tap(find.byTooltip('显示连接码'));
      await tester.pumpAndSettle();
      expect(field('peer-key').obscureText, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(field('peer-key').obscureText, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(field('peer-key').obscureText, isTrue);
      expect(jsonDecode(store.value!)['peerKey'], saved.peerKey);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'receiver code keeps copy and remasks after focus or role change',
    (tester) async {
      final saved = AppSettings()..role = InputRole.receiver;
      await open(
        tester,
        width: 420,
        store: MemorySettingsStore()..value = jsonEncode(saved.toJson()),
      );
      TextField code() =>
          tester.widget<TextField>(find.byKey(const Key('listen-key')));
      expect(code().readOnly, isTrue);
      expect(code().obscureText, isTrue);
      expect(find.byTooltip('复制连接码'), findsOneWidget);
      await tester.tap(find.byTooltip('显示连接码'));
      await tester.pumpAndSettle();
      expect(code().obscureText, isFalse);
      await tester.tap(find.byKey(const Key('remote-port')));
      await tester.pumpAndSettle();
      expect(code().obscureText, isTrue);
      await tester.tap(find.byTooltip('显示连接码'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('控制端'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('被控端'));
      await tester.pumpAndSettle();
      expect(code().obscureText, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'settings restore native shortcut and role survives a restart without listening',
    (tester) async {
      final saved = AppSettings()
        ..keyboardId = 'keyboard-1'
        ..mouseId = 'mouse-1'
        ..shortcut = const ExitShortcut(0x77, shift: true)
        ..sensitivity = 0.0017
        ..step = 0.001
        ..sendHz = 1000
        ..statisticsExpanded = true
        ..host = '192.168.1.9'
        ..peerKey = 'c' * 32;
      final store = MemorySettingsStore()..value = jsonEncode(saved.toJson());
      await open(tester, store: store);
      expect(
        calls.any(
          (call) =>
              call.method == 'restoreShortcut' &&
              (call.arguments as Map)['key'] == 0x77,
        ),
        isTrue,
      );
      expect(find.text('Ctrl + Alt + Shift + F8'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sensitivity')))
            .controller!
            .text,
        '0.0017',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('remote-host')))
            .controller!
            .text,
        '192.168.1.9',
      );
      expect(start(tester).onPressed, isNotNull);
      expect(find.text('按住 0'), findsOneWidget);
      await tester.tap(find.byKey(const Key('increase-sensitivity')));
      await tester.pumpAndSettle();
      expect(jsonDecode(store.value!)['sensitivity'], 0.0027);
      await tester.tap(find.text('被控端'));
      await tester.pumpAndSettle();
      expect(jsonDecode(store.value!)['role'], 'receiver');
      await tester.pumpWidget(const SizedBox());
      await open(tester, store: store);
      expect(find.byKey(const Key('listen-key')), findsOneWidget);
      expect(find.text('开始接收'), findsOneWidget);
      expect(find.text('未连接'), findsOneWidget);
      expect(find.byKey(const Key('start-control')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'temporarily absent devices keep their persisted identity and restore on arrival',
    (tester) async {
      final saved = AppSettings()
        ..keyboardId = 'keyboard-1'
        ..mouseId = 'mouse-1'
        ..shortcut = const ExitShortcut(0x77);
      final keyboard = devices.removeAt(0);
      final store = MemorySettingsStore()..value = jsonEncode(saved.toJson());
      await open(tester, store: store);
      expect(start(tester).onPressed, isNull);
      expect(jsonDecode(store.value!)['keyboardId'], 'keyboard-1');
      devices.add(keyboard);
      await native('devicesChanged');
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
