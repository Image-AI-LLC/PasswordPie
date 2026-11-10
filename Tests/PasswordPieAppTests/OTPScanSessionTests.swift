import AppKit
import CoreImage
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The editor's QR button and the scan from the browser extension waiting for Add (docs/UX.md, "Scan a two-step QR code").
@MainActor
final class OTPScanSessionTests: XCTestCase {
    private var directory: URL!
    private var clock = PremiumFixtures.now
    private let demo = "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo"
    private let normalized = "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo&period=30&digits=6"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("otp-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        clock = PremiumFixtures.now
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession(_ entries: [VaultEntry]) async -> VaultSession {
        #if PP_DIRECT
        let store = PremiumStore.testing(secrets: FakeSecrets(), now: { PremiumFixtures.now })
        store.start()
        #else
        let store = PremiumStore(backend: FakePremiumBackend(), secrets: FakeSecrets(), verify: PassKey.verifyActivation, now: { PremiumFixtures.now })
        #endif
        await store.refresh()
        let session = VaultSession(premium: store, pasteboard: FakePasteboard())
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for entry in entries { session.saveEditing(entry) }
        return session
    }

    private func item(_ title: String, user: String, url: String, otp: String = "") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = user
        entry.url = url
        entry.otp = otp
        return entry
    }

    private func scanned(_ raw: String? = nil) throws -> ScannedOTP {
        try OTPAuthImport.parse(raw ?? demo).get()
    }

    private func model(_ session: VaultSession) -> OTPScanModel {
        let model = OTPScanModel(session: session)
        model.now = { [unowned self] in self.clock }
        return model
    }

    /// The saved file, read back, not the session's copy.
    private func savedOTP(_ session: VaultSession, title: String) throws -> String? {
        let url = directory.appendingPathComponent("test.kdbx")
        let vault = try KDBX.load(data: Data(contentsOf: url), password: "pw")
        return vault.entries.first { $0.title == title && !$0.trashed }?.otp
    }

