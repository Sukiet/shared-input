import Cocoa
import FlutterMacOS
import XCTest
import ImageIO

class RunnerTests: XCTestCase {
  func testEdgeDragPixelGeometryInAllDirections() {
    let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
    XCTAssertEqual(dragProbeFrame(screen: screen, side: "left", scale: 2),
      CGRect(x: -1200, y: 100, width: 0.5, height: 800))
    XCTAssertEqual(dragProbeFrame(screen: screen, side: "right", scale: 2).minX, -0.5)
    XCTAssertEqual(dragProbeFrame(screen: screen, side: "top", scale: 2).minY, 899.5)
    XCTAssertEqual(dragProbeFrame(screen: screen, side: "bottom", scale: 2).height, 0.5)
  }
  func testReceiverDragDoesNotBecomeControllerSource() {
    var state = ReceiverDragState()
    state.begin(); state.edge(); state.crossed()
    XCTAssertTrue(state.onController)
    XCTAssertEqual(state.history, ["gesture", "edge", "crossed"])
    state.end(); XCTAssertEqual(state.stage, "ended")
    XCTAssertTrue(state.onController)
    state.returned(); XCTAssertEqual(state.stage, "returned")
    XCTAssertFalse(state.onController)
    let previous = state.flow
    state.begin(); XCTAssertGreaterThan(state.flow, previous)
    state.reset(); XCTAssertFalse(state.active)
  }
  func testInjectedDragReachesRetinaTargetOnAllEdges() {
    let quartz = CGRect(x: 0, y: 0, width: 1500, height: 900)
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
    for (side, point) in [
      ("left", CGPoint(x: 0, y: 400)), ("right", CGPoint(x: 1499, y: 400)),
      ("top", CGPoint(x: 700, y: 0)), ("bottom", CGPoint(x: 700, y: 899))
    ] {
      let snapped = dragProbeCursor(point, bounds: quartz, side: side, scale: 2)
      let appKit = CGPoint(x: snapped.x, y: 900 - snapped.y)
      XCTAssertTrue(dragProbeFrame(screen: screen, side: side, scale: 2).contains(appKit))
    }
    let center = CGPoint(x: 700, y: 400)
    XCTAssertEqual(dragProbeCursor(center, bounds: quartz, side: "right", scale: 2), center)
  }
  func testMacDragReadsUnicodeFileMetadataWithoutCreatingFiles() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let first = NSPasteboardItem(), second = NSPasteboardItem()
    first.setString(URL(fileURLWithPath: "/未创建/照片.png").absoluteString, forType: .fileURL)
    second.setString(URL(fileURLWithPath: "/未创建/文件夹").absoluteString, forType: .fileURL)
    board.writeObjects([first, second])
    let metadata = MacDragMetadata.inspect(board)
    XCTAssertEqual(metadata.count, 2)
    XCTAssertEqual(metadata.files[0]["name"] as? String, "照片.png")
    XCTAssertEqual(metadata.files[1]["path"] as? String, "/未创建/文件夹")
    XCTAssertEqual(metadata.files[0]["promised"] as? Bool, false)
  }
  func testMacDragRejectsNonFileURL() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString("https://example.com/file.txt", forType: .fileURL)
    board.writeObjects([item])
    XCTAssertEqual(MacDragMetadata.inspect(board).count, 0)
  }
  func testClipboardTiffConvertsToPngWithAlpha() throws {
    let bytes = Data([255, 0, 0, 255, 0, 255, 0, 128])
    let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
    let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let tiff = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let png = try XCTUnwrap(ClipboardBridge.png(tiff as Data))
    XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
    XCTAssertEqual(decoded.pixelsWide, 2)
    XCTAssertEqual(decoded.pixelsHigh, 1)
    let color = try XCTUnwrap(decoded.colorAt(x: 1, y: 0))
    XCTAssertEqual(color.alphaComponent, 128.0 / 255, accuracy: 0.01)
  }

  func testClipboardRejectsMalformedImage() {
    XCTAssertNil(ClipboardBridge.image(Data([1, 2, 3, 4])))
    XCTAssertNil(ClipboardBridge.png(Data()))
  }

  func testWindowsKeysMapToCommand() {
    XCTAssertEqual(windowsToMacKeyCode[0xe05b], 55)
    XCTAssertEqual(windowsToMacKeyCode[0xe05c], 54)
  }

  func testControlKeysRemainControl() {
    XCTAssertEqual(windowsToMacKeyCode[0x001d], 59)
    XCTAssertEqual(windowsToMacKeyCode[0xe01d], 62)
  }

  func testAltKeysMapToOption() {
    XCTAssertEqual(windowsToMacKeyCode[0x0038], 58)
    XCTAssertEqual(windowsToMacKeyCode[0xe038], 61)
  }

}
