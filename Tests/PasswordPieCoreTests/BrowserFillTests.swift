import XCTest
@testable import PasswordPieCore

final class PublicSuffixTests: XCTestCase {
    func testRegistrableDomainOfOrdinaryHosts() {
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "github.com"), "github.com")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "www.github.com"), "github.com")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "gist.github.com"), "github.com")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "WWW.GitHub.COM."), "github.com")
    }

    func testMultiLabelSuffixes() {
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "a.b.example.com.au"), "example.com.au")
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "co.uk"))
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "com"))
    }

    func testPrivateSectionKeepsCustomersApart() {
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "alice.github.io"), "alice.github.io")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "bob.github.io"), "bob.github.io")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "my-app.herokuapp.com"), "my-app.herokuapp.com")
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "github.io"))
    }

    func testWildcardAndExceptionRules() {
        // *.ck and !www.ck
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "foo.ck"))
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "bar.foo.ck"), "bar.foo.ck")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "www.ck"), "www.ck")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "a.www.ck"), "www.ck")
    }

    func testUnknownTopLevelDomainUsesTheImplicitRule() {
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "sub.example.notarealtld"), "example.notarealtld")
    }

    func testHostsWithoutARegistrableDomain() {
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "localhost"))
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "intranet"))
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "192.168.1.1"))
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: "::1"))
        XCTAssertNil(PublicSuffix.registrableDomain(ofHost: ""))
    }

    func testInternationalSuffixInPunycode() {
        // 中国 is xn--fiqs8s.
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "www.example.xn--fiqs8s"), "example.xn--fiqs8s")
    }
}

final class BrowserSiteTests: XCTestCase {
    func testSiteKeyIsTheRegistrableDomain() {
        XCTAssertEqual(BrowserSite(url: "https://gist.github.com/x")?.key, "github.com")
        XCTAssertEqual(BrowserSite(url: "github.com")?.key, "github.com")
        XCTAssertEqual(BrowserSite(url: "  http://www.GitHub.com:8080/login ")?.key, "github.com")
    }

    func testHostsWithoutASuffixKeyOnHostAndPort() {
        XCTAssertEqual(BrowserSite(url: "http://localhost:8000/login.html")?.key, "localhost:8000")
        XCTAssertEqual(BrowserSite(url: "http://localhost/login.html")?.key, "localhost")
        XCTAssertEqual(BrowserSite(url: "192.168.1.1")?.key, "192.168.1.1")
        XCTAssertNotEqual(BrowserSite(url: "http://localhost:8000")?.key, BrowserSite(url: "http://localhost:9000")?.key)
    }

    func testOnlyWebSchemes() {
        for raw in ["", "  ", "chrome://settings", "about:blank", "file:///etc/hosts", "javascript:alert(1)", "android://h@com.app/", "ssh://host"] {
            XCTAssertNil(BrowserSite(url: raw), raw)
        }
    }

    func testOrigin() {
        XCTAssertEqual(BrowserSite(url: "https://github.com/login?x=1")?.origin, "https://github.com")
        XCTAssertEqual(BrowserSite(url: "http://localhost:8000/a")?.origin, "http://localhost:8000")
        XCTAssertEqual(BrowserSite(url: "https://example.com:443/a")?.origin, "https://example.com")
        XCTAssertEqual(BrowserSite(url: "HTTPS://WWW.Example.com/")?.origin, "https://www.example.com")
    }

    func testFillNeedsTheSameSite() {
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "github.com", pageURL: "https://github.com/login"))
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "https://github.com", pageURL: "https://gist.github.com/auth"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "github.com", pageURL: "https://github.com.evil.example/login"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "github.com", pageURL: "https://githubb.com/login"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "alice.github.io", pageURL: "https://bob.github.io/"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "", pageURL: "https://github.com/"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "github.com", pageURL: "about:blank"))
    }

    func testNoDowngradeToPlainHTTP() {
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "https://github.com", pageURL: "http://github.com/login"))
        XCTAssertFalse(BrowserSite.allowsFill(entryWebsite: "github.com", pageURL: "http://github.com/login"))
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "http://router.example", pageURL: "http://router.example/"))
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "http://localhost:8000", pageURL: "http://localhost:8000/login.html"))
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "https://localhost:8000", pageURL: "http://localhost:8000/login.html"))
        XCTAssertTrue(BrowserSite.allowsFill(entryWebsite: "127.0.0.1:8000", pageURL: "http://127.0.0.1:8000/"))
    }
}

