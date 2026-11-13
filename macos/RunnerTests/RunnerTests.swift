import Cocoa
import FlutterMacOS
import XCTest
import ImageIO

class RunnerTests: XCTestCase {
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
