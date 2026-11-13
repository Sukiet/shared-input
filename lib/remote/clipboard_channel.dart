import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import '../clipboard_content.dart';
import 'protocol.dart';
import 'wire.dart';

/// Bulk encryption, hashing and sockets run outside the Flutter/input isolate.
class ClipboardChannel extends ChangeNotifier {
  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _commands;
  Completer<int>? _ready;
  int _generation = 0;
  bool connected = false;
  String error = '';
  void Function(Map<String, dynamic> metadata)? onPrepared;
  void Function(Map<String, dynamic> metadata, Uint8List bytes)? onPayload;
  bool _disposed = false;

  Future<int> listen({
    required String key,
    required String bindAddress,
    required String remoteAddress,
  }) => _start({
    'mode': 'listen',
    'key': key,
    'bind': bindAddress,
    'remote': remoteAddress,
  });

  Future<void> connect({
    required String key,
    required String host,
    required int port,
  }) async {
    await _start({'mode': 'connect', 'key': key, 'host': host, 'port': port});
  }

  Future<int> _start(Map<String, dynamic> options) async {
    close();
    final generation = _generation;
    final ready = _ready = Completer<int>();
    // Close/dispose may arrive while the isolate is being spawned.
    unawaited(ready.future.catchError((Object _) => -1));
    final events = _events = ReceivePort();
    events.listen((dynamic message) {
      if (generation != _generation || message is! Map) return;
      switch (message['event']) {
        case 'commands':
          _commands = message['port'] as SendPort;
        case 'listening':
          if (!ready.isCompleted) ready.complete(message['port'] as int);
        case 'connected':
          connected = true;
          error = '';
          if (!ready.isCompleted) ready.complete(0);
          _notify();
        case 'prepared':
          onPrepared?.call(Map<String, dynamic>.from(message));
        case 'payload':
          onPayload?.call(
            Map<String, dynamic>.from(message),
            (message['data'] as TransferableTypedData)
                .materialize()
                .asUint8List(),
          );
        case 'error':
          connected = false;
          error = '剪贴板连接中断，请重新连接';
          if (!ready.isCompleted) {
            ready.completeError(
              const SocketException('Clipboard channel failed'),
            );
          }
          _notify();
      }
    });
    try {
      final isolate = await Isolate.spawn(_clipboardWorker, [
        events.sendPort,
        options,
      ]);
      if (generation != _generation) {
        isolate.kill(priority: Isolate.immediate);
        throw const SocketException('Clipboard channel cancelled');
      }
      _isolate = isolate;
      return await ready.future.timeout(const Duration(seconds: 6));
    } catch (_) {
      if (generation == _generation) {
        close();
        error = '剪贴板连接失败，请重新连接';
        _notify();
      }
      rethrow;
    }
  }

  void prepare(String id, String kind, Uint8List bytes) => _commands?.send({
    'type': 'prepare',
    'id': id,
    'kind': kind,
    'data': TransferableTypedData.fromList([bytes]),
  });
  void expect(String? id) => _commands?.send({'type': 'expect', 'id': id});
  void send(String id) => _commands?.send({'type': 'send', 'id': id});

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void close() {
    ++_generation;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _events?.close();
    _events = null;
    _commands = null;
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(const SocketException('Clipboard channel closed'));
    }
    _ready = null;
    final wasConnected = connected;
    connected = false;
    error = '';
    if (wasConnected) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}

Future<void> _clipboardWorker(List<dynamic> arguments) async {
  final events = arguments[0] as SendPort;
  final options = Map<String, dynamic>.from(arguments[1] as Map);
  final worker = _BulkWorker(events);
  try {
    await worker.start(options);
  } catch (_) {
    worker.fail();
  }
}

class _BulkWorker {
  _BulkWorker(this.events);
  final SendPort events;
  final ReceivePort commands = ReceivePort();
  ServerSocket? server;
  EncryptedWire? wire;
  bool handshaking = false, failed = false, sending = false;
  String? winner, pendingSend;
  Map<String, dynamic>? local, incoming;
  Uint8List? localBytes;
  BytesBuilder? incomingBytes;
  int received = 0, preparation = 0;

