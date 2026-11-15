import XCTest

/// The App Store Connect fields in docs/APP_STORE_LISTING.md fit the store's limits, and the copy names nothing the App
/// Store build lacks (docs/CHANNELS.md).
final class AppStoreListingTests: XCTestCase {
    private func listing() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/APP_STORE_LISTING.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text inside the first ```text fence after the heading `heading` (any level), before the next heading.
    private func field(_ heading: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let lines = try listing().components(separatedBy: "\n")
        let start = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("#") && $0.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) == heading },
            "No heading \"\(heading)\"", file: file, line: line
        )
        var body: [String]?
        for text in lines[(start + 1)...] {
            if var collected = body {
                if text == "```" { return collected.joined(separator: "\n") }
                collected.append(text)
                body = collected
            } else if text == "```text" {
                body = []
            } else if text.hasPrefix("#") {
                break
            }
        }
        XCTFail("No ```text block under \"\(heading)\"", file: file, line: line)
        return ""
    }

    private func assertFits(_ heading: String, _ limit: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try field(heading, file: file, line: line)
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(heading) is empty", file: file, line: line)
        XCTAssertLessThanOrEqual(value.count, limit, "\(heading) has \(value.count) characters", file: file, line: line)
    }

    func testAppInformationFitsTheStoreLimits() throws {
        try assertFits("App name", 30)
        try assertFits("Subtitle", 30)
        try assertFits("Promotional text", 170)
        try assertFits("Description", 4000)
    }

    func testKeywordsAreCommaSeparatedWithinOneHundredCharacters() throws {
        let keywords = try field("Keywords")
        XCTAssertLessThanOrEqual(keywords.count, 100, "keywords have \(keywords.count) characters")
        XCTAssertFalse(keywords.contains("\n"))
        XCTAssertFalse(keywords.contains(", "), "no space after a comma")
        let words = keywords.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(words.count, 1)
        for word in words {
            XCTAssertFalse(word.isEmpty, "empty keyword")
            XCTAssertEqual(word, word.trimmingCharacters(in: .whitespaces)[...], "keyword \"\(word)\" has spaces around it")
        }
        let name = try field("App name").lowercased()
        for word in words where name.contains(word.lowercased()) {
            XCTFail("keyword \"\(word)\" repeats the app name")
        }
    }

    func testInAppPurchaseNamesAndDescriptionsFit() throws {
        try assertFits("Lifetime display name", 30)
        try assertFits("Yearly display name", 30)
        try assertFits("Lifetime description", 45)
        try assertFits("Yearly description", 45)
    }

    func testStoreCopyNamesNothingTheAppStoreBuildLacks() throws {
        let banned = ["chrome extension", "automatic update", "updates itself", "passwordpie.com/pricing"]
        for heading in ["Description", "Promotional text"] {
            let text = try field(heading).lowercased()
            for phrase in banned {
                XCTAssertFalse(text.contains(phrase), "\(heading) mentions \"\(phrase)\"")
            }
        }
    }

    func testReviewNotesCarryTheActivationPlaceholder() throws {
        let notes = try field("App Review notes")
        XCTAssertTrue(notes.contains("passwordpie://activate?token="))
        XCTAssertTrue(notes.contains("<ACTIVATION LINK FOR REVIEW"))
        // App Store Connect takes 4000 characters; the pasted link (about 380) replaces the placeholder.
        XCTAssertLessThanOrEqual(notes.count, 3500, "review notes have \(notes.count) characters")
    }
}
