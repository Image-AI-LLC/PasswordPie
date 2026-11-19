import AppKit
@testable import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// Preferences > Import > A Folder of .env Files, from the folder to the items being in the database file (docs/UX.md,
/// "A folder of .env files becomes items"). Every value in the folder is fake and starts with "PLANTED-".
@MainActor
final class DotenvImportFlowTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("test.kdbx") }

    private let serviceAccount = Data(#"{"type":"service_account","private_key":"PLANTED-json-key"}"#.utf8)
    private let pem = Data("-----BEGIN PRIVATE KEY-----\nPLANTED-pem\n-----END PRIVATE KEY-----\n".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", database.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    /// Two services, two identities, a JSON key and a PEM key, and files that are not secrets.
    private func makeFolder() throws -> URL {
        let root = directory.appendingPathComponent("keys", isDirectory: true)
        func write(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write("stripe/work.env", Data("# Stripe, work\nSTRIPE_SECRET_KEY=PLANTED-stripe-work\nSTRIPE_WEBHOOK_SECRET=\"PLANTED-webhook work\"\n".utf8))
        try write("stripe/personal.env", Data("STRIPE_SECRET_KEY=PLANTED-stripe-personal\n".utf8))
        try write("google/work.env", Data("GOOGLE_API_KEY=PLANTED-google-work\n".utf8))
        try write("google/personal.env", Data("GOOGLE_API_KEY=PLANTED-google-personal\nPASSWORD=PLANTED-own-name\n".utf8))
        try write("google/work-service-account.json", serviceAccount)
        try write("google/personal.pem", pem)
        try write("deploy.sh", Data("#!/bin/sh\necho PLANTED-stripe-work\n".utf8))
        try write("stripe/work.env.bak", Data("STRIPE_SECRET_KEY=PLANTED-older\n".utf8))
        try write("logo.png", Data([0x89, 0x50, 0x4E, 0x47]))
        return root
    }

    private func contents(of root: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            found[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
        return found
    }

    private func flow(_ session: VaultSession) throws -> ImportFlow {
        let flow = ImportFlow(session: session)
        flow.choose(try XCTUnwrap(ImportTile.tile("env-folder")))
        return flow
    }

    private func onDisk() throws -> Vault {
        try KDBX.load(data: Data(contentsOf: database), password: "pw", keyFile: nil)
    }

    private func said(_ folder: DotenvImportFlow) -> String {
        String(describing: folder.debugSummary) + String(describing: folder.rows) + folder.error + String(describing: folder.stage)
    }

    // MARK: Looking

    func testAFolderIsListedAndNothingIsInTheDatabaseYet() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        let root = try makeFolder()
        let before = try contents(of: root)
        folder.take(root)
        XCTAssertEqual(folder.stage, .reading(folderName: "keys"))
        await folder.settled()
        XCTAssertEqual(folder.stage, .found)
        XCTAssertEqual(folder.rows.map(\.place), ["google › personal", "google › work", "stripe › personal", "stripe › work"])
        XCTAssertEqual(folder.rows.map(DotenvImportFlow.contents), ["2 fields, 1 key file", "1 field, 1 key file", "1 field", "2 fields"])
        XCTAssertTrue(folder.rows.allSatisfy { $0.status == .new })
        XCTAssertEqual(folder.rows[0].fieldNames, ["GOOGLE_API_KEY", "PASSWORD (variable)"])
        XCTAssertEqual(folder.rows[0].fileNames, ["personal.pem"])
        XCTAssertEqual(folder.importTitle, "Import 4 Items")
        XCTAssertNil(folder.nothingToImport)
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertEqual(try contents(of: root), before, "the folder is only read")
        XCTAssertFalse(said(folder).contains("PLANTED"), "names and counts, never a value")
        XCTAssertEqual(DotenvImportFlow.leftAlone(try XCTUnwrap(folder.plan).skipped), ["2 other files", "1 old copy"])
        XCTAssertEqual(try XCTUnwrap(folder.plan).skipped.filter { !$0.holds.isEmpty }.map(\.path), ["deploy.sh"])
        XCTAssertEqual(try XCTUnwrap(folder.plan).remarks.map(DotenvImportFlow.remarkText), [
            "google/personal.env: PASSWORD is kept as the field “PASSWORD (variable)”, apart from the item’s own password."
        ])
    }

    // MARK: Importing

    func testImportWritesTheItemsIntoTheDatabaseFileAndLeavesTheFolder() async throws {
        let session = unlockedSession()
        session.saveGenerated("an item of its own")
        let folder = try flow(session).folder
        let root = try makeFolder()
        let before = try contents(of: root)
        folder.take(root)
        await folder.settled()
        folder.commit()
        XCTAssertEqual(folder.stage, .done(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(added: 4), folderName: "keys")))
        XCTAssertEqual(folder.error, "")
        XCTAssertNil(folder.plan, "what was read is dropped once it is in the database")
        XCTAssertEqual(try contents(of: root), before, "the folder is as it was")

        let vault = try onDisk()
        let work = try XCTUnwrap(vault.entries.first { $0.groupPath == ["stripe"] && $0.title == "work" })
        XCTAssertEqual(work.value(for: "STRIPE_SECRET_KEY"), "PLANTED-stripe-work")
        XCTAssertEqual(work.value(for: "STRIPE_WEBHOOK_SECRET"), "PLANTED-webhook work")
        XCTAssertTrue(work.fields.filter { $0.key.hasPrefix("STRIPE") }.allSatisfy(\.protected))
        XCTAssertEqual(work.notes, "Stripe, work")
        let googleWork = try XCTUnwrap(vault.entries.first { $0.groupPath == ["google"] && $0.title == "work" })
        XCTAssertEqual(vault.attachment(named: "work-service-account.json", of: googleWork.id), serviceAccount)
        let googlePersonal = try XCTUnwrap(vault.entries.first { $0.groupPath == ["google"] && $0.title == "personal" })
        XCTAssertEqual(vault.attachment(named: "personal.pem", of: googlePersonal.id), pem)
        XCTAssertEqual(googlePersonal.value(for: "PASSWORD (variable)"), "PLANTED-own-name")
        XCTAssertEqual(googlePersonal.password, "", "a variable named PASSWORD is not the item's password")
        XCTAssertEqual(vault.entries.filter { $0.title == "Generated Password" }.count, 1, "what was there stays")
        // The file from before the import is kept beside the database.
        let snapshot = try KDBX.load(data: Data(contentsOf: VaultFile.snapshotURL(for: database)), password: "pw", keyFile: nil)
        XCTAssertEqual(snapshot.entries.map(\.title), ["Generated Password"])

        // The list shows them, and an item's details name its key files.
        let listed = try XCTUnwrap(session.entries.first { $0.groupPath == ["google"] && $0.title == "work" })
        XCTAssertEqual(session.attachmentNames(of: listed.id), ["work-service-account.json"])
        XCTAssertEqual(DetailsModel(entry: listed, session: session, done: {}).attachments, ["work-service-account.json"])
        XCTAssertEqual(DotenvImportFlow.summaryText(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(added: 4), folderName: "keys")), "4 added.")
    }

    func testImportingTheSameFolderAgainWritesNothing() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        let root = try makeFolder()
        folder.take(root)
        await folder.settled()
        folder.commit()
        let written = try Data(contentsOf: database)

        folder.startOver()
        folder.take(root)
        await folder.settled()
        XCTAssertTrue(folder.rows.allSatisfy { $0.status == .upToDate })
        XCTAssertEqual(folder.pendingCount, 0)
        XCTAssertEqual(folder.nothingToImport, "Already up to date. Nothing to import.")
        folder.commit()
        XCTAssertEqual(folder.stage, .done(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(unchanged: 4), folderName: "keys")))
        XCTAssertEqual(try Data(contentsOf: database), written, "the database file was not written again")
        XCTAssertEqual(session.entries.count, 4)
        XCTAssertEqual(DotenvImportFlow.summaryText(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(unchanged: 4), folderName: "keys")), "Already up to date. Nothing was changed.")
    }

    func testAChangedValueIsOneItemToUpdate() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        let root = try makeFolder()
        folder.take(root)
        await folder.settled()
        folder.commit()
        try Data("# Stripe, work\nSTRIPE_SECRET_KEY=PLANTED-rotated\nSTRIPE_WEBHOOK_SECRET=\"PLANTED-webhook work\"\nSTRIPE_NEW=1\n".utf8)
            .write(to: root.appendingPathComponent("stripe/work.env"))
        folder.startOver()
        folder.take(root)
        await folder.settled()
        XCTAssertEqual(folder.rows.map { DotenvImportFlow.statusText($0.status) }, ["Up to date", "Up to date", "Up to date", "1 field changes, 1 new field"])
        XCTAssertEqual(folder.importTitle, "Import 1 Item")
        XCTAssertFalse(said(folder).contains("PLANTED"))
        folder.commit()
        XCTAssertEqual(folder.stage, .done(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(updated: 1, unchanged: 3), folderName: "keys")))
        let vault = try onDisk()
        XCTAssertEqual(vault.entries.count, 4)
        XCTAssertEqual(vault.entries.first { $0.title == "work" && $0.groupPath == ["stripe"] }?.value(for: "STRIPE_SECRET_KEY"), "PLANTED-rotated")
    }

    func testAnUntickedItemStaysOutAndPutThemInsideMovesTheRest() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        folder.take(try makeFolder())
        await folder.settled()
        folder.parentDraft = "Agents"
        XCTAssertEqual(folder.rows.map(\.place).first, "Agents › google › personal")
        folder.toggle(folder.rows[0].id)
        folder.toggle(folder.rows[1].id)
        XCTAssertFalse(folder.isIncluded(folder.rows[0].id))
        XCTAssertEqual(folder.importTitle, "Import 2 Items")
        folder.commit()
        let vault = try onDisk()
        XCTAssertEqual(vault.entries.map { ($0.groupPath + [$0.title]).joined(separator: "/") }.sorted(), ["Agents/stripe/personal", "Agents/stripe/work"])
        XCTAssertEqual(vault.attachmentNames(), [:], "the key files of the items left out stayed out")
    }

    func testUntickingEverythingLeavesNothingToImport() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        folder.take(try makeFolder())
        await folder.settled()
        for row in folder.rows { folder.toggle(row.id) }
        XCTAssertEqual(folder.pendingCount, 0)
        XCTAssertEqual(folder.nothingToImport, "Tick at least one item to import.")
    }

    // MARK: When it does not apply

    func testALockedDatabaseTakesNoFolderAndLockingForgetsWhatWasRead() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        folder.take(try makeFolder())
        await folder.settled()
        XCTAssertNotNil(folder.plan)
        session.lock()
        XCTAssertNil(folder.plan, "the values read from the folder go when the database locks")
        XCTAssertEqual(folder.rows, [])
        XCTAssertEqual(folder.stage, .waiting)
        folder.take(try makeFolder())
        XCTAssertEqual(folder.error, "Unlock PasswordPie first.")
        XCTAssertEqual(folder.stage, .waiting)
    }

    func testAFolderWithNothingInItAndAFileSayWhy() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        let empty = directory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: empty.appendingPathComponent("readme.md"))
        folder.take(empty)
        await folder.settled()
        XCTAssertEqual(folder.stage, .waiting)
        XCTAssertEqual(folder.error, "No .env files or key files in “docs”. Choose the folder that holds them.")
        folder.take(empty.appendingPathComponent("readme.md"))
        await folder.settled()
        XCTAssertEqual(folder.error, "Choose a folder: the one that holds the .env files.")
    }

    func testLeavingThePageForgetsTheFolder() async throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.folder.take(try makeFolder())
        await flow.folder.settled()
        flow.showSources()
        XCTAssertNil(flow.folder.plan)
        XCTAssertEqual(flow.folder.stage, .waiting)
        XCTAssertNil(flow.tile)
    }

    func testARereadThatFinishesAfterThePageMovedOnIsDropped() async throws {
        let session = unlockedSession()
        let folder = try flow(session).folder
        folder.take(try makeFolder())
        folder.startOver()
        await folder.settled()
        XCTAssertEqual(folder.stage, .waiting)
        XCTAssertNil(folder.plan)
    }

    // MARK: The pane

    func testTheSourceHasItsOwnRowAndPage() throws {
        let tile = try XCTUnwrap(ImportTile.tile("env-folder"))
        XCTAssertEqual(tile.kind, .envFolder)
        XCTAssertNil(tile.source)
        XCTAssertFalse(ImportTile.all.contains(tile), "it is not a file from another app")
        XCTAssertEqual(tile.name, "A Folder of .env Files")
    }

    func testThePageDrawsWithAFolderRead() async throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.folder.take(try makeFolder())
        await flow.folder.settled()
        let host = NSHostingView(rootView: ImportPane(flow: flow, session: session).frame(width: 560))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 900)
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        XCTAssertGreaterThan(host.fittingSize.height, 300)
    }

    func testWords() {
        XCTAssertEqual(DotenvImportFlow.statusText(.new), "New")
        XCTAssertEqual(DotenvImportFlow.statusText(.changes(DotenvImport.Changes(newFields: ["A"], changedFields: ["B", "C"], newFiles: ["k.pem", "j.json"], changedFiles: ["x"], notes: true))),
                       "2 fields change, 1 new field, 1 key file changes, 2 new key files, notes change")
        XCTAssertEqual(DotenvImportFlow.remarkText(.unreadable(file: "a.env", lines: [3])), "a.env: line 3 is not NAME=value, and was not read.")
        XCTAssertEqual(DotenvImportFlow.remarkText(.unreadable(file: "a.env", lines: [3, 9])), "a.env: lines 3, 9 are not NAME=value, and were not read.")
        XCTAssertEqual(DotenvImportFlow.remarkText(.repeated(file: "a.env", names: ["A"])), "a.env: A is set more than once. The last value is used.")
        XCTAssertEqual(DotenvImportFlow.summaryText(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(added: 2, updated: 1), folderName: "k")), "2 added, 1 updated.")
        XCTAssertEqual(DotenvImportFlow.folderText(DotenvImportFlow.Outcome(summary: DotenvImport.Summary(), folderName: "keys")),
                       "The files in “keys” are as they were. They still hold every value in plain text.")
    }
}
