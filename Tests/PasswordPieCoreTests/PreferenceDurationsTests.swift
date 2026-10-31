import XCTest
@testable import PasswordPieCore

final class PreferenceDurationsTests: XCTestCase {
    func testCoarseIdlePresetsIncludeTheExistingDefault() {
        XCTAssertEqual(PreferenceDurations.idleMinutes, [1, 5, 15, 30, 60, 240])
        XCTAssertEqual(AutoLockSettings().timeoutMinutes, 5)
        XCTAssertTrue(PreferenceDurations.idleMinutes.contains(AutoLockSettings().timeoutMinutes))
    }

    func testClipboardPresetsPreserveTheExistingNinetySecondDefault() {
        XCTAssertEqual(PreferenceDurations.clipboardSeconds, [15, 30, 60, 90, 120, 300])
        XCTAssertEqual(ClipboardGuard.defaultTimeout, 90)
        XCTAssertTrue(PreferenceDurations.clipboardOptions(including: 30).contains(Int(ClipboardGuard.defaultTimeout)))
        XCTAssertEqual(PreferenceDurations.clipboardOptions(including: 90), [15, 30, 60, 90, 120, 300])
    }

    func testLegacyIdleValuesAreIncludedAndSortedWithoutDuplicates() {
        XCTAssertEqual(PreferenceDurations.idleOptions(including: 7), [1, 5, 7, 15, 30, 60, 240])
        XCTAssertEqual(PreferenceDurations.idleOptions(including: 1440), [1, 5, 15, 30, 60, 240, 1440])
        XCTAssertEqual(PreferenceDurations.idleOptions(including: 5), PreferenceDurations.idleMinutes)
    }

    func testLegacyClipboardValuesAreIncludedAndSortedWithoutDuplicates() {
        XCTAssertEqual(PreferenceDurations.clipboardOptions(including: 5), [5, 15, 30, 60, 90, 120, 300])
        XCTAssertEqual(PreferenceDurations.clipboardOptions(including: 45), [15, 30, 45, 60, 90, 120, 300])
        XCTAssertEqual(PreferenceDurations.clipboardOptions(including: 300), PreferenceDurations.clipboardSeconds)
    }

    func testMinuteLabelsUseHoursOnlyForExactHourValues() {
        XCTAssertEqual(PreferenceDurations.minutesLabel(1), "1 minute")
        XCTAssertEqual(PreferenceDurations.minutesLabel(5), "5 minutes")
        XCTAssertEqual(PreferenceDurations.minutesLabel(60), "1 hour")
        XCTAssertEqual(PreferenceDurations.minutesLabel(90), "90 minutes")
        XCTAssertEqual(PreferenceDurations.minutesLabel(240), "4 hours")
        XCTAssertEqual(PreferenceDurations.minutesLabel(1440), "24 hours")
    }

    func testSecondLabelsKeepLegacyValuesExact() {
        XCTAssertEqual(PreferenceDurations.secondsLabel(1), "1 second")
        XCTAssertEqual(PreferenceDurations.secondsLabel(15), "15 seconds")
        XCTAssertEqual(PreferenceDurations.secondsLabel(60), "1 minute")
        XCTAssertEqual(PreferenceDurations.secondsLabel(90), "90 seconds")
        XCTAssertEqual(PreferenceDurations.secondsLabel(120), "2 minutes")
        XCTAssertEqual(PreferenceDurations.secondsLabel(3600), "1 hour")
    }
}