final class PendingFillTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let id = UUID()

    private func pending(_ website: String = "https://github.com/login", browser: BridgeBrowser = .chrome) -> PendingFill {
        PendingFill(entryID: id, browser: browser, website: website, created: start)!
    }

    func testTakenOnceByAMatchingReport() {
        var store = PendingFillStore()
        store.set(pending())
        XCTAssertNil(store.take(browser: .chrome, pageURL: "https://example.com/", now: start + 1))
        XCTAssertEqual(store.take(browser: .chrome, pageURL: "https://github.com/session", now: start + 2)?.entryID, id)
        XCTAssertNil(store.take(browser: .chrome, pageURL: "https://github.com/session", now: start + 3))
    }

    func testOtherBrowserGetsNothing() {
        var store = PendingFillStore()
        store.set(pending(browser: .safari))
        XCTAssertNil(store.take(browser: .chrome, pageURL: "https://github.com/", now: start + 1))
        XCTAssertNotNil(store.take(browser: .safari, pageURL: "https://github.com/", now: start + 1))
    }

    func testExpiresAfterThirtySeconds() {
        var store = PendingFillStore()
        store.set(pending())
        XCTAssertNil(store.take(browser: .chrome, pageURL: "https://github.com/", now: start + 30.5))
        XCTAssertNil(store.pending, "an expired fill is dropped, not kept")
    }

    func testANewPickReplacesTheOldOne() {
        var store = PendingFillStore()
        store.set(pending("https://example.com"))
        store.set(pending("https://github.com"))
        XCTAssertNil(store.take(browser: .chrome, pageURL: "https://example.com/", now: start + 1))
        XCTAssertNotNil(store.take(browser: .chrome, pageURL: "https://github.com/", now: start + 1))
    }

    func testDowngradedPageNeverTakesIt() {
        var store = PendingFillStore()
        store.set(pending("https://github.com"))
        XCTAssertNil(store.take(browser: .chrome, pageURL: "http://github.com/", now: start + 1))
        XCTAssertNotNil(store.pending)
    }

    func testNoPendingFillWithoutAWebsite() {
        XCTAssertNil(PendingFill(entryID: id, browser: .chrome, website: "", created: start))
        XCTAssertNil(PendingFill(entryID: id, browser: .chrome, website: "ssh://host", created: start))
    }
}

