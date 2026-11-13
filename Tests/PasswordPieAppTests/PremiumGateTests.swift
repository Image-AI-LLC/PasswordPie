import AppKit
import SwiftUI
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class PremiumGateTests: XCTestCase {
    private var directory: URL!
    private var backend: FakePremiumBackend!
    private var pasteboard: FakePasteboard!
    private var paywalls = 0
    private var secrets: FakeSecrets!
    private var clock = PremiumFixtures.now

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("premium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        backend = FakePremiumBackend()
        pasteboard = FakePasteboard()
        paywalls = 0
        secrets = FakeSecrets()
        clock = PremiumFixtures.now
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(premium: Bool, entries: [VaultEntry] = [PremiumFixtures.login()]) async -> VaultSession {
        #if PP_DIRECT
        secrets.values[.activation] = premium ? ActivationLink.token(in: PassKey.activationLink(expires: PremiumFixtures.now.addingTimeInterval(7 * 86400))) : nil
        let store = PremiumStore.testing(secrets: secrets, now: { [unowned self] in self.clock })
        store.start()
        #else
        backend.transactions = premium ? [PremiumFixtures.lifetime] : []
        let store = PremiumStore(backend: backend, secrets: secrets, verify: PassKey.verifyActivation, now: { [unowned self] in self.clock })
        #endif
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

    /// Premium arrives from wherever this channel gets it.
    private func grantPremium(_ session: VaultSession) async {
        #if PP_DIRECT
        session.premium.activate(PassKey.activationLink(expires: PremiumFixtures.now.addingTimeInterval(7 * 86400)))
        #else
        backend.transactions = [PremiumFixtures.lifetime]
        await session.premium.refresh(force: true)
        #endif
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

    #if PP_DIRECT
    /// Opening the menu looks again, so an activation that ran out while the Mac slept stops counting at once.
    func testOpeningTheMenuLooksAgain() async throws {
        let session = await session(premium: true)
        XCTAssertTrue(session.premium.hasPremium)
        clock = PremiumFixtures.now.addingTimeInterval(8 * 86400)
        let panel = PanelController(session: session)
        panel.show(.hotkey)
        let lapsed = await waitUntil { session.premium.lapse != nil }
        XCTAssertTrue(lapsed)
        XCTAssertFalse(session.premium.hasPremium)
        XCTAssertNil(secrets.values[.activation])
        panel.hide()
    }

    /// The proofs are on this Mac, so a shortcut at launch never waits on anything.
    func testAShortcutRightAfterLaunchCopiesWithAnActivationInTheKeychain() async throws {
        let session = await session(premium: true)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: try onlyID(session)), .copied)
        XCTAssertEqual(paywalls, 0)
    }

    /// An activation link unlocks a code in the app, and the code locks again the moment it runs out.
    func testAnActivationUnlocksTheAppAndItsEndLocksIt() async throws {
        let session = await session(premium: false)
        let id = try onlyID(session)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: id), .premiumRequired)
        await grantPremium(session)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: id), .copied)
        clock = PremiumFixtures.now.addingTimeInterval(8 * 86400)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: id), .premiumRequired)
        XCTAssertEqual(paywalls, 2)
    }
    #endif

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
        XCTAssertEqual(FieldAction.upgrade.title, "Upgrade to unlock")
    }

    /// The code sits right under the password, so it is next to what it goes with. Up and down walk the same order.
    func testTheCodeRowComesRightAfterThePasswordBeforeTheWebsites() async throws {
        var entry = PremiumFixtures.login()
        entry.fields.append(VaultField(key: "URL (2)", value: "https://second.example"))
        entry.fields.append(VaultField(key: "account id", value: "4821"))
        entry.notes = "a note"
        let kinds = DetailsModel.detailFields(of: entry).map(\.kind)
        XCTAssertEqual(kinds, [.username, .password, .oneTimePassword, .url, .otherWebsite("URL (2)"), .custom("account id"), .notes])
        let session = await session(premium: false, entries: [entry])
        let model = try model(session)
        XCTAssertEqual(model.focusedRow, .field("password"))
        model.move(1)
        XCTAssertEqual(model.focusedRow, .field("otp"))
        model.move(1)
        XCTAssertEqual(model.focusedRow, .field("url"))
    }

    func testEveryLockedCodeOffersTheSameUpgradeTitle() throws {
        for file in try appFiles() {
            XCTAssertFalse(file.text.contains(#"SplitActionButton(title: "Upgrade""#), "\(file.name) words Upgrade on its own")
        }
    }

    /// The locked look carries nothing about the code: no countdown, no period, no settings, no code.
    func testTheLockedLookNeverAsksForACode() throws {
        let details = try XCTUnwrap(try appFiles().first { $0.name == "DetailsView.swift" }?.text)
        let start = try XCTUnwrap(details.range(of: "struct LockedOneTimeCode: View {"))
        let end = try XCTUnwrap(details.range(of: "\n}\n", range: start.upperBound..<details.endIndex))
        let locked = String(details[start.lowerBound..<end.upperBound])
        for word in ["OneTimeCodes", "CountdownPie", "TimelineView", "period", "settings"] {
            XCTAssertFalse(locked.contains(word), "the locked look reads \(word)")
        }
        XCTAssertEqual(locked.components(separatedBy: "Included with Premium").count, 2, "said once, to VoiceOver only")
        XCTAssertTrue(locked.contains("static let accessibilityText = \"Locked. Included with Premium.\""))
        XCTAssertTrue(details.contains("case .locked:\n            LockedOneTimeCode()"), "OneTimeCodeView draws the locked look for .locked")
    }

    /// The dots say nothing, so the row says in words that the code is locked and comes with Premium: one element with
    /// that label, its dots not read one by one, and the lock after the label hidden. SwiftUI builds no accessibility
    /// tree offscreen, so this reads the view's source; the PR's check reads the running app's tree.
    func testVoiceOverHearsThatTheCodeIsLockedAndIncludedWithPremium() throws {
        XCTAssertEqual(LockedOneTimeCode.accessibilityText, "Locked. Included with Premium.")
        let details = try XCTUnwrap(try appFiles().first { $0.name == "DetailsView.swift" }?.text)
        let start = try XCTUnwrap(details.range(of: "struct LockedOneTimeCode: View {"))
        let end = try XCTUnwrap(details.range(of: "\n}\n", range: start.upperBound..<details.endIndex))
        let locked = String(details[start.lowerBound..<end.upperBound])
        XCTAssertTrue(locked.contains(".accessibilityElement(children: .ignore)\n        .accessibilityLabel(Self.accessibilityText)"))
        let lockMark = try XCTUnwrap(details.range(of: "private var lockMark: AnyView {"))
        let lockEnd = try XCTUnwrap(details.range(of: "\n    }\n", range: lockMark.upperBound..<details.endIndex))
        XCTAssertTrue(details[lockMark.lowerBound..<lockEnd.upperBound].contains(".accessibilityHidden(true)"))
    }

    // MARK: The locked row as drawn

    private struct Drawn {
        var height: CGFloat
        var bitmap: NSBitmapImageRep
        var scale: CGFloat
    }

    /// The real details of an item with only a code, so the code's row is the only row under the header.
    private func drawDetails(premium: Bool, dark: Bool) async throws -> Drawn {
        var entry = VaultEntry()
        entry.title = "Bank"
        entry.otp = PremiumFixtures.login().otp
        let session = await session(premium: premium, entries: [entry])
        let model = try model(session)
        model.focusedRow = .previousHeader // no row has the keyboard, so the tint shows
        var fitted: CGFloat = 0
        let host = NSHostingView(rootView: DetailsView(model: model) { fitted = $0 })
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["PP_TEST_DUMP"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("details-\(premium ? "premium" : "free")-\(dark ? "dark" : "light").png"))
        }
        return Drawn(height: fitted, bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width)
    }

    private func pixel(_ drawn: Drawn, x: CGFloat, y: CGFloat) -> NSColor? {
        drawn.bitmap.colorAt(x: Int(x * drawn.scale), y: Int(y * drawn.scale))?.usingColorSpace(.sRGB)
    }

    /// Rows of the tint, read down the right edge where nothing else is drawn: top and bottom in points.
    private func tintedRows(_ drawn: Drawn) -> ClosedRange<CGFloat>? {
        var rows: [CGFloat] = []
        for py in 0..<drawn.bitmap.pixelsHigh {
            let y = CGFloat(py) / drawn.scale
            if let color = pixel(drawn, x: 396, y: y), color.alphaComponent > 0.4 { rows.append(y) }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...(last + 1 / drawn.scale)
    }

    /// Pixels in `rect` (points) that `matches`, as points.
    private func points(_ drawn: Drawn, in rect: CGRect, _ matches: (NSColor) -> Bool) -> [CGPoint] {
        var found: [CGPoint] = []
        for py in Int(rect.minY * drawn.scale)..<Int(rect.maxY * drawn.scale) {
            for px in Int(rect.minX * drawn.scale)..<Int(rect.maxX * drawn.scale) {
                guard let color = drawn.bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), matches(color) else { continue }
                found.append(CGPoint(x: (CGFloat(px) + 0.5) / drawn.scale, y: (CGFloat(py) + 0.5) / drawn.scale))
            }
        }
        return found
    }

    private func isOrange(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.6 && color.redComponent - color.blueComponent > 0.2
    }

    func testTheLockedRowIsAsTallAsTheUnlockedOne() async throws {
        for dark in [true, false] {
            let locked = try await drawDetails(premium: false, dark: dark)
            let unlocked = try await drawDetails(premium: true, dark: dark)
            XCTAssertGreaterThan(locked.height, 0)
            XCTAssertEqual(locked.height, unlocked.height, accuracy: 0.5, "the row does not jump when Premium arrives")
            let tint = try XCTUnwrap(tintedRows(locked), "the locked row is tinted across its width")
            XCTAssertEqual(tint.upperBound - tint.lowerBound, 45, accuracy: 1.5)
            XCTAssertNil(tintedRows(unlocked), "the unlocked row keeps its look")
        }
    }

    /// The owner's note: the dots sat too close to the label and too far from the bottom edge.
    func testTheDotsSitWhereTheMockupPutsThem() async throws {
        for dark in [true, false] {
            let drawn = try await drawDetails(premium: false, dark: dark)
            let row = try XCTUnwrap(tintedRows(drawn))
            let below = CGRect(x: 0, y: row.lowerBound + 19, width: 120, height: row.upperBound - row.lowerBound - 19)
            let dots = points(drawn, in: below, isOrange)
            XCTAssertFalse(dots.isEmpty)
            let xs = dots.map(\.x), ys = dots.map(\.y)
            let top = try XCTUnwrap(ys.min()), bottom = try XCTUnwrap(ys.max())
            XCTAssertEqual((top + bottom) / 2 - row.lowerBound, 29.5, accuracy: 0.5, "halfway between the label's baseline and the row's bottom")
            XCTAssertEqual(bottom - top, 7, accuracy: 1.5, "7 pt dots")
            // Columns with ink, grouped into dots.
            let columns = Set(xs.map { ($0 * drawn.scale).rounded(.down) }).sorted()
            var runs: [[CGFloat]] = []
            for column in columns {
                if let last = runs.last?.last, column - last <= 1 { runs[runs.count - 1].append(column) } else { runs.append([column]) }
            }
            let centres = runs.map { (($0.first! + $0.last! + 1) / 2) / drawn.scale }
            XCTAssertEqual(centres.count, 6, "six dots: \(centres)")
            guard centres.count == 6 else { continue }
            for (centre, expected) in zip(centres, [17.5, 29.2, 40.9, 64.3, 76.0, 87.7]) {
                XCTAssertEqual(centre, expected, accuracy: 1)
            }
        }
    }

    func testUpgradeToUnlockSitsAtTheRightCentredInTheRow() async throws {
        let drawn = try await drawDetails(premium: false, dark: true)
        let row = try XCTUnwrap(tintedRows(drawn))
        let button = points(drawn, in: CGRect(x: 200, y: row.lowerBound, width: 200, height: row.upperBound - row.lowerBound)) { color in
            abs(color.redComponent - 0xEE / 255.0) < 0.03 && abs(color.greenComponent - 0x8C / 255.0) < 0.03 && abs(color.blueComponent - 0x32 / 255.0) < 0.03
        }
        let right = try XCTUnwrap(button.map(\.x).max()), top = try XCTUnwrap(button.map(\.y).min()), bottom = try XCTUnwrap(button.map(\.y).max())
        XCTAssertEqual(400 - right, 10, accuracy: 1.5)
        XCTAssertEqual(bottom - top, 20, accuracy: 1.5)
        XCTAssertEqual((top + bottom) / 2, (row.lowerBound + row.upperBound) / 2, accuracy: 1)
    }

    func testALockFollowsTheLabel() async throws {
        let drawn = try await drawDetails(premium: false, dark: true)
        let row = try XCTUnwrap(tintedRows(drawn))
        let lock = points(drawn, in: CGRect(x: 80, y: row.lowerBound + 2, width: 60, height: 15), isOrange)
        XCTAssertFalse(lock.isEmpty, "an orange lock after \"one-time password\"")
        let height = (lock.map(\.y).max() ?? 0) - (lock.map(\.y).min() ?? 0)
        XCTAssertLessThanOrEqual(height, 10, "a small lock")
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
        await grantPremium(session)
        XCTAssertFalse(model.codeIsLocked)
        XCTAssertEqual(session.runCopyShortcut(.copyOneTimePassword, of: id), .copied)
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

    /// The downloaded app may send people to passwordpie.com to buy or redeem. The App Store app may not (3.1.1), so that
    /// lives only in files that are wholly direct-channel.
    func testOnlyDirectOnlyFilesSendPeopleToTheSiteToBuy() throws {
        let toSite = try NSRegularExpression(pattern: #"(\"pricing\"|\"redeem\"|Redeem a Key|Get Premium\")"#)
        let files = try appFiles().filter { file in
            toSite.firstMatch(in: file.text, range: NSRange(file.text.startIndex..., in: file.text)) != nil
        }
        XCTAssertEqual(files.map(\.name), ["PremiumDirectViews.swift"])
        for file in files { XCTAssertTrue(file.text.hasPrefix("#if PP_DIRECT"), file.name) }
    }

    func testThePreviewBackendIsOnlyInDebugStoreBuilds() throws {
        let files = try appFiles()
        let preview = try XCTUnwrap(files.first { $0.name == "PremiumPreview.swift" })
        XCTAssertTrue(preview.text.hasPrefix("#if DEBUG && !PP_DIRECT"))
        XCTAssertEqual(files.filter { $0.text.contains("PASSWORDPIE_PREMIUM_PREVIEW") }.map(\.name), ["PremiumPreview.swift"])
    }

    /// Neither channel has an account: nothing in the app signs in, and the site's sign-in paths are not in any binary.
    /// What may reach the network at all is `NetworkSourceTests`.
    func testNothingSignsIn() throws {
        let signIn = try NSRegularExpression(pattern: #"(app/sign-in|api/auth|api/premium|passwordpie://auth|Sign In|Sign Out|Sign in with Apple)"#)
        for file in try appFiles() {
            let range = NSRange(file.text.startIndex..., in: file.text)
            XCTAssertNil(signIn.firstMatch(in: file.text, range: range), "\(file.name) signs in")
        }
    }

    /// The only things on disk that can turn Premium on are a signed pass or activation, read through `KeychainSecrets.swift`.
    func testThePremiumFilesKeepNoFlagOfTheirOwn() throws {
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
