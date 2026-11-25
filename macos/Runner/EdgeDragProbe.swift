import Cocoa

struct ReceiverDragLease {
  let token: String
  let button: Int
  let pressId: Int64
  let flow: Int
  let started: TimeInterval
  var renewed: TimeInterval
  var snapshot: [String: Any] { ["token": token, "button": button, "pressId": pressId] }
  func matches(_ value: [String: Any]) -> Bool {
    value["token"] as? String == token && (value["button"] as? NSNumber)?.intValue == button &&
      (value["pressId"] as? NSNumber)?.int64Value == pressId
  }
  func expired(at now: TimeInterval) -> Bool {
    now < renewed || now - renewed >= 1.5 || now - started >= 60
  }
}

// AppKit coordinates: origin at the lower-left. The configured side is the
// Mac side facing the controller, not the controller's own outgoing side.
func dragProbeFrame(screen: CGRect, side: String, scale: CGFloat) -> CGRect {
  let pixel = 1 / max(1, scale)
  switch side {
  case "right": return CGRect(x: screen.maxX - pixel, y: screen.minY, width: pixel, height: screen.height)
  case "top": return CGRect(x: screen.minX, y: screen.maxY - pixel, width: screen.width, height: pixel)
  case "bottom": return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: pixel)
  default: return CGRect(x: screen.minX, y: screen.minY, width: pixel, height: screen.height)
  }
}

// Bring injected dragging into the last physical pixel before reporting edge
// contact. Otherwise the existing one-point clamp can skip a Retina half-point
// destination on the right/bottom sides. Quartz uses a top-left origin here.
func dragProbeCursor(_ point: CGPoint, bounds: CGRect, side: String?, scale: CGFloat) -> CGPoint {
  let halfPixel = 0.5 / max(1, scale)
  switch side {
  case "left" where point.x <= bounds.minX + 1:
    return CGPoint(x: bounds.minX + halfPixel, y: point.y)
  case "right" where point.x >= bounds.maxX - 2:
    return CGPoint(x: bounds.maxX - halfPixel, y: point.y)
  case "top" where point.y <= bounds.minY + 1:
    return CGPoint(x: point.x, y: bounds.minY + halfPixel)
  case "bottom" where point.y >= bounds.maxY - 2:
    return CGPoint(x: point.x, y: bounds.maxY - halfPixel)
  default: return point
  }
}

func dragProbeAnchor(_ point: CGPoint, bounds: CGRect, side: String?, scale: CGFloat) -> CGPoint {
  let halfPixel = 0.5 / max(1, scale)
  var anchor = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - halfPixel),
                       y: min(max(point.y, bounds.minY), bounds.maxY - halfPixel))
  switch side {
  case "right": anchor.x = bounds.maxX - halfPixel
  case "top": anchor.y = bounds.minY + halfPixel
  case "bottom": anchor.y = bounds.maxY - halfPixel
  default: anchor.x = bounds.minX + halfPixel
  }
  return anchor
}

struct ReceiverDragState {
  private(set) var flow = 0
  private(set) var active = false
  private(set) var onController = false
  private(set) var stage = "idle"
  private(set) var history: [String] = []
  mutating func reset() {
    flow += 1; active = false; onController = false; stage = "idle"; history = []
  }
  mutating func begin() {
    guard !active else { return }
    flow += 1; active = true; onController = false; history = []; change("gesture")
  }
  mutating func prepareSuspension(distance: CGFloat) -> Bool {
    guard !onController else { return false }
    if !active {
      guard distance >= 4 else { return false }
      begin()
    }
    return true
  }
  mutating func edge() { if active && (stage == "gesture" || stage == "returned") { change("edge") } }
  mutating func crossed() {
    guard active, !onController else { return }
    edge(); onController = true; change("crossed")
  }
  mutating func end() {
    guard active else { return }
    active = false; change("ended")
  }
  mutating func returned(continuing: Bool = false) {
    guard onController else { return }
    active = continuing; onController = false; change("returned")
  }
  private mutating func change(_ value: String) {
    stage = value; history.append(value)
    if history.count > 16 { history.removeFirst(history.count - 16) }
  }
}

