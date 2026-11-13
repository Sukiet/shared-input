import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'protocol.dart';

class EncryptedWire {
  EncryptedWire(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _subscription = socket.listen(
      (bytes) {
        try {
          for (final frame in _decoder.add(bytes)) {
            _frames.add(frame);
          }
        } catch (error, stack) {
          _frames.addError(error, stack);
          close();
        }
      },
      onError: (Object error, StackTrace stack) {
        _frames.addError(error, stack);
        _frames.close();
      },
      onDone: () => _frames.close(),
    );
    incoming = StreamIterator(_frames.stream);
  }
  final Socket socket;
  final _decoder = FrameDecoder();
  final _frames = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;
  late final StreamIterator<Uint8List> incoming;
  Future<void> _sending = Future.value();
  int _queued = 0;
  bool closed = false;
  PacketCipher? transmit, receive;

  Future<Uint8List> next() async {
    if (!await incoming.moveNext().timeout(const Duration(seconds: 4))) {
      throw const SocketException('连接已关闭。');
    }
    return incoming.current;
  }

  Future<void> raw(Uint8List packet) async {
    if (closed) throw const SocketException('连接已关闭。');
    socket.add(frameTcp(packet));
    await socket.flush();
  }

  Future<void> send(Map<String, dynamic> json) =>
      sendBytes(Uint8List.fromList(utf8.encode(jsonEncode(json))));

  Future<void> sendBytes(Uint8List bytes) {
    if (++_queued > 512) {
      close();
      return Future.error(const SocketException('连接发送积压，已停止控制。'));
    }
    final operation = _sending
        .then((_) async {
          if (closed) throw const SocketException('连接已关闭。');
          socket.add(frameTcp(await transmit!.encrypt(bytes)));
          await socket.flush();
        })
        .whenComplete(() {
          --_queued;
        });
    _sending = operation.catchError((Object _) {});
    return operation;
  }

  void close() {
    if (closed) return;
    closed = true;
    socket.destroy();
    _subscription.cancel();
    _frames.close();
  }
}
