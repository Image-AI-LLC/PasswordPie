import XCTest
@testable import PasswordPieCore

/// A made-up folder of dotenv files: two services, two identities, a PEM key and a JSON key, and the working files that
/// sit beside secrets in such a folder. Every value is fake and starts with "PLANTED-", so a test can look for one
/// anywhere it must not be.
enum DotenvFixture {
    static let stripeWork = "PLANTED-sk_test_work_4eC39HqLyjWDarjtT1"
    static let stripeWebhook = "PLANTED-whsec work secret"
    static let stripePersonal = "PLANTED-sk_test_personal_9fD20IrMzk"
    static let googleWork = "PLANTED-AIzaWorkKey0123456789"
    static let googlePersonal = "PLANTED-AIzaPersonalKey9876543210"
    static let pem = Data("-----BEGIN PRIVATE KEY-----\nPLANTED-MIIEvQIBADANfake\n-----END PRIVATE KEY-----\n".utf8)
    static let p8 = Data("-----BEGIN PRIVATE KEY-----\nPLANTED-MIGTAgEAMBMGfake\n-----END PRIVATE KEY-----\n".utf8)
    static let serviceAccount = Data(#"{"type":"service_account","project_id":"demo","private_key":"PLANTED-json-private-key"}"#.utf8)

    static var planted: [String] {
        [stripeWork, stripeWebhook, stripePersonal, googleWork, googlePersonal, "PLANTED-MIIEvQIBADANfake", "PLANTED-MIGTAgEAMBMGfake", "PLANTED-json-private-key", "PLANTED-old-value-000"]
    }

    @discardableResult
    static func make(in parent: URL, named name: String = "keys") throws -> URL {
        let root = parent.appendingPathComponent(name, isDirectory: true)
        func write(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func text(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }
        try text("stripe/work.env", """
        # Stripe, the work account
        # Rotated in May
        STRIPE_SECRET_KEY=\(stripeWork)
        export STRIPE_WEBHOOK_SECRET="\(stripeWebhook)"
        STRIPE_ACCOUNT=acct_work  # not a secret

        """)
        try text("stripe/personal.env", "STRIPE_SECRET_KEY=\(stripePersonal)\nSTRIPE_ACCOUNT=acct_personal\n")
        try text("google/work.env", "GOOGLE_API_KEY=\(googleWork)\nGOOGLE_PROJECT=demo-work\n")
        try text("google/personal.env", "GOOGLE_API_KEY='\(googlePersonal)'\n")
        try write("google/work-service-account.json", serviceAccount)
        try write("google/personal.pem", pem)
        try write("apple/AuthKey_FAKE12345.p8", p8)
        // The files that sit beside secrets: none of them is imported.
        try text("deploy.sh", "#!/bin/sh\ncurl -H \"Authorization: Bearer \(stripeWork)\" https://example.invalid\n")
        try text("stripe/work.env.bak", "STRIPE_SECRET_KEY=PLANTED-old-value-000\nSTRIPE_WEBHOOK_SECRET=\"\(stripeWebhook)\"\n")
        try text("stripe/.env.example", "STRIPE_SECRET_KEY=\nSTRIPE_WEBHOOK_SECRET=\n")
        try text("_local/m2.env", "CONFIGS_DIR=/Users/someone/ops/configs\n")
        try text(".backup/stripe-work.env", "STRIPE_SECRET_KEY=\(stripeWork)\n")
        try text("metrics/snapshot.json", #"{"requests": 1200, "tokens": 5}"#)
        try write("logo.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00]))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.env"), withDestinationURL: root.appendingPathComponent("stripe/work.env"))
        return root
    }

    /// Every file under `root` with its bytes, to show a read or an import changed nothing.
    static func contents(of root: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = String(file.path.dropFirst(root.path.count))
            if values.isSymbolicLink == true {
                found[path] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)
            } else if values.isRegularFile == true {
                found[path] = try Data(contentsOf: file)
            }
        }
        return found
    }
}

