import XCTest
@testable import PasswordPieCore

final class PopularityRankingTests: XCTestCase {
    private let table = DomainPopularity(ranks: [
        "google.com": 1,
        "github.com": 50,
        "bbc.co.uk": 800,
        "tiny.example": 10_000
    ])

    private func entry(_ title: String, url: String = "", user: String = "", favorite: Bool = false) -> VaultEntry {
        var e = VaultEntry()
        e.title = title
        e.url = url
        e.username = user
        if favorite { e.favorite = true }
        return e
    }

    private func titles(_ query: String, _ entries: [VaultEntry], scope: SearchScope = .major) -> [String] {
        searchEntries(entries, query: query, scope: scope, popularity: table).map(\.title)
    }

    // MARK: Popularity table

    func testSubdomainsTakeTheirRootDomainsRank() {
        XCTAssertEqual(table.rank(forHost: "github.com"), 50)
        XCTAssertEqual(table.rank(forHost: "gist.github.com"), 50)
        XCTAssertEqual(table.rank(forHost: "a.b.github.com"), 50)
    }

    func testMultiPartSuffixesNeedNoPublicSuffixList() {
        XCTAssertEqual(table.rank(forHost: "www.bbc.co.uk"), 800)
        XCTAssertNil(table.rank(forHost: "evil.co.uk"))
        XCTAssertNil(table.rank(forHost: "co.uk"))
        XCTAssertNil(table.rank(forHost: "com"))
    }

    func testUnknownAndEmptyHostsHaveNoRank() {
        XCTAssertNil(table.rank(forHost: ""))
        XCTAssertNil(table.rank(forHost: "my-bank.example"))
        XCTAssertNil(table.rank(forHost: "192.168.0.1"))
    }

    func testPopularityFallsSlowlyFromOneToZero() {
        let top = table.popularity(forHost: "google.com")
        let mid = table.popularity(forHost: "github.com")
        let low = table.popularity(forHost: "bbc.co.uk")
        let edge = table.popularity(forHost: "tiny.example")
        XCTAssertEqual(top, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(top, mid)
        XCTAssertGreaterThan(mid, low)
        XCTAssertGreaterThan(low, edge)
        XCTAssertGreaterThanOrEqual(edge, 0)
        XCTAssertLessThan(edge, 0.01)
        XCTAssertEqual(table.popularity(forHost: "nobody.example"), 0)
        // Rank 1 against rank 100 is a gap of about 50%, not the 100x a reciprocal would give.
        XCTAssertGreaterThan(mid, 0.5)
    }

    // MARK: Ranking

    func testWhenMatchesAreEqualThePopularSiteWins() {
        let items = [
            entry("Alpha mail", url: "https://nobody.example"),
            entry("Zeta mail", url: "https://github.com")
        ]
        XCTAssertEqual(titles("mail", items), ["Zeta mail", "Alpha mail"])
    }

    func testAnExactWordOnAnUnrankedSiteBeatsAPrefixOnTheTopSite() {
        let items = [
            entry("Banking Portal", url: "https://google.com"),
            entry("Bank", url: "https://my-bank.example")
        ]
        XCTAssertEqual(titles("bank", items), ["Bank", "Banking Portal"])
    }

    func testPopularityNeverLiftsALaterWordPrefixAboveAFirstWordPrefix() {
        let items = [
            entry("Work Github", url: "https://google.com"),
            entry("Github Work", url: "https://nobody.example")
        ]
        XCTAssertEqual(titles("gith", items), ["Github Work", "Work Github"])
    }

    func testAnExactWordMatchIgnoresItsPosition() {
        let items = [
            entry("Github Work", url: "https://nobody.example"),
            entry("Work Github", url: "https://google.com")
        ]
        XCTAssertEqual(titles("github", items), ["Work Github", "Github Work"])
    }

    func testPrefixHitsStayAboveSubstringOnlyHits() {
        let items = [
            entry("Megamail", url: "https://google.com"),
            entry("Mail Box", url: "https://nobody.example")
        ]
        XCTAssertEqual(titles("mail", items), ["Mail Box"])
        // With no prefix hit at all, the substring pass runs and popularity orders its equal matches.
        XCTAssertEqual(titles("ail", items), ["Megamail", "Mail Box"])
    }

    func testFavoritesStillComeFirst() {
        let items = [
            entry("Zeta mail", url: "https://google.com"),
            entry("Alpha mail", url: "https://nobody.example", favorite: true)
        ]
        XCTAssertEqual(titles("mail", items), ["Alpha mail", "Zeta mail"])
    }

    func testUnrankedSitesTieBreakAlphabetically() {
        let items = [
            entry("Beta mail", url: "https://b.example"),
            entry("Alpha mail", url: "https://a.example")
        ]
        XCTAssertEqual(titles("mail", items), ["Alpha mail", "Beta mail"])
    }

    func testASubdomainEntryRanksWithItsRootDomain() {
        let items = [
            entry("Zeta mail", url: "https://gist.github.com/login"),
            entry("Alpha mail", url: "https://other.example")
        ]
        XCTAssertEqual(titles("mail", items), ["Zeta mail", "Alpha mail"])
    }

    func testAMoreCompleteMatchOnSeveralWordsOutranksAPartialOne() {
        let items = [
            entry("Zeta Google Drive", url: "https://nobody.example"),
            entry("Google Mail", url: "https://nobody2.example")
        ]
        XCTAssertEqual(titles("google mail", items), ["Google Mail"])
    }

    func testTitleThatIsAHostFallsBackWhenTheURLIsEmpty() {
        let items = [
            entry("Alpha mail"),
            entry("github.com mail")
        ]
        // "github.com mail" has no URL; its title is not a bare domain, so it gets no boost.
        XCTAssertEqual(titles("mail", items), ["Alpha mail", "github.com mail"])
        let bare = [entry("zeta.example"), entry("github.com")]
        XCTAssertEqual(titles(".", bare), ["github.com", "zeta.example"])
    }

    func testBundledTableIsLoadedAndSane() {
        let bundled = DomainPopularity.bundled
        XCTAssertEqual(bundled.rank(forHost: "google.com"), 1)
        XCTAssertNotNil(bundled.rank(forHost: "www.github.com"))
        XCTAssertGreaterThanOrEqual(bundled.count, 9_000)
        XCTAssertLessThanOrEqual(bundled.count, 10_000)
    }
}
