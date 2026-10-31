import XCTest
@testable import PasswordPie

final class LargeTypeTests: XCTestCase {
    func testGroupsOfFourKeepEveryCharacter() {
        let text = "abcdefghij"
        let groups = LargeType.groups(in: text)
        XCTAssertEqual(groups.map { String($0.map(\.character)) }, ["abcd", "efgh", "ij"])
        XCTAssertEqual(groups.flatMap { $0.map(\.character) }, Array(text))
    }

    func testAPasswordSpaceStaysACellAndDrawsAMark() {
        let cells = LargeType.groups(in: "ab cd").flatMap { $0 }
        XCTAssertEqual(cells.map(\.character), ["a", "b", " ", "c", "d"])
        XCTAssertEqual(cells.map(\.kind), [.letter, .letter, .space, .letter, .letter])
        XCTAssertEqual(cells.map(\.shown), ["a", "b", "␣", "c", "d"])
    }

    func testLettersDigitsAndSymbolsTakeDifferentKinds() {
        let cells = LargeType.groups(in: "aB3!字\t").flatMap { $0 }
        XCTAssertEqual(cells.map(\.kind), [.letter, .letter, .digit, .symbol, .letter, .space])
    }

    func testRowsBreakBetweenGroups() {
        let ranges = LargeType.rowRanges(widths: [100, 100, 100], spacing: 10, maxWidth: 210)
        XCTAssertEqual(ranges.map { Array($0) }, [[0, 1], [2]])
    }

    func testAWideGroupStaysWhole() {
        let ranges = LargeType.rowRanges(widths: [300], spacing: 8, maxWidth: 100)
        XCTAssertEqual(ranges.map { Array($0) }, [[0]])
    }

    func testWindowWrapsWholeGroupsInsideThePadding() {
        let layout = LargeTypeLayout(uniformCellWidth: 10, groupHeight: 20, groupSpacing: 8, lineSpacing: 8, stripePaddingH: 0, outerPadding: 24)
        let one = LargeTypeMetrics.windowSize(text: "abcd", maxWidth: 400, layout: layout)
        XCTAssertEqual(one, CGSize(width: 40 + 48, height: 20 + 48))
        // Three groups of 40. Content limit 88 fits two (40 + 8 + 40) and wraps the third.
        let wrapped = LargeTypeMetrics.windowSize(text: "abcdabcdabcd", maxWidth: 136, layout: layout)
        XCTAssertEqual(wrapped, CGSize(width: 88 + 48, height: 20 + 8 + 20 + 48))
    }

    func testAWideGlyphWidensItsOwnCell() {
        let layout = LargeTypeLayout.metrics(fontSize: 54)
        XCTAssertGreaterThan(layout.cellWidth(for: "字"), layout.cellWidth(for: "0"))
        XCTAssertGreaterThan(layout.cellWidth(for: "😀"), layout.cellWidth(for: "0"))
        let latin = layout.groupWidth(LargeType.groups(in: "0000")[0])
        let wide = layout.groupWidth(LargeType.groups(in: "字字字字")[0])
        XCTAssertGreaterThan(wide, latin)
    }

    func testALongPasswordShrinksToStayInsideTheBox() {
        let text = String(repeating: "abcd", count: 100)
        let fit = LargeTypeMetrics.fit(text: text, maxWidth: 360, maxHeight: 200)
        XCTAssertLessThanOrEqual(fit.size.width, 360)
        XCTAssertLessThanOrEqual(fit.size.height, 200)
        XCTAssertLessThan(fit.layout.fontSize, 54)
        XCTAssertEqual(fit.layout.scale, 1)
    }

    func testAnEnormousPasswordStaysInsideASmallBox() {
        let text = String(repeating: "字", count: 4000)
        let fit = LargeTypeMetrics.fit(text: text, maxWidth: 160, maxHeight: 120)
        XCTAssertLessThanOrEqual(fit.size.width, 160)
        XCTAssertLessThanOrEqual(fit.size.height, 120)
        XCTAssertLessThanOrEqual(fit.unscaled.width * fit.layout.scale, 160.5)
        XCTAssertLessThanOrEqual(fit.unscaled.height * fit.layout.scale, 120.5)
        XCTAssertGreaterThan(fit.size.width, 0)
        XCTAssertGreaterThan(fit.size.height, 0)
    }

    func testLastResortScaleCanShrinkBelowFivePercent() {
        let scale = LargeTypeMetrics.scaleThatFits(
            unscaled: CGSize(width: 576, height: 170_320),
            boxWidth: 160,
            boxHeight: 120
        )
        XCTAssertLessThan(scale, 0.05)
        XCTAssertLessThanOrEqual(576 * scale, 160.01)
        XCTAssertLessThanOrEqual(170_320 * scale, 120.01)
    }

    func testAShortPasswordKeepsThePreferredFont() {
        let fit = LargeTypeMetrics.fit(text: "abcd", maxWidth: 800, maxHeight: 600)
        XCTAssertEqual(fit.layout.fontSize, 54)
        XCTAssertEqual(fit.layout.scale, 1)
        XCTAssertLessThanOrEqual(fit.size.width, 800)
        XCTAssertLessThanOrEqual(fit.size.height, 600)
    }
}
