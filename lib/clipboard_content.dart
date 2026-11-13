import 'dart:convert';
import 'dart:typed_data';

const maxClipboardImageBytes = 32 * 1024 * 1024;
const maxClipboardTextBytes = 1024 * 1024;
const maxClipboardPixels = 32 * 1024 * 1024;

bool validClipboardId(dynamic value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

bool validClipboardBytes(String kind, Uint8List bytes) {
  if (kind == 'text') {
    if (bytes.length > maxClipboardTextBytes) return false;
    try {
      return !utf8.decode(bytes).contains('\u0000');
    } on FormatException {
      return false;
    }
  }
  if (kind != 'png' ||
      bytes.length < 33 ||
      bytes.length > maxClipboardImageBytes) {
    return false;
  }
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var i = 0; i < signature.length; ++i) {
    if (bytes[i] != signature[i]) return false;
  }
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(8) != 13 || view.getUint32(12) != 0x49484452) return false;
  final width = view.getUint32(16), height = view.getUint32(20);
  return width > 0 &&
      height > 0 &&
      width <= maxClipboardPixels &&
      height <= maxClipboardPixels &&
      width * height <= maxClipboardPixels;
}

class ClipboardOffer implements Comparable<ClipboardOffer> {
  const ClipboardOffer({
    required this.id,
    required this.actor,
    required this.clock,
    required this.kind,
    this.length = 0,
    this.hash = '',
  });
  final String id, actor, kind, hash;
  final int clock, length;

  Map<String, dynamic> toJson() => {
    'type': 'clipboardOffer',
    'id': id,
    'actor': actor,
    'clock': clock,
    'kind': kind,
    'length': length,
    'hash': hash,
  };

  static ClipboardOffer fromJson(Map<String, dynamic> value) {
    final id = value['id'], actor = value['actor'], clock = value['clock'];
    final kind = value['kind'], length = value['length'], hash = value['hash'];
    if (!validClipboardId(id) ||
        !validClipboardId(actor) ||
        clock is! int ||
        clock <= 0 ||
        clock > 0x1fffffffffffff ||
        !['text', 'png', 'none'].contains(kind) ||
        length is! int ||
        length < 0 ||
        length >
            (kind == 'text' ? maxClipboardTextBytes : maxClipboardImageBytes) ||
        hash is! String ||
        (kind == 'none'
            ? (length != 0 || hash.isNotEmpty)
            : !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))) {
      throw const FormatException('Invalid clipboard offer');
    }
    return ClipboardOffer(
      id: id as String,
      actor: actor as String,
      clock: clock,
      kind: kind as String,
      length: length,
      hash: hash,
    );
  }

  @override
  int compareTo(ClipboardOffer other) {
    final comparison = clock.compareTo(other.clock);
    return comparison != 0 ? comparison : actor.compareTo(other.actor);
  }
}
