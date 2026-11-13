import Cocoa
import FlutterMacOS
import ImageIO

// Pasteboard access stays on the main queue; ImageIO conversion runs separately
// and never acquires the input receiver's motion/keyboard lock.
final class ClipboardBridge {
  private let queue = DispatchQueue(label: "shared-input-clipboard", qos: .utility)
  private let originType = NSPasteboard.PasteboardType("app.shared-input.clipboard-origin.v1")
  private var enabled = false
  private var generation = 0
  private var permissionAttempted = false
  private let imageLimit = 32 * 1024 * 1024
  private let textLimit = 1024 * 1024
  private static let pixelLimit = 32 * 1024 * 1024

  func reset() { enabled = false; generation += 1 }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "clipboardConfigure":
      enabled = args["enabled"] as? Bool ?? false
      generation += 1
      permissionAttempted = false
      result(nil)
    case "clipboardCancel":
      generation += 1
      result(nil)
    case "clipboardRead":
      read(args, result)
    case "clipboardWrite":
      write(args, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func permission(_ board: NSPasteboard, _ result: @escaping FlutterResult) -> Bool {
    if #available(macOS 15.4, *) {
      switch board.accessBehavior {
      case .alwaysDeny:
        result(FlutterError(code: "clipboard_denied",
          message: "请在系统设置中允许 Shared Input 读取剪贴板，然后重新开启同步。", details: nil))
        return false
      case .ask, .default:
        if permissionAttempted {
          result(FlutterError(code: "clipboard_permission",
            message: "请在系统设置中始终允许 Shared Input 读取剪贴板，然后重新开启同步。", details: nil))
          return false
        }
        permissionAttempted = true
      default: break
      }
    }
    return true
  }

  private func read(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard enabled else { result(nil); return }
    let board = NSPasteboard.general
    let revision = board.changeCount
    if args["after"] as? String == String(revision) { result(nil); return }
    let epoch = generation
    var snapshot: [String: Any] = ["revision": String(revision), "kind": "none"]
    let types = board.types ?? []
    if types.contains(.fileURL) { result(snapshot); return }
    let imageType: NSPasteboard.PasteboardType? = types.contains(.png) ? .png : (types.contains(.tiff) ? .tiff : nil)
    if imageType == nil && !types.contains(.string) { result(snapshot); return }
    guard permission(board, result) else { return }
    if types.contains(originType), let origin = board.string(forType: originType) { snapshot["origin"] = origin }
    let imageData = imageType.flatMap { board.data(forType: $0) }
    if let data = imageData, !data.isEmpty {
      guard data.count <= imageLimit * 4 else { result(snapshot); return }
      let base = snapshot
      queue.async { [weak self] in
        let png = autoreleasepool { Self.png(data) }
        DispatchQueue.main.async {
          guard let self = self, self.enabled, self.generation == epoch,
                board.changeCount == revision else { result(nil); return }
          var snapshot = base
          if let png = png, png.count <= self.imageLimit {
            snapshot["kind"] = "png"
            snapshot["data"] = FlutterStandardTypedData(bytes: png)
          }
          result(snapshot)
        }
      }
    } else {
      if let text = board.string(forType: .string), !text.contains("\0"),
         text.utf8.count <= textLimit {
        snapshot["kind"] = "text"; snapshot["text"] = text
      }
      result(board.changeCount == revision ? snapshot : nil)
    }
  }

  private func write(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard enabled, let kind = args["kind"] as? String,
          let data = (args["data"] as? FlutterStandardTypedData)?.data,
          let expected = args["expected"] as? String,
          let origin = args["origin"] as? String, origin.count == 32,
          origin.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      result(["applied": false]); return
    }
    let epoch = generation
    func apply(_ text: String?, _ png: Data?) {
      let board = NSPasteboard.general
      guard self.enabled, self.generation == epoch, String(board.changeCount) == expected else {
        result(["applied": false]); return
      }
      let item = NSPasteboardItem()
      let prepared: Bool
      if let text = text { prepared = item.setString(text, forType: .string) }
      else if let png = png { prepared = item.setData(png, forType: .png) }
      else { result(["applied": false]); return }
      guard prepared, item.setString(origin, forType: self.originType) else {
        result(["applied": false]); return
      }
      board.clearContents()
      result(["applied": board.writeObjects([item])])
    }
    if kind == "text", data.count <= textLimit, let text = String(data: data, encoding: .utf8),
       !text.contains("\0") {
      apply(text, nil)
    } else if kind == "png", data.count <= imageLimit {
      queue.async {
        let decoded = autoreleasepool { Self.image(data) != nil }
        DispatchQueue.main.async {
          if decoded { apply(nil, data) } else { result(["applied": false]) }
        }
      }
    } else { result(["applied": false]) }
  }

  static func image(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
          width > 0, height > 0, width <= Int64(pixelLimit), height <= Int64(pixelLimit),
          width * height <= Int64(pixelLimit) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
  }

  static func png(_ data: Data) -> Data? {
    guard let image = image(data) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
