import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class PremiumGateTests: XCTestCase {
    private var directory: URL!
    private var backend: FakePremiumBackend!
    private var pasteboard: FakePasteboard!
    private var paywalls = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("premium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        backend = FakePremiumBackend()
        pasteboard = FakePasteboard()
        paywalls = 0
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(premium: Bool, entries: [VaultEntry] = [PremiumFixtures.login()]) async -> VaultSession {
        backend.transactions = premium ? [PremiumFixtures.lifetime] : []
        let store = PremiumStore(backend: backend)
        await store.refresh()
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
        let session = VaultSession(premium: store, pasteboard: pasteboard)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for entry in entries { session.saveEditing(entry) }
        return session
    }

    private func onlyID(_ session: VaultSession) throws -> UUID {
        try XCTUnwrap(session.entries.first { !$0.trashed }?.id)
    }

    // MARK: Copy

    func testAFreeCopyOpensThePlansAndLeavesTheClipboardAlone() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        session.copy(.oneTimePassword, of: id)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(paywalls, 1)
    }

    func testAFreeCopyIsNotCountedAsUsingTheAccount() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        session.copy(.oneTimePassword, of: id)
        XCTAssertNil(session.lastUsedMap[id])
    }

    func testAPremiumCopyWritesTheCode() async throws {
        let session = await session(premium: true)
        session.copy(.oneTimePassword, of: try onlyID(session))
        XCTAssertEqual(pasteboard.writes.count, 1)
        XCTAssertEqual(pasteboard.writes[0].count, 6)
        XCTAssertNotNil(Int(pasteboard.writes[0]))
        XCTAssertEqual(paywalls, 0)
    }

    func testTheValueOfALockedCodeIsEmpty() async throws {
        let session = await session(premium: false)
        let entry = try XCTUnwrap(session.entry(try onlyID(session)))
        XCTAssertEqual(session.value(of: .oneTimePassword, in: entry), "")
    }

    func testEverythingElseStillCopiesForAFreeUser() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        session.copy(.url, of: id)
        XCTAssertEqual(pasteboard.writes, ["ada", "secret", "https://bank.example/login"])
        XCTAssertEqual(paywalls, 0)
    }

    // MARK: Shortcuts: ⌥⌘C in Quick Access and with a pinned window share this

    func testTheCodeShortcutOpensThePlansForAFreeUser() async throws {
        let session = await session(premium: false)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: try onlyID(session)), .premiumRequired)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(paywalls, 1)
    }

    func testTheCodeShortcutCopiesForPremium() async throws {
        let session = await session(premium: true)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: try onlyID(session)), .copied)
        XCTAssertEqual(pasteboard.writes.count, 1)
    }

    func testAShortcutOnAnItemWithNoCodeIsNotAnUpsell() async throws {
        let session = await session(premium: false, entries: [PremiumFixtures.login(code: false)])
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: try onlyID(session)), .nothingToCopy)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(paywalls, 0)
    }

    func testOtherShortcutsAreNotGated() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        XCTAssertEqual(session.runCopyShortcut(.copyPrimary, of: id), .copied)
        XCTAssertEqual(session.runCopyShortcut(.copyPassword, of: id), .copied)
        XCTAssertEqual(pasteboard.writes, ["ada", "secret"])
        XCTAssertEqual(paywalls, 0)
    }

    func testTheShortcutInTheOpenMenuOpensThePlansAndClosesTheMenu() async throws {
        let session = await session(premium: false)
        let panel = PanelController(session: session)
        session.hidePanel = { panel.hide() }
        panel.show(.hotkey)
        let id = try onlyID(session)
        panel.header.searchField.stringValue = "Bank"
        panel.headerSearchChanged("Bank")
        let selected = await waitUntil { panel.menu.currentEntryID == id }
        XCTAssertTrue(selected)
        XCTAssertTrue(panel.headerShortcut(.copyOneTimePassword))
        XCTAssertEqual(paywalls, 1)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertFalse(panel.isVisible)
        panel.hide()
    }

    /// The updates stream does not always fire for a refund, and a menu-bar app rarely comes forward.
    func testOpeningTheMenuAsksTheStoreAgain() async throws {
        let session = await session(premium: true)
        XCTAssertTrue(session.premium.hasPremium)
        backend.transactions = []
        let panel = PanelController(session: session)
        panel.show(.hotkey)
        let locked = await waitUntil { !session.premium.hasPremium }
        XCTAssertTrue(locked)
        panel.hide()
    }

    func testAShortcutDuringTheFirstCheckCopiesOnceAPremiumAnswerArrives() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        backend.transactions = [PremiumFixtures.lifetime]
        backend.holdsAnswers = true
        let store = PremiumStore(backend: backend)
        store.presentPaywall = { [unowned self] in self.paywalls += 1 }
        let check = Task { await store.refresh() }
        let held = await waitUntil { self.backend.answerGate != nil }
        XCTAssertTrue(held)
        let waiting = VaultSession(premium: store, pasteboard: pasteboard)
        waiting.entries = session.entries
        XCTAssertEqual(waiting.runCopyShortcut(.copyOneTimePassword, of: id), .premiumRequired)
        XCTAssertEqual(pasteboard.writes, [])
        backend.answer()
        await check.value
        XCTAssertEqual(pasteboard.writes.count, 1)
        XCTAssertEqual(paywalls, 0)
    }

    // MARK: Fill

    func testFillNeverTypesACode() {
        XCTAssertEqual(fillKeystrokes(for: PremiumFixtures.login()), [.text("ada"), .tab, .text("secret")])
        var password = VaultEntry()
        password.password = "secret"
        password.otp = PremiumFixtures.login().otp
        XCTAssertEqual(password.category, .password)
        XCTAssertEqual(fillKeystrokes(for: password), [.text("secret")])
    }

    // MARK: Details

    private func model(_ session: VaultSession, presentation: DetailsPresentation = .popover, done: @escaping () -> Void = {}) throws -> DetailsModel {
        let entry = try XCTUnwrap(session.entry(try onlyID(session)))
        return DetailsModel(entry: entry, session: session, presentation: presentation, done: done)
    }

    func testTheRowStillSaysTheItemHasACode() async throws {
        let session = await session(premium: false)
        XCTAssertTrue(try model(session).fields.contains { $0.kind == .oneTimePassword })
    }

    func testAnItemWithNoCodeHasNoRow() async throws {
        let session = await session(premium: false, entries: [PremiumFixtures.login(code: false)])
        XCTAssertFalse(try model(session).fields.contains { $0.kind == .oneTimePassword })
    }

    func testALockedRowOffersUpgradeAndNothingElse() {
        let field = DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)
        XCTAssertEqual(fieldControl(field, revealed: false, codeLocked: true), FieldControl(primary: .upgrade, menu: []))
        XCTAssertEqual(fieldControl(field, revealed: false, codeLocked: false), FieldControl(primary: .copy, menu: []))
        XCTAssertEqual(FieldAction.upgrade.title, "Upgrade")
    }

    func testBeingLockedOnlyChangesTheCodeRow() {
        let password = DetailField(id: "password", kind: .password, label: "password", value: "x", secret: true)
        XCTAssertEqual(fieldControl(password, revealed: false, codeLocked: true), fieldControl(password, revealed: false, codeLocked: false))
    }

    func testUpgradeOpensThePlansAndClosesThePopoverButNotAPinnedWindow() async throws {
        let session = await session(premium: false)
        let field = DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)
        var closed = 0
        try model(session) { closed += 1 }.perform(.upgrade, on: field)
        XCTAssertEqual(paywalls, 1)
        XCTAssertEqual(closed, 1)
        try model(session, presentation: .pinned) { closed += 1 }.perform(.upgrade, on: field)
        XCTAssertEqual(paywalls, 2)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(pasteboard.writes, [])
    }

    func testAStaleCopyButtonOnALockedRowStillCopiesNothing() async throws {
        let session = await session(premium: false)
        let field = DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)
        try model(session).perform(.copy, on: field)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(paywalls, 1)
    }

    func testReturnOnALockedRowOpensThePlans() async throws {
        let session = await session(premium: false)
        let model = try model(session)
        model.focused = try XCTUnwrap(model.fields.firstIndex { $0.kind == .oneTimePassword })
        model.activateFocused()
        let opened = await waitUntil(timeout: 2) { self.paywalls == 1 }
        XCTAssertTrue(opened)
        XCTAssertEqual(pasteboard.writes, [])
    }

    func testPremiumArrivingUnlocksAnOpenRowAndTheShortcut() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        let model = try model(session, presentation: .pinned)
        XCTAssertTrue(model.codeIsLocked)
        session.premium.start()
        let checked = await waitUntil { session.premium.status == .free }
        XCTAssertTrue(checked)
        backend.transactions = [PremiumFixtures.lifetime]
        backend.emitUpdate()
        let unlocked = await waitUntil { !model.codeIsLocked }
        XCTAssertTrue(unlocked)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: id), .copied)
        session.premium.stop()
    }

    // MARK: Stored data

    private func reopen(_ session: VaultSession) throws -> [VaultEntry] {
        let path = session.databaseURL
        return try VaultFile.openRecovering(url: path, password: "pw").entries
    }

    func testSavingAsAFreeUserKeepsTheSecretExactly() async throws {
        let session = await session(premium: false)
        let original = PremiumFixtures.login().otp
        var entry = try XCTUnwrap(session.entries.first { !$0.trashed })
        entry.notes = "changed by a free user"
        session.saveEditing(entry)
        let saved = try XCTUnwrap(try reopen(session).first { $0.title == "Bank" })
        XCTAssertEqual(saved.notes, "changed by a free user")
        XCTAssertEqual(saved.otp, original)
        XCTAssertEqual(saved.fields.first { $0.key == "otp" }?.protected, true)
    }

    func testAFreeUserCanEditTheSecret() async throws {
        let session = await session(premium: false)
        var entry = try XCTUnwrap(session.entries.first { !$0.trashed })
        entry.otp = "otpauth://totp/Bank:ada?secret=JBSWY3DPEHPK3PXP&issuer=Bank"
        session.saveEditing(entry)
        XCTAssertEqual(try XCTUnwrap(try reopen(session).first { $0.title == "Bank" }).otp, entry.otp)
        XCTAssertEqual(paywalls, 0)
    }

    func testAFreeUserKeepsCodesThatComeWithAnImport() async throws {
        let session = await session(premium: false, entries: [])
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Imported,https://imported.example,ann,pw1,,otpauth://totp/Imported:ann?secret=JBSWY3DPEHPK3PXP
        """
        let imported = try BrowserImport.entries(fromCSV: Data(csv.utf8), source: .applePasswords)
        XCTAssertNotNil(session.mergeImported(imported, source: .applePasswords))
        let saved = try XCTUnwrap(try reopen(session).first { $0.title == "Imported" })
        XCTAssertEqual(saved.otp, "otpauth://totp/Imported:ann?secret=JBSWY3DPEHPK3PXP")
    }

    // MARK: Nothing gets around the gate

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp")
    }

    private func appFiles() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoCallerReachesTOTPWithoutTheGate() throws {
        let direct = try NSRegularExpression(pattern: #"TOTP\.(code|parse|parseOTPAuth)\b"#)
        for file in try appFiles() {
            let range = NSRange(file.text.startIndex..., in: file.text)
            XCTAssertNil(direct.firstMatch(in: file.text, range: range), "\(file.name) goes around OneTimeCodes")
        }
    }

    func testCodesAreMadeInOnlyTwoPlaces() throws {
        let makers = try appFiles().filter { $0.text.contains("OneTimeCodes.code(") }.map(\.name).sorted()
        XCTAssertEqual(makers, ["DetailsView.swift", "VaultSession.swift"])
    }

    func testOnlyOneFileImportsStoreKitAndItIsNotInTheDirectChannel() throws {
        let importers = try appFiles().filter { $0.text.contains("import StoreKit") }
        XCTAssertEqual(importers.map(\.name), ["StoreKitPremiumBackend.swift"])
        let text = try XCTUnwrap(importers.first?.text)
        XCTAssertTrue(text.hasPrefix("#if !PP_DIRECT"), "the direct binary must not link StoreKit")
    }

    func testTheUICarriesNoPricesAndNoWayToBuyElsewhere() throws {
        let price = try NSRegularExpression(pattern: #"(\$\d{2,}|\$\d+\.\d|US\$|€\s?\d|£\s?\d|¥\s?\d|\b(USD|EUR)\b)"#)
        let outside = try NSRegularExpression(pattern: #"(?i)(stripe\.com|paddle\.com|gumroad|lemonsqueezy|license key|buy (it )?(on|from) (our|the) (web|site)|passwordpie\.com/(buy|pricing|download))"#)
        // PremiumPreview.swift draws made-up prices in debug builds only, and its first line says so.
        for file in try appFiles() where file.name != "PremiumPreview.swift" {
            let range = NSRange(file.text.startIndex..., in: file.text)
            XCTAssertNil(price.firstMatch(in: file.text, range: range), "\(file.name) hard-codes a price")
            XCTAssertNil(outside.firstMatch(in: file.text, range: range), "\(file.name) mentions buying elsewhere")
        }
    }

    func testThePreviewBackendIsOnlyInDebugStoreBuilds() throws {
        let files = try appFiles()
        let preview = try XCTUnwrap(files.first { $0.name == "PremiumPreview.swift" })
        XCTAssertTrue(preview.text.hasPrefix("#if DEBUG && !PP_DIRECT"))
        XCTAssertEqual(files.filter { $0.text.contains("PASSWORDPIE_PREMIUM_PREVIEW") }.map(\.name), ["PremiumPreview.swift"])
    }

    func testTheStoreChannelStoresNothingThatCouldGrantPremium() throws {
        let store = try appFiles().filter { $0.name.hasPrefix("Premium") || $0.name.hasPrefix("StoreKit") }
        for file in store where file.name != "PremiumPreview.swift" {
            XCTAssertFalse(file.text.contains("UserDefaults"), "\(file.name) keeps a local flag")
            XCTAssertFalse(file.text.contains("SecItem"), "\(file.name) keeps a local flag")
            XCTAssertFalse(file.text.contains("ProcessInfo"), "\(file.name) reads a local override")
        }
    }

    #if DEBUG
    func testPaywallPreviewsLeaveTheGlobalHotkeyAlone() {
        XCTAssertTrue(AppDelegate.suppressesPreviewHotkey(["PASSWORDPIE_PAYWALL": "1"]))
    }
    #endif
}
