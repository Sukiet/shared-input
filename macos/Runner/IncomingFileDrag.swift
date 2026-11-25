import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import ImageIO

struct IncomingDragItem {
  let id: String
  let name: String
  let folder: Bool
  let size: Int64
  let thumbnail: Data?
  var previewImage: NSImage? {
    guard let data = thumbnail, let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          (1...128).contains(width.intValue), (1...128).contains(height.intValue),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
  }
  var contentType: UTType {
    folder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
  }
  static func parse(_ value: [String: Any]) -> IncomingDragItem? {
    guard let id = value["id"] as? String, transferIdentifier(id),
          let name = value["name"] as? String, !name.isEmpty, name != ".", name != "..",
          name.count <= 1024, name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil,
          let folder = value["folder"] as? Bool, let size = value["size"] as? NSNumber,
          size.int64Value >= 0 else { return nil }
    var thumbnail: Data?
    if let text = value["thumbnail"] as? String, text.count <= 24 * 1024,
       let data = Data(base64Encoded: text), data.count <= 16 * 1024 { thumbnail = data }
    return IncomingDragItem(id: id, name: name, folder: folder, size: size.int64Value, thumbnail: thumbnail)
  }
}

func transferIdentifier(_ value: String) -> Bool {
  value.count == 32 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
}

private final class IncomingDragPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class FilePromiseWrite {
  let id: String
  let progress: Progress
  let signal = DispatchSemaphore(value: 0)
  let mutex = NSLock()
  var finished = false
  var error: Error?
  init(id: String, url: URL, item: IncomingDragItem) {
    self.id = id
    progress = Progress(totalUnitCount: item.folder ? -1 : max(1, item.size))
    progress.kind = .file
    progress.fileURL = url
    progress.fileOperationKind = .copying
    progress.isCancellable = true
    progress.isPausable = false
    progress.fileTotalCount = 1
    progress.fileCompletedCount = 0
  }
  func complete(_ error: Error?) {
    mutex.lock()
    guard !finished else { mutex.unlock(); return }
    finished = true; self.error = error
    mutex.unlock()
    signal.signal()
  }
}

