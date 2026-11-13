import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/main.dart';
import 'package:shared_input/pointer_preview.dart';
import 'package:shared_input/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shared_input/dry_run');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var devices = <Map<String, dynamic>>[];
  var rejectStart = false;
  var pointer = const Offset(123.4567, 67.8912);
  Completer<Object?>? pendingPointer;

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
    pointer = const Offset(123.4567, 67.8912);
    pendingPointer = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'devices') return devices;
      if (call.method == 'pointer') {
        return pendingPointer?.future ?? [pointer.dx, pointer.dy, true];
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
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SharedInputApp(store: store));
    await tester.pumpAndSettle();
  }

  FilledButton start(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('start-control')));
  PointerPainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint && widget.painter is PointerPainter,
                ),
              )
              .painter!
          as PointerPainter;

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
    'cursor updates on frames without stats or rebuilding its widget',
    (tester) async {
      await open(tester);
      await configure(tester);
      await tester.tap(find.byKey(const Key('start-control')));
      await tester.pump();
      final originalPainter = painter(tester);
      for (var i = 0; i < 4; i++) {
        pointer = Offset(123 + i * 0.0001, 67.8912);
        await tester.pump(const Duration(milliseconds: 16));
        expect(originalPainter.position.value, pointer);
        expect(identical(painter(tester), originalPainter), isTrue);
      }
      await native('stats', {'keys': 4, 'held': 2, 'remainingMs': 29000});
      await tester.pump(const Duration(milliseconds: 16));
      expect(identical(painter(tester), originalPainter), isTrue);
      await native('stopped', {'reason': 'shake', 'held': 0});
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNotNull);
      expect(find.text('已通过晃动鼠标退出。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'slow pointer responses cannot queue requests or move cursor after stop',
    (tester) async {
      await open(tester);
      await configure(tester);
      pendingPointer = Completer<Object?>();
      await tester.tap(find.byKey(const Key('start-control')));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(calls.where((call) => call.method == 'pointer').length, 1);
      await native('stopped', {
        'reason': 'shortcut',
        'x': 80.0001,
        'y': 90.0002,
        'held': 0,
      });
      await tester.pump();
      pendingPointer!.complete([500.0, 200.0, true]);
      await tester.pumpAndSettle();
      expect(painter(tester).position.value, const Offset(80.0001, 90.0002));
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
      expect(start(tester).onPressed, isNotNull);
      devices = [];
      await native('devicesChanged');
      await tester.pumpAndSettle();
      expect(start(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest('compact window scrolls without overflow', (tester) async {
    await open(tester, width: 420);
    expect(tester.takeException(), isNull);
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
