import Foundation
@testable import PasswordPieCore
import XCTest

/// The merge engine (`KDBXMerge.swift`): two copies of one fixture database stand in for two Macs.
final class KDBXMergeTests: XCTestCase {
    // MARK: Different items

    func testDifferentItemsChangedOnEachCopyBothSurviveAndNothingIsListed() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        // This Mac changed Bank. The other Mac changed Mail and added a key.
        let here = try MergeCopy(items: [
            MergeItem(0xA1, "Bank", password: "new-bank", modified: 10, history: [original]),
            MergeItem(0xA2, "Mail", password: "mail")
        ]).vault()
        let there = try MergeCopy(items: [
            original,
            MergeItem(0xA2, "Mail", password: "new-mail", modified: 20, history: [MergeItem(0xA2, "Mail", password: "mail")]),
            MergeItem(0xA3, "API key", password: "key", modified: 15)
        ]).vault()

        let outcome = try merged(there, into: here)

        XCTAssertEqual(outcome.vault.item(0xA1)?.password, "new-bank")
        XCTAssertEqual(outcome.vault.item(0xA2)?.password, "new-mail")
        XCTAssertEqual(outcome.vault.item(0xA3)?.password, "key")
        XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["old"])
        XCTAssertEqual(outcome.vault.historyPasswords(0xA2), ["mail"])
        XCTAssertEqual(outcome.report.changedOnBoth, [])
        XCTAssertEqual(outcome.report.added, 1)
        XCTAssertEqual(outcome.report.updated, 1)
        XCTAssertTrue(outcome.report.changed)
        XCTAssertNil(outcome.vault.customData[MergeConflictLog.customDataKey])
    }

    // MARK: The same item

    func testTheSameItemChangedOnBothTheNewerIsCurrentAndTheOlderIsInItsHistoryAndListed() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "here", modified: 10, history: [original])]).vault()
        let there = try MergeCopy(items: [MergeItem(0xA1, "Bank (new)", password: "there", modified: 20, history: [original])]).vault()

        for (base, other) in [(here, there), (there, here)] {
            let outcome = try merged(other, into: base)
            XCTAssertEqual(outcome.vault.item(0xA1)?.password, "there")
            XCTAssertEqual(outcome.vault.item(0xA1)?.title, "Bank (new)")
            XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["old", "here"])
            XCTAssertEqual(outcome.vault.historyTimes(0xA1), [0, 10])
            XCTAssertEqual(outcome.report.changedOnBoth, [
                VaultMergeReport.Item(id: mergeID(0xA1), title: "Bank (new)", kept: mergeDate(20), older: mergeDate(10))
            ])
            // The database itself says so, for the Mac that did not do this merge.
            XCTAssertEqual(MergeConflictLog.records(in: outcome.vault.customData), [
                MergeConflictLog.Record(item: mergeID(0xA1), kept: Int64(mergeDate(20).timeIntervalSince1970), older: Int64(mergeDate(10).timeIntervalSince1970))
            ])
        }
    }

    func testAnItemChangedOnOneCopyOnlyIsNotListed() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        let unchanged = try MergeCopy(items: [original]).vault()
        let changed = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "new", modified: 10, history: [original])]).vault()

        for (base, other) in [(unchanged, changed), (changed, unchanged)] {
            let outcome = try merged(other, into: base)
            XCTAssertEqual(outcome.vault.item(0xA1)?.password, "new")
            XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["old"])
            XCTAssertEqual(outcome.report.changedOnBoth, [])
        }
        XCTAssertFalse(try merged(unchanged, into: changed).report.changed, "the changed copy already holds everything")
    }

    /// The way the app really edits: the version before an edit goes into the history, with the time it had.
    func testAnEditMadeByTheAppIsNotListedWhenTheOtherCopyDidNotChange() throws {
        let other = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "old"), MergeItem(0xA2, "Mail")]).vault()
        var edited = other
        edited.entries[0].password = "new"
        _ = try KDBX.save(vault: &edited, password: "secret")

        let outcome = try merged(other, into: edited)
        XCTAssertEqual(outcome.report.changedOnBoth, [])
        XCTAssertFalse(outcome.report.changed)
        let reverse = try merged(edited, into: other)
        XCTAssertEqual(reverse.report.changedOnBoth, [])
        XCTAssertEqual(reverse.vault.item(0xA1)?.password, "new")
        XCTAssertEqual(reverse.vault.historyPasswords(0xA1), ["old"])
    }

    func testAnEditNotYetSavedIsPartOfTheMerge() throws {
        let there = try MergeCopy(items: [MergeItem(0xA1, "Bank"), MergeItem(0xA2, "Mail", password: "new-mail", modified: 20)]).vault()
        var here = try MergeCopy(items: [MergeItem(0xA1, "Bank"), MergeItem(0xA2, "Mail")]).vault()
        here.entries[0].password = "typed-just-now"

        let outcome = try merged(here, into: there)
        XCTAssertEqual(outcome.vault.item(0xA1)?.password, "typed-just-now")
        XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["pw"])
        XCTAssertEqual(outcome.vault.item(0xA2)?.password, "new-mail")
        XCTAssertEqual(here.preserve?.versions(of: mergeID(0xA1)).count, 0, "the vault that was merged is not changed")
    }

    func testTheSameSecondAndDifferentContentGivesTheSameItemBothWaysAndKeepsBothVersions() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "here", modified: 10, history: [original])]).vault()
        let there = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "there", modified: 10, history: [original])]).vault()

        let one = try merged(there, into: here)
        let two = try merged(here, into: there)
        XCTAssertEqual(one.vault.item(0xA1)?.password, two.vault.item(0xA1)?.password)
        let current = try XCTUnwrap(one.vault.item(0xA1)?.password)
        XCTAssertEqual(one.vault.historyPasswords(0xA1), ["old", current == "here" ? "there" : "here"])
        XCTAssertEqual(mergeContents(one.vault), mergeContents(two.vault))
        XCTAssertEqual(one.report.changedOnBoth.map(\.id), [mergeID(0xA1)])
        XCTAssertEqual(two.report.changedOnBoth.map(\.id), [mergeID(0xA1)])
    }

    /// KeePass times are whole seconds, so a change saved in the same second as the version before it has that
    /// version's time. The other copy, which still holds that version, did not change the item: the copy that has it in
    /// its history was made from it and wins, both ways, and nobody is told of a change on both. (Seen in the two-Mac
    /// acceptance: a change made right after the item was written was undone by the merge about half the time.)
    func testAChangeInTheSameSecondAsTheVersionTheOtherCopyHoldsWins() throws {
        for password in ["second", "b", "c", "d", "e", "f"] {
            let original = MergeItem(0xA1, "Bank", password: "first", modified: 10)
            let here = try MergeCopy(items: [
                MergeItem(0xA1, "Bank", password: password, modified: 10, history: [original])
            ]).vault()
            let there = try MergeCopy(items: [original, MergeItem(0xA2, "Mail", modified: 20)]).vault()
            for (base, other) in [(here, there), (there, here)] {
                let outcome = try merged(other, into: base)
                XCTAssertEqual(outcome.vault.item(0xA1)?.password, password, "the later change is the item")
                XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["first"])
                XCTAssertEqual(outcome.report.changedOnBoth, [], "only one copy changed it")
            }
        }
    }

    /// The same for a move to the Recycle Bin in the same second as the version the other copy holds, wherever the
    /// folder and the Recycle Bin sort (the app gives groups random identifiers).
    func testAMoveToTheRecycleBinInTheSameSecondAsTheVersionTheOtherCopyHoldsWins() throws {
        for (folder, bin) in [(0x03, 0x02), (0xFE, 0x02), (0x03, 0xFF), (0xFE, 0xFF), (0x7E, 0x40)] {
            let original = MergeItem(0xA1, "Bank", modified: 10, located: 10)
            var trashedCopy = MergeCopy(groups: [
                MergeGroup(folder, "Agents"),
                mergeBin([MergeItem(0xA1, "Bank", modified: 10, located: 10, history: [original])], id: bin)
            ])
            trashedCopy.recycleBin = bin
            var liveCopy = MergeCopy(groups: [
                MergeGroup(folder, "Agents", items: [original, MergeItem(0xA2, "Other", modified: 20)]),
                mergeBin(id: bin)
            ])
            liveCopy.recycleBin = bin
            let trashed = try trashedCopy.vault()
            let live = try liveCopy.vault()
            for (base, other) in [(live, trashed), (trashed, live)] {
                let outcome = try merged(other, into: base)
                XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, true, "folder \(folder), bin \(bin)")
                XCTAssertEqual(outcome.report.changedOnBoth, [], "folder \(folder), bin \(bin)")
            }
        }
    }

    /// PasswordPie writes its list of older passwords without making a new version. That is not the item changing.
    func testBookkeepingOfOlderPasswordsIsNotListedAsAChange() throws {
        let field = (key: PreviousPasswords.key, value: "{\"v\":1}", protected: true)
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank", fields: [field])]).vault()
        let there = try MergeCopy(items: [MergeItem(0xA1, "Bank")]).vault()

        let one = try merged(there, into: here)
        let two = try merged(here, into: there)
        XCTAssertEqual(one.report.changedOnBoth, [])
        XCTAssertEqual(two.report.changedOnBoth, [])
        XCTAssertEqual(mergeContents(one.vault), mergeContents(two.vault))
    }

    func testHistoriesAreJoinedInTimeOrderWithoutDuplicates() throws {
        let v0 = MergeItem(0xA1, "Bank", password: "v0")
        let v1 = MergeItem(0xA1, "Bank", password: "v1", modified: 10)
        let v2 = MergeItem(0xA1, "Bank", password: "v2", modified: 20)
        let v3 = MergeItem(0xA1, "Bank", password: "v3", modified: 30)
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "v4", modified: 40, history: [v0, v1, v3])]).vault()
        let there = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "v4", modified: 40, history: [v0, v2, v3])]).vault()

        let outcome = try merged(there, into: here)
        XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["v0", "v1", "v2", "v3"])
        XCTAssertEqual(outcome.report.changedOnBoth, [])
    }

    func testTheHistoryKeepsToTheDatabasesLimit() throws {
        let versions = (0..<3).map { MergeItem(0xA1, "Bank", password: "v\($0)", modified: $0 * 10) }
        var here = MergeCopy(items: [MergeItem(0xA1, "Bank", password: "here", modified: 40, history: versions)])
        here.historyMaxItems = 3
        var there = MergeCopy(items: [MergeItem(0xA1, "Bank", password: "there", modified: 50, history: versions)])
        there.historyMaxItems = 3

        let outcome = try merged(try there.vault(), into: try here.vault())
        XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["v1", "v2", "here"])
    }

    // MARK: Whichever way, and again

    private func busyCopies() throws -> (here: Vault, there: Vault) {
        let bank = MergeItem(0xA1, "Bank", password: "old")
        var here = MergeCopy(
            items: [
                MergeItem(0xA1, "Bank", password: "here", modified: 10, history: [bank]),
                MergeItem(0xA2, "Mail", binaries: [("mail.pem", 0)]),
                MergeItem(0xA4, "Only here", modified: 5),
                MergeItem(0xA6, "Deleted there", modified: 3)
            ],
            groups: [
                MergeGroup(0x10, "Work", items: [MergeItem(0xA5, "Moved there")]),
                MergeGroup(0x11, "Renamed here", modified: 30),
                mergeBin([MergeItem(0xA7, "Trashed here", modified: 12, located: 12)])
            ]
        )
        here.binaries = [Data("mail key".utf8)]
        here.customData = [("PasswordPie.AgentSharing", #"{"folders":[],"items":["00000000-0000-0000-0000-0000000000A1"],"version":1}"#, nil), ("OtherApp", "here", nil)]
        var there = MergeCopy(
            items: [
                MergeItem(0xA1, "Bank", password: "there", modified: 20, history: [bank]),
                MergeItem(0xA2, "Mail", binaries: [("mail.pem", 1)]),
                MergeItem(0xA3, "Only there", modified: 7, binaries: [("there.key", 0)]),
                MergeItem(0xA5, "Moved there", located: 25),
                MergeItem(0xA7, "Trashed here")
            ],
            groups: [
                MergeGroup(0x10, "Work"),
                MergeGroup(0x11, "Old name", modified: 2),
                MergeGroup(0x12, "New there", items: [MergeItem(0xA8, "In a new folder", modified: 9)]),
                mergeBin()
            ]
        )
        there.binaries = [Data("there key".utf8), Data("mail key".utf8)]
        there.deleted = [(0xA6, 8), (0xEE, 4)]
        there.customData = [("PasswordPie.AgentSharing", #"{"folders":[["Work"]],"items":[],"version":1}"#, nil), ("OtherApp", "there", nil), ("ThereOnly", "x", nil)]
        return (try here.vault(), try there.vault())
    }

    func testTheResultIsTheSameWhicheverCopyIsMergedIntoWhich() throws {
        let (here, there) = try busyCopies()
        let one = try merged(there, into: here)
        let two = try merged(here, into: there)
        XCTAssertEqual(mergeContents(one.vault), mergeContents(two.vault))
        // And it is the merge the rules describe.
        let vault = one.vault
        XCTAssertEqual(vault.item(0xA1)?.password, "there")
        XCTAssertEqual(vault.historyPasswords(0xA1), ["old", "here"])
        XCTAssertNotNil(vault.item(0xA3))
        XCTAssertNotNil(vault.item(0xA4))
        XCTAssertEqual(vault.item(0xA5)?.groupPath, [])
        XCTAssertNil(vault.item(0xA6))
        XCTAssertEqual(vault.item(0xA7)?.trashed, true)
        XCTAssertEqual(vault.item(0xA8)?.groupPath, ["New there"])
        XCTAssertEqual(vault.attachment(named: "mail.pem", of: mergeID(0xA2)), Data("mail key".utf8))
        XCTAssertEqual(vault.attachment(named: "there.key", of: mergeID(0xA3)), Data("there key".utf8))
        XCTAssertEqual(vault.customData["ThereOnly"], "x")
        XCTAssertEqual(vault.customData["OtherApp"], "there")
    }

    func testMergingTheSameCopyAgainChangesNothing() throws {
        let (here, there) = try busyCopies()
        let first = try merged(there, into: here)
        XCTAssertTrue(first.report.changed)

        let again = try merged(there, into: first.vault)
        XCTAssertFalse(again.report.changed)
        XCTAssertEqual(mergeContents(again.vault), mergeContents(first.vault))
        // The other Mac, getting the merged file, has nothing to add and so nothing to write.
        XCTAssertFalse(try merged(there, into: first.vault).report.changed)
        XCTAssertFalse(try merged(here, into: first.vault).report.changed)
        // Nor does a Mac that did the same merge the other way round.
        let mirror = try merged(here, into: there)
        XCTAssertFalse(try merged(mirror.vault, into: first.vault).report.changed)
    }

    /// Many pairs of copies, each changed at random: edits, moves, the Recycle Bin, deletions, new items, renamed
    /// folders. Whatever the two Macs did, both merges give the same database and a second merge adds nothing, so two
    /// Macs that keep merging each other's file stop writing.
    func testRandomlyChangedCopiesMergeTheSameBothWaysAndThenSettle() throws {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        func copy(_ mac: Int) -> MergeCopy {
            var root: [MergeItem] = [], work: [MergeItem] = [], bin: [MergeItem] = []
            var deleted: [(id: Int, at: Int)] = []
            for number in 0..<8 {
                let id = 0xA0 + number
                let original = MergeItem(id, "Item \(number)", password: "v0")
                var item = original
                var place = number % 2
                switch random(7) {
                case 0:
                    item = MergeItem(id, "Item \(number)", password: "mac\(mac)-\(random(3))", modified: 1 + random(40), history: [original])
                case 1:
                    place = 1 - place
                    item.located = 1 + random(40)
                case 2:
                    place = 2
                    item = MergeItem(id, "Item \(number)", password: "v0", modified: 1 + random(40), history: [original])
                    item.located = item.modified
                case 3:
                    deleted.append((id, 1 + random(40)))
                    continue
                case 4:
                    let first = MergeItem(id, "Item \(number)", password: "mac\(mac)-a", modified: 1 + random(20), history: [original])
                    item = MergeItem(id, "Item \(number) renamed", password: "mac\(mac)-b", modified: 21 + random(20), history: [original, MergeItem(id, "Item \(number)", password: first.password, modified: first.modified)])
                default:
                    break
                }
                if place == 0 { root.append(item) } else if place == 1 { work.append(item) } else { bin.append(item) }
            }
            if random(2) == 0 { root.append(MergeItem(0xB0 + mac, "New on \(mac)", modified: 1 + random(40))) }
            var made = MergeCopy(items: root, groups: [
                MergeGroup(0x10, random(3) == 0 ? "Work \(mac)" : "Work", modified: random(3) == 0 ? 1 + random(40) : 0, items: work),
                mergeBin(bin)
            ])
            if random(3) == 0 { made.root.groups[0].modified = 1 + random(40) }
            made.deleted = deleted
            made.customData = [("Other", "value \(random(3))", nil)]
            return made
        }
        for round in 0..<150 {
            let here = try copy(1).vault(), there = try copy(2).vault()
            let one = try VaultMerge.merge(there, into: here)
            let two = try VaultMerge.merge(here, into: there)
            XCTAssertEqual(mergeContents(one.vault), mergeContents(two.vault), "round \(round)")
            XCTAssertFalse(try VaultMerge.merge(there, into: one.vault).report.changed, "round \(round)")
            XCTAssertFalse(try VaultMerge.merge(here, into: one.vault).report.changed, "round \(round)")
            XCTAssertFalse(try VaultMerge.merge(two.vault, into: one.vault).report.changed, "round \(round)")
            XCTAssertEqual(Set(one.report.changedOnBoth.map(\.id)), Set(two.report.changedOnBoth.map(\.id)), "round \(round)")
        }
    }

    func testAnUnchangedMergeLeavesTheDocumentExactlyAsItWas() throws {
        let (here, _) = try busyCopies()
        let before = try XCTUnwrap(here.preserve?.document.rootElement()?.xmlString)
        let outcome = try VaultMerge.merge(here, into: here)
        XCTAssertFalse(outcome.report.changed)
        XCTAssertEqual(outcome.vault.preserve?.document.rootElement()?.xmlString, before)
        XCTAssertEqual(outcome.vault.preserve?.pieces, here.preserve?.pieces)
    }

    // MARK: Deletions

    func testADeletionRemovesTheItemUnlessItChangedAfterTheDeletion() throws {
        let here = try MergeCopy(items: [
            MergeItem(0xA1, "Deleted there", modified: 10),
            MergeItem(0xA2, "Changed here after", modified: 20),
            MergeItem(0xA3, "Untouched")
        ]).vault()
        var there = MergeCopy(items: [MergeItem(0xA3, "Untouched")])
        there.deleted = [(0xA1, 15), (0xA2, 15)]

        for (base, other) in [(here, try there.vault()), (try there.vault(), here)] {
            let outcome = try merged(other, into: base)
            XCTAssertNil(outcome.vault.item(0xA1))
            XCTAssertEqual(outcome.vault.item(0xA2)?.title, "Changed here after")
            XCTAssertNotNil(outcome.vault.item(0xA3))
            let deleted = mergeContents(outcome.vault).filter { $0.hasPrefix("deleted") }
            XCTAssertEqual(deleted, ["deleted \(mergeID(0xA1).uuidString) at 15"], "the item that stays is no longer listed as deleted")
        }
        XCTAssertEqual(try merged(try there.vault(), into: here).report.removed, 1)
        // The other way round nothing is removed, and the deleted item is not counted as added and removed again.
        let back = try merged(here, into: try there.vault()).report
        XCTAssertEqual(back.added, 1)
        XCTAssertEqual(back.removed, 0)
    }

    func testAnItemChangedInTheSameSecondAsItsDeletionIsRemoved() throws {
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank", modified: 15)]).vault()
        var there = MergeCopy()
        there.deleted = [(0xA1, 15)]
        XCTAssertNil(try merged(try there.vault(), into: here).vault.item(0xA1))
    }

    func testTheEarlierOfTwoDeletionTimesIsKept() throws {
        var here = MergeCopy()
        here.deleted = [(0xA1, 30)]
        var there = MergeCopy()
        there.deleted = [(0xA1, 20)]
        let one = try merged(try there.vault(), into: try here.vault())
        let two = try merged(try here.vault(), into: try there.vault())
        XCTAssertEqual(mergeContents(one.vault), ["deleted \(mergeID(0xA1).uuidString) at 20"])
        XCTAssertEqual(mergeContents(two.vault), mergeContents(one.vault))
        XCTAssertFalse(two.report.changed)
    }

    func testMovingToTheRecycleBinReachesTheOtherCopy() throws {
        let trashed = try MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Bank", modified: 10, located: 10, history: [MergeItem(0xA1, "Bank")])])]).vault()
        let live = try MergeCopy(items: [MergeItem(0xA1, "Bank")], groups: [mergeBin()]).vault()

        for (base, other) in [(live, trashed), (trashed, live)] {
            let outcome = try merged(other, into: base)
            XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, true)
            XCTAssertEqual(outcome.report.changedOnBoth, [])
        }
        XCTAssertEqual(try merged(trashed, into: live).report.moved, 1)
    }

    func testAnItemChangedAfterItWasMovedToTheRecycleBinOnTheOtherCopyStays() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        let trashed = try MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Bank", password: "old", modified: 10, located: 10, history: [original])])]).vault()
        let changedAfter = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "new", modified: 20, history: [original])], groups: [mergeBin()]).vault()

        let one = try merged(changedAfter, into: trashed)
        let two = try merged(trashed, into: changedAfter)
        for outcome in [one, two] {
            XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, false)
            XCTAssertEqual(outcome.vault.item(0xA1)?.password, "new")
        }
        XCTAssertEqual(mergeContents(one.vault), mergeContents(two.vault))
        XCTAssertFalse(try merged(trashed, into: one.vault).report.changed, "the copy that still has it in the bin does not put it back")
    }

    func testAnItemChangedBeforeItWasMovedToTheRecycleBinOnTheOtherCopyGoesToTheBinWithItsChangeInTheHistory() throws {
        let original = MergeItem(0xA1, "Bank", password: "old")
        let trashed = try MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Bank", password: "old", modified: 10, located: 10, history: [original])])]).vault()
        let changedBefore = try MergeCopy(items: [MergeItem(0xA1, "Bank", password: "new", modified: 5, history: [original])], groups: [mergeBin()]).vault()

        for (base, other) in [(changedBefore, trashed), (trashed, changedBefore)] {
            let outcome = try merged(other, into: base)
            XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, true)
            XCTAssertEqual(outcome.vault.historyPasswords(0xA1), ["old", "new"])
            XCTAssertEqual(outcome.report.changedOnBoth.map(\.id), [mergeID(0xA1)])
        }
    }

    func testAnItemTakenOutOfTheRecycleBinLaterComesOut() throws {
        let trashed = try MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Bank", located: 10)])]).vault()
        let restored = try MergeCopy(items: [MergeItem(0xA1, "Bank", located: 20)], groups: [mergeBin()]).vault()
        XCTAssertEqual(try merged(restored, into: trashed).vault.item(0xA1)?.trashed, false)
        XCTAssertEqual(try merged(trashed, into: restored).vault.item(0xA1)?.trashed, false)
    }

    /// One Mac moved an item away and back. A third copy moved it elsewhere in between: every copy must end the same.
    func testTheLaterMoveTimeIsKeptWhenBothCopiesHaveTheItemInTheSamePlace() throws {
        let stayed = try MergeCopy(items: [MergeItem(0xA1, "Bank", located: 5)], groups: [MergeGroup(0x10, "Work")]).vault()
        let movedBack = try MergeCopy(items: [MergeItem(0xA1, "Bank", located: 10)], groups: [MergeGroup(0x10, "Work")]).vault()
        let third = try MergeCopy(groups: [MergeGroup(0x10, "Work", items: [MergeItem(0xA1, "Bank", located: 7)])]).vault()

        let one = try merged(movedBack, into: stayed)
        XCTAssertTrue(one.report.changed)
        XCTAssertEqual(try merged(third, into: one.vault).vault.item(0xA1)?.groupPath, [])
        XCTAssertEqual(try merged(third, into: movedBack).vault.item(0xA1)?.groupPath, [])
        XCTAssertFalse(try merged(stayed, into: movedBack).report.changed)
    }

    func testEachCopysOwnRecycleBinIsOneBin() throws {
        var here = MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Gone here", located: 5)], id: 0x02)])
        here.recycleBin = 0x02
        var there = MergeCopy(groups: [mergeBin([MergeItem(0xA2, "Gone there", located: 6)], id: 0x03)])
        there.recycleBin = 0x03

        let outcome = try merged(try there.vault(), into: try here.vault())
        XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, true)
        XCTAssertEqual(outcome.vault.item(0xA2)?.trashed, true)
        let root = try XCTUnwrap(outcome.vault.preserve?.document.rootElement().flatMap { direct($0, "Root").first }.flatMap { direct($0, "Group").first })
        XCTAssertEqual(direct(root, "Group").count, 1, "one Recycle Bin, not two")
    }

    func testACopyWithoutARecycleBinGetsTheOtherCopys() throws {
        var here = MergeCopy(items: [MergeItem(0xA1, "Bank")])
        here.recycleBin = nil
        let there = MergeCopy(groups: [mergeBin([MergeItem(0xA1, "Bank", located: 10)])])

        let outcome = try merged(try there.vault(), into: try here.vault())
        XCTAssertEqual(outcome.vault.item(0xA1)?.trashed, true)
        XCTAssertEqual(outcome.vault.preserve?.recycleBinID(), mergeID(0x02))
    }

    // MARK: Groups

    func testAGroupFollowsItsLaterNameAndLaterPlaceAndANewGroupComesWithItsItems() throws {
        let here = try MergeCopy(groups: [
            MergeGroup(0x10, "Work", items: [MergeItem(0xA1, "Bank")]),
            MergeGroup(0x11, "Servers", groups: [MergeGroup(0x12, "Old")])
        ]).vault()
        let there = try MergeCopy(groups: [
            MergeGroup(0x10, "Office", modified: 10, items: [MergeItem(0xA1, "Bank")], groups: [MergeGroup(0x12, "Old", located: 20)]),
            MergeGroup(0x11, "Servers"),
            MergeGroup(0x13, "Agents", items: [MergeItem(0xA2, "Token")], groups: [MergeGroup(0x14, "Deep", items: [MergeItem(0xA3, "Deep token")])])
        ]).vault()

        let one = try merged(there, into: here)
        XCTAssertEqual(one.vault.item(0xA1)?.groupPath, ["Office"])
        XCTAssertEqual(one.vault.item(0xA2)?.groupPath, ["Agents"])
        XCTAssertEqual(one.vault.item(0xA3)?.groupPath, ["Agents", "Deep"])
        let groups = one.vault.preserve.map { names(of: $0) } ?? []
        XCTAssertEqual(groups.sorted(), ["Passwords", "Passwords/Agents", "Passwords/Agents/Deep", "Passwords/Office", "Passwords/Office/Old", "Passwords/Servers"])
        let two = try merged(here, into: there)
        XCTAssertEqual(two.vault.preserve.map { names(of: $0) }?.sorted(), groups.sorted())
        XCTAssertFalse(two.report.changed)
    }

    /// Each Mac moved one group into the other. Whatever comes out, every group is there once and none is inside itself.
    func testAGroupIsNeverMovedIntoItself() throws {
        let here = try MergeCopy(groups: [MergeGroup(0x10, "A", located: 1, groups: [MergeGroup(0x11, "B", located: 10)])]).vault()
        let there = try MergeCopy(groups: [MergeGroup(0x11, "B", located: 5, groups: [MergeGroup(0x10, "A", located: 8)])]).vault()
        let one = try merged(there, into: here)
        XCTAssertEqual(one.vault.preserve.map { names(of: $0) }?.sorted(), ["Passwords", "Passwords/A", "Passwords/A/B"])
        let two = try merged(here, into: there)
        XCTAssertEqual(two.vault.preserve.map { names(of: $0) }?.sorted(), ["Passwords", "Passwords/B", "Passwords/B/A"])
    }

    func testADeletedGroupGoesWhenItIsEmptyAndStaysWhileSomethingIsInIt() throws {
        let here = try MergeCopy(groups: [
            MergeGroup(0x10, "Empty there", items: [MergeItem(0xA1, "Deleted with it", modified: 3)]),
            MergeGroup(0x11, "Still used", items: [MergeItem(0xA2, "Added here later", modified: 30)])
        ]).vault()
        var there = MergeCopy()
        there.deleted = [(0x10, 10), (0xA1, 10), (0x11, 10)]

        let outcome = try merged(try there.vault(), into: here)
        XCTAssertEqual(outcome.vault.preserve.map { names(of: $0) }?.sorted(), ["Passwords", "Passwords/Still used"])
        XCTAssertEqual(outcome.vault.item(0xA2)?.groupPath, ["Still used"])
        // And the copy that deleted them does not get the empty group back.
        let back = try merged(here, into: try there.vault())
        XCTAssertEqual(back.vault.preserve.map { names(of: $0) }?.sorted(), ["Passwords", "Passwords/Still used"])
    }

    private func names(of preserve: KDBXPreserve) -> [String] {
        guard let root = preserve.document.rootElement().flatMap({ direct($0, "Root").first }) else { return [] }
        var found: [String] = []
        func visit(_ group: XMLElement, _ prefix: String) {
            let path = prefix + (direct(group, "Name").first?.stringValue ?? "")
            found.append(path)
            for child in direct(group, "Group") { visit(child, path + "/") }
        }
        for group in direct(root, "Group") { visit(group, "") }
        return found
    }

    // MARK: Nothing the app does not understand is lost

    func testAttachmentsComeWithTheirItemAndTheOnesAlreadyHereKeepTheirPlace() throws {
        var here = MergeCopy(items: [MergeItem(0xA1, "Mine", binaries: [("mine.p8", 0)])])
        here.binaries = [Data("mine".utf8)]
        var there = MergeCopy(items: [
            MergeItem(0xA1, "Mine", binaries: [("mine.p8", 2)]),
            MergeItem(0xA2, "Theirs", modified: 5, binaries: [("first.pem", 0), ("second.json", 1), ("same-as-mine", 2)],
                      history: [MergeItem(0xA2, "Theirs", binaries: [("old.pem", 3)])])
        ])
        there.binaries = [Data("first".utf8), Data("second".utf8), Data("mine".utf8), Data("old".utf8)]

        let outcome = try merged(try there.vault(), into: try here.vault())
        let vault = outcome.vault
        XCTAssertEqual(vault.preserve?.binaryPayloads, [Data("mine".utf8), Data("first".utf8), Data("second".utf8), Data("old".utf8)])
        XCTAssertEqual(vault.attachment(named: "mine.p8", of: mergeID(0xA1)), Data("mine".utf8))
        XCTAssertEqual(vault.attachment(named: "first.pem", of: mergeID(0xA2)), Data("first".utf8))
        XCTAssertEqual(vault.attachment(named: "second.json", of: mergeID(0xA2)), Data("second".utf8))
        XCTAssertEqual(vault.attachment(named: "same-as-mine", of: mergeID(0xA2)), Data("mine".utf8))
        // The history's attachment came too: the file holds its bytes and the old version points at them.
        let entry = try XCTUnwrap(vault.preserve?.document.rootElement().flatMap { find(mergeID(0xA2), in: $0) })
        let old = try XCTUnwrap(direct(entry, "History").first.flatMap { direct($0, "Entry").first })
        XCTAssertEqual(direct(old, "Binary").first.flatMap { direct($0, "Value").first }?.attribute(forName: "Ref")?.stringValue, "3")
    }

    func testAnAttachmentChangedOnTheOtherCopyIsAChangeOfTheItem() throws {
        var here = MergeCopy(items: [MergeItem(0xA1, "Key", binaries: [("key.pem", 0)])])
        here.binaries = [Data("old key".utf8)]
        var there = MergeCopy(items: [MergeItem(0xA1, "Key", modified: 10, binaries: [("key.pem", 0)], history: [MergeItem(0xA1, "Key", binaries: [("key.pem", 1)])])])
        there.binaries = [Data("new key".utf8), Data("old key".utf8)]

        let outcome = try merged(try there.vault(), into: try here.vault())
        XCTAssertEqual(outcome.vault.attachment(named: "key.pem", of: mergeID(0xA1)), Data("new key".utf8))
        XCTAssertEqual(outcome.report.changedOnBoth, [], "the old attachment is the version in the other copy's history")
        XCTAssertEqual(outcome.vault.preserve?.binaryPayloads, [Data("old key".utf8), Data("new key".utf8)])
    }

    func testWhatIsNotTouchedStaysByteForByteAndUnknownXMLComesWithTheVersionThatWins() throws {
        let unknown = "<AutoType><Enabled>True</Enabled><Association><Window>Bank*</Window><KeystrokeSequence>{PASSWORD}</KeystrokeSequence></Association></AutoType><CustomData><Item><Key>KPXC_BROWSER_x</Key><Value>{\"a\":1}</Value></Item></CustomData><FutureThing mode=\"x\"><Deep>1 &amp; 2</Deep></FutureThing>"
        var here = MergeCopy(
            items: [
                MergeItem(0xA1, "Untouched", binaries: [("a.bin", 0)], history: [MergeItem(0xA1, "Untouched", password: "before")], extra: unknown),
                MergeItem(0xA2, "Changed there", extra: "<FutureThing>old</FutureThing>")
            ],
            groups: [MergeGroup(0x10, "Untouched group", items: [MergeItem(0xA4, "Inside")], extra: "<Notes>group notes</Notes><GroupFuture>1</GroupFuture>")]
        )
        here.binaries = [Data([0, 1, 2, 255])]
        here.metaExtra = "<MemoryProtection><ProtectPassword>True</ProtectPassword></MemoryProtection><MetaFuture a=\"1\">kept</MetaFuture><CustomIcons><Icon><UUID>\(base64UUID(mergeID(0xC1)))</UUID><Data>aWNvbg==</Data></Icon></CustomIcons>"
        here.rootExtra = "<RootFuture>kept</RootFuture>"
        here.customData = [("KPXC_DECRYPTION_TIME_PREFERENCE", "1000", nil)]
        var there = MergeCopy(items: [
            MergeItem(0xA1, "Untouched", binaries: [("a.bin", 0)], history: [MergeItem(0xA1, "Untouched", password: "before")], extra: unknown),
            MergeItem(0xA2, "Changed there", password: "new", modified: 10, history: [MergeItem(0xA2, "Changed there", extra: "<FutureThing>old</FutureThing>")], extra: "<FutureThing>new</FutureThing>"),
            MergeItem(0xA3, "Added there", modified: 5, extra: "<CustomIconUUID>\(base64UUID(mergeID(0xC2)))</CustomIconUUID>")
        ], groups: [MergeGroup(0x10, "Untouched group", items: [MergeItem(0xA4, "Inside")], extra: "<Notes>group notes</Notes><GroupFuture>1</GroupFuture>")])
        there.binaries = [Data([0, 1, 2, 255])]
        there.metaExtra = "<CustomIcons><Icon><UUID>\(base64UUID(mergeID(0xC2)))</UUID><Data>dGhlaXJz</Data></Icon></CustomIcons>"

        let base = try here.vault()
        let file = try XCTUnwrap(base.preserve?.document.rootElement())
        let before = [
            try XCTUnwrap(find(mergeID(0xA1), in: file)).xmlString,
            try XCTUnwrap(find(mergeID(0xA4), in: file)).xmlString,
            try XCTUnwrap(direct(file, "Meta").first.flatMap { direct($0, "MetaFuture").first }).xmlString,
            try XCTUnwrap(direct(file, "Meta").first.flatMap { direct($0, "MemoryProtection").first }).xmlString,
            try XCTUnwrap(direct(file, "Root").first.flatMap { direct($0, "RootFuture").first }).xmlString
        ]

        let outcome = try merged(try there.vault(), into: base)
        // Through a save and a read, as the next unlock gets it.
        var saved = outcome.vault
        let reloaded = try KDBX.load(data: try KDBX.save(vault: &saved, password: "secret"), password: "secret")
        let after = try XCTUnwrap(reloaded.preserve?.document.rootElement())
        XCTAssertEqual([
            try XCTUnwrap(find(mergeID(0xA1), in: after)).xmlString,
            try XCTUnwrap(find(mergeID(0xA4), in: after)).xmlString,
            try XCTUnwrap(direct(after, "Meta").first.flatMap { direct($0, "MetaFuture").first }).xmlString,
            try XCTUnwrap(direct(after, "Meta").first.flatMap { direct($0, "MemoryProtection").first }).xmlString,
            try XCTUnwrap(direct(after, "Root").first.flatMap { direct($0, "RootFuture").first }).xmlString
        ], before)
        XCTAssertEqual(reloaded.preserve?.binaryPayloads, [Data([0, 1, 2, 255])])
        XCTAssertEqual(reloaded.customData["KPXC_DECRYPTION_TIME_PREFERENCE"], "1000")
        // The version that won brought its unknown element; the one that lost keeps its own in the history.
        let changed = try XCTUnwrap(find(mergeID(0xA2), in: after))
        XCTAssertEqual(direct(changed, "FutureThing").map(\.stringValue), ["new"])
        XCTAssertEqual(direct(changed, "History").first.flatMap { direct($0, "Entry").first }.map { direct($0, "FutureThing").map(\.stringValue) }, ["old"])
        // The added item's icon came with it, and ours stayed.
        let icons = direct(after, "Meta").first.flatMap { direct($0, "CustomIcons").first }.map { direct($0, "Icon") } ?? []
        XCTAssertEqual(icons.compactMap { direct($0, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") } }, [mergeID(0xC1), mergeID(0xC2)])
    }

    private func find(_ id: UUID, in element: XMLElement) -> XMLElement? {
        var found: XMLElement?
        walkElements(element) { candidate in
            guard found == nil, candidate.name == "Entry", candidate.parent?.name == "Group",
                  direct(candidate, "UUID").first.flatMap({ uuidFromBase64($0.stringValue ?? "") }) == id else { return }
            found = candidate
        }
        return found
    }

    // MARK: Database custom data

    func testCustomDataOfOtherAppsIsKeptAndADifferenceIsSettledTheSameBothWays() throws {
        var here = MergeCopy()
        here.customData = [("HereOnly", "h", nil), ("Timed", "older", 10), ("Untimed", "apple", nil)]
        var there = MergeCopy()
        there.customData = [("ThereOnly", "t", nil), ("Timed", "newer", 20), ("Untimed", "banana", nil)]

        let one = try merged(try there.vault(), into: try here.vault())
        let two = try merged(try here.vault(), into: try there.vault())
        XCTAssertEqual(one.vault.customData, ["HereOnly": "h", "ThereOnly": "t", "Timed": "newer", "Untimed": "banana"])
        XCTAssertEqual(two.vault.customData, one.vault.customData)
        XCTAssertFalse(try merged(try here.vault(), into: one.vault).report.changed)
    }

    func testSharingWithAgentsIsMergedItemByItemAndAnUnshareIsNotUndoneByAnOlderCopy() throws {
        let (a, b, c) = (mergeID(0xA1), mergeID(0xA2), mergeID(0xA3))
        func record(_ states: [AgentSharingRecord.Key: AgentSharingRecord.State]) -> String {
            AgentSharingRecord(states: states).text ?? ""
        }
        // Here: a was unshared at 30, b shared at 10. There (an older copy): a still shared since 5, c shared at 20,
        // and the folder Work.
        var here = MergeCopy()
        here.customData = [(AgentSharingRecord.customDataKey, record([.item(a): .init(shared: false, at: 30), .item(b): .init(shared: true, at: 10)]), nil)]
        var there = MergeCopy()
        there.customData = [(AgentSharingRecord.customDataKey, record([
            .item(a): .init(shared: true, at: 5), .item(c): .init(shared: true, at: 20), .folder(["Work"]): .init(shared: true, at: 7)
        ]), nil)]

        let one = try merged(try there.vault(), into: try here.vault())
        let two = try merged(try here.vault(), into: try there.vault())
        for outcome in [one, two] {
            let states = try XCTUnwrap(AgentSharingRecord(text: outcome.vault.customData[AgentSharingRecord.customDataKey])).states
            XCTAssertEqual(states[.item(a)], .init(shared: false, at: 30))
            XCTAssertEqual(states[.item(b)], .init(shared: true, at: 10))
            XCTAssertEqual(states[.item(c)], .init(shared: true, at: 20))
            XCTAssertEqual(states[.folder(["Work"])], .init(shared: true, at: 7))
        }
        XCTAssertEqual(one.vault.customData, two.vault.customData)
    }

    func testSharingAgainAfterAnUnshareCountsAndTheSameSecondStaysUnshared() {
        let a = mergeID(0xA1)
        func merge(_ mine: AgentSharingRecord.State, _ other: AgentSharingRecord.State) -> AgentSharingRecord.State? {
            let text = AgentSharingRecord.merged(AgentSharingRecord(states: [.item(a): mine]).text, AgentSharingRecord(states: [.item(a): other]).text)
            return AgentSharingRecord(text: text)?.states[.item(a)]
        }
        XCTAssertEqual(merge(.init(shared: false, at: 30), .init(shared: true, at: 40)), .init(shared: true, at: 40))
        XCTAssertEqual(merge(.init(shared: true, at: 40), .init(shared: false, at: 30)), .init(shared: true, at: 40))
        XCTAssertEqual(merge(.init(shared: true, at: 30), .init(shared: false, at: 30)), .init(shared: false, at: 30))
        XCTAssertEqual(merge(.init(shared: false, at: 30), .init(shared: true, at: 30)), .init(shared: false, at: 30))
    }

    func testSharingWrittenBeforeTimesWereKeptIsJoined() {
        let old = #"{"folders":[["Agents"]],"items":["00000000-0000-0000-0000-0000000000A1"],"version":1}"#
        let other = #"{"folders":[],"items":["00000000-0000-0000-0000-0000000000A2"],"version":1}"#
        let merged = AgentSharingRecord(text: AgentSharingRecord.merged(old, other))
        XCTAssertEqual(merged?.items, [mergeID(0xA1).uuidString, mergeID(0xA2).uuidString])
        XCTAssertEqual(merged?.folders, [["Agents"]])
        XCTAssertEqual(AgentSharingRecord.merged(old, nil), old)
        XCTAssertEqual(AgentSharingRecord.merged(nil, old), old)
        XCTAssertEqual(AgentSharingRecord.merged(old, old), old)
        // A value this version cannot read is left as it is, and never replaces one it can.
        XCTAssertEqual(AgentSharingRecord.merged("{future", old), "{future")
        XCTAssertEqual(AgentSharingRecord.merged(old, "{future"), old)
    }

    func testStandingPermissionsAreMergedGrantByGrantAndARevokedOneStaysRevoked() throws {
        func grant(_ id: String, ends: Double = 1000) -> String {
            #"{"agent":"claude","ends":\#(ends),"id":"\#(id)","mac":"m"}"#
        }
        let g1 = "11111111-1111-1111-1111-111111111111", g2 = "22222222-2222-2222-2222-222222222222", g3 = "33333333-3333-3333-3333-333333333333"
        // Here: g1 was revoked, g2 was granted. There: g1 is still held, g3 was granted.
        let here = #"{"grants":[\#(grant(g2))],"revoked":[{"ends":1000,"id":"\#(g1)"}],"version":1}"#
        let there = #"{"grants":[\#(grant(g1)),\#(grant(g3))],"version":1}"#

        for (mine, other) in [(here, there), (there, here)] {
            let text = try XCTUnwrap(AgentGrantsRecord.merged(mine, other))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual((object["grants"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [g2, g3])
            XCTAssertEqual((object["revoked"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [g1])
        }
        XCTAssertEqual(AgentGrantsRecord.merged(here, there), AgentGrantsRecord.merged(there, here))
        // Not last-writer-wins: neither copy's list is the result.
        XCTAssertNotEqual(AgentGrantsRecord.merged(here, there), here)
        XCTAssertNotEqual(AgentGrantsRecord.merged(here, there), there)
        // Nothing to add: the text stays exactly as it was, so nothing is written.
        let merged = try XCTUnwrap(AgentGrantsRecord.merged(here, there))
        XCTAssertEqual(AgentGrantsRecord.merged(merged, here), merged)
        XCTAssertEqual(AgentGrantsRecord.merged(merged, there), merged)
        XCTAssertEqual(AgentGrantsRecord.merged(here, nil), here)
        XCTAssertEqual(AgentGrantsRecord.merged(nil, there), there)
        XCTAssertEqual(AgentGrantsRecord.merged("{future", there), "{future")
    }

    func testOneRevokedRecordHeldDifferentlyByTwoCopiesIsSettledTheSameBothWays() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let long = #"{"grants":[],"revoked":[{"ends":2000,"id":"\#(id)"}],"version":1}"#
        let short = #"{"grants":[],"revoked":[{"ends":1000,"id":"\#(id)"}],"version":1}"#
        XCTAssertEqual(AgentGrantsRecord.merged(long, short), long)
        XCTAssertEqual(AgentGrantsRecord.merged(short, long), long)
    }

    func testOneGrantHeldDifferentlyByTwoCopiesKeepsTheOneThatEndsSooner() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let long = #"{"grants":[{"ends":2000,"id":"\#(id)"}],"version":1}"#
        let short = #"{"grants":[{"ends":1000,"id":"\#(id)"}],"version":1}"#
        XCTAssertEqual(AgentGrantsRecord.merged(long, short), short)
        XCTAssertEqual(AgentGrantsRecord.merged(short, long), short)
    }

    func testStandingPermissionsInADatabaseAreMergedByTheEngine() throws {
        let g1 = "11111111-1111-1111-1111-111111111111", g2 = "22222222-2222-2222-2222-222222222222"
        var here = MergeCopy()
        here.customData = [(AgentGrantsRecord.customDataKey, #"{"grants":[{"ends":1000,"id":"\#(g1)"}],"version":1}"#, nil)]
        var there = MergeCopy()
        there.customData = [(AgentGrantsRecord.customDataKey, #"{"grants":[{"ends":1000,"id":"\#(g2)"}],"version":1}"#, nil)]
        let one = try merged(try there.vault(), into: try here.vault())
        let two = try merged(try here.vault(), into: try there.vault())
        let text = try XCTUnwrap(one.vault.customData[AgentGrantsRecord.customDataKey])
        XCTAssertTrue(text.contains(g1) && text.contains(g2))
        XCTAssertEqual(two.vault.customData, one.vault.customData)
    }

    func testTheListOfItemsChangedOnBothKeepsBothCopiesRecordsAndOnlyTheNewest() {
        func record(_ number: Int) -> MergeConflictLog.Record {
            MergeConflictLog.Record(item: mergeID(number), kept: Int64(number), older: 0)
        }
        func text(_ records: [MergeConflictLog.Record]) -> String? {
            MergeConflictLog.merged(nil, nil, adding: records)
        }
        let mine = text([record(1), record(2)]), other = text([record(2), record(3)])
        let merged = MergeConflictLog.merged(mine, other, adding: [record(4)])
        XCTAssertEqual(MergeConflictLog.records(in: [MergeConflictLog.customDataKey: merged ?? ""]), [record(1), record(2), record(3), record(4)])
        XCTAssertEqual(MergeConflictLog.merged(merged, mine, adding: []), merged)
        XCTAssertEqual(MergeConflictLog.merged(mine, other, adding: []), MergeConflictLog.merged(other, mine, adding: []))

        let many = text((1...(MergeConflictLog.limit + 10)).map(record))
        let kept = MergeConflictLog.records(in: [MergeConflictLog.customDataKey: many ?? ""])
        XCTAssertEqual(kept.count, MergeConflictLog.limit)
        XCTAssertEqual(kept.first, record(11))
        XCTAssertEqual(MergeConflictLog.merged("{future", other, adding: [record(9)]), "{future")
    }

    // MARK: What cannot be merged

    func testADatabaseThatWasNeverSavedCannotBeMerged() throws {
        let saved = try MergeCopy(items: [MergeItem(0xA1, "Bank")]).vault()
        let fresh = Vault(entries: [VaultEntry(fields: [VaultField(key: "Title", value: "New")])], kdf: .fastTest)
        XCTAssertThrowsError(try VaultMerge.merge(saved, into: fresh)) { XCTAssertTrue($0 is VaultMergeError) }
        XCTAssertThrowsError(try VaultMerge.merge(fresh, into: saved)) { XCTAssertTrue($0 is VaultMergeError) }
    }

    func testAnotherDatabaseAltogetherIsMergedInUnderOurRoot() throws {
        var mine = MergeCopy(items: [MergeItem(0xA1, "Mine")])
        mine.root.id = 0x01
        var other = MergeCopy(items: [MergeItem(0xB1, "Theirs")], groups: [MergeGroup(0x20, "Their folder", items: [MergeItem(0xB2, "Deep")])])
        other.root = MergeGroup(0x99, "Another root", modified: 99, items: other.root.items, groups: other.root.groups)

        let outcome = try merged(try other.vault(), into: try mine.vault())
        XCTAssertEqual(outcome.vault.rootName, "Passwords", "our root keeps its name")
        XCTAssertEqual(outcome.vault.rootGroupID, mergeID(0x01))
        XCTAssertEqual(try other.vault().rootGroupID, mergeID(0x99), "another root group: another database, not a copy of ours")
        XCTAssertNil(Vault().rootGroupID)
        XCTAssertEqual(outcome.vault.item(0xB1)?.groupPath, [])
        XCTAssertEqual(outcome.vault.item(0xB2)?.groupPath, ["Their folder"])
        XCTAssertEqual(outcome.report.added, 2)
    }

    func testTheResultKeepsTheKeysAndTheBytesOfTheDatabaseMergedInto() throws {
        let here = try MergeCopy(items: [MergeItem(0xA1, "Bank")]).vault()
        let there = try MergeCopy(items: [MergeItem(0xA2, "Mail")]).vault(password: "another password")
        let outcome = try VaultMerge.merge(there, into: here)
        XCTAssertEqual(outcome.vault.fileBaseline, here.fileBaseline)
        XCTAssertEqual(outcome.vault.kdf, here.kdf)
        var saved = outcome.vault
        let data = try KDBX.save(vault: &saved, password: "secret")
        XCTAssertEqual(try KDBX.load(data: data, password: "secret").entries.map(\.title).sorted(), ["Bank", "Mail"])
        XCTAssertThrowsError(try KDBX.load(data: data, password: "another password"))
    }
}
