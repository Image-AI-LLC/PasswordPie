import Foundation
import XCTest
@testable import PasswordPieCLI

/// `passwordpie_run` keeps the start and the end of each stream, at most 64 KiB.
final class ClippedTests: XCTestCase {
    func testShortOutputIsKeptWhole() {
        var clipped = Clipped(limit: 16)
        clipped.append(Data("hello".utf8))
        clipped.append(Data(" world".utf8))
        XCTAssertEqual(clipped.text, "hello world")
        XCTAssertEqual(clipped.dropped, 0)
    }

    func testLongOutputKeepsTheStartAndTheEnd() {
        var clipped = Clipped(limit: 8)
        for chunk in ["abc", "defgh", "ijklmnop", "qrst"] { clipped.append(Data(chunk.utf8)) }
        XCTAssertEqual(clipped.dropped, 12)
        XCTAssertEqual(clipped.text, "abcd\n[… 12 bytes cut by PasswordPie …]\nqrst")
    }

    func testACharacterCutInTwoIsDropped() {
        var clipped = Clipped(limit: 8)
        // Four bytes kept at each end: "aaa" and the first byte of é, the second byte of é and "bbb".
        clipped.append(Data("aaaé".utf8) + Data(repeating: 0x2D, count: 10) + Data("ébbb".utf8))
        XCTAssertEqual(clipped.text.hasPrefix("aaa\n["), true, clipped.text)
        XCTAssertEqual(clipped.text.hasSuffix("]\nbbb"), true, clipped.text)
        XCTAssertFalse(clipped.text.contains("\u{FFFD}"))
    }
}