  Future<void> start(Map<String, dynamic> options) async {
    commands.listen((dynamic value) {
      if (value is Map) {
        unawaited(
          command(
            Map<String, dynamic>.from(value),
          ).catchError((Object _) => fail()),
        );
      }
    });
    events.send({'event': 'commands', 'port': commands.sendPort});
    final master = await pairingKey(options['key'] as String);
    if (options['mode'] == 'listen') {
      server = await ServerSocket.bind(options['bind'] as String, 0);
      events.send({'event': 'listening', 'port': server!.port});
      server!.listen((socket) async {
        if (failed ||
            wire != null ||
            handshaking ||
            socket.remoteAddress.address != options['remote']) {
          socket.destroy();
          return;
        }
        handshaking = true;
        final candidate = EncryptedWire(socket);
        try {
          final hello = await openHandshake(await candidate.next(), master);
          if (hello['type'] != 'clipboardHello' || hello['version'] != 1) {
            throw const FormatException('Invalid bulk handshake');
          }
          final nonce = secureBytes(32);
          final keys = await SessionKeys.derive(
            master,
            base64Decode(hello['nonce'] as String),
            nonce,
          );
          await candidate.raw(
            await sealHandshake({
              'type': 'clipboardAck',
              'version': 1,
              'clientNonce': hello['nonce'],
              'nonce': base64Encode(nonce),
            }, master),
          );
          candidate.transmit = PacketCipher(keys.serverTcp);
          candidate.receive = PacketCipher(keys.clientTcp);
          final ready = await candidate.receive!.decrypt(
            await candidate.next(),
          );
          if (ready == null ||
              jsonDecode(utf8.decode(ready))['type'] != 'ready') {
            throw const FormatException('Invalid bulk confirmation');
          }
          await candidate.send({'type': 'connected'});
          activate(candidate);
        } catch (_) {
          candidate.close();
        } finally {
          handshaking = false;
        }
      }, onError: (Object _) => fail());
    } else {
      final socket = await Socket.connect(
        options['host'] as String,
        options['port'] as int,
        timeout: const Duration(seconds: 4),
      );
      final candidate = EncryptedWire(socket);
      final nonce = secureBytes(32);
      await candidate.raw(
        await sealHandshake({
          'type': 'clipboardHello',
          'version': 1,
          'nonce': base64Encode(nonce),
        }, master),
      );
      final ack = await openHandshake(await candidate.next(), master);
      if (ack['type'] != 'clipboardAck' ||
          ack['version'] != 1 ||
          ack['clientNonce'] != base64Encode(nonce)) {
        throw const FormatException('Invalid bulk handshake');
      }
      final keys = await SessionKeys.derive(
        master,
        nonce,
        base64Decode(ack['nonce'] as String),
      );
      candidate.transmit = PacketCipher(keys.clientTcp);
      candidate.receive = PacketCipher(keys.serverTcp);
      await candidate.send({'type': 'ready'});
      final confirmation = await candidate.receive!.decrypt(
        await candidate.next(),
      );
      if (confirmation == null ||
          jsonDecode(utf8.decode(confirmation))['type'] != 'connected') {
        throw const FormatException('Invalid bulk confirmation');
      }
      activate(candidate);
    }
  }

  void activate(EncryptedWire candidate) {
    wire = candidate;
    events.send({'event': 'connected'});
    unawaited(read().catchError((Object _) => fail()));
  }

