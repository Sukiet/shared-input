import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../settings.dart';
import '../scroll_speed.dart';
import 'protocol.dart';
import 'wire.dart';
import 'clipboard_channel.dart';
import 'input_diagnostics.dart';

class LanSession extends ChangeNotifier {
  final clipboard = ClipboardChannel();
  bool audioCaptureSupported = false,
      audioRenderSupported = false,
      supportsAudio = false;
  void Function(Map<String, dynamic>)? onAudioControl;
  String? get remoteHost => _wire?.socket.remoteAddress.address;
  Future<void> sendAudioControl(Map<String, dynamic> message) async {
    final wire = _wire;
    if (wire == null || !connected || !supportsAudio) {
      throw StateError('音频连接不可用');
    }
    await wire.send(message);
  }

  bool clipboardSupported = false, supportsClipboard = false;
  bool _clipboardOpening = false;
  void Function(Map<String, dynamic> message)? onClipboardControl;
  bool dragPreviewSupported = false, supportsDragPreview = false;
  FutureOr<void> Function(Map<String, dynamic>)? onDragPreviewControl;
  Future<void> sendDragPreviewControl(Map<String, dynamic> message) async {
    if (!connected || !supportsDragPreview) return;
    await _wire!.send(message);
  }

  int get connectionGeneration => _generation;
  bool get receiving => _receiver;
  final diagnostics = InputDiagnostics();
  double scrollSpeed = ScrollSpeed.defaultValue;
  Future<void> Function(String capture)? onBegin;
  Future<void> Function(String capture, Map<String, dynamic> options)?
  onBeginWithOptions;
  Future<Map<String, dynamic>?> Function()? onPointerInfo;
  Future<void> Function(Map<String, dynamic> pointer)? onPointerFeedback;
  bool supportsPrediction = false;
  bool supportsEdge = false;
  bool supportsLayout = false;
  Map<String, dynamic>? remoteDisplay;
  bool _edgeCapture = false, _pollingPointer = false;
  Timer? _pointerTimer;
  Future<void> Function(String capture, List<Map<String, dynamic>> frames)?
  onInput;
  Future<void> Function()? onEnd;
  Future<void> Function(String? reason)? onEndWithReason;
  Future<void> Function()? onHeartbeat;
  VoidCallback? onConnectionLost;
  VoidCallback? onCaptureEnded;

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  EncryptedWire? _wire;
  final Set<EncryptedWire> _handshakes = {};
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

