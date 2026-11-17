import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_input/display_layout.dart';
import 'package:shared_input/drag_preview_link.dart';
import 'package:shared_input/edge_drag_preview.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/remote/protocol.dart';

Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for drag metadata');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  testWidgets(
    'panel separates both source file lists and can clear peer-only events',
    (tester) async {
      var cleared = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EdgeDragPreviewPanel(
                preview: const EdgeDragPreview(enabled: true),
                peer: const EdgeDragPreview(
                  origin: DragOrigin.receiver,
                  enabled: true,
                  revision: 1,
                  phase: 'enter',
                  dragStage: 'edge',
                  count: 1,
                  files: [
                    DragPreviewFile('远端.png', '/Users/test/远端.png', false),
                  ],
                ),
                edgeLabel: '右侧边缘',
                canChange: true,
                onChanged: (_) {},
                onClear: () {
                  ++cleared;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('主控机拖拽事件'), findsOneWidget);
      expect(find.text('被控机拖拽事件'), findsOneWidget);
      expect(find.text('/Users/test/远端.png'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('clear-edge-drag-preview')),
      );
      await tester.tap(find.byKey(const Key('clear-edge-drag-preview')));
      expect(cleared, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('origin labels and destinations follow the source machine', () {
    const mac = EdgeDragPreview(
      origin: DragOrigin.receiver,
      dragStage: 'crossed',
      onRemote: true,
    );
    const win = EdgeDragPreview(dragStage: 'crossed', onRemote: true);
    expect(mac.originLabel, '被控机拖拽事件');
    expect(mac.dragStatus, '已跨机器 · Windows');
    expect(win.originLabel, '主控机拖拽事件');
    expect(win.dragStatus, '已跨机器 · Mac');
  });
  test(
    'metadata stays below control frame limit with UTF8 and escaped paths',
    () {
      final state = EdgeDragPreview(
        enabled: true,
        revision: 12,
        count: 256,
        files: List.generate(
          256,
          (i) => DragPreviewFile('名字$i', 'C:/${'汉\n"' * 500}', false),
        ),
        formats: List.filled(32, '\u0001' * 256),
        message: '\u0001' * 1024,
      );
      final wire = DragPreviewLink.wireState(state, DragOrigin.controller);
      final frame = utf8.encode(
        jsonEncode({'type': 'dragPreviewState', 'state': wire}),
      );
      expect(frame.length + 28, lessThan(maxControlFrame));
      expect(wire['truncated'], true);
      expect(wire['count'], 256);
      expect(
        DragPreviewLink.parseWireState(wire, DragOrigin.controller),
        isNotNull,
      );
      expect(DragPreviewLink.parseWireState(wire, DragOrigin.receiver), isNull);
      expect(
        DragPreviewLink.parseWireState({
          ...wire,
          'dragStage': 'unknown',
        }, DragOrigin.controller),
        isNull,
      );
      expect(
        DragPreviewLink.parseWireState({
          ...wire,
          'count': -1,
        }, DragOrigin.controller),
        isNull,
      );
    },
  );
  test(
    'layout, both source states, clear and reconnect use encrypted LAN metadata',
    () async {
      final controller = LanSession(), receiver = LanSession();
      late DragPreviewLink win, mac;
      var winRevision = 10, macRevision = 10;
      var configuredSide = '', macEnabled = false, clearWin = 0, clearMac = 0;
      win = DragPreviewLink(
        controller,
        origin: DragOrigin.controller,
        configureReceiver: (_, _) async {},
        clearLocal: () async {
          ++clearWin;
          win.publish(EdgeDragPreview(enabled: true, revision: ++winRevision));
        },
      );
      mac = DragPreviewLink(
        receiver,
        origin: DragOrigin.receiver,
        configureReceiver: (enabled, side) async {
          configuredSide = side;
          macEnabled = enabled;
          mac.publish(
            EdgeDragPreview(
              origin: DragOrigin.receiver,
              enabled: enabled,
              side: side,
              revision: ++macRevision,
            ),
          );
        },
        clearLocal: () async {
          ++clearMac;
          mac.publish(
            EdgeDragPreview(
              origin: DragOrigin.receiver,
              enabled: macEnabled,
              revision: ++macRevision,
            ),
          );
        },
      );
      try {
        win.configureLayout(const DisplayLayout(side: ScreenSide.top));
        win.publish(
          EdgeDragPreview(
            enabled: true,
            revision: winRevision,
            dragStage: 'edge',
            gestureActive: true,
            files: const [DragPreviewFile('本地.txt', r'C:\本地.txt', false)],
            count: 1,
          ),
        );
        await receiver.listen(port: 0, key: 'a' * 32, bindAddress: '127.0.0.1');
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'a' * 32,
        );
        await eventually(
          () =>
              configuredSide == 'bottom' &&
              macEnabled &&
              mac.peer.files.isNotEmpty,
        );
        expect(controller.supportsDragPreview, true);
        expect(receiver.supportsDragPreview, true);
        await eventually(() => win.receiverReady);
        expect(mac.peer.files.single.path, r'C:\本地.txt');
        mac.publish(
          EdgeDragPreview(
            origin: DragOrigin.receiver,
            enabled: true,
            side: configuredSide,
            revision: ++macRevision,
            dragStage: 'edge',
            count: 1,
            files: const [
              DragPreviewFile('Mac 文件夹', '/Users/test/Mac 文件夹', false),
            ],
          ),
        );
        await eventually(() => win.peer.files.isNotEmpty);
        expect(win.peer.origin, DragOrigin.receiver);
        expect(win.peer.files.single.path, '/Users/test/Mac 文件夹');
        // An older callback cannot overwrite a newer snapshot.
        await receiver.sendDragPreviewControl({
          'type': 'dragPreviewState',
          'state': DragPreviewLink.wireState(
            const EdgeDragPreview(origin: DragOrigin.receiver, revision: 1),
            DragOrigin.receiver,
          ),
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(win.peer.files, isNotEmpty);
        for (final side in ScreenSide.values) {
          win.configureLayout(DisplayLayout(side: side));
          await eventually(() => configuredSide == side.opposite.name);
        }
        await win.clearBoth();
        await eventually(
          () =>
              clearWin == 1 &&
              clearMac == 1 &&
              win.peer.files.isEmpty &&
              mac.peer.files.isEmpty,
        );
        await controller.close();
        await eventually(() => !macEnabled && !receiver.connected);
        expect(win.peer.revision, -1);
        expect(win.peer.files, isEmpty);
        // Reconnect must reapply layout and enabled state, not an old callback.
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'a' * 32,
        );
        await eventually(() => macEnabled && configuredSide == 'top');
        expect(controller.capturing, false);
        expect(receiver.capturing, false);
      } finally {
        win.dispose();
        mac.dispose();
        await controller.close();
        await receiver.close();
        controller.dispose();
        receiver.dispose();
      }
    },
  );
  test('old peers remain connected without drag metadata capability', () async {
    final controller = LanSession(), receiver = LanSession();
    final link = DragPreviewLink(
      controller,
      origin: DragOrigin.controller,
      configureReceiver: (_, _) async {},
      clearLocal: () async {},
    );
    try {
      await receiver.listen(port: 0, key: 'b' * 32, bindAddress: '127.0.0.1');
      await controller.connect(
        host: '127.0.0.1',
        port: receiver.port,
        key: 'b' * 32,
      );
      expect(controller.supportsDragPreview, false);
      expect(link.receiverReady, false);
      link.publish(const EdgeDragPreview(enabled: true, revision: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.connected, true);
      expect(link.status, contains('对端需更新'));
    } finally {
      link.dispose();
      await controller.close();
      await receiver.close();
      controller.dispose();
      receiver.dispose();
    }
  });
  test(
    'receiver stop receives edge reason before releasing Mac source drag',
    () async {
      final controller = LanSession(), receiver = LanSession();
      String? reason;
      receiver.onEndWithReason = (value) async {
        reason = value;
      };
      try {
        await receiver.listen(port: 0, key: 'c' * 32, bindAddress: '127.0.0.1');
        await controller.connect(
          host: '127.0.0.1',
          port: receiver.port,
          key: 'c' * 32,
        );
        await controller.beginCapture();
        await controller.endCapture(reason: 'edge');
        await eventually(() => reason == 'edge');
        expect(receiver.capturing, false);
      } finally {
        await controller.close();
        await receiver.close();
        controller.dispose();
        receiver.dispose();
      }
    },
  );
}
