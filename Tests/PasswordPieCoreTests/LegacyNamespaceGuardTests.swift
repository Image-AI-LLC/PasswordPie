import Foundation
import XCTest

/// PasswordPie moved from its old namespace (`AppNamespace.legacyID`) to `com.passwordpie` on 2026-11-13. The old name may stay only
/// where an upgrade or an older browser extension still needs it. Every such place is listed here with its line count and
/// why; anything else that names the old namespace fails this test.
final class LegacyNamespaceGuardTests: XCTestCase {
    /// Split so this file never matches itself.
    private static let needle = "com." + "oldcai"

    /// Path → (lines that name the old namespace, why they stay).
    private static let allowed: [String: (lines: Int, why: String)] = [
        "Sources/PasswordPieCore/AppNamespace.swift": (1, "`legacyID`: the defaults domain and keychain services an upgrade from the direct build v0.1.0 reads once"),
        "Sources/PasswordPieBridge/BridgeTransport.swift": (1, "`legacyNativeHostName`: the Chrome Web Store extension ≤ 0.4.0 connects to it; remove once the store's live version is ≥ 0.5.0"),
        "Tests/PasswordPieCoreTests/LegacyMigrationTests.swift": (16, "pins the old names the upgrade reads (AppNamespace, LegacyMigration)"),
        "Tests/PasswordPieAppTests/BrowserFillPlanTests.swift": (2, "pins the legacy native messaging host name the store extension ≤ 0.4.0 uses, and that its manifest is written"),
        "docs/BROWSER_EXTENSION.md": (2, "documents the legacy host manifest and when it can go"),
        "docs/CHANNELS.md": (1, "documents what an upgrade from v0.1.0 carries over")
    ]

    /// Folders whose contents are records of the past, not the product.
    private static let excludedPrefixes: [String: String] = [
        ".agent/": "dated requirement and design records; they describe the names in use when they were written"
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Tracked files, plus new ones git does not ignore, so a file is caught before it is committed.
    private static func files() throws -> [String] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { throw XCTSkip("git ls-files failed (\(git.terminationStatus))") }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    func testTheOldNamespaceStaysOnlyWhereItIsNeeded() throws {
        var found: [String: Int] = [:]
        for path in try Self.files() where !Self.excludedPrefixes.keys.contains(where: { path.hasPrefix($0) }) {
            guard let data = try? Data(contentsOf: Self.root.appendingPathComponent(path)), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains(Self.needle) }.count
            if lines > 0 { found[path] = lines }
        }
        for (path, lines) in found.sorted(by: { $0.key < $1.key }) {
            guard let entry = Self.allowed[path] else {
                XCTFail("\(path) names the old namespace on \(lines) line(s). Use com.passwordpie, or add it to the allow-list with a reason.")
                continue
            }
            XCTAssertEqual(lines, entry.lines, "\(path): \(entry.why)")
        }
        for path in Self.allowed.keys where found[path] == nil {
            XCTFail("\(path) is allowed but no longer names the old namespace; remove it from the allow-list.")
        }
    }
}