final class BridgeHandlerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func login(_ url: String = "https://github.com", username: String = "octocat", password: String = "hunter2") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = url
        entry.username = username
        entry.password = password
        return entry
    }

    private func request(_ json: String) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
    }

    private func object(_ response: BridgeResponse) -> [String: Any] {
        let data = try! JSONEncoder().encode(response)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testHelloSaysWhetherLocked() {
        var state = BridgeState()
        let entry = login()
        let answer = state.handle(request(#"{"type":"hello","id":1,"version":1}"#), from: .chrome, locked: true, now: start) { _ in entry }
        XCTAssertEqual(object(answer)["type"] as? String, "hello")
        XCTAssertEqual(object(answer)["id"] as? Int, 1)
        XCTAssertEqual(object(answer)["locked"] as? Bool, true)
        XCTAssertEqual(object(answer)["version"] as? Int, 1)
    }

    func testTabReportFillsTheMatchingPendingOnce() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start)!)
        let tab = request(#"{"type":"tab","id":7,"url":"https://github.com/login","reason":"poke"}"#)
        let first = object(state.handle(tab, from: .chrome, locked: false, now: start + 1) { $0 == entry.id ? entry : nil })
        XCTAssertEqual(first["id"] as? Int, 7)
        let fill = first["fill"] as? [String: String]
        XCTAssertEqual(fill?["origin"], "https://github.com")
        XCTAssertEqual(fill?["username"], "octocat")
        XCTAssertEqual(fill?["password"], "hunter2")
        let second = object(state.handle(tab, from: .chrome, locked: false, now: start + 2) { _ in entry })
        XCTAssertNil(second["fill"])
    }

    func testTabReportUpdatesTheCurrentURL() {
        var state = BridgeState()
        _ = state.handle(request(#"{"type":"tab","id":1,"url":"https://github.com/login","reason":"activated"}"#), from: .safari, locked: false, now: start) { _ in nil }
        XCTAssertEqual(state.currentURL(for: .safari, now: start + 5), "https://github.com/login")
        XCTAssertNil(state.currentURL(for: .chrome, now: start + 5))
        _ = state.handle(request(#"{"type":"tab","id":2,"url":"chrome://newtab/","reason":"activated"}"#), from: .safari, locked: false, now: start) { _ in nil }
        XCTAssertNil(state.currentURL(for: .safari, now: start + 5), "a non-web page clears it")
    }

    func testLockedVaultNeverAnswersWithCredentials() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start)!)
        let tab = request(#"{"type":"tab","id":3,"url":"https://github.com/login"}"#)
        let answer = object(state.handle(tab, from: .chrome, locked: true, now: start + 1) { _ in entry })
        XCTAssertNil(answer["fill"])
        XCTAssertNil(state.pending.pending, "locking drops the pending fill")
    }

    func testEntryWhoseWebsiteChangedGetsNothing() {
        var state = BridgeState()
        let entry = login()
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: entry.url, created: start)!)
        let moved = login("https://example.com")
        let answer = object(state.handle(request(#"{"type":"tab","id":3,"url":"https://github.com/login"}"#), from: .chrome, locked: false, now: start + 1) { _ in moved })
        XCTAssertNil(answer["fill"])
    }

    func testOtherWebsiteOfTheEntryCounts() {
        var state = BridgeState()
        var entry = login("https://github.com")
        entry.setValue("https://github.enterprise.example", for: "URL (2)")
        state.pending.set(PendingFill(entryID: entry.id, browser: .chrome, website: "https://github.enterprise.example", created: start)!)
        let answer = object(state.handle(request(#"{"type":"tab","id":3,"url":"https://github.enterprise.example/login"}"#), from: .chrome, locked: false, now: start + 1) { _ in entry })
        XCTAssertEqual((answer["fill"] as? [String: String])?["origin"], "https://github.enterprise.example")
    }

    func testUnknownTypeIsABadRequest() {
        var state = BridgeState()
        let answer = object(state.handle(request(#"{"type":"steal","id":9}"#), from: .chrome, locked: false, now: start) { _ in nil })
        XCTAssertEqual(answer["type"] as? String, "error")
        XCTAssertEqual(answer["code"] as? String, "bad-request")
        XCTAssertEqual(answer["id"] as? Int, 9)
    }

    func testPokeHasNoID() {
        let poke = object(BridgeResponse.poke)
        XCTAssertEqual(poke["type"] as? String, "poke")
        XCTAssertNil(poke["id"])
        XCTAssertEqual(poke.count, 1)
    }

    func testResponseWithoutFillHasNoSecretKeys() {
        var state = BridgeState()
        let answer = object(state.handle(request(#"{"type":"tab","id":3,"url":"https://github.com/"}"#), from: .chrome, locked: false, now: start) { _ in nil })
        XCTAssertEqual(Set(answer.keys), ["type", "id"])
    }
}

final class SiteSuggestionTests: XCTestCase {
    private func entry(_ title: String, _ url: String, favorite: Bool = false, trashed: Bool = false) -> VaultEntry {
        var entry = VaultEntry(trashed: trashed)
        entry.title = title
        entry.url = url
        entry.username = title.lowercased()
        entry.favorite = favorite
        return entry
    }

    func testEntriesForTheSameSiteOnly() {
        let github = entry("GitHub", "https://github.com")
        let gist = entry("Gist", "gist.github.com")
        let other = entry("GitLab", "https://gitlab.com")
        let phishing = entry("Fake", "https://github.com.evil.example")
        let trashed = entry("Old", "https://github.com", trashed: true)
        let found = SiteSuggestions.entries([other, github, phishing, gist, trashed], pageURL: "https://github.com/login")
        XCTAssertEqual(Set(found.map(\.id)), [github.id, gist.id])
    }

    func testFavoritesThenRecentThenTitle() {
        let alpha = entry("Alpha", "github.com")
        let beta = entry("Beta", "github.com")
        let gamma = entry("Gamma", "github.com", favorite: true)
        let used = [beta.id: Date(timeIntervalSince1970: 100)]
        let found = SiteSuggestions.entries([alpha, beta, gamma], pageURL: "https://github.com/", lastUsed: used)
        XCTAssertEqual(found.map(\.title), ["Gamma", "Beta", "Alpha"])
    }

    func testOtherWebsitesMatchToo() {
        var jira = entry("Atlassian", "https://atlassian.com")
        jira.setValue("https://acme.atlassian.net", for: "URL (2)")
        let found = SiteSuggestions.entries([jira], pageURL: "https://acme.atlassian.net/login")
        XCTAssertEqual(found.map(\.id), [jira.id])
        XCTAssertEqual(SiteSuggestions.matchingWebsite(of: jira, pageURL: "https://acme.atlassian.net/login"), "https://acme.atlassian.net")
        XCTAssertNil(SiteSuggestions.matchingWebsite(of: jira, pageURL: "https://example.com"))
    }

    func testNoSuggestionsForNonWebPages() {
        XCTAssertTrue(SiteSuggestions.entries([entry("GitHub", "github.com")], pageURL: "chrome://newtab").isEmpty)
    }

    func testMenuRowsHaveAHeaderTheEntriesAndASeparator() {
        let github = entry("GitHub", "github.com")
        let rows = MenuBuilder.siteRows(site: "github.com", entries: [github])
        XCTAssertEqual(rows.map(\.kind), [.header, .entry(github.id), .separator])
        XCTAssertEqual(rows[0].title, "github.com")
    }

    func testMenuRowsCapAtFiveWithShowMore() {
        let many = (0..<7).map { entry("Account \($0)", "github.com") }
        let rows = MenuBuilder.siteRows(site: "github.com", entries: many)
        XCTAssertEqual(rows.filter { $0.entryID != nil }.count, 5)
        XCTAssertEqual(rows[6].kind, .showMore)
        XCTAssertEqual(rows[6].children.count, 2)
        XCTAssertEqual(rows.last?.kind, .separator)
    }

    func testNoRowsWithoutEntries() {
        XCTAssertTrue(MenuBuilder.siteRows(site: "github.com", entries: []).isEmpty)
    }
}
