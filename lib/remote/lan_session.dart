import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../settings.dart';
import 'protocol.dart';
import 'input_diagnostics.dart';

class _Wire {
  _Wire(this.socket) {
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

  Future<void> send(Map<String, dynamic> json) {
    if (++_queued > 512) {
      close();
      return Future.error(const SocketException('连接发送积压，已停止控制。'));
    }
    final operation = _sending
        .then((_) async {
          if (closed) throw const SocketException('连接已关闭。');
          socket.add(
            frameTcp(await transmit!.encrypt(utf8.encode(jsonEncode(json)))),
          );
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

class LanSession extends ChangeNotifier {
  final diagnostics = InputDiagnostics();
  Future<void> Function(String capture)? onBegin;
  Future<void> Function(String capture, List<Map<String, dynamic>> frames)?
  onInput;
  Future<void> Function()? onEnd;
  Future<void> Function()? onHeartbeat;
  VoidCallback? onConnectionLost;
  VoidCallback? onCaptureEnded;

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  _Wire? _wire;
  final Set<_Wire> _handshakes = {};
  PacketCipher? _mouseCipher;
  Timer? _heartbeat;
  InternetAddress? _remoteAddress;
  int _remoteUdpPort = 0;
  bool _receiver = false, _disposed = false, _closing = false;
  bool _sendingMouse = false, _handlingEvents = false;
  MotionFrame? _pendingSend, _pendingReceive;
  int _pendingReceiveAt = 0;
  MotionFrame? _latestMotion;
  Future<void> _delivery = Future.value();
  int _generation = 0, _appliedEpoch = 0;
  String? _capture;
  Completer<void>? _startAck;
  DateTime _lastReceived = DateTime.now();
  String status = '未连接';
  int sentPackets = 0, receivedPackets = 0;
  double? latencyMs;
  final metrics = ValueNotifier<(int, int, double?)>((0, 0, null));
  DateTime _rateSince = DateTime.now();
  int _previousSent = 0, _previousReceived = 0;

  bool get connected => _wire != null && !_wire!.closed;
  bool get listening => _server != null;
  bool get capturing => _capture != null;
  int get port => _server?.port ?? 0;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> listen({
    required int port,
    required String key,
    String bindAddress = '0.0.0.0',
  }) async {
    await close();
    final master = await pairingKey(key);
    _receiver = true;
    try {
      _server = await ServerSocket.bind(bindAddress, port, shared: false);
      _udp = await RawDatagramSocket.bind(bindAddress, _server!.port);
      _udp!.writeEventsEnabled = false;
      _udp!.listen(_receiveUdp);
      _server!.listen((socket) async {
        if (connected || _handshakes.isNotEmpty) {
          socket.destroy();
          return;
        }
        final wire = _Wire(socket);
        _handshakes.add(wire);
        final generation = _generation;
        try {
          final hello = await openHandshake(await wire.next(), master);
          if (hello['version'] != protocolVersion || hello['type'] != 'hello') {
            throw const FormatException('协议版本不匹配。');
          }
          final clientNonce = base64Decode(hello['nonce'] as String);
          final serverNonce = secureBytes(32);
          final udpPort = hello['udpPort'] as int;
          if (udpPort <= 0 || udpPort > 65535) {
            throw const FormatException('Invalid UDP port');
          }
          await wire.raw(
            await sealHandshake({
              'type': 'helloAck',
              'version': protocolVersion,
              'clientNonce': hello['nonce'],
              'nonce': base64Encode(serverNonce),
              'udpPort': _udp!.port,
            }, master),
          );
          final keys = await SessionKeys.derive(
            master,
            clientNonce,
            serverNonce,
          );
          wire.transmit = PacketCipher(keys.serverTcp);
          wire.receive = PacketCipher(keys.clientTcp);
          final ready = await wire.receive!.decrypt(await wire.next());
          if (ready == null ||
              jsonDecode(utf8.decode(ready))['type'] != 'ready') {
            throw const FormatException('配对确认失败。');
          }
          if (generation != _generation || _server == null) {
            throw const SocketException('监听已停止。');
          }
          _wire = wire;
          _mouseCipher = PacketCipher(keys.mouse);
          _remoteAddress = socket.remoteAddress;
          _remoteUdpPort = udpPort;
          await wire.send({'type': 'connected'});
          _activate(wire);
        } catch (_) {
          wire.close();
          if (generation == _generation && !connected) {
            status = '配对失败，请核对连接码';
            _changed();
          }
        } finally {
          _handshakes.remove(wire);
        }
      });
      status = '等待连接';
      _changed();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> connect({
    required String host,
    required int port,
    required String key,
  }) async {
    await close();
    final address = InternetAddress.tryParse(host.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw const FormatException('请输入被控端的局域网 IPv4 地址。');
    }
    final master = await pairingKey(key);
    _receiver = false;
    final generation = _generation;
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udp!.writeEventsEnabled = false;
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 4),
      );
      final wire = _Wire(socket);
      _handshakes.add(wire);
      final clientNonce = secureBytes(32);
      await wire.raw(
        await sealHandshake({
          'type': 'hello',
          'version': protocolVersion,
          'nonce': base64Encode(clientNonce),
          'udpPort': _udp!.port,
        }, master),
      );
      final ack = await openHandshake(await wire.next(), master);
      if (ack['type'] != 'helloAck' ||
          ack['version'] != protocolVersion ||
          ack['clientNonce'] != base64Encode(clientNonce)) {
        throw const FormatException('配对失败。');
      }
      final keys = await SessionKeys.derive(
        master,
        clientNonce,
        base64Decode(ack['nonce'] as String),
      );
      wire.transmit = PacketCipher(keys.clientTcp);
      wire.receive = PacketCipher(keys.serverTcp);
      await wire.send({'type': 'ready'});
      final connected = await wire.receive!.decrypt(await wire.next());
      if (connected == null ||
          jsonDecode(utf8.decode(connected))['type'] != 'connected') {
        throw const FormatException('连接确认失败。');
      }
      if (generation != _generation) throw const SocketException('连接已取消。');
      _wire = wire;
      _handshakes.remove(wire);
      _mouseCipher = PacketCipher(keys.mouse);
      _remoteAddress = socket.remoteAddress;
      _remoteUdpPort = ack['udpPort'] as int;
      _activate(wire);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _activate(_Wire wire) {
    unawaited(diagnostics.start());
    latencyMs = null;
    sentPackets = receivedPackets = _previousSent = _previousReceived = 0;
    _rateSince = DateTime.now();
    _lastReceived = DateTime.now();
    status = '已连接 ${wire.socket.remoteAddress.address}';
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_disposed || !identical(wire, _wire)) return;
      final elapsed = DateTime.now().difference(_rateSince).inMilliseconds;
      if (elapsed >= 1000) {
        metrics.value = (
          ((sentPackets - _previousSent) * 1000 / elapsed).round(),
          ((receivedPackets - _previousReceived) * 1000 / elapsed).round(),
          latencyMs,
        );
        _previousSent = sentPackets;
        _previousReceived = receivedPackets;
        _rateSince = DateTime.now();
      }
      if (DateTime.now().difference(_lastReceived).inMilliseconds > 1800) {
        _lost('连接超时');
      } else {
        wire
            .send({
              'type': 'ping',
              'time': DateTime.now().microsecondsSinceEpoch,
              if (!_receiver && _latestMotion != null)
                'motion': _latestMotion!.toJson(),
            })
            .catchError((Object _) {
              if (identical(wire, _wire)) _lost('连接已断开');
            });
      }
    });
    _changed();
    unawaited(_readControl(wire));
  }

  Future<void> _readControl(_Wire wire) async {
    try {
      while (!wire.closed && await wire.incoming.moveNext()) {
        final plain = await wire.receive!.decrypt(wire.incoming.current);
        if (plain == null) throw const FormatException('重复控制帧。');
        final json = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(plain)) as Map,
        );
        _lastReceived = DateTime.now();
        switch (json['type']) {
          case 'ping':
            if (_receiver && capturing) await onHeartbeat?.call();
            if (_receiver && json['motion'] is Map) {
              diagnostics.count('tcpMotionFallback');
              _acceptMotion(
                MotionFrame.fromJson(
                  Map<String, dynamic>.from(json['motion'] as Map),
                ),
              );
            }
            await wire.send({'type': 'pong', 'time': json['time']});
          case 'pong':
            latencyMs =
                (DateTime.now().microsecondsSinceEpoch -
                    (json['time'] as int)) /
                1000;
            if (_receiver && capturing) await onHeartbeat?.call();
          case 'begin':
            if (!_receiver) throw const FormatException('Invalid role');
            await _end();
            final id = json['capture'] as String;
            MotionFrame(id, 0, 0, 0).validate();
            try {
              await onBegin?.call(id);
              _capture = id;
              _appliedEpoch = 0;
              await wire.send({'type': 'begun', 'capture': id});
              _changed();
            } catch (error) {
              await wire.send({'type': 'rejected', 'message': '$error'});
            }
          case 'begun':
            if (json['capture'] == _capture) {
              _startAck?.complete();
              _startAck = null;
            }
          case 'rejected':
            _startAck?.completeError(
              StateError(json['message'] as String? ?? '被控端未允许输入。'),
            );
            _startAck = null;
            _capture = null;
          case 'end':
            if (json['capture'] == _capture) {
              await _end();
              if (!_receiver) onCaptureEnded?.call();
              _changed();
            }
          case 'events':
            if (!_receiver || json['capture'] != _capture) break;
            final events = (json['events'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            if (events.length > 256) {
              throw const FormatException('Too many input events');
            }
            var epoch = _appliedEpoch;
            for (final event in events) {
              if (event['epoch'] != ++epoch ||
                  !['key', 'button', 'wheel'].contains(event['kind'])) {
                throw const FormatException('输入事件顺序错误。');
              }
              MotionFrame.fromJson({...event, 'capture': _capture});
            }
            final capture = _capture!;
            _handlingEvents = true;
            try {
              await _delivery;
              if (_capture == capture) {
                await onInput?.call(capture, events);
                if (_capture == capture) _appliedEpoch = epoch;
              }
            } finally {
              _handlingEvents = false;
            }
            _flushReceive();
          default:
            throw const FormatException('Unknown control message');
        }
      }
    } catch (_) {
      if (identical(wire, _wire)) await _lost('连接已断开');
    } finally {
      if (identical(wire, _wire)) await _lost('连接已断开');
    }
  }

  Future<void> beginCapture() async {
    if (!connected || _receiver) throw StateError('请先连接被控端。');
    await endCapture();
    _capture = randomHex();
    final ack = Completer<void>();
    _startAck = ack;
    try {
      final sent = _wire!.send({'type': 'begin', 'capture': _capture});
      await Future.wait([sent, ack.future.timeout(const Duration(seconds: 4))]);
    } catch (_) {
      if (identical(_startAck, ack)) _startAck = null;
      await endCapture();
      rethrow;
    }
  }

  void sendInput(Map<String, dynamic> frame) {
    if (_receiver || !connected || _capture == null) return;
    final motion = MotionFrame(
      _capture!,
      frame['sequence'] as int,
      (frame['x'] as num).toDouble(),
      (frame['y'] as num).toDouble(),
      frame['epoch'] as int,
    );
    final events = (frame['events'] as List?) ?? [];
    _latestMotion = motion;
    if (events.isNotEmpty) {
      // Every reliable event includes its preceding motion and an epoch barrier.
      // Later UDP motion waits until that button/key transition is applied.
      final wire = _wire!;
      wire
          .send({'type': 'events', 'capture': _capture, 'events': events})
          .catchError((Object _) {
            if (identical(wire, _wire)) _lost('输入发送失败');
          });
    }
    _pendingSend = motion;
    if (!_sendingMouse) unawaited(_flushSend());
  }

  Future<void> _flushSend() async {
    _sendingMouse = true;
    final generation = _generation;
    try {
      while (_pendingSend != null && connected && generation == _generation) {
        final motion = _pendingSend!;
        _pendingSend = null;
        final cipher = _mouseCipher!;
        final packet = await cipher.encrypt(motion.encode());
        if (generation != _generation || motion.capture != _capture) break;
        _udp?.send(packet, _remoteAddress!, _remoteUdpPort);
        ++sentPackets;
      }
    } catch (_) {
      await _lost('鼠标发送失败');
    } finally {
      _sendingMouse = false;
      if (_pendingSend != null && connected && !_receiver) {
        unawaited(_flushSend());
      }
    }
  }

  void _receiveUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? packet;
    while ((packet = _udp?.receive()) != null) {
      final data = packet!;
      diagnostics.count('udpRead');
      diagnostics.gap('udpArrivalGapUs');
      if (!connected ||
          !_receiver ||
          !capturing ||
          data.address.address != _remoteAddress?.address ||
          data.port != _remoteUdpPort ||
          data.data.length != 76) {
        diagnostics.count('udpFiltered');
        continue;
      }
      if (InputDiagnostics.enabled) {
        diagnostics.udpCounter(ByteData.sublistView(data.data).getUint64(4));
      }
      final generation = _generation;
      final capture = _capture;
      final cipher = _mouseCipher!;
      unawaited(() async {
        final started = diagnostics.now;
        try {
          final plain = await cipher.decrypt(data.data);
          diagnostics.timing('decryptUs', diagnostics.now - started);
          if (plain == null ||
              generation != _generation ||
              capture != _capture) {
            diagnostics.count('udpReplayOrSessionRejected');
            return;
          }
          final motion = MotionFrame.decode(plain);
          ++receivedPackets;
          diagnostics.count('udpAccepted');
          _acceptMotion(motion);
        } catch (_) {
          diagnostics.count('udpDecryptOrDecodeError');
          /* Unauthenticated/corrupt datagrams never change state. */
        }
      }());
    }
  }

  bool _delivering = false;
  void _acceptMotion(MotionFrame motion) {
    if (motion.capture != _capture || motion.epoch < _appliedEpoch) {
      diagnostics.count('motionStaleSessionOrEpoch');
      return;
    }
    if (motion.epoch > _appliedEpoch) {
      diagnostics.count('motionWaitingForTcpEpoch');
    }
    if (_pendingReceive != null) diagnostics.count('motionCoalesced');
    if (_pendingReceive == null ||
        motion.sequence > _pendingReceive!.sequence) {
      _pendingReceive = motion;
      _pendingReceiveAt = diagnostics.now;
    }
    _flushReceive();
  }

  void _flushReceive() {
    if (_delivering ||
        _handlingEvents ||
        _pendingReceive == null ||
        _pendingReceive!.epoch != _appliedEpoch) {
      return;
    }
    final motion = _pendingReceive!;
    diagnostics.timing(
      'pendingToDeliveryUs',
      diagnostics.now - _pendingReceiveAt,
    );
    final generation = _generation;
    _pendingReceive = null;
    _delivering = true;
    _delivery = () async {
      try {
        if (_capture == motion.capture) {
          final started = diagnostics.now;
          diagnostics.gap('deliveryStartGapUs');
          await onInput?.call(motion.capture, [
            {...motion.toJson(), 'kind': 'motion'},
          ]);
          diagnostics.timing('platformRoundTripUs', diagnostics.now - started);
          diagnostics.count('motionDelivered');
        }
      } catch (_) {
        if (generation == _generation && _capture == motion.capture) {
          await _lost('输入注入失败');
        }
      } finally {
        _delivering = false;
      }
    }();
    unawaited(_delivery.then((_) => _flushReceive()));
  }

  Future<void> _end() async {
    final wasCapturing = _capture != null;
    _capture = null;
    _pendingSend = _pendingReceive = null;
    _latestMotion = null;
    if (wasCapturing && _receiver) await onEnd?.call();
  }

  Future<void> endCapture() async {
    final capture = _capture;
    await _end();
    if (capture != null && connected) {
      try {
        await _wire!.send({'type': 'end', 'capture': capture});
      } catch (_) {
        /* native watchdog also releases */
      }
    }
    _changed();
  }

  Future<void> _lost(String message) async {
    if (_closing) return;
    final hadConnection = connected;
    await close(keepListener: _receiver);
    status = message;
    _changed();
    if (hadConnection) onConnectionLost?.call();
  }

  Future<void> close({bool keepListener = false}) async {
    if (_closing) return;
    _closing = true;
    diagnostics.stop();
    ++_generation;
    _heartbeat?.cancel();
    _heartbeat = null;
    _startAck?.completeError(const SocketException('连接已关闭。'));
    _startAck = null;
    try {
      await _end();
    } finally {
      _wire?.close();
      _wire = null;
      for (final wire in _handshakes.toList()) {
        wire.close();
      }
      _handshakes.clear();
      _mouseCipher = null;
      if (!keepListener) {
        await _server?.close();
        _server = null;
        _udp?.close();
        _udp = null;
      }
      status = keepListener ? '等待连接' : '未连接';
      _closing = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    metrics.dispose();
    super.dispose();
  }
}