struct MacDragMetadata {
  var files: [[String: Any]] = []
  var formats: [String] = []
  var count = 0
  var truncated = false
  var message = ""
  static func inspect(_ pasteboard: NSPasteboard) -> MacDragMetadata {
    var value = MacDragMetadata()
    value.formats = Array((pasteboard.types ?? []).prefix(32)).map { $0.rawValue }
    var budget = 16 * 1024 * 1024
    func append(_ path: String) {
      guard !path.isEmpty, path.utf8.count <= 131072, budget >= path.utf8.count else {
        value.truncated = true; return
      }
      budget -= path.utf8.count; value.count += 1
      if value.files.count < 256 {
        value.files.append(["name": (path as NSString).lastPathComponent,
          "path": path, "promised": false])
      } else { value.truncated = true }
    }
    for item in pasteboard.pasteboardItems ?? [] {
      // File URL metadata only. Never request file contents or resolve aliases.
      guard budget > 0 else { value.truncated = true; break }
      if let text = item.string(forType: .fileURL), text.utf8.count <= 131072,
         let url = URL(string: text), url.isFileURL { append(url.path) }
    }
    if value.count == 0 {
      let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
      if let bytes = pasteboard.data(forType: filenames), bytes.count <= budget,
         let object = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
         let paths = object as? [String] {
        for path in paths { append(path) }
      }
    }
    if value.count == 0 {
      value.message = "没有可识别的本地文件列表；虚拟文件只展示格式，不请求生成内容。"
    }
    return value
  }
}

private final class DragProbePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class DragProbeView: NSView {
  weak var probe: MacEdgeDragProbe?
  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {} // Deliberately no visual surface.
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    probe?.entered(sender); return []
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
  override func wantsPeriodicDraggingUpdates() -> Bool { false }
  override func draggingExited(_ sender: NSDraggingInfo?) { probe?.left() }
  override func draggingEnded(_ sender: NSDraggingInfo) { probe?.ended() }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// Main-thread only. Transparent, nonactivating, one-physical-pixel target.
/// Monitors observe both physical Mac events and injected remote events; an
/// actual press on the Mac desktop therefore belongs to the receiver source.
final class MacEdgeDragProbe {
  private(set) var enabled = false
  private(set) var side = "left"
  private var revision = 0
  private var state = ReceiverDragState()
  private var metadata = MacDragMetadata()
  private var phase = "off"
  private var hovering = false
  private var sourceButton: Int?
  private var downPoint = CGPoint.zero
  private var panel: DragProbePanel?
  private var globalMonitor: Any?, localMonitor: Any?
  private var screenObserver: NSObjectProtocol?
  private var incomingFileDrag = false
  func suppressIncomingFileDrag(_ value: Bool) {
    incomingFileDrag = value
    if value || !state.active { panel?.ignoresMouseEvents = true }
    publish()
  }
  var changed: (([String: Any]) -> Void)?
  var localInput: ((NSEvent) -> Void)?
  var dragEnded: ((Int) -> Void)?
  func suspensionFlow(button: Int, from down: CGPoint, to point: CGPoint) -> Int? {
    guard enabled, !incomingFileDrag, atEdge else { return nil }
    let wasActive = state.active
    guard state.prepareSuspension(distance: hypot(point.x - down.x, point.y - down.y)) else { return nil }
    panel?.ignoresMouseEvents = false
    if !wasActive {
      sourceButton = button; downPoint = down
      if !hovering { metadata = MacDragMetadata(); phase = "waiting" }
    }
    // Metadata/AppKit destination callbacks can lag behind pointer feedback.
    // Keeping a genuine drag must not depend on file enumeration completing.
    return state.flow
  }

