import XCTest
@testable import PasswordPieCore

/// A `tab` report's `signIn`: whether the page shows a sign-in form (docs/BROWSER_EXTENSION.md, "`tab`").
final class BridgeSignInTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let chrome = BridgePeer(.chrome, link: 1)

    private func request(_ json: String) throws -> BridgeRequest {
        try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    @discardableResult
    private func report(_ state: inout BridgeState, _ json: String, at time: Date? = nil) throws -> BridgeResponse {
        state.handle(try request(json), from: .chrome, link: 1, locked: false, now: time ?? now) { _ in nil }
    }

    func testAReportThatSaysSoIsKeptWithItsPage() throws {
        var state = BridgeState()
        try report(&state, #"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":true,"signIn":true}"#)
        XCTAssertEqual(state.currentPage(for: .chrome, now: now), ReportedPage(url: "https://portal.example.com/", signIn: true))
        XCTAssertEqual(state.currentURL(for: .chrome, now: now), "https://portal.example.com/")
    }

    func testAReportThatSaysNoOrNothingIsNotASignInPage() throws {
        var state = BridgeState()
        try report(&state, #"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":true,"signIn":false}"#)
        XCTAssertEqual(state.currentPage(for: .chrome, now: now)?.signIn, false)
        // An extension from before 0.8.0 says nothing.
        try report(&state, #"{"type":"tab","id":2,"url":"https://portal.example.com/","focused":true}"#)
        XCTAssertEqual(state.currentPage(for: .chrome, now: now)?.signIn, false)
    }

    func testTheNextReportReplacesIt() throws {
        var state = BridgeState()
        try report(&state, #"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":true,"signIn":true}"#)
        // The person went on to a page without a form: what was said of the last page is not said of this one.
        try report(&state, #"{"type":"tab","id":2,"url":"https://news.example.org/","focused":true}"#)
        XCTAssertEqual(state.currentPage(for: .chrome, now: now), ReportedPage(url: "https://news.example.org/", signIn: false))
        // A page that is not a web page is no page at all.
        try report(&state, #"{"type":"tab","id":3,"url":"https://portal.example.com/","focused":true,"signIn":true}"#)
        try report(&state, #"{"type":"tab","id":4,"url":"","focused":true,"signIn":true}"#)
        XCTAssertNil(state.currentPage(for: .chrome, now: now))
    }

    func testAnotherProfilesSignInPageIsNotThePageInFront() throws {
        var state = BridgeState()
        try report(&state, #"{"type":"tab","id":1,"url":"https://news.example.org/","focused":true}"#)
        _ = state.handle(
            try request(#"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":false,"signIn":true}"#),
            from: .chrome, link: 2, locked: false, now: now
        ) { _ in nil }
        XCTAssertEqual(state.currentPage(for: .chrome, now: now), ReportedPage(url: "https://news.example.org/", signIn: false))
    }

    func testAnOldReportIsForgottenWithItsPage() throws {
        var state = BridgeState()
        try report(&state, #"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":true,"signIn":true}"#)
        XCTAssertNil(state.currentPage(for: .chrome, now: now.addingTimeInterval(3601)))
    }

    func testALockedVaultStillLearnsThePage() throws {
        // The report is about the browser, not the vault: after unlocking, the panel knows the page it is over.
        var state = BridgeState()
        _ = state.handle(
            try request(#"{"type":"tab","id":1,"url":"https://portal.example.com/","focused":true,"signIn":true}"#),
            from: .chrome, link: 1, locked: true, now: now
        ) { _ in nil }
        XCTAssertEqual(state.currentPage(for: .chrome, now: now)?.signIn, true)
    }
}

/// The website a pick on a sign-in page adds to the account, and takes off again (docs/UX.md, "An account you pick on
/// another site's sign-in page").
final class EntryWebsitesTests: XCTestCase {
    private func login(url: String = "https://github.com/login") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = url
        entry.username = "octocat"
        entry.password = "hunter2"
        return entry
    }

    func testTheAddressKeptIsThePagesOrigin() {
        XCTAssertEqual(EntryWebsites.address(forPage: "https://portal.example.com/"), "https://portal.example.com")
        XCTAssertEqual(EntryWebsites.address(forPage: "https://portal.example.com:8443/sign-in?next=%2F"), "https://portal.example.com:8443")
        XCTAssertEqual(EntryWebsites.address(forPage: "http://localhost:8787/demo/login"), "http://localhost:8787")
    }

    func testAPlainHTTPPageOrNoPageIsNeverAdded() {
        XCTAssertNil(EntryWebsites.address(forPage: "http://portal.example.com/"))
        XCTAssertNil(EntryWebsites.address(forPage: "chrome://settings/"))
        XCTAssertNil(EntryWebsites.address(forPage: ""))
    }

    func testTheLabelIsTheHostAndItsPort() {
        XCTAssertEqual(EntryWebsites.label(of: "https://portal.example.com"), "portal.example.com")
        XCTAssertEqual(EntryWebsites.label(of: "http://localhost:8787"), "localhost:8787")
        XCTAssertEqual(EntryWebsites.label(of: "http://[::1]:8787"), "[::1]:8787")
        XCTAssertEqual(EntryWebsites.label(of: "not a site"), "not a site")
    }

    func testASiteIsAddedAfterTheWebsitesTheAccountHas() {
        var entry = login()
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &entry))
        XCTAssertEqual(entry.url, "https://github.com/login", "the main website stays")
        XCTAssertEqual(entryWebsites(entry), ["https://github.com/login", "https://portal.example.com"])
        XCTAssertEqual(entry.value(for: "URL (2)"), "https://portal.example.com")

        XCTAssertTrue(EntryWebsites.add("https://checkout.example.net", to: &entry))
        XCTAssertEqual(entry.value(for: "URL (3)"), "https://checkout.example.net")
        XCTAssertEqual(entry.username, "octocat")
        XCTAssertEqual(entry.password, "hunter2")
    }

    func testAnAccountWithoutAWebsiteGetsItAsItsWebsite() {
        var entry = login(url: "")
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &entry))
        XCTAssertEqual(entry.url, "https://portal.example.com")
        XCTAssertTrue(EntryMerge.otherWebsites(entry).isEmpty)
    }

    func testASiteTheAccountAlreadyFillsIsNotAddedAgain() {
        var entry = login()
        let before = entry
        XCTAssertFalse(EntryWebsites.add("https://gist.github.com", to: &entry), "the same site, by its registrable domain")
        XCTAssertFalse(EntryWebsites.add("nonsense://", to: &entry))
        XCTAssertEqual(entry, before)
    }

    func testANameAlreadyTakenIsSkipped() {
        var entry = login()
        entry.setValue("https://acme.atlassian.net", for: "URL (2)")
        entry.setValue("kept", for: "url (3)")
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &entry))
        XCTAssertEqual(entry.value(for: "URL (4)"), "https://portal.example.com")
        XCTAssertEqual(entry.value(for: "url (3)"), "kept")
    }

    func testUndoTakesOffExactlyWhatWasAdded() {
        var entry = login()
        entry.setValue("https://acme.atlassian.net", for: "URL (2)")
        let before = entry
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &entry))
        XCTAssertTrue(EntryWebsites.remove("https://portal.example.com", from: &entry))
        XCTAssertEqual(entry, before)
        XCTAssertFalse(EntryWebsites.remove("https://portal.example.com", from: &entry), "nothing left to take off")

        var bare = login(url: "")
        let bareBefore = bare
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &bare))
        XCTAssertTrue(EntryWebsites.remove("https://portal.example.com", from: &bare))
        XCTAssertEqual(bare, bareBefore)
    }

    func testUndoLeavesAWebsiteThePersonChangedSince() {
        var entry = login()
        XCTAssertTrue(EntryWebsites.add("https://portal.example.com", to: &entry))
        entry.setValue("https://portal.example.com/sign-in", for: "URL (2)")
        let edited = entry
        XCTAssertFalse(EntryWebsites.remove("https://portal.example.com", from: &entry))
        XCTAssertEqual(entry, edited)
    }
}
