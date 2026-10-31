import XCTest
@testable import PasswordPie

@MainActor
final class PanelPresenceTests: XCTestCase {
    func testTouchIDSheetDoesNotCloseThePanel() {
        XCTAssertFalse(PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: 0, touchIDBusy: true, recordingHotKey: false, autoHideEnabled: true
        ))
        XCTAssertTrue(PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: 0, touchIDBusy: false, recordingHotKey: false, autoHideEnabled: true
        ))
        XCTAssertFalse(PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: 1, touchIDBusy: false, recordingHotKey: false, autoHideEnabled: true
        ))
        XCTAssertFalse(PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: 0, touchIDBusy: false, recordingHotKey: true, autoHideEnabled: true
        ))
        XCTAssertFalse(PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: 0, touchIDBusy: true, recordingHotKey: false, autoHideEnabled: false
        ))
    }
}
