import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import '../settings.dart';
import 'protocol.dart';
import 'wire.dart';

/// Separate socket/isolate: encryption, directory walking and file I/O cannot
/// occupy the input isolate. At most eight 48 KiB blocks are in flight.
class FileTransferChannel extends ChangeNotifier {
  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _commands;
  final _pending = <int, Completer<dynamic>>{};
  int _serial = 0, _generation = 0;
  bool connected = false, _disposed = false;
  String error = '';
  Future<void>? _closing;
  void Function(Map<String, dynamic>)? onProgress;

  Future<int> listen({required String key, required String remote}) =>
      _start({'mode': 'listen', 'key': key, 'remote': remote});
  Future<void> connect({
    required String key,
    required String host,
    required int port,
  }) async {
    await _start({'mode': 'connect', 'key': key, 'host': host, 'port': port});
  }

  Future<int> _start(Map<String, dynamic> options) async {
    await close();
    error = '';
    final generation = _generation;
    final ready = Completer<int>();
    unawaited(ready.future.catchError((Object _) => -1));
    final events = _events = ReceivePort();
    events.listen((dynamic raw) {
      if (generation != _generation || raw is! Map) return;
      final event = Map<String, dynamic>.from(raw);
      switch (event['event']) {
        case 'commands':
          _commands = event['port'] as SendPort;
        case 'ready':
          if (!ready.isCompleted) ready.complete(event['port'] as int);
        case 'connected':
          connected = true;
          if (!ready.isCompleted) ready.complete(0);
          if (!_disposed) notifyListeners();
        case 'reply':
          final pending = _pending.remove(event['serial']);
          if (event['error'] != null) {
            pending?.completeError(
              FileSystemException(event['error'] as String),
            );
          } else {
            pending?.complete(event['value']);
          }
        case 'progress':
          onProgress?.call(event);
        case 'error':
          connected = false;
          this.error = event['error'] as String? ?? '文件通道已关闭';
          final error = FileSystemException(
            event['error'] as String? ?? '文件通道已关闭',
          );
          if (!ready.isCompleted) ready.completeError(error);
          for (final pending in _pending.values) {
            pending.completeError(error);
          }
          _pending.clear();
          if (!_disposed) notifyListeners();
      }
    });
    final isolate = await Isolate.spawn(_fileWorker, [
      events.sendPort,
      options,
    ]);
    if (generation != _generation || _disposed) {
      isolate.kill(priority: Isolate.immediate);
      throw const SocketException('File channel cancelled');
    }
    _isolate = isolate;
    return ready.future.timeout(const Duration(seconds: 8));
  }

  Future<dynamic> _call(String command, Map<String, dynamic> args) {
    if (_commands == null) {
      return Future.error(const SocketException('文件通道未就绪'));
    }
    final serial = ++_serial, result = Completer<dynamic>();
    _pending[serial] = result;
    _commands!.send({'command': command, 'serial': serial, ...args});
    return result.future;
  }

