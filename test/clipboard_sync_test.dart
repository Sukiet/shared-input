import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/clipboard_content.dart';
import 'package:shared_input/clipboard_sync.dart';
import 'package:shared_input/remote/lan_session.dart';
import 'package:shared_input/settings.dart';

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Clipboard state timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List testPng(int seed, {int size = 256}) {
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, Uint8List bytes) {
    final tag = ascii.encode(type);
    final header = ByteData(4)..setUint32(0, bytes.length);
    var crc = 0xffffffff;
    for (final b in [...tag, ...bytes]) {
      crc ^= b;
      for (var i = 0; i < 8; ++i) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    final footer = ByteData(4)..setUint32(0, crc ^ 0xffffffff);
    output.add(header.buffer.asUint8List());
    output.add(tag);
    output.add(bytes);
    output.add(footer.buffer.asUint8List());
  }

  final dimensions = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size);
  dimensions.setUint8(8, 8);
  dimensions.setUint8(9, 6);
  chunk('IHDR', dimensions.buffer.asUint8List());
  final raw = Uint8List((size * 4 + 1) * size);
  final random = Random(seed);
  for (var y = 0; y < size; ++y) {
    for (var x = 1; x <= size * 4; ++x) {
      raw[y * (size * 4 + 1) + x] = random.nextInt(256);
    }
  }
  chunk('IDAT', Uint8List.fromList(ZLibEncoder().convert(raw)));
  chunk('IEND', Uint8List(0));
  return output.takeBytes();
}