  var snapshot: [String: Any] {
    ["origin": "receiver", "enabled": enabled, "side": side, "revision": revision,
     "hitEnabled": panel != nil && !(panel?.ignoresMouseEvents ?? true),
     "hovering": hovering, "phase": phase, "dragFlow": state.flow,
     "dragStage": state.stage, "gestureActive": state.active, "onRemote": state.onController,
     "dragHistory": state.history, "dragReason": "", "files": metadata.files,
     "formats": metadata.formats, "count": metadata.count, "truncated": metadata.truncated,
     "message": metadata.message]
  }
  func configure(enabled: Bool, side: String) {
    guard ["left", "right", "top", "bottom"].contains(side) else { return }
    self.side = side
    if !enabled {
      self.enabled = false; sourceButton = nil; state.reset()
      removeMonitors()
      // Keep refusing the current source until AppKit acknowledges its end.
      if !hovering { closePanel() }
      phase = hovering ? "closing" : "off"; publish(); return
    }
    if self.enabled { reposition(); publish(); return }
    self.enabled = true; state.reset()
    if hovering { state.begin(); state.edge() }
    else { metadata = MacDragMetadata(); phase = "waiting" }
    // A disabled target can still be rejecting an in-flight source. Reuse it
    // if re-enabled before draggingEnded, instead of leaking a second window.
    if panel == nil {
      let view = DragProbeView(frame: .zero); view.probe = self
      let types = [NSPasteboard.PasteboardType.fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType")] +
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
      view.registerForDraggedTypes(types)
      let window = DragProbePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
      window.alphaValue = 1; window.hasShadow = false; window.hidesOnDeactivate = false
      window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
      window.level = .statusBar; window.animationBehavior = .none
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
      panel = window
    }
    panel?.ignoresMouseEvents = !hovering
    reposition(); panel?.orderFrontRegardless()
    let events: NSEvent.EventTypeMask = [.mouseMoved, .scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown,
      .rightMouseUp, .leftMouseDragged, .rightMouseDragged]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      self?.observe(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      self?.observe(event); return event
    }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
        self?.reposition(); self?.publish()
      }
    if globalMonitor == nil || localMonitor == nil {
      self.enabled = false; removeMonitors(); closePanel(); phase = "unsupported"
      metadata.message = "无法监听拖拽手势，请检查辅助功能权限后重试。"
    }
    publish()
  }
  func setSide(_ side: String) {
    guard ["left", "right", "top", "bottom"].contains(side), self.side != side else { return }
    self.side = side; reposition(); publish()
  }
  func clear() {
    metadata = MacDragMetadata()
    if !state.active { state.reset() }
    phase = enabled ? "waiting" : "off"; publish()
  }
  func receiverBegan(resuming: Bool = false) { state.returned(continuing: resuming); publish() }
  func suspendedEnded(flow: Int) {
    guard state.flow == flow && state.onController else { return }
    sourceButton = nil; state.end(); phase = enabled ? "drop" : "off"; publish()
  }
  func receiverStopped(reason: String?, suspended: Bool = false) {
    if enabled && reason == "edge" && state.active && (suspended || atEdge) {
      state.crossed(); publish()
    }
  }
  private var mainScreen: NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() } ?? NSScreen.screens.first
  }
  private var atEdge: Bool {
    guard let point = CGEvent(source: nil)?.location else { return false }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    guard bounds.contains(point) else { return false }
    switch side {
    case "right": return point.x >= bounds.maxX - 2
    case "top": return point.y <= bounds.minY + 1
    case "bottom": return point.y >= bounds.maxY - 2
    default: return point.x <= bounds.minX + 1
    }
  }
  var pixelScale: CGFloat { mainScreen?.backingScaleFactor ?? 1 }
  private func reposition() {
    guard let screen = mainScreen, let panel = panel else { return }
    panel.setFrame(dragProbeFrame(screen: screen.frame, side: side,
      scale: screen.backingScaleFactor), display: false)
  }
  private func observe(_ event: NSEvent) {
    localInput?(event)
    guard enabled, !incomingFileDrag else { return }
    let point = event.cgEvent?.location ?? NSEvent.mouseLocation
    switch event.type {
    case .leftMouseDown, .rightMouseDown:
      sourceButton = event.type == .leftMouseDown ? 0 : 1; downPoint = point
    case .leftMouseDragged, .rightMouseDragged:
      let button = event.type == .leftMouseDragged ? 0 : 1
      guard sourceButton == button else { return }
      var notify = false
      if !state.active && hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 {
        state.begin(); metadata = MacDragMetadata(); phase = "waiting"
        panel?.ignoresMouseEvents = false; notify = true
      }
      if atEdge && state.stage == "gesture" { state.edge(); notify = true }
      if notify { publish() }
    case .leftMouseUp, .rightMouseUp:
      guard sourceButton == (event.type == .leftMouseUp ? 0 : 1) else { return }
      sourceButton = nil; state.end()
      if !hovering { panel?.ignoresMouseEvents = true }
      publish()
    default: break
    }
  }
  fileprivate func entered(_ sender: NSDraggingInfo) {
    guard enabled, !incomingFileDrag else { return }
    if !state.active { state.begin() }
    state.edge(); hovering = true; metadata = MacDragMetadata.inspect(sender.draggingPasteboard)
    phase = metadata.count > 0 ? "enter" : "unsupported"; publish()
  }
  fileprivate func left() {
    hovering = false; phase = enabled ? "leave" : "off"
    if !enabled { closePanel() }
    else if !state.active { panel?.ignoresMouseEvents = true }
    publish()
  }
  fileprivate func ended() {
    let endedFlow = state.flow
    hovering = false; sourceButton = nil; state.end(); phase = enabled ? "drop" : "off"
    if enabled { panel?.ignoresMouseEvents = true } else { closePanel() }
    publish()
    dragEnded?(endedFlow)
  }
  private func publish() { revision += 1; changed?(snapshot) }
  private func closePanel() {
    panel?.contentView?.unregisterDraggedTypes(); panel?.orderOut(nil); panel?.close(); panel = nil
  }
  private func removeMonitors() {
    if let token = globalMonitor { NSEvent.removeMonitor(token) }; globalMonitor = nil
    if let token = localMonitor { NSEvent.removeMonitor(token) }; localMonitor = nil
    if let token = screenObserver { NotificationCenter.default.removeObserver(token) }; screenObserver = nil
  }
  func shutdown() {
    enabled = false; hovering = false; sourceButton = nil; state.reset(); removeMonitors(); closePanel()
  }
  deinit { removeMonitors(); closePanel() }
}