    private func qrPNG(_ text: String) throws -> Data {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let padded = code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -32, dy: -32)))
        let cg = try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("pp-otp-scan-\(UUID().uuidString)"))
        board.clearContents()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    // MARK: Editor

    func testAScreenshotOnTheClipboardScansIntoTheEditorAndSaves() async throws {
        let session = await unlockedSession([])
        let board = pasteboard()
        board.setData(try qrPNG(demo), forType: .png)
        XCTAssertTrue(OTPInputScanner.holdsOnlyAnImage(board))
        guard case .scanned(let scan) = OTPInputScanner.scan(pasteboard: board) else { return XCTFail("no scan") }
        session.newEntry()
        var entry = try XCTUnwrap(session.editing)
        entry.title = "Demo"
        entry.otp = editorOTPValue(scan.uri, title: entry.title, username: entry.username)
        XCTAssertTrue(session.oneTimeCodeAccess(for: entry) != .noCode, "the editor previews a code")
        session.saveEditing(entry)
        XCTAssertNil(session.editing)
        XCTAssertEqual(try savedOTP(session, title: "Demo"), normalized)
    }

    func testAnImageFileAndALinkOnTheClipboardScanToo() throws {
        let file = directory.appendingPathComponent("qr.png")
        try qrPNG(demo).write(to: file)
        XCTAssertEqual(OTPInputScanner.scan(fileURL: file), .scanned(try scanned()))
        let board = pasteboard()
        board.writeObjects([file as NSURL])
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: board), .scanned(try scanned()))
        let text = pasteboard()
        text.setString("  \(demo)\n", forType: .string)
        XCTAssertFalse(OTPInputScanner.holdsOnlyAnImage(text), "a link pastes as text")
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: text), .scanned(try scanned()))
    }

    func testWhatCannotBeScannedSaysWhy() throws {
        let empty = pasteboard()
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: empty), .failed(OTPInputScanner.nothingToScan))
        let words = pasteboard()
        words.setString("hello", forType: .string)
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: words), .failed(OTPInputScanner.nothingToScan))
        let hotp = pasteboard()
        hotp.setString("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP", forType: .string)
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: hotp), .failed(OTPImportError.hotp.message))
        let website = pasteboard()
        website.setData(try qrPNG("https://example.com"), forType: .png)
        XCTAssertEqual(OTPInputScanner.scan(pasteboard: website), .failed(OTPImportError.notOTPAuth.message))
        let blank = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        XCTAssertEqual(OTPInputScanner.scan(image: blank), .failed(OTPInputScanner.noQRCode))
    }

    func testABareSecretIsStoredAsALink() {
        XCTAssertEqual(editorOTPValue(" ", title: "A", username: "b"), "")
        XCTAssertEqual(editorOTPValue(demo, title: "A", username: "b"), demo)
        XCTAssertTrue(editorOTPValue("JBSWY3DPEHPK3PXP", title: "A", username: "b").hasPrefix("otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP"))
    }

    // MARK: From the extension

    func testAScanWhileLockedWaitsForTheUnlockThenAddsToTheBestItem() async throws {
        let session = await unlockedSession([
            item("Demo", user: "bob", url: "https://example.com"),
            item("Demo", user: "ada", url: "https://www.example.com"),
        ])
        session.lock()
        let model = model(session)
        var presented = 0
        var added: [(UUID, BridgeBrowser, String)] = []
        model.present = { presented += 1 }
        model.codeAdded = { added.append(($0, $1, $2)) }
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(model.isWaiting)
        XCTAssertEqual(model.candidates, [], "nothing about the vault while locked")
        model.add()
        XCTAssertTrue(model.isWaiting, "Add does nothing while locked")

        session.passwordDraft = "pw"
        session.unlock()
        let unlocked = await waitUntil(timeout: 20) { !session.locked }
        XCTAssertTrue(unlocked)
        model.prepare()
        let ada = try XCTUnwrap(session.entries.first { $0.username == "ada" })
        XCTAssertEqual(model.target, .entry(ada.id))
        XCTAssertEqual(model.candidates.map(\.username), ["ada", "bob"])
        model.add()
        XCTAssertEqual(model.phase, .added(ada.id))
        XCTAssertNil(model.scan, "the secret leaves the scan once saved")
        XCTAssertEqual(session.storedEntry(ada.id)?.otp, normalized)
        XCTAssertEqual(added.first?.0, ada.id)
        XCTAssertEqual(added.first?.2, "https://example.com")
        XCTAssertEqual(session.oneTimeCodeAccess(for: try XCTUnwrap(session.entry(ada.id))), .locked, "no Premium: the code row is locked")
    }

    func testAnItemWithACodeAsksBeforeReplacingIt() async throws {
        let old = "otpauth://totp/Demo:ada?secret=GEZDGNBVGY3TQOJQ&issuer=Demo"
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com", otp: old)])
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .safari)
        XCTAssertTrue(model.targetHasCode)
        model.add()
        XCTAssertEqual(model.phase, .confirmReplace)
        XCTAssertEqual(try savedOTP(session, title: "Demo"), old, "nothing written before Replace")
        model.keepChoosing()
        XCTAssertEqual(model.phase, .choosing)
        model.add()
        model.add()
        XCTAssertEqual(try savedOTP(session, title: "Demo"), normalized)
    }

    func testAScanRunsOutAfterTwoMinutes() async throws {
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com")])
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        clock = clock.addingTimeInterval(119)
        XCTAssertTrue(model.isWaiting)
        clock = clock.addingTimeInterval(1)
        model.add()
        XCTAssertEqual(model.phase, .expired)
        XCTAssertNil(model.scan)
        XCTAssertEqual(try savedOTP(session, title: "Demo"), "")
    }

    func testANewScanReplacesTheOneWaiting() async throws {
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com")])
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        let other = try scanned("otpauth://totp/Other:zed?secret=GEZDGNBV&issuer=Other")
        model.receive(other, origin: nil, browser: .safari)
        XCTAssertEqual(model.scan?.otp, other)
        XCTAssertEqual(model.target, .newItem, "nothing named Other")
        model.add()
        let created = try XCTUnwrap(session.entries.first { $0.title == "Other" })
        XCTAssertEqual(created.username, "zed")
        XCTAssertEqual(created.otp, other.uri)
        XCTAssertEqual(try savedOTP(session, title: "Demo"), "", "the first scan never landed")
    }

    func testCancelDropsTheScanAndWritesNothing() async throws {
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com")])
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        model.cancel()
        XCTAssertNil(model.scan)
        XCTAssertFalse(model.isWaiting)
        model.add()
        XCTAssertEqual(try savedOTP(session, title: "Demo"), "")
    }

    func testSearchFindsOtherItems() async throws {
        let session = await unlockedSession([
            item("Demo", user: "ada", url: "https://example.com"),
            item("Mail", user: "ada@mail.test", url: "https://mail.test"),
        ])
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        model.query = "mail"
        XCTAssertEqual(model.searchResults.map(\.title), ["Mail"])
        model.query = "demo"
        XCTAssertEqual(model.searchResults, [], "already listed")
    }

    func testAddingAScannedCodeLeavesTheEditorOpen() async throws {
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com"), item("Other", user: "x", url: "")])
        let other = try XCTUnwrap(session.entries.first { $0.title == "Other" })
        session.edit(other.id)
        let model = model(session)
        model.receive(try scanned(), origin: "https://example.com", browser: .chrome)
        model.add()
        XCTAssertEqual(session.editing?.id, other.id)
    }

    func testABridgeScanReachesTheModelAndAddLetsThatPageFillTheCode() async throws {
        let session = await unlockedSession([item("Demo", user: "ada", url: "https://example.com")])
        let bridge = BrowserBridge(session: session)
        let model = model(session)
        bridge.onScan = { model.receive($0, origin: $1, browser: $2) }
        model.codeAdded = { bridge.expectScannedCode(entryID: $0, browser: $1, origin: $2) }
        let frame = try JSONSerialization.data(withJSONObject: ["type": "scan", "id": 9, "otpauth": demo, "url": "https://example.com/"])
        let answer = try JSONSerialization.jsonObject(with: XCTUnwrap(bridge.answer(frame, from: .chrome))) as? NSDictionary
        XCTAssertEqual(answer, ["type": "scan", "id": 9])
        let arrived = await waitUntil { model.scan != nil }
        XCTAssertTrue(arrived)
        model.add()
        let tab = try JSONSerialization.data(withJSONObject: ["type": "tab", "id": 10, "url": "https://example.com/"])
        let told = try JSONSerialization.jsonObject(with: XCTUnwrap(bridge.answer(tab, from: .chrome))) as? [String: Any]
        XCTAssertEqual((told?["expectCode"] as? [String: Any])?["origin"] as? String, "https://example.com")
    }
}
