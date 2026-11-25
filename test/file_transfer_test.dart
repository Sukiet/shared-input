import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/remote/file_transfer_channel.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for file transfer');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FileTransferChannel sender, receiver;
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'shared-input-file-test-',
    );
    sender = FileTransferChannel();
    receiver = FileTransferChannel();
    final port = await receiver.listen(key: 'a' * 32, remote: '127.0.0.1');
    await sender.connect(key: 'a' * 32, host: '127.0.0.1', port: port);
    await eventually(() => receiver.connected);
  });
  tearDown(() async {
    await sender.close();
    await receiver.close();
    sender.dispose();
    receiver.dispose();
    await workspace.delete(recursive: true);
  });
  String path(String name) => '${workspace.path}${Platform.pathSeparator}$name';

  test(
    'promised file streams multiple windows, reports real bytes, preserves source',
    () async {
      final data = Uint8List.fromList(
        List.generate(2 * 1024 * 1024 + 123, (i) => i % 251),
      );
      final source = await File(path('图片 image.png')).writeAsBytes(data);
      final items = await sender.offer('b' * 32, [source.path]);
      expect(items.single['name'], '图片 image.png');
      expect(items.single['size'], data.length);
      final progress = <Map<String, dynamic>>[];
      receiver.onProgress = progress.add;
      expect(await File(path('copy.png')).exists(), false);
      await receiver.receive(
        drag: 'b' * 32,
        item: items.single['id'] as String,
        request: 'c' * 32,
        destination: path('copy.png'),
      );
      expect(await File(path('copy.png')).readAsBytes(), data);
      expect(await source.readAsBytes(), data);
      await eventually(() => progress.any((v) => v['done'] == true));
      expect(progress.last['bytes'], data.length);
    },
  );

  test(
    'directories preserve nesting, empty files and empty directories',
    () async {
      final source = await Directory(path('folder')).create();
      await Directory('${source.path}/nested/empty').create(recursive: true);
      await File('${source.path}/nested/readme.txt').writeAsString('你好 🖱');
      await File('${source.path}/zero').create();
      final items = await sender.offer('d' * 32, [source.path]);
      expect(items.single['folder'], true);
      await receiver.receive(
        drag: 'd' * 32,
        item: items.single['id'] as String,
        request: 'e' * 32,
        destination: path('folder-copy'),
      );
      expect(
        await File(path('folder-copy/nested/readme.txt')).readAsString(),
        '你好 🖱',
      );
      expect(await File(path('folder-copy/zero')).length(), 0);
      expect(await Directory(path('folder-copy/nested/empty')).exists(), true);
    },
  );

  test(
    'unoffered tokens cannot read a path and failures leave no destination',
    () async {
      await expectLater(
        receiver.receive(
          drag: 'f' * 32,
          item: '0' * 32,
          request: '1' * 32,
          destination: path('forged'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(path('forged')).exists(), false);
      expect(sender.connected, true);
    },
  );

  test('existing destination is never overwritten', () async {
    final source = await File(path('source.txt')).writeAsString('new data');
    await File(path('existing.txt')).writeAsString('keep me');
    final items = await sender.offer('2' * 32, [source.path]);
    await expectLater(
      receiver.receive(
        drag: '2' * 32,
        item: items.single['id'] as String,
        request: '3' * 32,
        destination: path('existing.txt'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(path('existing.txt')).readAsString(), 'keep me');
  });

  test('cancel removes the partial copy and keeps the original', () async {
    final source = await File(
      path('large.bin'),
    ).writeAsBytes(Uint8List(16 * 1024 * 1024));
    final items = await sender.offer('4' * 32, [source.path]);
    var cancelled = false;
    receiver.onProgress = (value) {
      if (!cancelled && value['bytes'] > 0) {
        cancelled = true;
        receiver.cancel('5' * 32);
      }
    };
    await expectLater(
      receiver.receive(
        drag: '4' * 32,
        item: items.single['id'] as String,
        request: '5' * 32,
        destination: path('partial.bin'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(cancelled, true);
    expect(await File(path('partial.bin')).exists(), false);
    expect(await source.length(), 16 * 1024 * 1024);
  });

  test(
    'multiple promised roots queue safely and do not share file data',
    () async {
      final one = await File(path('one')).writeAsString('first');
      final two = await File(path('two')).writeAsString('second');
      final items = await sender.offer('6' * 32, [one.path, two.path]);
      await Future.wait([
        receiver.receive(
          drag: '6' * 32,
          item: items[0]['id'] as String,
          request: '7' * 32,
          destination: path('one-copy'),
        ),
        receiver.receive(
          drag: '6' * 32,
          item: items[1]['id'] as String,
          request: '8' * 32,
          destination: path('two-copy'),
        ),
      ]);
      expect(await File(path('one-copy')).readAsString(), 'first');
      expect(await File(path('two-copy')).readAsString(), 'second');
    },
  );

  test(
    'relative path validation rejects escapes, absolute paths and ambiguity',
    () {
      for (final value in [
        '../secret',
        '/etc/passwd',
        r'C:\secret',
        'a//b',
        'a/./b',
        'a/../b',
        'a:b',
        'a\u0000b',
      ]) {
        expect(() => transferPath(value), throwsFormatException, reason: value);
      }
      expect(transferPath('文件夹/image.png'), ['文件夹', 'image.png']);
    },
  );
}
