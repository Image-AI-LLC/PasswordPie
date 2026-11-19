import XCTest
@testable import PasswordPieCore

/// A folder of dotenv files into a real KDBX file and back (docs/UX.md, "A folder of .env files becomes items").
final class DotenvImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A database with an item of its own, saved once so it is a file.
    private func database() throws -> Vault {
        var own = VaultEntry(groupPath: ["Web"])
        own.title = "GitHub"
        own.username = "octocat"
        own.password = "own-password"
        var vault = Vault(name: "Box", rootName: "Box", entries: [own], kdf: .fastTest)
        return try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
    }

    /// Saves and reads the file again, as the app does after an import.
    private func saved(_ vault: inout Vault) throws -> Vault {
        let data = try KDBX.save(vault: &vault, password: "secret")
        return try KDBX.load(data: data, password: "secret")
    }

    private func entry(_ vault: Vault, _ path: String) throws -> VaultEntry {
        try XCTUnwrap(vault.entries.first { !$0.trashed && ($0.groupPath + [$0.title]).joined(separator: "/") == path }, "no item \(path)")
    }

    func testAnImportMakesAnItemPerFileWithProtectedFieldsNotesAndKeyFiles() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        var vault = try database()
        XCTAssertTrue(plan.items.allSatisfy { DotenvImport.status(of: $0, inside: [], in: vault) == .new })
        XCTAssertEqual(DotenvImport.apply(plan.items, inside: [], to: &vault), DotenvImport.Summary(added: 5))
        let loaded = try saved(&vault)

        let work = try entry(loaded, "stripe/work")
        XCTAssertEqual(work.fields.map(\.key), ["Title", "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_ACCOUNT", "Notes"])
        XCTAssertEqual(work.value(for: "STRIPE_SECRET_KEY"), DotenvFixture.stripeWork)
        XCTAssertEqual(work.value(for: "STRIPE_WEBHOOK_SECRET"), DotenvFixture.stripeWebhook)
        XCTAssertEqual(work.value(for: "STRIPE_ACCOUNT"), "acct_work")
        XCTAssertTrue(work.fields.filter { $0.key.hasPrefix("STRIPE") }.allSatisfy(\.protected), "every variable is a protected field")
        XCTAssertEqual(work.notes, "Stripe, the work account\nRotated in May")
        XCTAssertEqual(try entry(loaded, "stripe/personal").value(for: "STRIPE_SECRET_KEY"), DotenvFixture.stripePersonal)

        let google = try entry(loaded, "google/work")
        XCTAssertEqual(loaded.attachmentNames(of: google.id), ["work-service-account.json"])
        XCTAssertEqual(loaded.attachment(named: "work-service-account.json", of: google.id), DotenvFixture.serviceAccount)
        XCTAssertEqual(loaded.attachment(named: "personal.pem", of: try entry(loaded, "google/personal").id), DotenvFixture.pem)
        XCTAssertEqual(loaded.attachment(named: "AuthKey_FAKE12345.p8", of: try entry(loaded, "apple/Key files").id), DotenvFixture.p8)

        // What was there is as it was.
        let own = try entry(loaded, "Web/GitHub")
        XCTAssertEqual(own.password, "own-password")
        XCTAssertEqual(loaded.entries.count, 6)
    }

    func testImportingTwiceChangesNothingTheSecondTime() throws {
        let root = try DotenvFixture.make(in: directory)
        var vault = try database()
        _ = DotenvImport.apply(try DotenvFolder.read(root).items, inside: [], to: &vault)
        var loaded = try saved(&vault)
        let first = loaded

        let again = try DotenvFolder.read(root)
        XCTAssertTrue(again.items.allSatisfy { DotenvImport.status(of: $0, inside: [], in: loaded) == .upToDate })
        XCTAssertEqual(DotenvImport.apply(again.items, inside: [], to: &loaded), DotenvImport.Summary(unchanged: 5))
        XCTAssertEqual(loaded.entries, first.entries, "no entry is touched, so a save has nothing to write")
        let reloaded = try saved(&loaded)
        XCTAssertEqual(reloaded.entries, first.entries)
        XCTAssertEqual(reloaded.preserve?.binaryPayloads, first.preserve?.binaryPayloads)
        XCTAssertEqual(reloaded.preserve?.document.xmlString, first.preserve?.document.xmlString, "not a version, not a time: the document is the same")
    }

    func testAChangedFolderUpdatesFieldsAndKeepsEverythingElse() throws {
        let root = try DotenvFixture.make(in: directory)
        var vault = try database()
        _ = DotenvImport.apply(try DotenvFolder.read(root).items, inside: [], to: &vault)
        var loaded = try saved(&vault)
        // The person adds a field of their own, and a tag.
        let index = try XCTUnwrap(loaded.entries.firstIndex { $0.title == "work" && $0.groupPath == ["stripe"] })
        loaded.entries[index].setValue("mine", for: "Dashboard login")
        loaded.entries[index].tags = "billing"
        loaded = try saved(&loaded)

        // One value changes, one variable is new, one is removed, the comments change, a key file changes, one is new.
        try Data("# Stripe, the work account\nSTRIPE_SECRET_KEY=PLANTED-rotated-value\nSTRIPE_ACCOUNT=acct_work\nSTRIPE_REGION=eu\n".utf8)
            .write(to: root.appendingPathComponent("stripe/work.env"))
        let newKey = Data("-----BEGIN PRIVATE KEY-----\nPLANTED-rotated-key\n-----END PRIVATE KEY-----\n".utf8)
        try newKey.write(to: root.appendingPathComponent("google/personal.pem"))
        try Data("PLANTED-bare-token\n".utf8).write(to: root.appendingPathComponent("google/personal-token.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("google/work-service-account.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("stripe/personal.env"))

        let plan = try DotenvFolder.read(root)
        func status(_ path: String) throws -> DotenvImport.Status {
            let item = try XCTUnwrap(plan.items.first { ($0.folder + [$0.title]).joined(separator: "/") == path })
            return DotenvImport.status(of: item, inside: [], in: loaded)
        }
        XCTAssertEqual(try status("stripe/work"), .changes(DotenvImport.Changes(newFields: ["STRIPE_REGION"], changedFields: ["STRIPE_SECRET_KEY"], notes: true)))
        XCTAssertEqual(try status("google/personal"), .changes(DotenvImport.Changes(newFiles: ["personal-token.txt"], changedFiles: ["personal.pem"])))
        XCTAssertEqual(try status("google/work"), .upToDate)
        XCTAssertEqual(try status("apple/Key files"), .upToDate)
        XCTAssertFalse(String(describing: try status("stripe/work")).contains("PLANTED"), "a status names fields, never a value")

        XCTAssertEqual(DotenvImport.apply(plan.items, inside: [], to: &loaded), DotenvImport.Summary(updated: 2, unchanged: 2))
        let after = try saved(&loaded)
        let work = try entry(after, "stripe/work")
        XCTAssertEqual(work.value(for: "STRIPE_SECRET_KEY"), "PLANTED-rotated-value")
        XCTAssertEqual(work.value(for: "STRIPE_REGION"), "eu")
        XCTAssertEqual(work.value(for: "STRIPE_WEBHOOK_SECRET"), DotenvFixture.stripeWebhook, "a variable gone from the file stays")
        XCTAssertEqual(work.value(for: "Dashboard login"), "mine")
        XCTAssertEqual(work.tags, "billing")
        XCTAssertEqual(work.notes, "Stripe, the work account")
        let personal = try entry(after, "google/personal")
        XCTAssertEqual(after.attachment(named: "personal.pem", of: personal.id), newKey)
        XCTAssertEqual(after.attachment(named: "personal-token.txt", of: personal.id), Data("PLANTED-bare-token\n".utf8))
        // What is gone from the folder is still in the database.
        XCTAssertEqual(after.attachment(named: "work-service-account.json", of: try entry(after, "google/work").id), DotenvFixture.serviceAccount)
        XCTAssertEqual(try entry(after, "stripe/personal").value(for: "STRIPE_SECRET_KEY"), DotenvFixture.stripePersonal)
        // The value from before the change is in the item's history.
        XCTAssertTrue(try XCTUnwrap(after.preserve).document.xmlString.contains(DotenvFixture.stripeWork))
        XCTAssertTrue(try XCTUnwrap(after.preserve?.binaryPayloads).contains(DotenvFixture.pem), "the key file from before is still in the file, for the history")
    }

    func testPutThemInsideAFolder() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        var vault = try database()
        XCTAssertEqual(DotenvImport.parentPath(" Agents / Keys /"), ["Agents", "Keys"])
        XCTAssertEqual(DotenvImport.parentPath(""), [])
        _ = DotenvImport.apply(plan.items, inside: ["Agents"], to: &vault)
        var loaded = try saved(&vault)
        XCTAssertEqual(try entry(loaded, "Agents/stripe/work").value(for: "STRIPE_SECRET_KEY"), DotenvFixture.stripeWork)
        XCTAssertTrue(plan.items.allSatisfy { DotenvImport.status(of: $0, inside: ["Agents"], in: loaded) == .upToDate })
        XCTAssertTrue(plan.items.allSatisfy { DotenvImport.status(of: $0, inside: [], in: loaded) == .new }, "another place is another set of items")
        XCTAssertEqual(DotenvImport.apply(plan.items, inside: ["Agents"], to: &loaded).unchanged, 5)
    }

    func testOnlyTheChosenItemsAreImported() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        var vault = try database()
        let chosen = plan.items.filter { $0.folder == ["stripe"] }
        XCTAssertEqual(DotenvImport.apply(chosen, inside: [], to: &vault).added, 2)
        let loaded = try saved(&vault)
        XCTAssertEqual(loaded.entries.map(\.title).sorted(), ["GitHub", "personal", "work"])
        XCTAssertEqual(loaded.preserve?.binaryPayloads, [])
    }

    func testAnItemInTheRecycleBinIsNotBroughtBackAndAnEmptyValueIsAField() throws {
        let root = directory.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("svc"), withIntermediateDirectories: true)
        try Data("EMPTY=\nKEY=PLANTED-value\n".utf8).write(to: root.appendingPathComponent("svc/me.env"))
        let plan = try DotenvFolder.read(root)
        var vault = try database()
        _ = DotenvImport.apply(plan.items, inside: [], to: &vault)
        var loaded = try saved(&vault)
        let me = try entry(loaded, "svc/me")
        XCTAssertEqual(me.fields.map(\.key), ["Title", "EMPTY", "KEY"])
        XCTAssertEqual(DotenvImport.status(of: plan.items[0], inside: [], in: loaded), .upToDate, "an empty value is there too")

        let index = try XCTUnwrap(loaded.entries.firstIndex { $0.id == me.id })
        loaded.entries[index].trashed = true
        loaded = try saved(&loaded)
        XCTAssertEqual(DotenvImport.status(of: plan.items[0], inside: [], in: loaded), .new)
        XCTAssertEqual(DotenvImport.apply(plan.items, inside: [], to: &loaded).added, 1)
        XCTAssertEqual(try saved(&loaded).entries.filter { $0.title == "me" }.count, 2)
    }

    func testAFieldSomeoneLeftUnprotectedIsProtectedByTheImport() throws {
        let root = directory.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("svc"), withIntermediateDirectories: true)
        try Data("KEY=PLANTED-value\n".utf8).write(to: root.appendingPathComponent("svc/me.env"))
        var mine = VaultEntry(groupPath: ["svc"])
        mine.title = "me"
        mine.setValue("PLANTED-value", for: "KEY")
        var vault = Vault(name: "Box", rootName: "Box", entries: [mine], kdf: .fastTest)
        var loaded = try saved(&vault)
        let plan = try DotenvFolder.read(root)
        XCTAssertEqual(DotenvImport.status(of: plan.items[0], inside: [], in: loaded), .changes(DotenvImport.Changes(changedFields: ["KEY"])))
        XCTAssertEqual(DotenvImport.apply(plan.items, inside: [], to: &loaded).updated, 1)
        let after = try saved(&loaded)
        XCTAssertEqual(after.entries.count, 1, "the item someone made by hand is the item")
        XCTAssertEqual(after.entries[0].fields.first { $0.key == "KEY" }?.protected, true)
    }

    func testTheSubjectsOfACheckAreEveryVariableAndKeyFileWithItsPlace() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        let subjects = DotenvImport.subjects(of: plan, inside: ["Agents"])
        XCTAssertEqual(subjects.count, 3 + 2 + 2 + 1 + 3)
        let webhook = try XCTUnwrap(subjects.first { $0.name == "STRIPE_WEBHOOK_SECRET" })
        XCTAssertEqual(webhook.file, "stripe/work.env")
        XCTAssertEqual(webhook.folder, ["Agents", "stripe"])
        XCTAssertEqual(webhook.title, "work")
        XCTAssertEqual(webhook.key, "STRIPE_WEBHOOK_SECRET")
        XCTAssertEqual(webhook.expected, Data(DotenvFixture.stripeWebhook.utf8))
        let key = try XCTUnwrap(subjects.first { $0.name == "AuthKey_FAKE12345.p8" })
        XCTAssertNil(key.key)
        XCTAssertEqual(key.file, "apple/AuthKey_FAKE12345.p8")
        XCTAssertEqual(key.title, "Key files")
        XCTAssertEqual(key.expected, DotenvFixture.p8)
    }

    /// KeePassXC reads what the import wrote: the fields as protected attributes, the key files as attachments.
    func testKeePassXCReadsAnImportedFolder() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cli), "KeePassXC CLI is not installed")
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        var vault = try database()
        _ = DotenvImport.apply(plan.items, inside: [], to: &vault)
        let file = directory.appendingPathComponent("box.kdbx")
        try KDBX.save(vault: &vault, password: "secret").write(to: file)
        func run(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            let (input, output, error) = (Pipe(), Pipe(), Pipe())
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            input.fileHandleForWriting.write(Data("secret\n".utf8))
            try input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
            return out
        }
        XCTAssertEqual(try run(["show", "-q", "-s", "-a", "STRIPE_WEBHOOK_SECRET", file.path, "stripe/work"]), Data((DotenvFixture.stripeWebhook + "\n").utf8))
        XCTAssertEqual(try run(["attachment-export", "-q", "--stdout", file.path, "google/work", "work-service-account.json"]), DotenvFixture.serviceAccount)
        XCTAssertEqual(try run(["attachment-export", "-q", "--stdout", file.path, "apple/Key files", "AuthKey_FAKE12345.p8"]), DotenvFixture.p8)
    }
}