class FakeClipboard {
  FakeClipboard(this.name);
  final String name;
  late final channel = MethodChannel(name);
  int revision = 1, generation = 0, writes = 0, busyWrites = 0, busyReads = 0;
  bool enabled = false, deny = false;
  String kind = 'text', text = '', origin = '';
  Uint8List? bytes;
  Completer<void>? writeEntered, releaseWrite;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  void install() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'clipboardConfigure':
          enabled = args['enabled'] == true;
          ++generation;
          return null;
        case 'clipboardCancel':
          ++generation;
          return null;
        case 'clipboardRead':
          if (busyReads > 0) {
            --busyReads;
            return null;
          }
          if (!enabled || args['after'] == '$revision') return null;
          if (deny) {
            throw PlatformException(
              code: 'clipboard_denied',
              message: 'Clipboard permission required',
            );
          }
          return {
            'revision': '$revision',
            'kind': kind,
            if (origin.isNotEmpty) 'origin': origin,
            if (kind == 'text') 'text': text,
            if (kind == 'png') 'data': bytes,
          };
        case 'clipboardWrite':
          final epoch = generation;
          if (busyWrites > 0) {
            --busyWrites;
            return {'applied': false};
          }
          if (writeEntered != null && !writeEntered!.isCompleted) {
            writeEntered!.complete();
          }
          await releaseWrite?.future;
          if (!enabled ||
              epoch != generation ||
              args['expected'] != '$revision') {
            return {'applied': false};
          }
          kind = args['kind'] as String;
          final data = args['data'] as Uint8List;
          if (kind == 'text') {
            text = utf8.decode(data);
            bytes = null;
          } else {
            bytes = data;
            text = '';
          }
          origin = args['origin'] as String;
          ++revision;
          ++writes;
          return {'applied': true};
      }
      return null;
    });
  }

  void copyText(String value) {
    ++revision;
    kind = 'text';
    text = value;
    bytes = null;
    origin = '';
  }

  void copyPng(Uint8List value) {
    ++revision;
    kind = 'png';
    bytes = value;
    text = '';
    origin = '';
  }

  void dispose() {
    if (releaseWrite != null && !releaseWrite!.isCompleted) {
      releaseWrite!.complete();
    }
    messenger.setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LanSession receiver, controller;
  late FakeClipboard win, mac;
  late ClipboardSync winSync, macSync;
  setUp(() {
    receiver = LanSession();
    controller = LanSession();
    win = FakeClipboard('test/clipboard/win')
      ..copyText('Windows 初始\r\n😀')
      ..install();
    mac = FakeClipboard('test/clipboard/mac')
      ..copyText('Mac 初始')
      ..install();
    winSync = ClipboardSync(controller, win.channel)..start(true);
    macSync = ClipboardSync(receiver, mac.channel)..start(true);
  });
  tearDown(() async {
    winSync.dispose();
    macSync.dispose();
    await controller.close();
    await receiver.close();
    controller.dispose();
    receiver.dispose();
    win.dispose();
    mac.dispose();
  });
  Future<void> connect() async {
    const key = '0123456789abcdef0123456789abcdef';
    await receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1');
    await controller.connect(host: '127.0.0.1', port: receiver.port, key: key);
    await waitFor(
      () => controller.clipboard.connected && receiver.clipboard.connected,
    );
  }

  test(
    'connected peers synchronize Unicode both ways without capture or echo',
    () async {
      await connect();
      await waitFor(() => mac.text == 'Windows 初始\n😀');
      expect(controller.capturing, isFalse);
      mac.copyText('Mac 复制：中文 👨‍👩‍👧‍👦\n第二行');
      await waitFor(() => win.text == mac.text);
      final counts = (win.writes, mac.writes);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect((win.writes, mac.writes), counts);
      expect(winSync.status, '文字和图片双向同步');
    },
  );

  test(
    'PNG larger than a control frame transfers intact in both directions',
    () async {
      await connect();
      await waitFor(() => mac.writes > 0);
      final first = testPng(3);
      expect(first.length, greaterThan(65536));
      win.copyPng(first);
      await waitFor(() => mac.kind == 'png');
      expect(mac.bytes, orderedEquals(first));
      final second = testPng(9);
      mac.copyPng(second);
      await waitFor(
        () =>
            win.kind == 'png' &&
            win.bytes?.length == second.length &&
            win.writes > 0,
      );
      expect(win.bytes, orderedEquals(second));
    },
  );

  test(
    'a local copy made during remote image decode wins over stale image',
    () async {
      await connect();
      await waitFor(() => mac.writes > 0);
      mac.writeEntered = Completer<void>();
      mac.releaseWrite = Completer<void>();
      win.copyPng(testPng(1));
      await mac.writeEntered!.future.timeout(const Duration(seconds: 12));
      mac.copyText('刚复制的新内容');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      mac.releaseWrite!.complete();
      await waitFor(() => win.text == '刚复制的新内容');
      expect(mac.kind, 'text');
      expect(mac.text, '刚复制的新内容');
    },
  );

  test(
    'disabling during a pending write cancels it and stops both peers',
    () async {
      await connect();
      await waitFor(() => mac.writes > 0);
      final text = mac.text, writes = mac.writes;
      mac.writeEntered = Completer<void>();
      mac.releaseWrite = Completer<void>();
      win.copyPng(testPng(2));
      await mac.writeEntered!.future.timeout(const Duration(seconds: 12));
      winSync.setEnabled(false);
      await waitFor(() => !mac.enabled && !win.enabled);
      mac.releaseWrite!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(mac.writes, writes);
      expect(mac.text, text);
      win.copyText('不同步');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mac.text, text);
      winSync.setEnabled(true);
      await waitFor(() => mac.text == '不同步');
    },
  );

  test(
    'simultaneous copies converge and unsupported content fences old transfers',
    () async {
      await connect();
      await waitFor(() => mac.writes > 0);
      win.copyText('Windows new');
      mac.copyText('Mac new');
      await waitFor(() => win.text == mac.text);
      expect(['Windows new', 'Mac new'], contains(win.text));
      mac.kind = 'none';
      mac.origin = '';
      ++mac.revision;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      win.copyText('下一次正常复制');
      await waitFor(() => mac.text == '下一次正常复制');
    },
  );

  test(
    'clipboard permission errors leave keyboard connection usable',
    () async {
      mac.deny = true;
      await connect();
      await waitFor(() => macSync.status.contains('permission'));
      expect(controller.connected, isTrue);
      expect(receiver.connected, isTrue);
      await controller.beginCapture();
      expect(controller.capturing, isTrue);
      await controller.endCapture();
    },
  );

  test(
    'new controller remains compatible with a peer lacking clipboard capability',
    () async {
      receiver.clipboardSupported = false;
      await connectWithoutClipboard(receiver, controller);
      expect(controller.supportsClipboard, isFalse);
      expect(winSync.status, contains('更新'));
      await controller.beginCapture();
      expect(controller.capturing, isTrue);
    },
  );

  test(
    'a newer remote copy replaces an image whose native write is pending',
    () async {
      await connect();
      await waitFor(() => mac.writes > 0);
      mac.writeEntered = Completer<void>();
      mac.releaseWrite = Completer<void>();
      win.copyPng(testPng(12));
      await mac.writeEntered!.future.timeout(const Duration(seconds: 12));
      win.copyText('new remote copy');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      mac.releaseWrite!.complete();
      await waitFor(() => mac.text == 'new remote copy');
      expect(win.text, 'new remote copy');
      expect(mac.kind, 'text');
    },
  );

  test(
    'busy clipboard writes retry without dropping input connection',
    () async {
      mac.busyWrites = 2;
      await connect();
      await waitFor(() => mac.writes > 0);
      expect(mac.text, win.text.replaceAll('\r\n', '\n'));
      expect(controller.connected, isTrue);
      expect(mac.busyWrites, 0);
    },
  );

  test('reconnection uses a fresh snapshot and clipboard channel', () async {
    await connect();
    await waitFor(() => mac.writes > 0);
    await controller.close();
    await waitFor(() => !receiver.connected);
    win.copyText('after reconnect');
    mac.copyText('old receiver clipboard');
    await connect();
    await waitFor(() => mac.text == 'after reconnect');
    expect(win.text, 'after reconnect');
    expect(controller.clipboard.connected, isTrue);
  });

  test(
    'initially busy clipboard reads defer requesting the payload until ready',
    () async {
      mac.busyReads = 3;
      await connect();
      await waitFor(() => mac.writes > 0);
      expect(mac.text, win.text.replaceAll('\r\n', '\n'));
      expect(mac.busyReads, 0);
    },
  );

  test(
    'clipboard formats reject invalid data and settings restore the toggle',
    () {
      expect(
        validClipboardBytes('text', Uint8List.fromList([0xc0, 0x80])),
        isFalse,
      );
      expect(validClipboardBytes('text', Uint8List.fromList([0])), isFalse);
      expect(validClipboardBytes('png', Uint8List(33)), isFalse);
      final png = testPng(4, size: 2);
      expect(validClipboardBytes('png', png), isTrue);
      ByteData.sublistView(png).setUint32(16, 0xffffffff);
      ByteData.sublistView(png).setUint32(20, 0xffffffff);
      expect(validClipboardBytes('png', png), isFalse);
      expect(AppSettings().clipboardEnabled, isTrue);
      final settings = AppSettings()..clipboardEnabled = false;
      expect(AppSettings.fromJson(settings.toJson()).clipboardEnabled, isFalse);
      expect(
        () => ClipboardOffer.fromJson({'id': 'bad'}),
        throwsFormatException,
      );
      final low = ClipboardOffer(
        id: 'a' * 32,
        actor: 'b' * 32,
        clock: 1,
        kind: 'none',
      );
      final high = ClipboardOffer(
        id: 'c' * 32,
        actor: 'd' * 32,
        clock: 1,
        kind: 'none',
      );
      expect(low.compareTo(high), lessThan(0));
    },
  );
}

Future<void> connectWithoutClipboard(
  LanSession receiver,
  LanSession controller,
) async {
  const key = '0123456789abcdef0123456789abcdef';
  await receiver.listen(port: 0, key: key, bindAddress: '127.0.0.1');
  await controller.connect(host: '127.0.0.1', port: receiver.port, key: key);
}