  Future<List<Map<String, dynamic>>> offer(
    String drag,
    List<String> paths,
  ) async {
    final value = await _call('offer', {'drag': drag, 'paths': paths});
    return (value as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> receive({
    required String drag,
    required String item,
    required String request,
    required String destination,
  }) async {
    await _call('pull', {
      'drag': drag,
      'item': item,
      'request': request,
      'destination': destination,
    });
  }

  void cancel(String request) =>
      _commands?.send({'command': 'cancel', 'request': request});
  Future<void> close() {
    if (_closing != null) return _closing!;
    final operation = _closeOwned();
    _closing = operation;
    return operation.whenComplete(() {
      if (identical(_closing, operation)) _closing = null;
    });
  }

  Future<void> _closeOwned() async {
    final commands = _commands;
    final isolate = _isolate;
    final events = _events;
    _commands = null;
    _isolate = null;
    _events = null;
    connected = false;
    ++_generation;
    if (commands != null) {
      final done = ReceivePort();
      commands.send({'command': 'close', 'done': done.sendPort});
      try {
        await done.first.timeout(const Duration(seconds: 2));
      } catch (_) {
        /* bounded cleanup */
      }
      done.close();
    }
    isolate?.kill(priority: Isolate.immediate);
    events?.close();
    for (final pending in _pending.values) {
      pending.completeError(const SocketException('文件连接已关闭'));
    }
    _pending.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

bool validTransferName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    name.length <= 1024 &&
    !name.contains(RegExp(r'[/\\\x00-\x1f:]'));
List<String> transferPath(String value) {
  final parts = value.split('/');
  if (parts.length > 128 || !parts.every(validTransferName)) {
    throw const FormatException('非法的文件相对路径');
  }
  return parts;
}

bool _id(dynamic value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
String _join(String root, String name) => '$root${Platform.pathSeparator}$name';
String _basename(String path) =>
    path.replaceAll('\\', '/').split('/').where((v) => v.isNotEmpty).last;

void _fileWorker(List<dynamic> args) {
  final worker = _FileWorker(
    args[0] as SendPort,
    Map<String, dynamic>.from(args[1] as Map),
  );
  unawaited(worker.start().catchError((Object error) => worker.fail(error)));
}

class _ReceiveJob {
  _ReceiveJob(
    this.serial,
    this.drag,
    this.item,
    this.request,
    this.destination,
  );
  final int serial;
  final String drag, item, request, destination;
  bool created = false, rootSeen = false, folder = false, cancelled = false;
  RandomAccessFile? file;
  int expected = 0, written = 0, total = 0, blocks = 0, planned = -1;
  DateTime lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  final paths = <String>{};
}

class _SendJob {
  _SendJob(this.request);
  final String request;
  bool cancelled = false;
  int sent = 0, acknowledged = 0;
  Completer<void>? wake;
}

class _Source {
  _Source(this.path, this.name, this.folder);
  final String path, name;
  final bool folder;
}

class _FileWorker {
  _FileWorker(this.parent, this.options);
  final SendPort parent;
  final Map<String, dynamic> options;
  final commands = ReceivePort();
  ServerSocket? server;
  EncryptedWire? wire;
  bool closed = false, handshaking = false;
  bool get sender => options['mode'] == 'connect';
  final offers = <String, Map<String, _Source>>{};
  final offeredAt = <String, DateTime>{};
  final receivers = <String, _ReceiveJob>{};
  final senders = <String, _SendJob>{};
  Future<void> outgoing = Future.value();
  Future<void> incoming = Future.value();
  Future<void> serializeReceive(Future<void> Function() action) {
    final task = incoming.then((_) => action());
    incoming = task.catchError((Object _) {});
    return task;
  }

  static const chunkSize = 48 * 1024, window = 8;

  void event(String kind, [Map<String, dynamic> data = const {}]) =>
      parent.send({'event': kind, ...data});
  void reply(dynamic serial, [dynamic value, Object? error]) {
    if (serial is int) {
      event('reply', {
        'serial': serial,
        'value': value,
        if (error != null) 'error': '$error',
      });
    }
  }

  Future<void> start() async {
    event('commands', {'port': commands.sendPort});
    commands.listen((dynamic value) {
      if (value is Map) unawaited(command(Map<String, dynamic>.from(value)));
    });
    if (sender) {
      final socket = await Socket.connect(
        options['host'] as String,
        options['port'] as int,
        timeout: const Duration(seconds: 5),
      );
      await handshake(socket);
    } else {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      event('ready', {'port': server!.port});
      server!.listen((socket) async {
        if (closed ||
            wire != null ||
            handshaking ||
            socket.remoteAddress.address != options['remote']) {
          socket.destroy();
          return;
        }
        handshaking = true;
        try {
          await handshake(socket);
        } catch (_) {
          socket.destroy();
        } finally {
          handshaking = false;
        }
      });
    }
  }

  Future<void> handshake(Socket socket) async {
    final candidate = EncryptedWire(socket);
    try {
      final secret = await pairingKey(options['key'] as String);
      final local = secureBytes(32);
      late List<int> client, remote;
      if (sender) {
        client = local;
        await candidate.raw(
          await sealHandshake({
            'type': 'fileHello',
            'nonce': base64Encode(local),
          }, secret),
        );
        final ack = await openHandshake(await candidate.next(), secret);
        if (ack['type'] != 'fileAck' || ack['client'] != base64Encode(client)) {
          throw const FormatException('File handshake');
        }
        remote = base64Decode(ack['nonce'] as String);
      } else {
        final hello = await openHandshake(await candidate.next(), secret);
        if (hello['type'] != 'fileHello') {
          throw const FormatException('File handshake');
        }
        client = base64Decode(hello['nonce'] as String);
        remote = local;
        await candidate.raw(
          await sealHandshake({
            'type': 'fileAck',
            'client': hello['nonce'],
            'nonce': base64Encode(local),
          }, secret),
        );
      }
      final keys = await SessionKeys.derive(secret, client, remote);
      candidate.transmit = PacketCipher(
        sender ? keys.clientTcp : keys.serverTcp,
      );
      candidate.receive = PacketCipher(
        sender ? keys.serverTcp : keys.clientTcp,
      );
      if (closed) throw const SocketException('File channel closed');
      wire = candidate;
      event('connected');
      unawaited(read(candidate));
    } catch (_) {
      candidate.close();
      rethrow;
    }
  }

  Future<void> json(Map<String, dynamic> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    await wire!.sendBytes(Uint8List.fromList([0, ...bytes]));
  }

  Future<void> read(EncryptedWire active) async {
    try {
      while (!closed && await active.incoming.moveNext()) {
        final plain = await active.receive!.decrypt(active.incoming.current);
        if (plain == null || plain.isEmpty) {
          throw const FormatException('Invalid file frame');
        }
        if (plain[0] == 0) {
          final value = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(plain.sublist(1))) as Map,
          );
          if (sender) {
            await message(value);
          } else {
            await serializeReceive(() => message(value));
          }
        } else if (plain[0] == 1 &&
            !sender &&
            plain.length > 17 &&
            plain.length <= chunkSize + 17) {
          final request = plain
              .sublist(1, 17)
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          await serializeReceive(
            () => data(request, Uint8List.sublistView(plain, 17)),
          );
        } else {
          throw const FormatException('Invalid file data');
        }
      }
      if (!closed) throw const SocketException('文件连接中断');
    } catch (error) {
      if (!closed) await fail(error);
    }
  }

  Future<void> command(Map<String, dynamic> value) async {
    final serial = value['serial'];
    try {
      switch (value['command']) {
        case 'offer':
          if (!sender || !_id(value['drag'])) {
            throw const FormatException('Invalid offer');
          }
          final paths = List<String>.from(value['paths'] as List);
          if (paths.isEmpty || paths.length > 128) {
            throw const FormatException('一次最多拖拽 128 个对象');
          }
          final sources = <String, _Source>{};
          final items = <Map<String, dynamic>>[];
          for (final path in paths) {
            final type = await FileSystemEntity.type(path, followLinks: false);
            if (type != FileSystemEntityType.file &&
                type != FileSystemEntityType.directory) {
              throw const FileSystemException('暂不支持符号链接或虚拟文件');
            }
            final folder = type == FileSystemEntityType.directory;
            final name = _basename(path);
            if (!validTransferName(name)) {
              throw const FormatException('文件名不能映射到 Mac');
            }
            final canonical = await (folder ? Directory(path) : File(path))
                .resolveSymbolicLinks();
            final item = randomHex();
            sources[item] = _Source(canonical, name, folder);
            items.add({
              'id': item,
              'name': name,
              'folder': folder,
              'size': folder ? 0 : await File(canonical).length(),
            });
          }
          // Bounded authorization list; no peer-provided filesystem path is read.
          while (offers.length >= 8) {
            final oldest = offers.keys.first;
            offers.remove(oldest);
            offeredAt.remove(oldest);
          }
          offers[value['drag'] as String] = sources;
          offeredAt[value['drag'] as String] = DateTime.now();
          reply(serial, items);
        case 'pull':
          if (sender ||
              wire == null ||
              !_id(value['request']) ||
              receivers.length >= 128) {
            throw const FormatException('Invalid file request');
          }
          final request = value['request'] as String;
          if (receivers.containsKey(request)) {
            throw const FormatException('Duplicate request');
          }
          final job = _ReceiveJob(
            serial as int,
            value['drag'] as String,
            value['item'] as String,
            request,
            value['destination'] as String,
          );
          receivers[request] = job;
          await json({
            'type': 'pull',
            'drag': job.drag,
            'item': job.item,
            'request': request,
          });
        case 'cancel':
          final request = value['request'] as String;
          await serializeReceive(() => reject(request, '传输已取消'));
          if (wire != null) await json({'type': 'cancel', 'request': request});
        case 'close':
          await shutdown();
          (value['done'] as SendPort).send(true);
          commands.close();
      }
    } catch (error) {
      reply(serial, null, error);
    }
  }

  Future<void> message(Map<String, dynamic> value) async {
    final request = value['request'];
    if (!_id(request)) throw const FormatException('Invalid request ID');
    if (sender) {
      if (value['type'] == 'pull') {
        final created = offeredAt[value['drag']];
        final source =
            created != null && DateTime.now().difference(created).inMinutes < 10
            ? (offers[value['drag']]?[value['item']])
            : null;
        if (source == null ||
            senders.length >= 128 ||
            senders.containsKey(request)) {
          await json({
            'type': 'error',
            'request': request,
            'error': '拖拽对象已过期，请重新拖拽',
          });
          return;
        }
        final job = _SendJob(request as String);
        senders[job.request] = job;
        outgoing = outgoing
            .then((_) => sendRoot(job, source))
            .catchError((Object _) {});
      } else if (value['type'] == 'ack') {
        final job = senders[request], count = value['blocks'];
        if (job != null &&
            count is int &&
            count >= job.acknowledged &&
            count <= job.sent) {
          job.acknowledged = count;
          job.wake?.complete();
          job.wake = null;
        }
      } else if (value['type'] == 'cancel') {
        final job = senders[request];
        if (job != null) {
          job.cancelled = true;
          job.wake?.complete();
          job.wake = null;
        }
      }
      return;
    }
    final job = receivers[request];
    if (job == null) {
      return; // Cancelled jobs drain their already in-flight blocks.
    }
    try {
      switch (value['type']) {
        case 'root':
          if (job.rootSeen || value['folder'] is! bool) {
            throw const FormatException('Duplicate root');
          }
          job.rootSeen = true;
          final planned = value['total'];
          if (planned is! int || planned < 0) {
            throw const FormatException('Invalid total');
          }
          job.planned = planned;
          if (await FileSystemEntity.type(
                job.destination,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            throw const FileSystemException('目标已存在，未覆盖文件');
          }
          job.folder = value['folder'] as bool;
          if (job.folder) {
            await Directory(job.destination).create();
            job.created = true;
          }
          progress(job);
        case 'entry':
          if (!job.rootSeen ||
              job.file != null ||
              value['folder'] is! bool ||
              value['size'] is! int ||
              (value['size'] as int) < 0) {
            throw const FormatException('Invalid file entry');
          }
          final relative = value['path'] as String;
          String path;
          if (job.folder) {
            final parts = transferPath(relative);
            path = parts.fold(job.destination, _join);
            final parent = parts.length == 1
                ? ''
                : parts.take(parts.length - 1).join('/');
            if (parent.isNotEmpty && !job.paths.contains('$parent/')) {
              throw const FormatException('Missing parent');
            }
          } else {
            if (relative.isNotEmpty ||
                value['folder'] != false ||
                job.created) {
              throw const FormatException('Invalid root file');
            }
            path = job.destination;
          }
          if (job.paths.contains(relative) ||
              job.paths.contains('$relative/')) {
            throw const FormatException('Duplicate path');
          }
          if (value['folder'] == true) {
            if (await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.notFound) {
              throw const FileSystemException('目录已存在');
            }
            await Directory(path).create();
            job.paths.add('$relative/');
          } else {
            // Exclusive creation prevents overwriting an unrelated local file.
            await File(path).create(exclusive: true);
            if (!job.folder) job.created = true;
            job.file = await File(path).open(mode: FileMode.writeOnly);
            job.paths.add(relative);
            job.expected = value['size'] as int;
            job.written = 0;
          }
          if (job.paths.length > 100000) {
            throw const FormatException('目录文件数超出限制');
          }
        case 'fileEnd':
          if (job.file == null || job.expected != job.written) {
            throw const FormatException('文件大小不匹配');
          }
          await job.file!.flush();
          await job.file!.close();
          job.file = null;
        case 'done':
          if (!job.created || job.file != null || job.total != job.planned) {
            throw const FormatException('文件传输未完成');
          }
          receivers.remove(request);
          progress(job, done: true);
          reply(job.serial);
        case 'error':
          await reject(
            request as String,
            value['error'] as String? ?? '文件传输失败',
          );
      }
    } catch (error) {
      await reject(request as String, '$error');
      await json({'type': 'cancel', 'request': request});
    }
  }

  Future<void> data(String request, Uint8List bytes) async {
    final job = receivers[request];
    if (job == null) return;
    try {
      if (job.file == null || job.written + bytes.length > job.expected) {
        throw const FormatException('文件块超出范围');
      }
      await job.file!.writeFrom(bytes);
      job.written += bytes.length;
      job.total += bytes.length;
      ++job.blocks;
      await json({'type': 'ack', 'request': request, 'blocks': job.blocks});
      if (DateTime.now().difference(job.lastProgress).inMilliseconds >= 100) {
        job.lastProgress = DateTime.now();
        progress(job);
      }
    } catch (error) {
      await reject(request, '$error');
      await json({'type': 'cancel', 'request': request});
    }
  }

  void progress(_ReceiveJob job, {bool done = false}) => event('progress', {
    'request': job.request,
    'bytes': job.total,
    'total': job.planned,
    'done': done,
  });

  Future<void> capacity(_SendJob job, {bool drain = false}) async {
    while (job.sent - job.acknowledged >= (drain ? 1 : window)) {
      if (closed || job.cancelled) throw const SocketException('传输已取消');
      final wake = job.wake ??= Completer<void>();
      await wake.future.timeout(const Duration(seconds: 20));
    }
    if (closed || job.cancelled) throw const SocketException('传输已取消');
  }

  Future<void> sendRoot(_SendJob job, _Source source) async {
    try {
      await capacity(job);
      final manifest = <(String, String, bool)>[];
      var planned = 0, metadataBytes = 0;
      Future<void> scan(String directory, String prefix, int depth) async {
        if (depth > 128) throw const FileSystemException('目录层级过深');
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          await capacity(job);
          final name = _basename(entity.path);
          if (!validTransferName(name) || entity is Link) {
            throw const FormatException('不支持的名称或符号链接');
          }
          final relative = prefix.isEmpty ? name : '$prefix/$name';
          metadataBytes += utf8.encode(relative).length;
          if (manifest.length >= 100000 || metadataBytes > 32 * 1024 * 1024) {
            throw const FileSystemException('目录文件清单过大');
          }
          final folder = entity is Directory;
          manifest.add((entity.path, relative, folder));
          if (folder) {
            await scan(entity.path, relative, depth + 1);
          } else {
            planned += (await entity.stat()).size;
          }
        }
      }

      if (source.folder) {
        await scan(source.path, '', 0);
      } else {
        manifest.add((source.path, '', false));
        planned = await File(source.path).length();
      }
      await json({
        'type': 'root',
        'request': job.request,
        'folder': source.folder,
        'total': planned,
      });
      var count = 0;
      Future<void> entry(String path, String relative, bool folder) async {
        await capacity(job);
        if (++count > 100000) throw const FileSystemException('目录文件数超出限制');
        if (relative.isNotEmpty) transferPath(relative);
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type !=
            (folder
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file)) {
          throw const FileSystemException('暂不支持符号链接或文件类型发生变化');
        }
        final actual = await (folder ? Directory(path) : File(path))
            .resolveSymbolicLinks();
        if (actual != source.path &&
            !actual.startsWith('${source.path}${Platform.pathSeparator}')) {
          throw const FileSystemException('文件已移到授权目录以外');
        }
        final stat = await FileStat.stat(path);
        await json({
          'type': 'entry',
          'request': job.request,
          'path': relative,
          'folder': folder,
          'size': folder ? 0 : stat.size,
        });
        if (folder) return;
        final file = await File(path).open();
        try {
          var remaining = stat.size;
          while (remaining > 0) {
            await capacity(job);
            final bytes = await file.read(
              remaining < chunkSize ? remaining : chunkSize,
            );
            if (bytes.isEmpty) throw const FileSystemException('源文件在传输过程中被截断');
            final header = <int>[
              1,
              for (var i = 0; i < 32; i += 2)
                int.parse(job.request.substring(i, i + 2), radix: 16),
            ];
            ++job.sent;
            await wire!.sendBytes(Uint8List.fromList([...header, ...bytes]));
            remaining -= bytes.length;
          }
          await capacity(job, drain: true);
          final after = await FileStat.stat(path);
          if (after.size != stat.size || after.modified != stat.modified) {
            throw const FileSystemException('源文件在传输过程中被修改');
          }
          await json({'type': 'fileEnd', 'request': job.request});
        } finally {
          await file.close();
        }
      }

      for (final (path, relative, folder) in manifest) {
        await entry(path, relative, folder);
      }
      await json({'type': 'done', 'request': job.request});
    } catch (error) {
      try {
        await json({
          'type': 'error',
          'request': job.request,
          'error': '$error',
        });
      } catch (_) {
        /* disconnected */
      }
    } finally {
      senders.remove(job.request);
    }
  }

  Future<void> reject(String request, String error) async {
    final job = receivers.remove(request);
    if (job == null) return;
    job.cancelled = true;
    try {
      await job.file?.close();
    } catch (_) {
      /* already closed */
    }
    if (job.created) {
      try {
        if (job.folder) {
          await Directory(job.destination).delete(recursive: true);
        } else {
          await File(job.destination).delete();
        }
      } catch (_) {
        /* preserve cleanup error instead of deleting any other path */
      }
    }
    reply(job.serial, null, error);
  }

  Future<void> shutdown() async {
    closed = true;
    wire?.close();
    wire = null;
    await server?.close();
    server = null;
    for (final job in senders.values) {
      job.cancelled = true;
      job.wake?.complete();
      job.wake = null;
    }
    await serializeReceive(() async {
      for (final request in receivers.keys.toList()) {
        await reject(request, '文件连接已关闭');
      }
    });
    await outgoing;
  }

  Future<void> fail(Object error) async {
    await shutdown();
    event('error', {'error': '$error'});
  }
}
