import AppKit
import PasswordPieBridge
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Reset Password in the app: the new password that waits with the account, the page that opens, and the answer to
/// "Did the site accept it?" (docs/UX.md, "Reset Password makes the new password for you"). No browser is opened.
@MainActor
final class PasswordResetSessionTests: XCTestCase {
    private var directory: URL!
    /// The bridge holds its session unowned.
    private var session: VaultSession!
    private var pages: [URL] = []
    private var opened: [(url: URL, app: URL?)] = []
    private let chrome = FrontApp(bundleID: BrowserBridge.chromeBundleID, bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    private let resetLink = "https://example.com/account/password"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        pages = []
        opened = []
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// An unlocked database with one account that has a reminder and a reset link. Pages it would open are recorded.
    private func payroll(resetLink link: String? = nil) throws -> UUID {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.openWebPage = { [weak self] in self?.pages.append($0) }
        var entry = VaultEntry()
        entry.title = "Payroll"
        entry.url = "https://example.com"
        entry.username = "ada"
        entry.password = "first"
        PasswordRotation.setPeriod(30, on: &entry)
        PasswordRotation.setResetLink(link ?? resetLink, on: &entry)
        session.saveEditing(entry)
        self.session = session
        return try XCTUnwrap(session.entries.first { $0.title == "Payroll" }).id
    }

    private func stored(_ id: UUID) throws -> VaultEntry {
        try XCTUnwrap(session.storedEntry(id))
    }

    private func onDisk() throws -> VaultEntry {
        let vault = try KDBX.load(data: Data(contentsOf: directory.appendingPathComponent("test.kdbx")), password: "pw")
        return try XCTUnwrap(vault.entries.first { $0.title == "Payroll" })
    }

    #if PP_DIRECT
    func testResetPasswordKeepsANewPasswordInTheFileAndLeavesTheSavedOne() throws {
        let id = try payroll()

        XCTAssertEqual(session.resetPassword(id), .ready)

        let entry = try stored(id)
        XCTAssertEqual(entry.password, "first")
        let candidate = try XCTUnwrap(PreviousPasswords.candidate(of: entry, now: Date()))
        XCTAssertEqual(candidate.value.count, CharacterRecipe().length)
        XCTAssertNotEqual(candidate.value, "first")
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: Date()).count, 1)
        XCTAssertEqual(previousPasswordCaption(candidate), "new · not used yet")

