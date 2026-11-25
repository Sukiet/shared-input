import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/edge_drag_preview.dart';
import 'package:shared_input/file_drag_sync.dart';
import 'package:shared_input/remote/lan_session.dart';

Future<void> eventually(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(until)) {
      fail('File drag handshake did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceNative = MethodChannel('file-drag-test/source');
  const targetNative = MethodChannel('file-drag-test/target');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LanSession source, target;
  late FileDragSync sender, receiver;
  late Directory workspace;
  final targetCalls = <MethodCall>[];
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'shared-input-file-link-',
    );
    targetCalls.clear();
    messenger.setMockMethodCallHandler(
      sourceNative,
      (call) async => call.method == 'fileDragCapabilities'
          ? {'source': true, 'target': false}
          : null,
    );
    messenger.setMockMethodCallHandler(targetNative, (call) async {
      targetCalls.add(call);
      return call.method == 'fileDragCapabilities'
          ? {'source': false, 'target': true, 'deferred': true}
          : null;
    });
    source = LanSession();
    target = LanSession();
    sender = FileDragSync(source, sourceNative);
    receiver = FileDragSync(target, targetNative);
    await sender.initialize();
    await receiver.initialize();
    await target.listen(port: 0, key: 'a' * 32, bindAddress: '127.0.0.1');
    await source.connect(host: '127.0.0.1', port: target.port, key: 'a' * 32);
    await eventually(() => sender.files.connected && receiver.files.connected);
  });
  tearDown(() async {
    await source.close();
    await target.close();
    sender.dispose();
    receiver.dispose();
    source.dispose();
    target.dispose();
    await sender.files.close();
    await receiver.files.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    messenger.setMockMethodCallHandler(sourceNative, null);
    messenger.setMockMethodCallHandler(targetNative, null);
    await workspace.delete(recursive: true);
  });
  Future<EdgeDragPreview> preview({
    int metadataPress = 17,
    bool promised = false,
  }) async {
    final file = await File(
      '${workspace.path}/sample.txt',
    ).writeAsString('from Windows');
    return EdgeDragPreview(
      enabled: true,
      gestureActive: true,
      sourcePress: 17,
      metadataPress: metadataPress,
      dragFlow: 1,
      files: [DragPreviewFile('sample.txt', file.path, promised)],
    );
  }

  test(
    'file activation dispatch does not wait for native AppKit and failure keeps capture',
    () async {
      final blocked = Completer<void>();
      messenger.setMockMethodCallHandler(targetNative, (call) async {
        targetCalls.add(call);
        if (call.method == 'receiverFileDragActivate') await blocked.future;
        return null;
      });
      await source.beginCapture();
      await source.activateFileDrag();
      await eventually(
        () => targetCalls.any(
          (call) => call.method == 'receiverFileDragActivate',
        ),
      );
      // The independent file task must not block Stop/Begin in the reader.
      await source.endCapture().timeout(const Duration(seconds: 1));
      await eventually(() => !target.capturing);
      await source.beginCapture().timeout(const Duration(seconds: 1));
      blocked.completeError(
        PlatformException(code: 'file_drag_failed', message: 'native rejected'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(receiver.status.contains('native rejected'), false);
      await source.activateFileDrag();
      await eventually(() => receiver.status.contains('native rejected'));
      expect(source.capturing && target.capturing, true);
      receiver.onNativeEvent('fileDragSessionState', {
        'drag': 'c' * 32,
        'phase': 'ended',
        'unexpected': true,
        'captureContinues': true,
        'inputStopped': false,
        'error': '来源窗口启动失败',
      });
      await eventually(() => sender.status.contains('普通鼠标控制继续'));
      expect(sender.lastSessionState['inputStopped'], false);
      expect(source.capturing && target.capturing, true);
    },
  );
  test(
    'promise destination requests use separate channel and finish native progress',
    () async {
      final offer = await sender.prepare(await preview());
      final items = offer!['items'] as List;
      expect((items.single as Map).containsKey('path'), false);
      expect(source.capturing, false);
      final destination = '${workspace.path}/received.txt';
      receiver.onNativeEvent('fileDragRequest', {
        'drag': offer['drag'],
        'item': (items.single as Map)['id'],
        'request': 'b' * 32,
        'destination': destination,
      });
      await eventually(
        () => targetCalls.any((call) => call.method == 'fileDragComplete'),
      );
      expect(await File(destination).readAsString(), 'from Windows');
      expect(targetCalls.last.arguments, {'request': 'b' * 32, 'error': null});
      expect(
        targetCalls.any((call) => call.method == 'fileDragProgress'),
        true,
      );
      expect(source.connected, true);
    },
  );
  test(
    'retained metadata from another press cannot create a file offer',
    () async {
      expect(await sender.prepare(await preview(metadataPress: 16)), isNull);
      expect(await sender.prepare(await preview(metadataPress: 0)), isNull);
    },
  );
  test(
    'native session loss is reported to controller instead of silently becoming a local drag',
    () async {
      expect(source.supportsFileDragState, true);
      receiver.onNativeEvent('fileDragSessionState', {
        'drag': 'c' * 32,
        'phase': 'dragging',
      });
      await eventually(() => sender.status == 'Mac 文件拖拽进行中');
      receiver.onNativeEvent('fileDragSessionState', {
        'drag': 'c' * 32,
        'phase': 'ended',
        'unexpected': true,
        'accepted': false,
        'elapsedMs': 247,
        'sourceEventNumber': 819,
        'combinedLeftDown': true,
        'hidLeftDown': false,
      });
      await eventually(() => sender.status.contains('提前结束'));
      expect(sender.lastSessionState['elapsedMs'], 247);
      expect(sender.lastSessionState['sourceEventNumber'], 819);
      expect(sender.lastSessionState['combinedLeftDown'], true);
      expect(source.connected && target.connected, true);
    },
  );

  test(
    'native diagnostics do not send a new control type to older controllers',
    () async {
      source.fileDragStateSupported = false;
      await source.close();
      await eventually(() => !target.connected);
      await source.connect(host: '127.0.0.1', port: target.port, key: 'a' * 32);
      await eventually(
        () => sender.files.connected && receiver.files.connected,
      );
      expect(target.supportsFileDrag, true);
      expect(target.supportsFileDragState, false);
      receiver.onNativeEvent('fileDragSessionState', {
        'drag': 'd' * 32,
        'phase': 'ended',
        'unexpected': true,
        'accepted': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(receiver.status, contains('提前结束'));
      expect(sender.lastSessionState, isEmpty);
      expect(source.connected && target.connected, true);
    },
  );

  test('startup phases are visible and the first failure survives cancellation cleanup', () async {
    final drag = 'e' * 32;
    receiver.onNativeEvent('fileDragSessionState', {'drag': drag, 'phase': 'awaitingDown'});
    await eventually(() => sender.status == 'Mac 来源窗口等待按下事件');
    receiver.onNativeEvent('fileDragSessionState', {'drag': drag, 'phase': 'starting', 'sourceEventNumber': 61});
    await eventually(() => sender.status == 'Mac 已收到按下，正在启动文件拖拽');
    receiver.onNativeEvent('fileDragSessionState', {'drag': drag, 'phase': 'ended', 'unexpected': true,
      'error': 'Mac 已收到按下，但 AppKit 未启动文件拖拽', 'startupPhase': 'starting', 'elapsedMs': 1003});
    await eventually(() => sender.status == 'Mac 已收到按下，但 AppKit 未启动文件拖拽');
    receiver.onNativeEvent('fileDragSessionState', {'drag': drag, 'phase': 'ended', 'unexpected': false,
      'accepted': false, 'elapsedMs': 1010});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sender.status, 'Mac 已收到按下，但 AppKit 未启动文件拖拽');
    expect(sender.lastSessionState['unexpected'], true);
    expect(sender.lastSessionState['elapsedMs'], 1003);
    expect(sender.lastSessionState['startupPhase'], 'starting');
    receiver.onNativeEvent('fileDragSessionState', {'drag': 'f' * 32, 'phase': 'awaitingDown'});
    await eventually(() => sender.status == 'Mac 来源窗口等待按下事件');
  });
  test(
    'late OLE metadata may join the same physical press before crossing',
    () async {
      final stale = await preview(metadataPress: 16), fresh = await preview();
      var reads = 0;
      final offer = await sender.prepare(
        stale,
        current: () => ++reads >= 2 ? fresh : stale,
      );
      expect(offer, isNotNull);
      expect(reads, 2);
    },
  );
  test(
    'virtual attachments fail visibly without reading arbitrary paths',
    () async {
      await expectLater(
        sender.prepare(await preview(promised: true)),
        throwsFormatException,
      );
    },
  );
}
