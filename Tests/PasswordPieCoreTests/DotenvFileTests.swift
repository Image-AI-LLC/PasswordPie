import XCTest
@testable import PasswordPieCore

/// A dotenv file read as a dotenv library reads it (docs/UX.md, "A folder of .env files becomes items").
final class DotenvFileTests: XCTestCase {
    private func values(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: DotenvFile.parse(text).variables.map { ($0.name, $0.value) })
    }

    func testPlainLinesExportAndSpacesAroundTheEqualsSign() {
        let parsed = DotenvFile.parse("A=1\nexport B=two\n  C = three  \n\nD=\nE=a=b\n")
        XCTAssertEqual(parsed.variables.map(\.name), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(parsed.variables.map(\.value), ["1", "two", "three", "", "a=b"])
        XCTAssertEqual(parsed.variables.map(\.line), [1, 2, 3, 5, 6])
        XCTAssertEqual(parsed.unreadable, [])
    }

    func testQuotesAreRemovedAndDoubleQuotesTakeEscapes() {
        XCTAssertEqual(values(#"A="a b"  # trailing"# + "\n" + #"B='c # d'"# + "\n" + #"C="line\none\ttab \"q\" \\ \x""# + "\n"), [
            "A": "a b", "B": "c # d", "C": "line\none\ttab \"q\" \\ \\x"
        ])
        // In single quotes only \\ and \' stand for something.
        XCTAssertEqual(values(#"A='it\'s \n \\'"#), ["A": #"it's \n \"#])
    }

    func testAQuotedValueMayRunOverLines() {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIIfake\n-----END PRIVATE KEY-----"
        let parsed = DotenvFile.parse("KEY=\"\(pem)\"\nNEXT=1\n")
        XCTAssertEqual(parsed.variables.map(\.value), [pem, "1"])
        XCTAssertEqual(parsed.variables.map(\.line), [1, 4], "lines are counted through the value")
    }

    func testCommentsAreWholeLinesAndInlineOnesAreDropped() {
        let parsed = DotenvFile.parse("# Stripe, test mode\n#no space\n  # indented\nA=1 # the key\nB=a#b\nC= # nothing\nD=#x\n")
        XCTAssertEqual(parsed.comments, ["Stripe, test mode", "no space", "indented"])
        XCTAssertEqual(parsed.variables.map(\.value), ["1", "a#b", "", "#x"])
    }

    /// A variable switched off with `#` usually still holds a value: it is no note, and is reported by line.
    func testACommentedOutAssignmentIsNotANote() {
        let parsed = DotenvFile.parse("# Rotated in May\n# OLD_KEY=PLANTED-old\n#export OTHER = PLANTED-other\n# see https://example.invalid/?a=b\nKEY=1\n")
        XCTAssertEqual(parsed.comments, ["Rotated in May", "see https://example.invalid/?a=b"])
        XCTAssertEqual(parsed.commentedOut, [2, 3])
        XCTAssertEqual(parsed.variables.map(\.name), ["KEY"])
    }

    func testTheLastValueOfARepeatedNameWins() {
        let parsed = DotenvFile.parse("A=1\nB=2\nA=3\nA=4\n")
        XCTAssertEqual(parsed.variables.map(\.name), ["A", "B"])
        XCTAssertEqual(parsed.variables.map(\.value), ["4", "2"])
        XCTAssertEqual(parsed.repeated, ["A"])
    }

    func testLinesThatAreNotAssignmentsAreReportedByNumberAndNothingIsTakenFromThem() {
        let parsed = DotenvFile.parse("A=1\njust words\n1BAD=x\nFOO-BAR=x\nNOEQUALS\nB=\"never closed\nC=2\nD=\"x\"y\n")
        XCTAssertEqual(parsed.variables.map(\.name), ["A", "C"])
        XCTAssertEqual(parsed.unreadable, [2, 3, 4, 5, 6, 8])
    }

    func testWindowsLineEndsAndAByteOrderMark() {
        let parsed = DotenvFile.parse("\u{FEFF}A=1\r\nB=\"two\"\r\n# note\r\nC=3")
        XCTAssertEqual(parsed.variables.map(\.value), ["1", "two", "3"])
        XCTAssertEqual(parsed.comments, ["note"])
        XCTAssertEqual(parsed.unreadable, [])
    }

    func testNothingIsExpanded() {
        XCTAssertEqual(values("HOST=example.com\nURL=https://${HOST}/x\nP=\"$HOME\"\n")["URL"], "https://${HOST}/x")
        XCTAssertEqual(values("P=\"$HOME\"\n")["P"], "$HOME")
    }

    /// What a shell running `source` reads differently is named, so the person can look at it.
    func testValuesAShellReadsDifferentlyAreMarked() {
        func marked(_ line: String) -> Bool { DotenvFile.parse(line).variables.first?.shellSensitive ?? false }
        XCTAssertFalse(marked("A=sk_live_abc123-_.:/+=@%"))
        XCTAssertFalse(marked("A=\"plain words & more\""))
        XCTAssertFalse(marked("A='$not `expanded` here'"))
        XCTAssertTrue(marked("A=two words"))
        XCTAssertTrue(marked("A=pa$$word"))
        XCTAssertTrue(marked("A=\"pa$$word\""))
        XCTAssertTrue(marked("A=\"line\\nbreak\""))
        XCTAssertTrue(marked("A=`date`"))
        XCTAssertTrue(marked("A='back\\slash'"))
        XCTAssertTrue(marked("A=a;b"))
    }

    func testVariableNames() {
        XCTAssertTrue(DotenvFile.isVariableName("_A1"))
        XCTAssertFalse(DotenvFile.isVariableName("1A"))
        XCTAssertFalse(DotenvFile.isVariableName("A-B"))
        XCTAssertFalse(DotenvFile.isVariableName(""))
        XCTAssertFalse(DotenvFile.isVariableName("É"))
    }
}
