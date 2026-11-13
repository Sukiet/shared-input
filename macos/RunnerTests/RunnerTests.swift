import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

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