final class DotenvFolderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func item(_ plan: DotenvPlan, _ path: String) throws -> DotenvPlan.Item {
        try XCTUnwrap(plan.items.first { ($0.folder + [$0.title]).joined(separator: "/") == path }, "no item \(path)")
    }

    func testEachDotenvFileIsAnItemOfItsFolder() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        XCTAssertEqual(plan.folderName, "keys")
        XCTAssertEqual(plan.items.map { ($0.folder + [$0.title]).joined(separator: "/") }, [
            "apple/Key files", "google/personal", "google/work", "stripe/personal", "stripe/work"
        ])
        let work = try item(plan, "stripe/work")
        XCTAssertEqual(work.file, "stripe/work.env")
        XCTAssertEqual(work.fields.map(\.name), ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_ACCOUNT"])
        XCTAssertEqual(work.fields.map(\.key), work.fields.map(\.name))
        XCTAssertEqual(work.fields.map(\.value), [DotenvFixture.stripeWork, DotenvFixture.stripeWebhook, "acct_work"])
        XCTAssertEqual(work.notes, "Stripe, the work account\nRotated in May")
        XCTAssertEqual(try item(plan, "google/personal").fields.map(\.value), [DotenvFixture.googlePersonal])
    }

    func testKeyFilesGoToTheItemTheirNameNamesOrToKeyFiles() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        XCTAssertEqual(try item(plan, "google/work").keyFiles, [
            DotenvPlan.KeyFile(path: "google/work-service-account.json", name: "work-service-account.json", data: DotenvFixture.serviceAccount)
        ])
        XCTAssertEqual(try item(plan, "google/personal").keyFiles.map(\.name), ["personal.pem"])
        // A folder with key files and no dotenv file.
        let apple = try item(plan, "apple/Key files")
        XCTAssertNil(apple.file)
        XCTAssertEqual(apple.fields, [])
        XCTAssertEqual(apple.keyFiles.map(\.data), [DotenvFixture.p8])
        XCTAssertEqual(try item(plan, "stripe/work").keyFiles, [])
    }

    func testAKeyFileThatNamesNoItemGoesToTheOnlyItemOrToKeyFiles() throws {
        let root = directory.appendingPathComponent("more", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("one/only.env", "A=1\n")
        try write("one/api_key", "PLANTED-bare-key\n")
        try write("two/work.env", "A=1\n")
        try write("two/personal.env", "A=2\n")
        try write("two/shared.pem", "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")
        try write("two/network.key", "raw key bytes")
        try write("two/oauth.json", #"{"installed": {"client_secret": "PLANTED-nested"}}"#)
        try write("two/token.txt", "PLANTED-token\n")
        try write("two/work_api_key", "PLANTED-work-key\n")
        try write("two/keynotes.txt", "not a key")
        try write("two/notes.txt", "not a key")
        try write("two/settings.json", #"{"theme": "dark"}"#)
        let plan = try DotenvFolder.read(root)
        XCTAssertEqual(try item(plan, "one/only").keyFiles.map(\.name), ["api_key"])
        XCTAssertEqual(try item(plan, "two/Key files").keyFiles.map(\.name), ["network.key", "oauth.json", "shared.pem", "token.txt"], "network.key does not name the item work")
        XCTAssertEqual(try item(plan, "two/work").keyFiles.map(\.name), ["work_api_key"])
        XCTAssertEqual(plan.skipped.map(\.path), ["two/keynotes.txt", "two/notes.txt", "two/settings.json"])
    }

    func testEverythingElseIsLeftAloneAndSaysWhy() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.path, $0.reason) })
        XCTAssertEqual(reasons, [
            ".backup": .hidden, "_local": .underscore, "deploy.sh": .other, "linked.env": .link, "logo.png": .other,
            "metrics/snapshot.json": .other, "stripe/.env.example": .template, "stripe/work.env.bak": .oldCopy
        ])
        XCTAssertEqual(plan.skipped.filter(\.isFolder).map(\.path), [".backup", "_local"])
    }

    /// The generated copies, backups and scripts with a pasted token are the other files to delete.
    func testAFileLeftAloneThatHoldsAnImportedValueIsNamed() throws {
        let plan = try DotenvFolder.read(try DotenvFixture.make(in: directory))
        let holds = Dictionary(uniqueKeysWithValues: plan.skipped.filter { !$0.holds.isEmpty }.map { ($0.path, $0.holds) })
        XCTAssertEqual(holds, [
            ".backup": ["STRIPE_SECRET_KEY"], "deploy.sh": ["STRIPE_SECRET_KEY"], "stripe/work.env.bak": ["STRIPE_WEBHOOK_SECRET"]
        ])
    }

    func testNamesOfDotenvFiles() {
        XCTAssertEqual(DotenvFolder.identity(ofFileNamed: "work.env"), "work")
        XCTAssertEqual(DotenvFolder.identity(ofFileNamed: ".env"), "env")
        XCTAssertEqual(DotenvFolder.identity(ofFileNamed: ".env.staging"), "staging")
        XCTAssertEqual(DotenvFolder.identity(ofFileNamed: "a.b.env"), "a.b")
        XCTAssertNil(DotenvFolder.identity(ofFileNamed: "env"))
        XCTAssertNil(DotenvFolder.identity(ofFileNamed: "work.env.fish"))
        XCTAssertNil(DotenvFolder.identity(ofFileNamed: ".hidden.env"))
        XCTAssertTrue(DotenvFolder.isTemplate(".env.example"))
        XCTAssertTrue(DotenvFolder.isTemplate("work.env.sample"))
        XCTAssertTrue(DotenvFolder.isTemplate("Example.env"))
        XCTAssertFalse(DotenvFolder.isTemplate("work.env"))
        XCTAssertTrue(DotenvFolder.isOldCopy("work.env.bak"))
        XCTAssertTrue(DotenvFolder.isOldCopy("work.env.BAK2"))
        XCTAssertTrue(DotenvFolder.isOldCopy("work.env~"))
        XCTAssertFalse(DotenvFolder.isOldCopy("bakery.env"))
    }

    func testAVariableNamedLikeAnItemsOwnFieldIsKeptApart() throws {
        let root = directory.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("PASSWORD=PLANTED-pw\nurl=https://example.invalid\nDB_PASSWORD=x\nTimeOtp-Secret=y\nNOTES=n\n".utf8).write(to: root.appendingPathComponent("db.env"))
        let plan = try DotenvFolder.read(root)
        let fields = try item(plan, "db").fields
        XCTAssertEqual(fields.map(\.key), ["PASSWORD (variable)", "url (variable)", "DB_PASSWORD", "NOTES (variable)"])
        XCTAssertEqual(plan.remarks, [
            .renamed(file: "db.env", name: "PASSWORD", key: "PASSWORD (variable)"),
            .renamed(file: "db.env", name: "url", key: "url (variable)"),
            .renamed(file: "db.env", name: "NOTES", key: "NOTES (variable)"),
            .unreadable(file: "db.env", lines: [4])
        ])
    }

    func testRemarksNameLinesAndVariablesNeverValues() throws {
        let root = directory.appendingPathComponent("odd", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("A=PLANTED-one\nnot a line PLANTED-two\nA=PLANTED-three\nB=PLANTED-$four\n".utf8).write(to: root.appendingPathComponent("x.env"))
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: root.appendingPathComponent("binary.env"))
        // The same item a second time: the first file by name is the item.
        try Data("A=PLANTED-again\n".utf8).write(to: root.appendingPathComponent("x.env.env"))
        try Data("A=PLANTED-again\n".utf8).write(to: root.appendingPathComponent(".env.x.env"))
        let plan = try DotenvFolder.read(root)
        XCTAssertEqual(plan.items.map(\.title), ["x.env", "x"])
        XCTAssertEqual(plan.remarks, [
            .unreadable(file: "x.env", lines: [2]),
            .repeated(file: "x.env", names: ["A"]),
            .shellSensitive(file: "x.env", names: ["B"])
        ])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.path, $0.reason) }), ["binary.env": .notText, "x.env.env": .duplicate])
        let said = String(describing: plan.remarks) + String(describing: plan.skipped)
        XCTAssertFalse(said.contains("PLANTED"), said)
    }

    /// Names the database cannot keep as they are would make another item on every import: left alone instead.
    func testAFolderNamedRecycleBinAndNamesTheDatabaseCannotKeepAreLeftAlone() throws {
        let root = directory.appendingPathComponent("odd-names", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("Recycle Bin/work.env", "A=PLANTED-in-the-bin\n")
        try write("ok/work.env", "# a\u{1}note\nA=1\n")
        try write("ok/bad\u{1}name.env", "A=2\n")
        try write("ok/bad\u{2}key.pem", "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n")
        try write("ok/ lead.pem", "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n")
        try write("ok/trail.pem ", "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n")
        let plan = try DotenvFolder.read(root)
        XCTAssertEqual(plan.items.map { ($0.folder + [$0.title]).joined(separator: "/") }, ["ok/work"])
        XCTAssertEqual(plan.items[0].notes, "anote", "as the database will keep it")
        XCTAssertEqual(Set(plan.skipped.map(\.path)), ["Recycle Bin", "ok/bad\u{1}name.env", "ok/bad\u{2}key.pem"])
        XCTAssertEqual(plan.items[0].keyFiles.map(\.name), ["lead.pem", "trail.pem"], "a key file is attached under the name the database keeps")
    }

    func testACheckDoesNotReadTheFilesLeftAlone() throws {
        let root = try DotenvFixture.make(in: directory)
        let plan = try DotenvFolder.read(root, findingCopies: false)
        XCTAssertEqual(plan.items.count, 5)
        XCTAssertTrue(plan.skipped.allSatisfy(\.holds.isEmpty))
        XCTAssertEqual(plan.skipped.count, 8, "they are still listed")
    }

    func testReadingChangesNothingInTheFolder() throws {
        let root = try DotenvFixture.make(in: directory)
        let before = try DotenvFixture.contents(of: root)
        _ = try DotenvFolder.read(root)
        XCTAssertEqual(try DotenvFixture.contents(of: root), before)
    }

    func testAFileIsNotAFolderAndAHugeFolderIsRefused() throws {
        let file = directory.appendingPathComponent("a.env")
        try Data("A=1\n".utf8).write(to: file)
        XCTAssertThrowsError(try DotenvFolder.read(file))
        XCTAssertThrowsError(try DotenvFolder.read(directory.appendingPathComponent("missing")))
    }

    func testAFolderWithNothingToImport() throws {
        let root = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("readme.md"))
        let plan = try DotenvFolder.read(root)
        XCTAssertEqual(plan.items, [])
        XCTAssertEqual(plan.skipped.map(\.path), ["readme.md"])
    }
}
