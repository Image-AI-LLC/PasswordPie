import Foundation
@testable import PasswordPieCore
import XCTest

/// PasswordPie's merge against KeePassXC's, on two copies of a database that KeePassXC itself changed apart
/// (`Fixtures/Merge/README.md`).
final class KeePassXCMergeTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let keyFileURL = fixtures.appendingPathComponent("KeyFiles/any.key")

    private func fixture(_ name: String) throws -> Vault {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("Merge/\(name).kdbx"))
        var vault = try KDBX.load(data: data, password: "pie-test", keyFile: try Data(contentsOf: Self.keyFileURL))
        vault.noteFileContents(data)
        return vault
    }

    /// One line per item: where it is, its fields, its attachments' bytes and the passwords of its earlier versions.
    private func items(_ vault: Vault, history: Bool = true) -> [String: String] {
        var lines: [String: String] = [:]
        for entry in vault.entries where !entry.trashed {
            let fields = entry.fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "|")
            let attachments = vault.attachmentNames(of: entry.id).sorted().map { name in
                "\(name)=\(vault.attachment(named: name, of: entry.id).map { String(decoding: $0, as: UTF8.self) } ?? "?")"
            }
            let versions = vault.versions(of: entry.id).map { $0.fields.first { $0.key == "Password" }?.value ?? "" }
            lines[entry.title] = "\(entry.groupPath) \(fields) \(attachments)" + (history ? " \(versions)" : "")
        }
        return lines
    }

    func testMergingTheTwoCopiesGivesWhatKeePassXCGave() throws {
        let a = try fixture("mac-a"), b = try fixture("mac-b"), keepassxc = try fixture("merged-by-keepassxc")
        let outcome = try VaultMerge.merge(b, into: a)
        let mine = items(outcome.vault), theirs = items(keepassxc)

        // Deleted for good on A. `keepassxc-cli merge` does not apply deletions, so it is back in KeePassXC's file.
        XCTAssertNotNil(theirs["Old account"])
        XCTAssertNil(mine["Old account"])
        XCTAssertEqual(Set(mine.keys), Set(theirs.keys).subtracting(["Old account"]))
        // Deploy holds two versions with one time, of which KeePassXC keeps one (it says so while merging).
        for title in mine.keys where title != "Deploy" {
            XCTAssertEqual(mine[title], theirs[title], title)
        }
        XCTAssertEqual(items(outcome.vault, history: false)["Deploy"], items(keepassxc, history: false)["Deploy"])

        XCTAssertEqual(outcome.vault.entries.first { $0.title == "Bank" }?.password, "bank-b")
        XCTAssertEqual(outcome.vault.entries.first { $0.title == "Mail" }?.groupPath, ["Work"])
        let deploy = try XCTUnwrap(outcome.vault.entries.first { $0.title == "Deploy" })
        XCTAssertEqual(outcome.vault.attachment(named: "deploy.pem", of: deploy.id), Data("second key, changed on B\n".utf8))
        let key = try XCTUnwrap(outcome.vault.entries.first { $0.title == "Key from B" })
        XCTAssertEqual(outcome.vault.attachment(named: "b.json", of: key.id), Data("{\"b\":true}\n".utf8))
        XCTAssertEqual(outcome.report.changedOnBoth.map(\.title), ["Bank"])
        XCTAssertEqual(outcome.report.added, 1)
    }

    func testTheOtherWayRoundGivesTheSameDatabase() throws {
        let a = try fixture("mac-a"), b = try fixture("mac-b")
        let one = try VaultMerge.merge(b, into: a), two = try VaultMerge.merge(a, into: b)
        XCTAssertEqual(items(one.vault), items(two.vault))
        XCTAssertFalse(try VaultMerge.merge(b, into: one.vault).report.changed)
        XCTAssertFalse(try VaultMerge.merge(two.vault, into: one.vault).report.changed)
    }

    /// What KeePassXC wrote and PasswordPie did not touch is still there after the merge was saved and read again.
    func testWhatKeePassXCWroteIsKeptThroughAMergeAndASave() throws {
        let a = try fixture("mac-a"), b = try fixture("mac-b")
        func untouched(_ vault: Vault) throws -> [String] {
            let file = try XCTUnwrap(vault.preserve?.document.rootElement())
            let meta = try XCTUnwrap(direct(file, "Meta").first)
            var parts = ["MemoryProtection", "Generator", "DatabaseName", "HistoryMaxItems", "HistoryMaxSize", "RecycleBinUUID", "MasterKeyChanged", "SettingsChanged"]
                .compactMap { direct(meta, $0).first?.xmlString }
            walkElements(file) { element in
                guard element.name == "Entry", element.parent?.name == "Group",
                      ["Example any", "Key from A"].contains(direct(element, "String").first { direct($0, "Key").first?.stringValue == "Title" }
                        .flatMap { direct($0, "Value").first }?.stringValue ?? "") else { return }
                parts.append(element.xmlString)
            }
            return parts
        }
        let before = try untouched(a)
        XCTAssertGreaterThan(before.count, 6)
        var merged = try VaultMerge.merge(b, into: a).vault
        let key = try Data(contentsOf: Self.keyFileURL)
        let reloaded = try KDBX.load(data: try KDBX.save(vault: &merged, password: "pie-test", keyFile: key), password: "pie-test", keyFile: key)
        XCTAssertEqual(try untouched(reloaded), before)
    }

    /// With KeePassXC installed (`brew install --cask keepassxc`): it opens what PasswordPie merged and saved, reads the
    /// merged values and attachments, and has nothing of the other copy left to merge in.
    func testKeePassXCReadsTheMergedDatabase() throws {
        let tool = "/opt/homebrew/bin/keepassxc-cli"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("keepassxc-cli is not installed") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keepassxc-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try Data(contentsOf: Self.keyFileURL)
        var merged = try VaultMerge.merge(try fixture("mac-b"), into: try fixture("mac-a")).vault
        let file = directory.appendingPathComponent("merged.kdbx")
        try KDBX.save(vault: &merged, password: "pie-test", keyFile: key).write(to: file)
        let other = directory.appendingPathComponent("mac-b.kdbx")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("Merge/mac-b.kdbx"), to: other)

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            input.fileHandleForWriting.write(Data("pie-test\n".utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let unlock = ["-q", "-k", Self.keyFileURL.path]
        let listing = try run(["ls"] + unlock + ["-R", "-f", file.path])
        XCTAssertEqual(listing.status, 0, listing.output)
        for title in ["Example any", "Key from A", "Key from B", "Bank", "Work/Deploy", "Work/Mail"] {
            XCTAssertTrue(listing.output.contains(title), "\(title) is missing from: \(listing.output)")
        }
        XCTAssertFalse(listing.output.contains("Old account"))
        let bank = try run(["show"] + unlock + ["-s", "-a", "Password", file.path, "Bank"])
        XCTAssertEqual(bank.output.trimmingCharacters(in: .whitespacesAndNewlines), "bank-b")
        let attachment = try run(["attachment-export"] + unlock + ["--stdout", file.path, "Work/Deploy", "deploy.pem"])
        XCTAssertEqual(attachment.output, "second key, changed on B\n")
        // KeePassXC's own merge of the other copy into ours finds only what it re-creates by not applying deletions.
        let again = try run(["merge", "-q", "-s", "-d", "-k", Self.keyFileURL.path, file.path, other.path])
        XCTAssertEqual(again.status, 0, again.output)
        let changes = again.output.split(separator: "\n").filter { !$0.contains("Old account") && !$0.contains("Database was not modified") && !$0.contains("conflicting changes") }
        XCTAssertEqual(changes, [], again.output)
    }
}
