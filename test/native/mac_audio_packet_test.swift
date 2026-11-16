import Foundation
import CryptoKit

@main
struct AudioPacketTest {
  static func main() throws {
    let lines = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")
    guard let key = AudioPacket.key(String(lines[0])) else { fatalError("invalid fixture key") }
    let pcm = Data((0..<960).map { UInt8($0 % 256) })
    let actual = try AudioPacket.seal(pcm, sequence: 7, key: SymmetricKey(data: key))
    let hex = actual.map { String(format: "%02x", $0) }.joined()
    precondition(hex == String(lines[1]), "CryptoKit must match independent AES-GCM fixture and Windows decoder")
    precondition(AudioPacket.key("not-a-key") == nil)
    print("Mac audio packet fixture passed")
  }
}
