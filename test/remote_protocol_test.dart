import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_input/remote/protocol.dart';

void main() {
  const id = '0123456789abcdef0123456789abcdef';
  test('TCP decoder handles fragmented headers and coalesced messages', () {
    final first = Uint8List.fromList(List.filled(35, 7));
    final second = Uint8List.fromList(List.filled(40, 9));
    final bytes = [...frameTcp(first), ...frameTcp(second)];
    final decoder = FrameDecoder();
    expect(decoder.add(bytes.take(2).toList()), isEmpty);
    expect(decoder.add(bytes.sublist(2, 10)), isEmpty);
    expect(decoder.add(bytes.sublist(10)), [first, second]);
    final bad = ByteData(4)..setUint32(0, maxControlFrame + 1);
    expect(
      () => FrameDecoder().add(bad.buffer.asUint8List()),
      throwsFormatException,
    );
  });
  test(
    'binary mouse frame preserves fractional cumulative motion and event epoch',
    () {
      const frame = MotionFrame(id, 9000, 0.0001, -0.0017, 25);
      expect(frame.encode().length, 48);
      expect(MotionFrame.decode(frame.encode()).toJson(), frame.toJson());
      expect(
        () => MotionFrame(id, 1, double.nan, 0).encode(),
        throwsFormatException,
      );
    },
  );
  test(
    'cumulative motion repairs packet loss and ignores duplicates and old captures',
    () {
      final tracker = MotionTracker()..begin(id);
      expect(tracker.accept(const MotionFrame(id, 1, 1, 2)), (
        dx: 1.0,
        dy: 2.0,
      ));
      expect(tracker.accept(const MotionFrame(id, 10, 7, -2)), (
        dx: 6.0,
        dy: -4.0,
      ));
      expect(tracker.accept(const MotionFrame(id, 8, 6, -1)), isNull);
      expect(tracker.accept(const MotionFrame(id, 10, 7, -2)), isNull);
      tracker.end();
      expect(tracker.accept(const MotionFrame(id, 11, 9, 0)), isNull);
    },
  );
  test(
    'authenticated encryption rejects tampering, replay and different keys',
    () async {
      final master = await pairingKey('a' * 32);
      final keys = await SessionKeys.derive(
        master,
        List.filled(32, 1),
        List.filled(32, 2),
      );
      final sender = PacketCipher(keys.mouse),
          receiver = PacketCipher(keys.mouse);
      final first = await sender.encrypt([1, 2, 3]);
      final tampered = Uint8List.fromList(first)..[14] ^= 1;
      await expectLater(receiver.decrypt(tampered), throwsA(anything));
      expect(await receiver.decrypt(first), [1, 2, 3]);
      expect(await receiver.decrypt(first), isNull);
      final second = await sender.encrypt([4, 5, 6]);
      await expectLater(
        PacketCipher(keys.clientTcp).decrypt(second),
        throwsA(anything),
      );
      expect(await receiver.decrypt(second), [4, 5, 6]);
    },
  );
}
