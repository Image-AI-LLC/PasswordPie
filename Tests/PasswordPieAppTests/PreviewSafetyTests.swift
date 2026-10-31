#if DEBUG
import XCTest
@testable import PasswordPie

final class PreviewSafetyTests: XCTestCase {
    func testPreviewHotkeySuppressionInputs() async {
        await MainActor.run {
            XCTAssertTrue(AppDelegate.suppressesPreviewHotkey(["PASSWORDPIE_PREFERENCES": "1"]))
            XCTAssertTrue(AppDelegate.suppressesPreviewHotkey(["PASSWORDPIE_PREFERENCES": ""]))
            XCTAssertTrue(AppDelegate.suppressesPreviewHotkey(["PASSWORDPIE_DISABLE_HOTKEY": "1"]))
            XCTAssertFalse(AppDelegate.suppressesPreviewHotkey([:]))
            XCTAssertFalse(AppDelegate.suppressesPreviewHotkey(["PASSWORDPIE_APPEARANCE": "dark"]))
        }
    }
}
#endif