/// AppKit owns drag hit testing, copy badges, Finder destination selection and
/// promise filename collision handling. Network/file writing remains in Dart's
/// independent worker. Only OS-issued promise URLs can become destinations.
final class IncomingFileDrag: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
  private let channel: FlutterMethodChannel
  private let writesQueue: OperationQueue = {
    let queue = OperationQueue(); queue.name = "shared-input-file-promises"
    queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated
    return queue
  }()
  private let mutex = NSLock()
  private var writes: [String: FilePromiseWrite] = [:]
  private var panel: IncomingDragPanel?
  private var session: NSDraggingSession?
  private var drag: String?
  private var providers: [NSFilePromiseProvider] = []
  private var released = false
  var sessionEnded: (() -> Void)?
  // A bounded retain set keeps promise delegates alive after a drop, while a
  // later screen crossing may already start a new drag.
  private var offered: [String: [String: IncomingDragItem]] = [:]

  init(channel: FlutterMethodChannel) { self.channel = channel; super.init() }

  func validate(_ raw: [String: Any]) -> Bool {
    guard let drag = raw["drag"] as? String, transferIdentifier(drag),
          let items = raw["items"] as? [[String: Any]], !items.isEmpty, items.count <= 128 else { return false }
    let parsed = items.compactMap(IncomingDragItem.parse)
    return parsed.count == items.count && Set(parsed.map { $0.id }).count == parsed.count
  }

  func start(_ raw: [String: Any], at quartz: CGPoint, mouseSource: CGEventSource?) -> Bool {
    guard validate(raw), session == nil,
          let id = raw["drag"] as? String, let values = raw["items"] as? [[String: Any]] else { return false }
    let items = values.compactMap(IncomingDragItem.parse)
    let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    let point = NSPoint(x: quartz.x, y: primaryHeight - quartz.y)
    let panel = IncomingDragPanel(contentRect: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
    panel.level = .floating; panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
    panel.contentView = view
    panel.orderFrontRegardless()
    self.panel = panel; self.drag = id
    mutex.lock(); released = false
    offered[id] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    if offered.count > 8, let first = offered.keys.first(where: { $0 != id }) { offered.removeValue(forKey: first) }
    mutex.unlock()
    providers = items.map { item in
      let provider = NSFilePromiseProvider(fileType: item.contentType.identifier, delegate: self)
      provider.userInfo = ["drag": id, "item": item.id]
      return provider
    }
    let draggingItems = zip(items, providers).enumerated().map { index, pair -> NSDraggingItem in
      let (item, provider) = pair
      let dragging = NSDraggingItem(pasteboardWriter: provider)
      let icon = item.previewImage ?? NSWorkspace.shared.icon(for: item.contentType)
      let offset = CGFloat(min(index, 4)) * 3
      dragging.draggingFrame = NSRect(x: offset, y: offset - 24, width: 240, height: 48)
      dragging.imageComponentsProvider = {
        let image = NSDraggingImageComponent(key: .icon)
        image.contents = icon; image.frame = NSRect(x: 0, y: 0, width: 48, height: 48)
        let label = NSDraggingImageComponent(key: .label)
        let text = NSImage(size: NSSize(width: 190, height: 24), flipped: false) { rect in
          let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
          let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.85), .paragraphStyle: paragraph]
          (item.name as NSString).draw(in: rect.insetBy(dx: 3, dy: 3), withAttributes: attributes)
          return true
        }
        label.contents = text; label.frame = NSRect(x: 52, y: 12, width: 188, height: 24)
        return [image, label]
      }
      return dragging
    }
    guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 1, y: 1),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
      panel.orderOut(nil); self.panel = nil; self.drag = nil; return false
    }
    let down = CGEvent(mouseEventSource: mouseSource, mouseType: .leftMouseDown,
      mouseCursorPosition: quartz, mouseButton: .left)
    down?.setIntegerValueField(.eventSourceUserData, value: ReceiverCursorVisibility.remoteEventTag)
    down?.post(tap: .cghidEventTap)
    let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = false
    session.draggingFormation = .pile
    mutex.lock(); self.session = session; mutex.unlock()
    // Keep the source window alive, but pass subsequent events to the desktop.
    panel.ignoresMouseEvents = true
    return true
  }

  func userReleased() { mutex.lock(); released = true; mutex.unlock() }
  // Can be requested from the input watchdog queue while it holds its input
  // lock. Queue cancellation before the paired MouseUp, rather than calling
  // AppKit synchronously from that queue or changing focus.
  func cancelDrag() {
    mutex.lock()
    let cancel = session != nil && !released
    if cancel { released = true }
    mutex.unlock()
    guard cancel else { return }
    let source = CGEventSource(stateID: .privateState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    mutex.lock(); self.session = nil; mutex.unlock()
    panel?.orderOut(nil); panel = nil; providers = []; drag = nil
    sessionEnded?()
  }

  func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
    mutex.lock(); defer { mutex.unlock() }
    guard let identity = filePromiseProvider.userInfo as? [String: String],
          let drag = identity["drag"], let item = identity["item"], let value = offered[drag]?[item] else { return "Shared Input" }
    return value.name
  }
  func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { writesQueue }
  func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
      completionHandler: @escaping (Error?) -> Void) {
    mutex.lock()
    let identity = provider.userInfo as? [String: String]
    let itemValue = identity.flatMap { value in offered[value["drag"] ?? ""]?[value["item"] ?? ""] }
    mutex.unlock()
    guard let identity = identity,
          let drag = identity["drag"], let id = identity["item"], let item = itemValue,
          url.isFileURL else {
      completionHandler(NSError(domain: "SharedInputFileDrag", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "拖拽对象已过期"])); return
    }
    let request = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Receiving a dragged file")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let write = FilePromiseWrite(id: request, url: url, item: item)
    mutex.lock(); writes[request] = write; mutex.unlock()
    write.progress.cancellationHandler = { [weak self] in
      DispatchQueue.main.async { self?.channel.invokeMethod("fileDragCancel", arguments: ["request": request]) }
    }
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
      write.progress.fileURL = destination
      write.progress.publish()
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod("fileDragRequest", arguments: ["drag": drag, "item": id,
          "request": request, "destination": destination.path])
      }
      if write.signal.wait(timeout: .now() + .seconds(1800)) == .timedOut {
        write.complete(NSError(domain: "SharedInputFileDrag", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "文件传输超时"]))
        DispatchQueue.main.async { [weak self] in
          self?.channel.invokeMethod("fileDragCancel", arguments: ["request": request])
        }
      }
      write.progress.unpublish()
    }
    mutex.lock(); writes.removeValue(forKey: request); mutex.unlock()
    write.mutex.lock(); let error = write.error; write.mutex.unlock()
    if let coordinationError = coordinationError { completionHandler(coordinationError) }
    else { completionHandler(error) }
  }

  func progress(_ args: [String: Any]) {
    guard let id = args["request"] as? String, let bytes = args["bytes"] as? NSNumber else { return }
    mutex.lock(); let write = writes[id]; mutex.unlock()
    guard let write = write else { return }
    let done = args["done"] as? Bool ?? false
    if let total = args["total"] as? NSNumber, total.int64Value >= 0 {
      write.progress.totalUnitCount = max(1, total.int64Value)
    }
    if done {
      write.progress.totalUnitCount = max(1, bytes.int64Value)
      write.progress.completedUnitCount = write.progress.totalUnitCount
      write.progress.fileCompletedCount = 1
    } else { write.progress.completedUnitCount = max(0, bytes.int64Value) }
  }
  func complete(_ args: [String: Any]) {
    guard let id = args["request"] as? String else { return }
    mutex.lock(); let write = writes[id]; mutex.unlock()
    let error = (args["error"] as? String).map {
      NSError(domain: "SharedInputFileDrag", code: 3, userInfo: [NSLocalizedDescriptionKey: $0])
    }
    write?.complete(error)
  }
  func reset() {
    cancelDrag()
    mutex.lock(); let pending = Array(writes.values); offered.removeAll(); mutex.unlock()
    for write in pending {
      write.complete(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
        userInfo: [NSLocalizedDescriptionKey: "连接已结束，文件传输已取消"]))
    }
  }
}
