import XCTest
@testable import PasswordPieCore

final class RecencyRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let table = DomainPopularity(ranks: ["google.com": 1, "github.com": 50])

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    private func entry(_ title: String, url: String = "", favorite: Bool = false) -> VaultEntry {
        var e = VaultEntry()
        e.title = title
        e.url = url
        if favorite { e.favorite = true }
        return e
    }

    private func titles(_ query: String, _ entries: [VaultEntry], used: [UUID: Date] = [:]) -> [String] {
        searchEntries(entries, query: query, scope: .major, popularity: table, lastUsed: used, now: now).map(\.title)
    }

    // MARK: Recency curve

    func testRecencyHalvesEveryThirtyDays() {
        XCTAssertEqual(Recency.score(lastUsed: now, now: now), 1, accuracy: 1e-9)
        XCTAssertEqual(Recency.score(lastUsed: ago(30), now: now), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Recency.score(lastUsed: ago(60), now: now), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Recency.score(lastUsed: ago(90), now: now), 0.125, accuracy: 1e-9)
        XCTAssertEqual(Recency.score(lastUsed: ago(1), now: now), 0.977, accuracy: 0.001)
        XCTAssertLessThan(Recency.score(lastUsed: ago(365), now: now), 0.001)
    }

    func testUnknownAndFutureTimesAreSafe() {
        XCTAssertEqual(Recency.score(lastUsed: nil, now: now), 0)
        XCTAssertEqual(Recency.score(lastUsed: now.addingTimeInterval(day), now: now), 1, "a clock skew counts as just used")
    }

    // MARK: How the two factors combine

    func testBoostWeighsRecencyOverSiteRankAndStaysUnderTheClassGap() {
        XCTAssertEqual(RankingBoost.value(recency: 1, site: 1), 0.24, accuracy: 1e-12)
        XCTAssertEqual(RankingBoost.value(recency: 0, site: 0), 0)
        XCTAssertEqual(RankingBoost.value(recency: 1, site: 0), 0.144, accuracy: 1e-12)
        XCTAssertEqual(RankingBoost.value(recency: 0, site: 1), 0.096, accuracy: 1e-12)
        // The closest match classes are 1.0 and 0.8, a factor of 1.25. The biggest boost must stay below that.
        XCTAssertLessThan(1 + RankingBoost.cap, 1.25)
    }

    // MARK: Ranking

    func testAnInternalToolUsedLastWeekBeatsAnUnusedTopSite() {
        let internalTool = entry("Alpha mail", url: "https://tool.internal.example")
        let top = entry("Zeta mail", url: "https://google.com")
        XCTAssertEqual(titles("mail", [top, internalTool], used: [internalTool.id: ago(7)]), ["Alpha mail", "Zeta mail"])
    }

    func testRecentUseBeatsAnOldUseOnAPopularSite() {
        let popularOld = entry("Zeta mail", url: "https://github.com")
        let unrankedRecent = entry("Alpha mail", url: "https://tool.internal.example")
        XCTAssertEqual(titles("mail", [popularOld, unrankedRecent], used: [popularOld.id: ago(60), unrankedRecent.id: ago(1)]),
                       ["Alpha mail", "Zeta mail"])
    }

    func testSiteRankStillBreaksATieWhenNeitherWasUsed() {
        let popular = entry("Zeta mail", url: "https://github.com")
        let unranked = entry("Alpha mail", url: "https://nobody.example")
        XCTAssertEqual(titles("mail", [unranked, popular]), ["Zeta mail", "Alpha mail"])
    }

    func testSiteRankStillCountsWhenBothWereUsedEquallyRecently() {
        let popular = entry("Zeta mail", url: "https://github.com")
        let unranked = entry("Alpha mail", url: "https://nobody.example")
        XCTAssertEqual(titles("mail", [unranked, popular], used: [popular.id: ago(3), unranked.id: ago(3)]), ["Zeta mail", "Alpha mail"])
    }

    func testRecentUseNeverLiftsAWeakerMatchClassAboveAStrongerOne() {
        let exactNeverUsed = entry("Bank", url: "https://nobody.example")
        let prefixUsedToday = entry("Banking Portal", url: "https://google.com")
        XCTAssertEqual(titles("bank", [prefixUsedToday, exactNeverUsed], used: [prefixUsedToday.id: now]),
                       ["Bank", "Banking Portal"])
        let laterPrefixToday = entry("Work Github", url: "https://google.com")
        let firstPrefixNever = entry("Github Work", url: "https://nobody.example")
        XCTAssertEqual(titles("gith", [laterPrefixToday, firstPrefixNever], used: [laterPrefixToday.id: now]),
                       ["Github Work", "Work Github"])
    }

    func testFavoritesStillComeFirstEvenWhenOthersWereUsedToday() {
        let favorite = entry("Zeta mail", url: "https://nobody.example", favorite: true)
        let recent = entry("Alpha mail", url: "https://google.com")
        XCTAssertEqual(titles("mail", [recent, favorite], used: [recent.id: now]), ["Zeta mail", "Alpha mail"])
    }

    func testNoUsageDataKeepsTheEarlierOrdering() {
        let items = [entry("Beta mail", url: "https://b.example"), entry("Alpha mail", url: "https://a.example")]
        XCTAssertEqual(titles("mail", items), ["Alpha mail", "Beta mail"])
    }

    func testMenuRowsUseTheLastUsedTimes() {
        let tool = entry("Alpha mail", url: "https://tool.internal.example")
        let other = entry("Zeta mail", url: "https://nobody.example")
        let rows = MenuBuilder.searchResults(entries: [other, tool], query: "mail", scope: .major, lastUsed: [tool.id: Date()])
        let order = rows.filter { if case .entry = $0.kind { return true } else { return false } }.map(\.title)
        XCTAssertEqual(order, ["Alpha mail", "Zeta mail"])
    }
}

final class UsageStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testRecordsSurviveAReload() throws {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UsageStore(url: url)
        try store.record(id, at: when)
        let reloaded = UsageStore(url: url)
        XCTAssertEqual(reloaded.lastUsed[id]?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
    }

    func testTheLatestUseWins() throws {
        let id = UUID()
        let store = UsageStore(url: url)
        try store.record(id, at: Date(timeIntervalSince1970: 2_000))
        try store.record(id, at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(store.lastUsed[id]?.timeIntervalSince1970 ?? 0, 2_000, accuracy: 1)
    }

    func testTheFileIsPrivate() throws {
        try UsageStore(url: url).record(UUID())
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAMissingOrCorruptFileStartsEmpty() throws {
        XCTAssertTrue(UsageStore(url: url).lastUsed.isEmpty)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(UsageStore(url: url).lastUsed.isEmpty)
    }

    func testTheFileHoldsOnlyIDsAndTimes() throws {
        let id = UUID()
        try UsageStore(url: url).record(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(id.uuidString))
        XCTAssertFalse(text.lowercased().contains("password"))
    }
}
