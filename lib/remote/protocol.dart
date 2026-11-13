import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

const protocolVersion = 1;
const maxControlFrame = 65536;
final _aead = Chacha20.poly1305Aead();
final _aad = utf8.encode('shared-input/1');

List<int> secureBytes(int count) {
  final random = Random.secure();
  return List.generate(count, (_) => random.nextInt(256));
}

Future<SecretKey> pairingKey(String text) async {
  if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(text.trim())) {
    throw const FormatException('连接码应为被控端显示的 32 位字符。');
  }
  return SecretKey(
    (await Sha256().hash(utf8.encode(text.trim().toLowerCase()))).bytes,
  );
}

Future<Uint8List> seal(List<int> bytes, SecretKey key, List<int> nonce) async {
  final box = await _aead.encrypt(
    bytes,
    secretKey: key,
    nonce: nonce,
    aad: _aad,
  );
  return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> open(List<int> packet, SecretKey key) async {
  if (packet.length < 28 || packet.length > maxControlFrame) {
    throw const FormatException('Invalid encrypted frame');
  }
  final plain = await _aead.decrypt(
    SecretBox(
      packet.sublist(12, packet.length - 16),
      nonce: packet.sublist(0, 12),
      mac: Mac(packet.sublist(packet.length - 16)),
    ),
    secretKey: key,
    aad: _aad,
  );
  return Uint8List.fromList(plain);
}

Future<Uint8List> sealHandshake(Map<String, dynamic> json, SecretKey key) =>
    seal(utf8.encode(jsonEncode(json)), key, secureBytes(12));
Future<Map<String, dynamic>> openHandshake(
  List<int> packet,
  SecretKey key,
) async => Map<String, dynamic>.from(
  jsonDecode(utf8.decode(await open(packet, key))) as Map,
);

class SessionKeys {
  SessionKeys(this.clientTcp, this.serverTcp, this.mouse);
  final SecretKey clientTcp, serverTcp, mouse;
  static Future<SessionKeys> derive(
    SecretKey master,
    List<int> clientNonce,
    List<int> serverNonce,
  ) async {
    if (clientNonce.length != 32 || serverNonce.length != 32) {
      throw const FormatException('Invalid handshake nonce');
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> key(String label) => hkdf.deriveKey(
      secretKey: master,
      nonce: [...clientNonce, ...serverNonce],
      info: utf8.encode('shared-input/1/$label'),
    );
    return SessionKeys(
      await key('client-tcp'),
      await key('server-tcp'),
      await key('mouse-udp'),
    );
  }
}

class PacketCipher {
  PacketCipher(this.key);
  final SecretKey key;
  int _sending = 0, _received = 0;
  Future<Uint8List> encrypt(List<int> plain) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, ++_sending);
    return seal(plain, key, nonce);
  }

  Future<Uint8List?> decrypt(Uint8List packet) async {
    if (packet.length < 28) return null;
    final plain = await open(
      packet,
      key,
    ); // Authenticate before advancing counter.
    final counter = ByteData.sublistView(packet).getUint64(4);
    if (counter <= _received) return null;
    _received = counter;
    return plain;
  }
}

class MotionFrame {
  const MotionFrame(
    this.capture,
    this.sequence,
    this.x,
    this.y, [
    this.epoch = 0,
  ]);
  final String capture;
  final int sequence;
  final int epoch;
  final double x, y;
  Map<String, dynamic> toJson() => {
    'capture': capture,
    'sequence': sequence,
    'x': x,
    'y': y,
    'epoch': epoch,
  };
  static MotionFrame fromJson(Map<String, dynamic> json) {
    final frame = MotionFrame(
      json['capture'] as String,
      json['sequence'] as int,
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      json['epoch'] as int? ?? 0,
    );
    frame.validate();
    return frame;
  }

  void validate() {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(capture) ||
        sequence < 0 ||
        epoch < 0 ||
        !x.isFinite ||
        !y.isFinite ||
        x.abs() > 1e12 ||
        y.abs() > 1e12) {
      throw const FormatException('Invalid mouse frame');
    }
  }

  Uint8List encode() {
    validate();
    final data = ByteData(48);
    for (var i = 0; i < 16; i++) {
      data.setUint8(
        i,
        int.parse(capture.substring(i * 2, i * 2 + 2), radix: 16),
      );
    }
    data.setUint64(16, sequence);
    data.setFloat64(24, x);
    data.setFloat64(32, y);
    data.setUint64(40, epoch);
    return data.buffer.asUint8List();
  }

  static MotionFrame decode(Uint8List bytes) {
    if (bytes.length != 48) {
      throw const FormatException('Invalid mouse frame size');
    }
    final data = ByteData.sublistView(bytes);
    final id = bytes
        .take(16)
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    final frame = MotionFrame(
      id,
      data.getUint64(16),
      data.getFloat64(24),
      data.getFloat64(32),
      data.getUint64(40),
    );
    frame.validate();
    return frame;
  }
}

class MotionTracker {
  String? capture;
  int sequence = -1;
  double x = 0, y = 0;
  void begin(String id) {
    capture = id;
    sequence = -1;
    x = y = 0;
  }

  void end() {
    capture = null;
    sequence = -1;
    x = y = 0;
  }

  ({double dx, double dy})? accept(MotionFrame frame) {
    if (frame.capture != capture || frame.sequence <= sequence) return null;
    final delta = (dx: frame.x - x, dy: frame.y - y);
    sequence = frame.sequence;
    x = frame.x;
    y = frame.y;
    return delta;
  }
}

// TCP is a byte stream: preserve partial headers/bodies and parse multiple
// messages from one read. Refuse oversized lengths before allocating a body.
class FrameDecoder {
  Uint8List _pending = Uint8List(0);
  List<Uint8List> add(List<int> chunk) {
    _pending = Uint8List.fromList([..._pending, ...chunk]);
    final frames = <Uint8List>[];
    var consumed = 0;
    while (_pending.length - consumed >= 4) {
      final length = ByteData.sublistView(
        _pending,
        consumed,
        consumed + 4,
      ).getUint32(0);
      if (length < 28 || length > maxControlFrame) {
        throw const FormatException('Invalid TCP frame length');
      }
      if (_pending.length - consumed < length + 4) break;
      frames.add(
        Uint8List.fromList(
          _pending.sublist(consumed + 4, consumed + 4 + length),
        ),
      );
      consumed += 4 + length;
    }
    if (consumed != 0) {
      _pending = Uint8List.fromList(_pending.sublist(consumed));
    }
    return frames;
  }
}

Uint8List frameTcp(Uint8List packet) {
  if (packet.length > maxControlFrame) {
    throw const FormatException('TCP frame too large');
  }
  final result = Uint8List(packet.length + 4);
  ByteData.sublistView(result).setUint32(0, packet.length);
  result.setRange(4, result.length, packet);
  return result;
}