  static Map<String, dynamic>? _displayInfo(dynamic value) {
    if (value is! Map) return null;
    final width = value['width'], height = value['height'];
    if (width is! num ||
        height is! num ||
        !width.isFinite ||
        !height.isFinite ||
        width <= 1 ||
        height <= 1 ||
        width > 100000 ||
        height > 100000) {
      return null;
    }
    return {'width': width.toDouble(), 'height': height.toDouble()};
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
        final wire = EncryptedWire(socket);
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
          Map<String, dynamic>? display;
          try {
            display = _displayInfo(await onPointerInfo?.call());
          } catch (_) {
            /* Optional metadata. */
          }
          await wire.raw(
            await sealHandshake({
              'type': 'helloAck',
              'version': protocolVersion,
              'clientNonce': hello['nonce'],
              'nonce': base64Encode(serverNonce),
              'udpPort': _udp!.port,
              'capabilities': [
                'motion-prediction-v1',
                if (clipboardSupported) 'clipboard-v1',
                if (dragPreviewSupported) 'edge-drag-preview-v1',
                if (audioCaptureSupported) 'audio-capture-pcm-v1',
                if (audioRenderSupported) 'audio-render-pcm-v1',
                if (onPointerInfo != null) 'edge-pointer-v1',
                if (display != null && onBeginWithOptions != null)
                  'edge-layout-v1',
              ],
              ...?(display == null ? null : {'display': display}),
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
          supportsPrediction =
              (hello['capabilities'] as List?)?.contains(
                'motion-prediction-v1',
              ) ==
              true;
          supportsClipboard =
              clipboardSupported &&
              (hello['capabilities'] as List?)?.contains('clipboard-v1') ==
                  true;
          supportsDragPreview =
              dragPreviewSupported &&
              (hello['capabilities'] as List?)?.contains(
                    'edge-drag-preview-v1',
                  ) ==
                  true;
          supportsAudio =
              audioCaptureSupported &&
              (hello['capabilities'] as List?)?.contains(
                    'audio-render-pcm-v1',
                  ) ==
                  true;
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
      final wire = EncryptedWire(socket);
      _handshakes.add(wire);
      final clientNonce = secureBytes(32);
      await wire.raw(
        await sealHandshake({
          'type': 'hello',
          'version': protocolVersion,
          'nonce': base64Encode(clientNonce),
          'udpPort': _udp!.port,
          'capabilities': [
            'motion-prediction-v1',
            if (clipboardSupported) 'clipboard-v1',
            if (dragPreviewSupported) 'edge-drag-preview-v1',
            if (audioCaptureSupported) 'audio-capture-pcm-v1',
            if (audioRenderSupported) 'audio-render-pcm-v1',
          ],
        }, master),
      );
      final ack = await openHandshake(await wire.next(), master);
      if (ack['type'] != 'helloAck' ||
          ack['version'] != protocolVersion ||
          ack['clientNonce'] != base64Encode(clientNonce)) {
        throw const FormatException('配对失败。');
      }
      supportsEdge =
          (ack['capabilities'] as List?)?.contains('edge-pointer-v1') == true;
      supportsDragPreview =
          dragPreviewSupported &&
          (ack['capabilities'] as List?)?.contains('edge-drag-preview-v1') ==
              true;
      supportsPrediction =
          (ack['capabilities'] as List?)?.contains('motion-prediction-v1') ==
          true;
      supportsClipboard =
          clipboardSupported &&
          (ack['capabilities'] as List?)?.contains('clipboard-v1') == true;
      supportsAudio =
          audioRenderSupported &&
          (ack['capabilities'] as List?)?.contains('audio-capture-pcm-v1') ==
              true;
      remoteDisplay = _displayInfo(ack['display']);
      supportsLayout =
          remoteDisplay != null &&
          (ack['capabilities'] as List?)?.contains('edge-layout-v1') == true;
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

  void _activate(EncryptedWire wire) {
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
    if (_receiver && supportsClipboard) unawaited(_startClipboard(wire));
  }

  Future<void> _startClipboard(EncryptedWire wire) async {
    final key = randomHex();
    try {
      final port = await clipboard.listen(
        key: key,
        bindAddress: wire.socket.address.address,
        remoteAddress: wire.socket.remoteAddress.address,
      );
      if (identical(wire, _wire) && supportsClipboard) {
        await wire.send({'type': 'clipboardPort', 'port': port, 'key': key});
      }
    } catch (_) {
      /* Clipboard failure never interrupts input sharing. */
    }
  }

  Future<void> sendClipboardControl(Map<String, dynamic> message) async {
    if (!connected || !supportsClipboard) return;
    await _wire!.send(message);
  }

  Future<void> _readControl(EncryptedWire wire) async {
    try {
      while (!wire.closed && await wire.incoming.moveNext()) {
        final plain = await wire.receive!.decrypt(wire.incoming.current);
        if (plain == null) throw const FormatException('重复控制帧。');
        final json = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(plain)) as Map,
        );
        _lastReceived = DateTime.now();
        switch (json['type']) {
          case 'dragPreviewConfig':
          case 'dragPreviewState':
          case 'dragPreviewClear':
            if (supportsDragPreview) await onDragPreviewControl?.call(json);
          case 'audioStart':
          case 'audioStarted':
          case 'audioStop':
          case 'audioLease':
          case 'audioError':
            if (supportsAudio) onAudioControl?.call(json);
          case 'clipboardPort':
            if (!_receiver && supportsClipboard && !_clipboardOpening) {
              final port = json['port'], key = json['key'];
              if (port is! int ||
                  port <= 0 ||
                  port > 65535 ||
                  key is! String ||
                  !RegExp(r'^[a-f0-9]{32}$').hasMatch(key)) {
                throw const FormatException('Invalid clipboard endpoint');
              }
              _clipboardOpening = true;
              unawaited(
                clipboard
                    .connect(
                      key: key,
                      host: wire.socket.remoteAddress.address,
                      port: port,
                    )
                    .catchError((Object _) {}),
              );
            }
          case 'clipboardState':
          case 'clipboardOffer':
          case 'clipboardRequest':
            if (supportsClipboard) onClipboardControl?.call(json);
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
              final options = Map<String, dynamic>.from(
                json['options'] as Map? ?? {},
              );
              final entry = options['edgeEntryY'];
              final side = options['edgeEntrySide'] ?? 'left';
              if (!['left', 'right', 'top', 'bottom'].contains(side) ||
                  (entry == null && options.containsKey('edgeEntrySide')) ||
                  (side != 'left' && onBeginWithOptions == null)) {
                throw const FormatException('被控端不支持此显示屏布局。');
              }
              if (entry != null &&
                  (entry is! num ||
                      !entry.isFinite ||
                      entry < 0 ||
                      entry > 1 ||
                      onPointerInfo == null)) {
                throw const FormatException('被控端不支持边缘切换。');
              }
              if (onBeginWithOptions != null) {
                await onBeginWithOptions!(id, options);
              } else {
                await onBegin?.call(id);
              }
              _capture = id;
              _edgeCapture = entry != null;
              _appliedEpoch = 0;
              await wire.send({'type': 'begun', 'capture': id});
              if (_edgeCapture) {
                _pointerTimer = Timer.periodic(
                  const Duration(milliseconds: 16),
                  (_) => unawaited(_sendPointer()),
                );
                unawaited(_sendPointer());
              }
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
              final reason = json['reason'];
              await _end(
                reason: reason is String && reason.length <= 64 ? reason : null,
              );
              if (!_receiver) onCaptureEnded?.call();
              _changed();
            }
          case 'pointer':
            if (!_receiver && _edgeCapture && json['capture'] == _capture) {
              final pointer = Map<String, dynamic>.from(json['pointer'] as Map);
              for (final key in [
                'x',
                'y',
                'left',
                'top',
                'width',
                'height',
                'sequence',
              ]) {
                final value = pointer[key];
                if (value is! num || !value.isFinite || value.abs() > 1e12) {
                  throw const FormatException('无效的指针反馈。');
                }
              }
              await onPointerFeedback?.call(pointer);
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

  Future<void> beginCapture({
    double? edgeEntryY,
    String edgeEntrySide = 'left',
  }) async {
    if (!connected || _receiver) throw StateError('请先连接被控端。');
    if (edgeEntryY != null &&
        (!supportsEdge ||
            !edgeEntryY.isFinite ||
            edgeEntryY < 0 ||
            edgeEntryY > 1)) {
      throw StateError('请更新 Mac 被控端以支持边缘切换。');
    }
    if (!['left', 'right', 'top', 'bottom'].contains(edgeEntrySide) ||
        (edgeEntrySide != 'left' && (edgeEntryY == null || !supportsLayout))) {
      throw StateError('请更新 Mac 被控端以支持此显示屏布局。');
    }
    await endCapture();
    _capture = randomHex();
    _edgeCapture = edgeEntryY != null;
    final ack = Completer<void>();
    _startAck = ack;
    try {
      final sent = _wire!.send({
        'type': 'begin',
        'capture': _capture,
        if (edgeEntryY != null)
          'options': {
            'edgeEntryY': edgeEntryY,
            if (edgeEntrySide != 'left') 'edgeEntrySide': edgeEntrySide,
          },
      });
      await Future.wait([sent, ack.future.timeout(const Duration(seconds: 4))]);
    } catch (_) {
      if (identical(_startAck, ack)) _startAck = null;
      await endCapture();
      rethrow;
    }
  }

  Future<void> _sendPointer() async {
    if (_pollingPointer || !_receiver || !_edgeCapture || _capture == null) {
      return;
    }
    _pollingPointer = true;
    final capture = _capture;
    final wire = _wire;
    try {
      final pointer = await onPointerInfo?.call();
      if (pointer != null &&
          capture == _capture &&
          wire == _wire &&
          wire != null) {
        await wire.send({
          'type': 'pointer',
          'capture': capture,
          'pointer': {
            ...pointer,
            if (pointer['predicted'] == true) 'sequence': -1,
          },
        });
      }
    } catch (_) {
      if (capture == _capture) await _lost('指针反馈中断');
    } finally {
      _pollingPointer = false;
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
      frame['sampleTimeUs'] as int? ?? 0,
      frame['moving'] as bool? ?? true,
    );
    final events = [
      for (final event in (frame['events'] as List?) ?? [])
        if (event is Map && event['kind'] == 'wheel')
          {...event, 'scrollSpeed': scrollSpeed}
        else
          event,
    ];
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
        final packet = await cipher.encrypt(
          motion.encode(prediction: supportsPrediction),
        );
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
          (data.data.length != 76 &&
              !(supportsPrediction && data.data.length == 92))) {
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
        motion.sequence > _pendingReceive!.sequence ||
        (motion.sequence == _pendingReceive!.sequence &&
            motion.sampleTimeUs > _pendingReceive!.sampleTimeUs)) {
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

  Future<void> _end({String? reason}) async {
    _pointerTimer?.cancel();
    _pointerTimer = null;
    _edgeCapture = false;
    final wasCapturing = _capture != null;
    _capture = null;
    _pendingSend = _pendingReceive = null;
    _latestMotion = null;
    if (wasCapturing && _receiver) {
      if (onEndWithReason != null) {
        await onEndWithReason!(reason);
      } else {
        await onEnd?.call();
      }
    }
  }

  Future<void> endCapture({String? reason}) async {
    final capture = _capture;
    await _end(reason: reason);
    if (capture != null && connected) {
      try {
        await _wire!.send({
          'type': 'end',
          'capture': capture,
          'reason': ?reason,
        });
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
    supportsEdge = false;
    supportsDragPreview = false;
    supportsLayout = false;
    supportsClipboard = false;
    supportsAudio = false;
    _clipboardOpening = false;
    clipboard.close();
    remoteDisplay = null;
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
    clipboard.dispose();
    metrics.dispose();
    super.dispose();
  }
}
