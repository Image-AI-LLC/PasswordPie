@testable import PasswordPieCore
import XCTest

final class AppLinksTests: XCTestCase {
    private let harbor = LinkedApp(bundleID: "example.harbor", teamID: "TEAM123456", name: "Harbor")
    private let ledger = LinkedApp(bundleID: "example.ledger", teamID: nil, name: "Ledger Pro")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ title: String = "Northwind SSO") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada@northwind.example"
        entry.password = "secret"
        return entry
    }

    // MARK: The link on the account

    func testAnAccountStartsWithNoApps() {
        XCTAssertEqual(AppLinks.apps(of: account()), [])
        XCTAssertFalse(AppLinks.isLinked(account(), to: harbor))
    }

    func testLinkingKeepsTheAppWithItsNameAndTeam() {
        var entry = account()
        XCTAssertTrue(AppLinks.link(harbor, to: &entry))
        XCTAssertTrue(AppLinks.link(ledger, to: &entry))
        XCTAssertEqual(AppLinks.apps(of: entry), [harbor, ledger], "in the order they were linked; a name may hold a space")
        XCTAssertTrue(AppLinks.isLinked(entry, to: harbor))
    }

    func testLinkingTwiceChangesNothing() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        let once = entry
        XCTAssertFalse(AppLinks.link(harbor, to: &entry))
        XCTAssertEqual(entry, once)
    }

    func testUnlinkingRemovesOnlyThatAppAndRemembersTheRefusal() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        AppLinks.link(ledger, to: &entry)
        XCTAssertTrue(AppLinks.unlink(harbor, from: &entry))
        XCTAssertEqual(AppLinks.apps(of: entry), [ledger])
        XCTAssertTrue(AppLinks.refuses(entry, harbor), "the link is not made again on its own")
        XCTAssertTrue(AppLinks.refuses(entry, LinkedApp(bundleID: "EXAMPLE.harbor", teamID: nil, name: "Harbor")),
                      "a refusal goes by the identifier, whoever signed the app in front")
        XCTAssertFalse(AppLinks.refuses(entry, ledger))
        XCTAssertFalse(AppLinks.unlink(harbor, from: &entry), "nothing left to take back")
    }

    func testLinkingAgainByHandClearsTheRefusal() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        AppLinks.unlink(harbor, from: &entry)
        XCTAssertTrue(AppLinks.link(harbor, to: &entry))
        XCTAssertFalse(AppLinks.refuses(entry, harbor))
        XCTAssertEqual(AppLinks.apps(of: entry), [harbor])
    }

    func testTheLastAppGoneLeavesNoEmptyField() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        AppLinks.unlink(harbor, from: &entry, remember: false)
        XCTAssertFalse(entry.fields.contains { $0.key == AppLinks.key })
    }

    func testAnotherAppWithTheSameIdentifierButAnotherTeamIsNotTheLinkedApp() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        let impostor = LinkedApp(bundleID: "example.harbor", teamID: "OTHER00000", name: "Harbor")
        let unsigned = LinkedApp(bundleID: "example.harbor", teamID: nil, name: "Harbor")
        XCTAssertFalse(AppLinks.isLinked(entry, to: impostor))
        XCTAssertFalse(AppLinks.isLinked(entry, to: unsigned))
        let before = entry
        XCTAssertFalse(AppLinks.link(impostor, to: &entry), "it does not take the link over")
        XCTAssertFalse(AppLinks.link(unsigned, to: &entry), "and an app whose signer cannot be read does not loosen it")
        XCTAssertEqual(entry, before)
        XCTAssertTrue(AppLinks.isLinked(entry, to: LinkedApp(bundleID: "Example.Harbor", teamID: "TEAM123456", name: "Harbor 2")),
                      "an identifier has no case, and a renamed app is the same app")
    }

    func testAnAppLinkedWithoutATeamMatchesByIdentifier() {
        var entry = account()
        AppLinks.link(ledger, to: &entry)
        XCTAssertTrue(AppLinks.isLinked(entry, to: LinkedApp(bundleID: "example.ledger", teamID: "ANYTEAM000", name: "Ledger")))
    }

    func testAFieldSomeoneElseWroteIsReadAsFarAsItMakesSense() {
        var entry = account()
        entry.setValue("example.harbor\tTEAM123456\tHarbor\n\nnot a line\n!example.ledger\t-\tLedger Pro\nexample.notes", for: AppLinks.key)
        XCTAssertEqual(AppLinks.apps(of: entry), [harbor, LinkedApp(bundleID: "example.notes", teamID: nil, name: "example.notes")])
        XCTAssertTrue(AppLinks.refuses(entry, ledger))
    }

    func testANameWithALineBreakOrATabInItStaysOneLine() {
        var entry = account()
        AppLinks.link(LinkedApp(bundleID: "example.odd", teamID: nil, name: "Odd\u{2028}Name\r\tHere"), to: &entry)
        AppLinks.link(ledger, to: &entry)
        XCTAssertEqual(AppLinks.apps(of: entry), [LinkedApp(bundleID: "example.odd", teamID: nil, name: "Odd Name  Here"), ledger])
    }

    func testTheFieldIsBookkeepingAndNotACustomField() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        XCTAssertTrue(EntryMerge.isReservedKey(AppLinks.key))
        XCTAssertEqual(EntryFields.custom(of: entry), [])
    }

    func testMergingTwoCopiesOfAnAccountKeepsTheAppsOfBoth() throws {
        func copy(_ title: String) -> VaultEntry {
            var entry = account(title)
            entry.url = "https://sso.northwind.example/login"
            return entry
        }
        var first = copy("Northwind SSO")
        var second = copy("Northwind")
        AppLinks.link(harbor, to: &first)
        AppLinks.link(ledger, to: &second)
        let merged = EntryMerge.merged([first, second])
        let survivor = try XCTUnwrap(merged.first { !$0.trashed })
        XCTAssertEqual(merged.filter { !$0.trashed }.count, 1)
        XCTAssertEqual(Set(AppLinks.apps(of: survivor)), [harbor, ledger])
        XCTAssertEqual(EntryMerge.merged(merged), merged, "a second pass changes nothing")

        // An app the user took off the survivor is not brought back by a copy.
        var refusing = copy("Northwind SSO")
        refusing.notes = "the one with more in it"
        AppLinks.link(harbor, to: &refusing)
        AppLinks.unlink(harbor, from: &refusing)
        var linked = copy("Northwind")
        AppLinks.link(harbor, to: &linked)
        let kept = try XCTUnwrap(EntryMerge.merged([refusing, linked]).first { !$0.trashed })
        XCTAssertEqual(AppLinks.apps(of: kept), [])
        XCTAssertTrue(AppLinks.refuses(kept, harbor))

        // A refusal on the copy is kept when the survivor has no word on the app.
        var fuller = copy("Northwind SSO")
        fuller.notes = "the one with more in it"
        var unlinked = copy("Northwind")
        AppLinks.link(harbor, to: &unlinked)
        AppLinks.unlink(harbor, from: &unlinked)
        let refused = EntryMerge.merged([fuller, unlinked])
        let refusedSurvivor = try XCTUnwrap(refused.first { !$0.trashed })
        XCTAssertTrue(AppLinks.refuses(refusedSurvivor, harbor))
        XCTAssertEqual(EntryMerge.merged(refused), refused, "a second pass changes nothing")

        // The survivor's own link is not undone by a copy that refused it.
        var linkedSurvivor = copy("Northwind SSO")
        linkedSurvivor.notes = "the one with more in it"
        AppLinks.link(harbor, to: &linkedSurvivor)
        let stayed = try XCTUnwrap(EntryMerge.merged([linkedSurvivor, unlinked]).first { !$0.trashed })
        XCTAssertEqual(AppLinks.apps(of: stayed), [harbor])
        XCTAssertFalse(AppLinks.refuses(stayed, harbor))
    }

    // MARK: The accounts of an app

    func testAccountsOfAnAppAreFavoritesThenMostRecentlyUsedThenTitle() {
        var first = account("Alpha")
        var second = account("Beta")
        var third = account("Gamma")
        var favorite = account("Zeta")
        favorite.favorite = true
        var trashed = account("Trashed")
        trashed.trashed = true
        let other = account("Other")
        for index in [0, 1, 2, 3, 4] {
            switch index {
            case 0: AppLinks.link(harbor, to: &first)
            case 1: AppLinks.link(harbor, to: &second)
            case 2: AppLinks.link(harbor, to: &third)
            case 3: AppLinks.link(harbor, to: &favorite)
            default: AppLinks.link(harbor, to: &trashed)
            }
        }
        let used = [third.id: start, second.id: start.addingTimeInterval(60)]
        let found = AppLinks.entries([first, second, third, favorite, trashed, other], linkedTo: harbor, lastUsed: used)
        XCTAssertEqual(found.map(\.title), ["Zeta", "Beta", "Gamma", "Alpha"])
    }

    func testTheAppGroupHasTheAppsNameAndItsAccounts() {
        var entry = account()
        AppLinks.link(harbor, to: &entry)
        let rows = MenuBuilder.appRows(app: harbor, entries: [entry])
        XCTAssertEqual(rows.first?.kind, .header)
        XCTAssertEqual(rows.first?.title, "Harbor")
        XCTAssertEqual(rows.first?.appBundleID, "example.harbor", "the header shows which app the group is for")
        XCTAssertEqual(rows.dropFirst().first?.entryID, entry.id)
        XCTAssertEqual(rows.last, .separator)
        XCTAssertEqual(MenuBuilder.appRows(app: harbor, entries: []), [])
    }

    // MARK: The rule that makes a link

    func testUsernameThenPasswordOverTheSameAppMakesTheLink() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start))
        XCTAssertTrue(learner.copied(.password, of: id, over: harbor, at: start.addingTimeInterval(20)))
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start.addingTimeInterval(21)), "the pair is spent")
    }

    func testTheOrderDoesNotMatter() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start))
        XCTAssertTrue(learner.copied(.username, of: id, over: harbor, at: start.addingTimeInterval(5)))
    }

    func testTheSameFieldTwiceIsNotAPair() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start))
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start.addingTimeInterval(5)))
        XCTAssertTrue(learner.copied(.username, of: id, over: harbor, at: start.addingTimeInterval(10)))
    }

    func testAnotherAppOrAnotherAccountStartsAgain() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start))
        XCTAssertFalse(learner.copied(.password, of: id, over: ledger, at: start.addingTimeInterval(5)), "pasted somewhere else")
        XCTAssertFalse(learner.copied(.password, of: UUID(), over: ledger, at: start.addingTimeInterval(6)), "another account")
        XCTAssertFalse(learner.copied(.username, of: id, over: ledger, at: start.addingTimeInterval(7)), "the first copy is forgotten")
    }

    func testThePairHasFiveMinutes() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start))
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start.addingTimeInterval(300)))
        XCTAssertTrue(learner.copied(.username, of: id, over: harbor, at: start.addingTimeInterval(599)))
    }

    func testAClockThatWentBackDoesNotCount() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start))
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start.addingTimeInterval(-1)))
    }

    func testLockingForgetsTheFirstCopy() {
        var learner = AppLinkLearner()
        let id = UUID()
        XCTAssertFalse(learner.copied(.username, of: id, over: harbor, at: start))
        learner.forget()
        XCTAssertFalse(learner.copied(.password, of: id, over: harbor, at: start.addingTimeInterval(5)))
    }
}
