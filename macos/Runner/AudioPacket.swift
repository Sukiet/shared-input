import Foundation
import CryptoKit

enum AudioPacket {
  static let frames = 240
  static let pcmBytes = frames * 4

  static func key(_ text: String) -> Data? {
    guard text.count == 64 else { return nil }
    let chars = Array(text.utf8)
    guard chars.count == 64 else { return nil }
    func digit(_ value: UInt8) -> UInt8? {
      if value >= 48 && value <= 57 { return value - 48 }
      if value >= 97 && value <= 102 { return value - 97 + 10 }
      return nil
    }
    var bytes = Data(capacity: 32)
    for index in stride(from: 0, to: chars.count, by: 2) {
      guard let high = digit(chars[index]), let low = digit(chars[index + 1]) else { return nil }
      bytes.append((high << 4) | low)
    }
    return bytes
  }

  static func seal(_ pcm: Data, sequence: UInt64, key: SymmetricKey) throws -> Data {
    guard pcm.count == pcmBytes && sequence != 0 else { throw AudioPacketError.invalidFrame }
    var header = Data("SIA1".utf8)
    var counter = sequence.bigEndian
    withUnsafeBytes(of: &counter) { header.append(contentsOf: $0) }
    var count = UInt32(frames).bigEndian
    withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }
    let nonce = try AES.GCM.Nonce(data: header.prefix(12))
    let sealed = try AES.GCM.seal(pcm, using: key, nonce: nonce, authenticating: header)
    var packet = header
    packet.append(sealed.ciphertext)
    packet.append(sealed.tag)
    return packet
  }
}
enum AudioPacketError: Error { case invalidFrame }