        let file = try onDisk()
        XCTAssertEqual(file.password, "first")
        XCTAssertEqual(PreviousPasswords.candidate(of: file, now: Date())?.value, candidate.value)
        XCTAssertEqual(file.fields.first { $0.key == PreviousPasswords.key }?.protected, true)
        XCTAssertEqual(pages.map(\.absoluteString), [resetLink], "without the extension the page only opens")
    }

    func testASecondResetPasswordReusesTheWaitingPassword() throws {
        let id = try payroll()
        session.resetPassword(id)
        let first = try XCTUnwrap(PreviousPasswords.candidate(of: try stored(id), now: Date()))

        XCTAssertEqual(session.resetPassword(id), .ready)

        let entry = try stored(id)
        XCTAssertEqual(PreviousPasswords.candidate(of: entry, now: Date()), first)
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: Date()).count, 1)
        XCTAssertEqual(pages.count, 2)
    }

    func testUsingTheNewPasswordMakesItTheSavedOneAndRestartsTheClock() throws {
        let id = try payroll()
        // As if the password had been set 40 days ago: the reminder is due.
        session.edit(id)
        var aged = try XCTUnwrap(session.editing)
        let old = Int(Date().addingTimeInterval(-40 * 86_400).timeIntervalSince1970)
        let digest = aged.value(for: PasswordRotation.changedKey).split(separator: " ")[1]
        aged.setValue("\(old) \(digest)", for: PasswordRotation.changedKey)
        session.saveEditing(aged)
        XCTAssertTrue(PasswordRotation.isDue(try stored(id), now: Date()))

        session.resetPassword(id)
        let candidate = try XCTUnwrap(PreviousPasswords.candidate(of: try stored(id), now: Date()))
        XCTAssertTrue(PasswordRotation.isDue(try stored(id), now: Date()), "a waiting password changes nothing yet")

        XCTAssertTrue(session.usePasswordCandidate(of: id))

        let entry = try stored(id)
        XCTAssertEqual(entry.password, candidate.value)
        XCTAssertNil(PreviousPasswords.candidate(of: entry, now: Date()))
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: Date()).map(\.value), ["first"])
        let changed = try XCTUnwrap(PasswordRotation.changed(of: entry))
        XCTAssertLessThan(abs(changed.timeIntervalSinceNow), 5)
        XCTAssertFalse(PasswordRotation.isDue(entry, now: Date()))
        let file = try onDisk()
        XCTAssertEqual(file.password, candidate.value)
        XCTAssertNotNil(PasswordRotation.changed(of: file))

        XCTAssertFalse(session.usePasswordCandidate(of: id), "nothing is waiting any more")
        XCTAssertEqual(try stored(id).password, candidate.value)
    }

    func testAFileThatChangedOnDiskRefusesTheNewPasswordAndSaysSo() throws {
        let id = try payroll()
        // Another app wrote the file: the write is refused rather than overwrite it.
        let url = directory.appendingPathComponent("test.kdbx")
        var vault = try KDBX.load(data: Data(contentsOf: url), password: "pw")
        vault.entries[0].notes = "edited elsewhere"
        try KDBX.save(vault: &vault, password: "pw").write(to: url)

        XCTAssertEqual(session.resetPassword(id), .notSaved)

        XCTAssertNil(PreviousPasswords.candidate(of: try stored(id), now: Date()))
        XCTAssertEqual(pages.map(\.absoluteString), [resetLink], "the page still opens, as it always did")
    }

    // MARK: Through the Chrome extension

    private func bridge(for id: UUID) -> BrowserBridge {
        let bridge = BrowserBridge(session: session)
        bridge.pushToChrome = { _, _ in }
        bridge.openInBrowser = { [weak self] url, app in self?.opened.append((url, app)) }
        bridge.defaultBrowser = { _ in nil }
        session.browserReset = { [chrome] entry, address, newPassword in
            bridge.openReset(entry, address: address, newPassword: newPassword, front: chrome)
        }
        bridge.connectionsChanged([BridgePeer(.chrome, link: 1)])
        return bridge
    }

    @discardableResult
    private func send(_ bridge: BrowserBridge, _ object: [String: Any]) throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: object)
        let answer = try XCTUnwrap(bridge.answer(frame, from: .chrome, link: 1))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    func testThePageFillsTheNewPasswordAndItsReportAsksThePerson() async throws {
        let id = try payroll()
        let bridge = bridge(for: id)
        try send(bridge, ["type": "tab", "id": 1, "url": "https://news.example.org/", "focused": true])
        var asked: [(UUID, String)] = []
        bridge.onPasswordChanged = { asked.append(($0, $1)) }

        XCTAssertEqual(session.resetPassword(id), .ready)

        let candidate = try XCTUnwrap(PreviousPasswords.candidate(of: try stored(id), now: Date()))
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(opened.map(\.url.absoluteString), [resetLink])
        XCTAssertEqual(opened.first?.app, chrome.bundleURL)

        let fill = try XCTUnwrap(try send(bridge, ["type": "tab", "id": 2, "url": "https://example.com/", "focused": true])["fill"] as? [String: Any])
        XCTAssertEqual(fill["password"] as? String, "first")
        XCTAssertEqual(fill["newPassword"] as? String, candidate.value)
        XCTAssertEqual(try stored(id).password, "first", "filling the page changes nothing")

        let answer = try send(bridge, ["type": "changed", "id": 3, "url": "https://example.com/"])
        XCTAssertEqual(answer["type"] as? String, "changed")
        XCTAssertEqual(answer["id"] as? Int, 3)
        XCTAssertEqual(answer["version"] as? Int, 1)
        for _ in 0..<200 where asked.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(asked.map(\.0), [id])
        XCTAssertEqual(asked.map(\.1), ["example.com"])

        // The question: Not Yet changes nothing, Use New Password saves it.
        let model = PasswordChangeModel(session: session)
        var presented = 0
        var dismissed = 0
        model.present = { presented += 1 }
        model.dismiss = { dismissed += 1 }
        model.receive(id, host: "example.com")
        XCTAssertEqual(model.question, PasswordChangeModel.Question(entryID: id, title: "Payroll", host: "example.com"))
        XCTAssertEqual(presented, 1)
        model.cancel()
        XCTAssertNil(model.question)
        XCTAssertEqual(try stored(id).password, "first")
        XCTAssertNotNil(PreviousPasswords.candidate(of: try stored(id), now: Date()))

        model.receive(id, host: "example.com")
        model.useNewPassword()
        XCTAssertEqual(try stored(id).password, candidate.value)
        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(model.question)

        // Once: a second report finds nothing waiting, and nothing to ask about either.
        asked = []
        try send(bridge, ["type": "changed", "id": 4, "url": "https://example.com/"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(asked.isEmpty)
        model.receive(id, host: "example.com")
        XCTAssertNil(model.question)
        XCTAssertEqual(presented, 2)
    }

    func testAResetLinkOnAnotherSiteOnlyOpensThePage() throws {
        let id = try payroll(resetLink: "https://accounts.example.net/reset")
        let bridge = bridge(for: id)
        try send(bridge, ["type": "tab", "id": 1, "url": "https://news.example.org/", "focused": true])

        XCTAssertEqual(session.resetPassword(id), .ready)

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(pages.map(\.absoluteString), ["https://accounts.example.net/reset"])
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 2, "url": "https://accounts.example.net/", "focused": true])["fill"])
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 3, "url": "https://example.com/", "focused": true])["fill"])
    }

    func testWithoutAnExtensionForTheProfileInFrontThePageOnlyOpens() throws {
        let id = try payroll()
        let bridge = bridge(for: id)
        // The window in front belongs to a profile without the extension.
        try send(bridge, ["type": "tab", "id": 1, "url": "https://example.com/", "focused": false])

        XCTAssertEqual(session.resetPassword(id), .ready)

        XCTAssertTrue(opened.isEmpty, "nothing is handed to the bridge, and nothing is typed")
        XCTAssertEqual(pages.map(\.absoluteString), [resetLink])
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 2, "url": "https://example.com/", "focused": false])["fill"])
    }

    func testSafariOnlyOpensThePage() throws {
        let id = try payroll()
        let bridge = bridge(for: id)
        let safari = FrontApp(bundleID: BrowserBridge.safariBundleID, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        let entry = try stored(id)
        XCTAssertFalse(bridge.openReset(entry, address: resetLink, newPassword: "brand-new", front: safari))
        XCTAssertTrue(opened.isEmpty)
    }

    func testALockedVaultDropsTheQuestion() throws {
        let id = try payroll()
        session.resetPassword(id)
        let model = PasswordChangeModel(session: session)
        var presented = 0
        model.present = { presented += 1 }
        session.lock()
        model.receive(id, host: "example.com")
        XCTAssertNil(model.question)
        XCTAssertEqual(presented, 0)
    }
    #else
    /// The App Store app has no previous passwords: Reset Password opens the page and writes nothing.
    func testResetPasswordOnlyOpensThePage() throws {
        let id = try payroll()
        XCTAssertEqual(session.resetPassword(id), .opened)
        XCTAssertEqual(pages.map(\.absoluteString), [resetLink])
        XCTAssertFalse(try stored(id).fields.contains { $0.key == PreviousPasswords.key })
        XCTAssertEqual(try onDisk().password, "first")
    }
    #endif

    func testWithoutAResetLinkTheWebsiteOpens() throws {
        let id = try payroll(resetLink: " ")
        session.resetPassword(id)
        XCTAssertEqual(pages.map(\.absoluteString), ["https://example.com"])
    }
}