  Future<void> command(Map<String, dynamic> command) async {
    if (failed) return;
    switch (command['type']) {
      case 'expect':
        winner = command['id'] as String?;
        ++preparation;
        if (incoming?['id'] != winner) {
          incoming = null;
          incomingBytes = null;
          received = 0;
        }
        if (local?['id'] != winner) {
          local = null;
          localBytes = null;
          pendingSend = null;
        }
      case 'prepare':
        final generation = ++preparation;
        final id = command['id'] as String, kind = command['kind'] as String;
        winner = id;
        incoming = null;
        incomingBytes = null;
        received = 0;
        final data = (command['data'] as TransferableTypedData)
            .materialize()
            .asUint8List();
        if (!validClipboardId(id) || !validClipboardBytes(kind, data)) {
          throw const FormatException('Invalid local clipboard');
        }
        final hash = (await Sha256().hash(
          data,
        )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (generation != preparation || winner != id) return;
        localBytes = data;
        local = {'id': id, 'kind': kind, 'length': data.length, 'hash': hash};
        events.send({'event': 'prepared', ...local!});
      case 'send':
        if (command['id'] == winner && local?['id'] == winner) {
          pendingSend = winner;
          if (!sending) unawaited(drain().catchError((Object _) => fail()));
        }
    }
  }

  Future<void> drain() async {
    sending = true;
    try {
      while (pendingSend != null && !failed && wire != null) {
        final id = pendingSend!;
        pendingSend = null;
        final metadata = local, data = localBytes;
        if (metadata == null || data == null || id != winner) continue;
        await wire!.sendBytes(
          Uint8List.fromList([1, ...utf8.encode(jsonEncode(metadata))]),
        );
        for (var offset = 0; offset < data.length && id == winner && !failed;) {
          final count = math.min(32768, data.length - offset);
          final frame = Uint8List(37 + count);
          frame[0] = 2;
          frame.setRange(1, 33, ascii.encode(id));
          ByteData.sublistView(frame).setUint32(33, offset);
          frame.setRange(37, frame.length, data, offset);
          await wire!.sendBytes(frame);
          offset += count;
          // At most one 32 KiB chunk queued; leave bandwidth for input traffic.
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
        if (id == winner && !failed) {
          await wire!.sendBytes(Uint8List.fromList([3, ...ascii.encode(id)]));
        }
      }
    } finally {
      sending = false;
    }
  }

  Future<void> read() async {
    final current = wire!;
    while (!failed && await current.incoming.moveNext()) {
      final bytes = await current.receive!.decrypt(current.incoming.current);
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('Invalid bulk frame');
      }
      switch (bytes[0]) {
        case 1:
          final value = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes.sublist(1))) as Map,
          );
          final kind = value['kind'],
              length = value['length'],
              hash = value['hash'];
          if (!validClipboardId(value['id']) ||
              !['text', 'png'].contains(kind) ||
              length is! int ||
              length < 0 ||
              length >
                  (kind == 'text'
                      ? maxClipboardTextBytes
                      : maxClipboardImageBytes) ||
              hash is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
            throw const FormatException('Invalid bulk metadata');
          }
          incoming = value['id'] == winner ? value : null;
          incomingBytes = incoming == null ? null : BytesBuilder(copy: false);
          received = 0;
        case 2:
          if (bytes.length < 37 || bytes.length > 32805) {
            throw const FormatException('Invalid chunk size');
          }
          final id = ascii.decode(bytes.sublist(1, 33));
          if (incoming?['id'] != id || id != winner) continue;
          final offset = ByteData.sublistView(bytes).getUint32(33);
          if (offset != received ||
              received + bytes.length - 37 > incoming!['length']) {
            throw const FormatException('Invalid chunk offset');
          }
          incomingBytes!.add(Uint8List.sublistView(bytes, 37));
          received += bytes.length - 37;
        case 3:
          if (bytes.length != 33) {
            throw const FormatException('Invalid completion');
          }
          final id = ascii.decode(bytes.sublist(1));
          if (incoming?['id'] != id || id != winner) continue;
          final metadata = incoming!;
          if (received != metadata['length']) {
            throw const FormatException('Incomplete clipboard');
          }
          final data = incomingBytes!.takeBytes();
          incoming = null;
          incomingBytes = null;
          final hash = (await Sha256().hash(
            data,
          )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          if (id != winner) continue;
          if (hash != metadata['hash'] ||
              !validClipboardBytes(metadata['kind'] as String, data)) {
            throw const FormatException('Invalid clipboard payload');
          }
          events.send({
            'event': 'payload',
            ...metadata,
            'data': TransferableTypedData.fromList([data]),
          });
        default:
          throw const FormatException('Unknown bulk frame');
      }
    }
    fail();
  }

  void fail() {
    if (failed) return;
    failed = true;
    wire?.close();
    unawaited(server?.close());
    commands.close();
    localBytes = null;
    incomingBytes = null;
    events.send({'event': 'error'});
  }
}
