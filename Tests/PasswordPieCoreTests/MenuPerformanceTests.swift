import Foundation
import XCTest
@testable import PasswordPieCore

/// Menus and search must stay fast for vaults of thousands of entries: the panel opens on the main thread.
final class MenuPerformanceTests: XCTestCase {
    static func sample(_ count: Int) -> [VaultEntry] {
        (0..<count).map { i in
            var entry = VaultEntry(
                groupPath: i % 2 == 0 ? ["Chrome", "Profile 1"] : ["Internet", "Sites \(i % 7)"],
                tags: i % 3 == 0 ? "Chrome" : ""
            )
            // Many repeated titles, as Chrome gives one row per account on the same site.
            entry.title = i % 5 == 0 ? "site\(i % 40).com" : "Account \(i) Ünïcode"
            entry.username = "user\(i)@example.com"
            entry.url = "https://site\(i % 300).example.com/login"
            entry.favorite = i % 50 == 0
            return entry
        }
    }

    private func titles(_ rows: [MenuRow]) -> [String] { rows.map(\.title) }

    /// Before the fix, each row compared its title with every other row: 3,000 entries took tens of seconds.
    func testLargeVaultBuildsMenuAndSearchQuickly() {
        let entries = Self.sample(3000)
        let start = Date()
        let top = MenuBuilder.topLevel(entries: entries)
        let found = MenuBuilder.searchResults(entries: entries, query: "acc", scope: .major)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(top.isEmpty)
        XCTAssertFalse(found.isEmpty)
        XCTAssertLessThan(elapsed, 3, "menu and search for 3,000 entries took \(elapsed) s")
    }

    func testASearchFindsAnAccountByAnyOfItsWebsites() {
        var account = VaultEntry()
        account.title = "corp.example"
        account.url = "https://gitlab.corp.example/users/sign_in"
        account.setValue("https://path-alm.corp.example/login.action", for: "URL (2)")
        account.setValue("https://path-jira.corp.example/login.jsp", for: "URL (3)")
        for query in ["path", "path-jira", "jira", "gitlab"] {
            XCTAssertEqual(searchEntries([account], query: query, scope: .major).map(\.id), [account.id], query)
        }
        XCTAssertEqual(searchEntries([account], query: "login", scope: .major), [], "only the host of a website is searched")
        XCTAssertEqual(searchEntries([account], query: "login", scope: .allFields), [])
    }

    func testOpeningFromASearchPicksTheWebsiteItNamed() {
        var account = VaultEntry()
        account.url = "https://gitlab.corp.example/users/sign_in"
        account.setValue("https://path-alm.corp.example/login.action", for: "URL (2)")
        account.setValue("https://path-jira.corp.example/login.jsp", for: "URL (3)")
        XCTAssertEqual(otherWebsite(of: account, matching: "jira"), "https://path-jira.corp.example/login.jsp")
        XCTAssertEqual(otherWebsite(of: account, matching: "PATH jira"), "https://path-jira.corp.example/login.jsp")
        XCTAssertEqual(otherWebsite(of: account, matching: "path"), "https://path-alm.corp.example/login.action", "the first site that matches")
        XCTAssertNil(otherWebsite(of: account, matching: "gitlab"), "the main website")
        XCTAssertNil(otherWebsite(of: account, matching: "corp.example"), "every site matches, so the main one wins")
        XCTAssertNil(otherWebsite(of: account, matching: "ann"), "not about a website")
        XCTAssertNil(otherWebsite(of: account, matching: ""))
    }

    func testAsciiTitleKeyMatchesTransform() {
        for title in ["GitHub", "mail.Example.COM", "Bank of X - Savings", ""] {
            let transformed = title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Any-Lower"), reverse: false) ?? title.lowercased()
            XCTAssertEqual(MenuBuilder.titleKey(title), transformed)
        }
        XCTAssertEqual(MenuBuilder.titleKey("Ünïcode"), "unicode")
    }

    func testIndexedSearchMatchesPlainSearch() {
        let entries = Self.sample(400)
        let index = SearchIndex(entries)
        for query in ["acc", "site3", "unicode 12", "zzz"] {
            XCTAssertEqual(
                titles(MenuBuilder.searchResults(index: index, query: query, scope: .major)),
                titles(MenuBuilder.searchResults(entries: entries, query: query, scope: .major)),
                query
            )
        }
    }

    func testIndexBuiltInPiecesGivesTheSameResults() {
        let entries = Self.sample(300)
        var index = SearchIndex()
        for start in stride(from: 0, to: entries.count, by: 70) {
            index = index.adding(SearchIndex(entries[start..<min(start + 70, entries.count)]))
        }
        XCTAssertEqual(index.count, entries.count)
        XCTAssertEqual(
            searchEntries(in: index, query: "site", scope: .major).map(\.id),
            searchEntries(entries, query: "site", scope: .major).map(\.id)
        )
    }

    /// While the index is incomplete, a search ranks only what has been indexed.
    func testPartialIndexSearchesWhatIsIndexed() {
        var github = VaultEntry()
        github.title = "GitHub"
        var gitlab = VaultEntry()
        gitlab.title = "GitLab"
        let partial = SearchIndex([github])
        XCTAssertEqual(searchEntries(in: partial, query: "git", scope: .major).map(\.title), ["GitHub"])
        XCTAssertEqual(searchEntries(in: partial.adding(SearchIndex([gitlab])), query: "git", scope: .major).map(\.title), ["GitHub", "GitLab"])
    }

    func testReusingKeepsUnchangedEntriesAndQueuesChangedOnes() {
        var entries = Self.sample(50)
        let index = SearchIndex(entries)
        entries[3].title = "Renamed"
        entries[7].trashed = true
        var added = VaultEntry()
        added.title = "Brand New"
        entries.append(added)
        let (kept, pending) = index.reusing(for: entries)
        XCTAssertEqual(kept.count, 48, "50 minus the renamed and the trashed entry")
        XCTAssertEqual(pending.map(\.title), ["Renamed", "Brand New"])
        let full = kept.adding(SearchIndex(pending))
        XCTAssertEqual(searchEntries(in: full, query: "renamed", scope: .major).map(\.id), [entries[3].id])
        XCTAssertTrue(searchEntries(in: full, query: entries[7].title, scope: .major).allSatisfy { $0.id != entries[7].id })
    }
}
