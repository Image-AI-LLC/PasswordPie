import AppKit
import PasswordPieBridge
import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// Other browsers built on Chromium: docs/UX.md, "Other browsers built on Chrome".
@MainActor
final class ChromiumBrowsersBridgeTests: XCTestCase {
    private var directory: URL!
    /// The bridge holds its session unowned.
    private var session: VaultSession?
    private var defaults: UserDefaults!
    private var suite = ""
    private var pokes: [Int?] = []
    private var opened: [(url: URL, app: URL?)] = []
    private var asked: [ChromiumBrowserIdentity] = []
    private var answerQuestion: ((Bool) -> Void)?

    private static let egoID = "com.example.passwordpie-tests.ego"
    private let chrome = FrontApp(bundleID: BrowserBridge.chromeBundleID, bundleURL: URL(fileURLWithPath: "/tmp/Test Chrome.app"))
    private let ego = FrontApp(bundleID: ChromiumBrowsersBridgeTests.egoID, bundleURL: URL(fileURLWithPath: "/tmp/ego lite.app"))
    private let egoIdentity = ChromiumBrowserIdentity(
        bundleID: ChromiumBrowsersBridgeTests.egoID,
        teamID: "JGQLC6YQYJ",
        bundleURL: URL(fileURLWithPath: "/tmp/ego lite.app"),
        name: "ego lite",
        signer: "CITRO LABS PTE. LIMITED"
    )
    private let chromeIdentity = ChromiumBrowserIdentity(
        bundleID: BrowserBridge.chromeBundleID,
        teamID: ChromiumBrowserIdentity.googleTeamID,
        bundleURL: URL(fileURLWithPath: "/tmp/Test Chrome.app"),
        name: "Google Chrome",
        signer: "Google LLC"
    )

    override func setUpWithError() throws {
        try XCTSkipUnless(BrowserBridge.chromeSupported, "Chrome is in the direct channel only")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-chromium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        suite = "passwordpie-chromium-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        ChromiumBrowsers.assume(Self.egoID, isChromium: true)
    }

    override func tearDownWithError() throws {
        ChromiumBrowsers.assume(Self.egoID, isChromium: nil)
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        defaults?.removePersistentDomain(forName: suite)
        session = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// An unlocked database with one GitHub login, and a bridge that records what it would send, open and ask.
    private func bridge() -> (BrowserBridge, VaultEntry) {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://github.com"
        entry.username = "octocat"
        entry.password = "hunter2"
        session.saveEditing(entry)
        self.session = session
        let bridge = BrowserBridge(session: session, defaults: defaults)
        bridge.pushToChrome = { [weak self] _, link in self?.pokes.append(link) }
        bridge.openInBrowser = { [weak self] url, app in self?.opened.append((url, app)) }
        bridge.askToAllow = { [weak self] identity, answer in
            self?.asked.append(identity)
            self?.answerQuestion = { allowed in MainActor.assumeIsolated { answer(allowed) } }
        }
        return (bridge, session.allEntries.first { $0.title == "GitHub" }!)
    }

    @discardableResult
    private func tab(_ bridge: BrowserBridge, link: Int, _ url: String, focused: Bool?) throws -> [String: Any] {
        var report: [String: Any] = ["type": "tab", "id": 1, "url": url, "reason": "focus"]
        if let focused { report["focused"] = focused }
        let frame = try JSONSerialization.data(withJSONObject: report)
        let answer = try XCTUnwrap(bridge.answer(frame, from: .chrome, link: link))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    /// Chrome on link 1, ego lite on link 2.
    private func connectBoth(_ bridge: BrowserBridge) {
        let chromePeer = BridgePeer(.chrome, link: 1)
        let egoPeer = BridgePeer(.chrome, link: 2)
        bridge.connectionsChanged([chromePeer, egoPeer], apps: [chromePeer: chromeIdentity, egoPeer: egoIdentity])
    }

    // MARK: The same extension, any browser built on Chromium

    func testABrowserBuiltOnChromiumUsesChromesExtension() {
        XCTAssertEqual(BrowserBridge.browser(forBundleID: Self.egoID), .chrome)
        XCTAssertEqual(BrowserBridge.browser(forBundleID: BrowserBridge.chromeBundleID), .chrome)
        XCTAssertEqual(BrowserBridge.browser(forBundleID: BrowserBridge.safariBundleID), .safari)
        XCTAssertNil(BrowserBridge.browser(forBundleID: "com.apple.TextEdit"))
        XCTAssertNil(BrowserBridge.browser(forBundleID: nil))
    }

    func testEachBrowserHasItsOwnProfileInFront() throws {
        let (bridge, _) = bridge()
        connectBoth(bridge)
        try tab(bridge, link: 1, "https://github.com/", focused: false)
        try tab(bridge, link: 2, "https://example.com/", focused: true)
        XCTAssertEqual(bridge.pageURL(for: .chrome, app: Self.egoID), "https://example.com/")
        XCTAssertNil(bridge.pageURL(for: .chrome, app: BrowserBridge.chromeBundleID), "Chrome's window is not in front")
        XCTAssertEqual(bridge.chromeProfiles, 1, "Chrome's row counts Chrome alone")
        XCTAssertEqual(bridge.chromiumProfiles, [BrowserBridge.chromeBundleID: 1, Self.egoID: 1])
    }

    func testTheFillGoesToTheBrowserInFrontAndNoOther() throws {
        let (bridge, entry) = bridge()
        connectBoth(bridge)
        try tab(bridge, link: 1, "https://github.com/login", focused: false)
        try tab(bridge, link: 2, "https://github.com/login", focused: true)
        pokes = []
        XCTAssertTrue(bridge.fill(entry, .fillOrOpen, website: nil, front: ego))
        XCTAssertEqual(pokes, [2], "only ego lite's profile is asked")
        XCTAssertNil(try tab(bridge, link: 1, "https://github.com/login", focused: false)["fill"])
        let fill = try XCTUnwrap(try tab(bridge, link: 2, "https://github.com/login", focused: true)["fill"] as? [String: Any])
        XCTAssertEqual(fill["password"] as? String, "hunter2")
    }

    func testAnotherBrowsersConnectionNeverStandsForTheOneInFront() throws {
        // Only Chrome has the extension; ego lite is in front without it.
        let (bridge, entry) = bridge()
        let chromePeer = BridgePeer(.chrome, link: 1)
        bridge.connectionsChanged([chromePeer], apps: [chromePeer: chromeIdentity])
        try tab(bridge, link: 1, "https://github.com/login", focused: nil)
        XCTAssertNil(bridge.pageURL(for: .chrome, app: Self.egoID))
        XCTAssertFalse(bridge.fill(entry, .fillOrOpen, website: nil, front: ego), "the caller types the keystrokes")
        XCTAssertEqual(bridge.banner(frontBundleID: Self.egoID), .addChrome)
        XCTAssertNil(bridge.banner(frontBundleID: BrowserBridge.chromeBundleID), "Chrome's own extension speaks for Chrome")
    }

    func testTheStorePageOpensInTheChromiumBrowserInFront() {
        let (bridge, _) = bridge()
        bridge.install(.addChrome, in: ego)
        XCTAssertEqual(opened.map(\.url), [BrowserBridge.chromeInstallURL])
        XCTAssertEqual(opened.first?.app, ego.bundleURL)
    }

    // MARK: Asked once, remembered

    func testABrowserIsAskedAboutOnceAndTheAnswerStays() {
        let (bridge, _) = bridge()
        var answers: [Bool] = []
        bridge.approve(egoIdentity) { answers.append($0) }
        // A second profile connects while the question is open: it waits for the same answer.
        bridge.approve(egoIdentity) { answers.append($0) }
        XCTAssertEqual(asked.map(\.bundleID), [Self.egoID])
        XCTAssertTrue(answers.isEmpty)

        answerQuestion?(true)
        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(bridge.approvals.approval(bundleID: Self.egoID, teamID: "JGQLC6YQYJ"), .allowed)

        bridge.approve(egoIdentity) { answers.append($0) }
        XCTAssertEqual(answers, [true, true, true])
        XCTAssertEqual(asked.count, 1, "never asked again")

        // Kept in the preferences: a new launch knows it.
        let relaunched = BrowserBridge(session: session!, defaults: defaults)
        XCTAssertEqual(relaunched.approvals.approval(bundleID: Self.egoID, teamID: "JGQLC6YQYJ"), .allowed)
    }

    func testDontAllowIsRememberedAndHidesTheBanner() {
        let (bridge, _) = bridge()
        var answers: [Bool] = []
        bridge.approve(egoIdentity) { answers.append($0) }
        answerQuestion?(false)
        XCTAssertEqual(answers, [false])
        bridge.approve(egoIdentity) { answers.append($0) }
        XCTAssertEqual(answers, [false, false])
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(
            bridge.banner(frontBundleID: Self.egoID), .allowBrowser(name: "ego lite"),
            "not Add Chrome Extension… over a browser the person said no to: the line that asks again"
        )

        // Changed in Preferences.
        bridge.setApproval(.allowed, bundleID: Self.egoID, teamID: "JGQLC6YQYJ", name: "ego lite")
        bridge.approve(egoIdentity) { answers.append($0) }
        XCTAssertEqual(answers, [false, false, true])
        XCTAssertEqual(bridge.banner(frontBundleID: Self.egoID), .addChrome)
    }

    func testTheSameBrowserSignedBySomeoneElseIsAskedAgain() {
        let (bridge, _) = bridge()
        bridge.approve(egoIdentity) { _ in }
        answerQuestion?(true)
        let impostor = ChromiumBrowserIdentity(bundleID: Self.egoID, teamID: "ZZZZZZZZZZ", bundleURL: egoIdentity.bundleURL, name: "ego lite", signer: nil)
        var answers: [Bool] = []
        bridge.approve(impostor) { answers.append($0) }
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(answers.isEmpty)
    }

    func testAnotherTeamsBrowserCallingItselfChromeIsRefusedWithoutAQuestion() {
        let (bridge, _) = bridge()
        let impostor = ChromiumBrowserIdentity(bundleID: BrowserBridge.chromeBundleID, teamID: "ZZZZZZZZZZ", bundleURL: URL(fileURLWithPath: "/tmp/Fake.app"), name: "Chrome", signer: nil)
        var answers: [Bool] = []
        bridge.approve(impostor) { answers.append($0) }
        XCTAssertEqual(answers, [false])
        XCTAssertTrue(asked.isEmpty)
        XCTAssertNil(bridge.approvals.approval(bundleID: BrowserBridge.chromeBundleID, teamID: "ZZZZZZZZZZ"))
        XCTAssertEqual(bridge.banner(frontBundleID: BrowserBridge.chromeBundleID), .addChrome)
    }

    func testGooglesBrowsersAreNeverAskedAbout() {
        let (bridge, _) = bridge()
        let beta = ChromiumBrowserIdentity(bundleID: "com.google.Chrome.beta", teamID: ChromiumBrowserIdentity.googleTeamID, bundleURL: URL(fileURLWithPath: "/tmp/Chrome Beta.app"), name: "Google Chrome Beta", signer: "Google LLC")
        var answers: [Bool] = []
        bridge.approve(chromeIdentity) { answers.append($0) }
        bridge.approve(beta) { answers.append($0) }
        XCTAssertEqual(answers, [true, true])
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: Preferences

    func testPreferencesListsTheAnsweredAndTheConnected() {
        var approvals = BrowserApprovals()
        approvals.set(.allowed, bundleID: Self.egoID, teamID: "JGQLC6YQYJ", name: "ego lite", now: Date())
        approvals.set(.denied, bundleID: "com.example.other", teamID: "AAAAAAAAAA", name: "Other", now: Date())
        let beta = ChromiumBrowserIdentity(bundleID: "com.google.Chrome.beta", teamID: ChromiumBrowserIdentity.googleTeamID, bundleURL: URL(fileURLWithPath: "/tmp/Chrome Beta.app"), name: "Chrome Beta", signer: nil)

        let idle = chromiumBrowserRows(approvals: approvals, connected: [:], seen: [:])
        XCTAssertEqual(idle.map(\.name), ["ego lite", "Other"])
        XCTAssertEqual(idle.map(\.status.text), ["Allowed", "Not allowed"])
        XCTAssertEqual(idle.map(\.button), ["Don't Allow", "Allow"])
        XCTAssertEqual(idle.map(\.toggled), [.denied, .allowed])

        let busy = chromiumBrowserRows(
            approvals: approvals,
            connected: [Self.egoID: 2, "com.google.Chrome.beta": 1, BrowserBridge.chromeBundleID: 1],
            seen: [Self.egoID: egoIdentity, "com.google.Chrome.beta": beta, BrowserBridge.chromeBundleID: chromeIdentity]
        )
        XCTAssertEqual(busy.map(\.name), ["Chrome Beta", "ego lite", "Other"], "Chrome has its own row")
        XCTAssertEqual(busy.map(\.status.text), ["Connected", "Connected in 2 profiles", "Not allowed"])
        XCTAssertEqual(busy.map(\.button), [nil, "Don't Allow", "Allow"], "Google's browsers have no answer to change")
    }

    // MARK: Asking again about a browser the person said no to

    private func show(id: Int) -> Data { Data(#"{"type":"show","id":\#(id)}"#.utf8) }

    private func refuse(_ bridge: BrowserBridge) {
        bridge.approve(egoIdentity) { _ in }
        answerQuestion?(false)
        answerQuestion = nil
    }

    func testThePanelsLineOverARefusedBrowserAsksAgain() {
        let (bridge, _) = bridge()
        refuse(bridge)
        let line = ExtensionBanner.allowBrowser(name: "ego lite")
        XCTAssertEqual(line.title, "Allow “ego lite” to Fill Passwords…")
        XCTAssertEqual(bridge.banner(frontBundleID: Self.egoID), line)

        // The question names the running browser by its own signature, not by the line's words.
        var looked: [FrontApp] = []
        bridge.identityOfRunning = { [egoIdentity] front in
            looked.append(front)
            return egoIdentity
        }
        bridge.install(line, in: ego)
        XCTAssertEqual(looked, [ego])
        XCTAssertEqual(asked.count, 2, "the question opens again")
        bridge.install(line, in: ego)
        XCTAssertEqual(asked.count, 2, "one question at a time")

        answerQuestion?(true)
        XCTAssertEqual(bridge.approvals.approval(bundleID: Self.egoID, teamID: "JGQLC6YQYJ"), .allowed)
        XCTAssertEqual(bridge.banner(frontBundleID: Self.egoID), .addChrome, "allowed and not connected yet: Chrome's line")
        XCTAssertTrue(opened.isEmpty, "the line opens no store page")
    }

    func testThePanelsLineAsksNothingWhenTheBrowserIsGoneOrIsAnother() {
        let (bridge, _) = bridge()
        refuse(bridge)
        let line = ExtensionBanner.allowBrowser(name: "ego lite")
        bridge.identityOfRunning = { _ in nil }
        bridge.install(line, in: ego)
        XCTAssertEqual(asked.count, 1, "the browser quit meanwhile")

        // The same bundle ID signed by someone else has no answer on record: its own first connection asks, not this line.
        let impostor = ChromiumBrowserIdentity(bundleID: Self.egoID, teamID: "ZZZZZZZZZZ", bundleURL: egoIdentity.bundleURL, name: "ego lite", signer: nil)
        bridge.identityOfRunning = { _ in impostor }
        bridge.install(line, in: ego)
        XCTAssertEqual(asked.count, 1)
    }

    func testTheToolbarButtonOfARefusedBrowserAsksAgain() throws {
        let (bridge, _) = bridge()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        bridge.now = { clock }
        refuse(bridge)

        // Nothing else it sends is served or answered.
        for other in [#"{"type":"hello","id":1,"version":1}"#, #"{"type":"tab","id":2,"url":"https://github.com/login"}"#, "not json"] {
            XCTAssertEqual(bridge.refusedFrame(Data(other.utf8), from: egoIdentity), .hold(answer: nil), other)
        }
        XCTAssertEqual(asked.count, 1)

        // The button is answered at once, so the extension does not open the website; right after a Don't Allow it does
        // not bring the question back.
        guard case .hold(let early?) = bridge.refusedFrame(show(id: 7), from: egoIdentity) else { return XCTFail("the button gets an answer") }
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: early) as? [String: Any])
        XCTAssertEqual(answer["type"] as? String, "show")
        XCTAssertEqual(answer["id"] as? Int, 7)
        XCTAssertEqual(answer.count, 2, "nothing but the request's own id")
        XCTAssertEqual(asked.count, 1, "not within 10 seconds of the answer")

        clock += BrowserBridge.askAgainAfter
        XCTAssertNotEqual(bridge.refusedFrame(show(id: 8), from: egoIdentity), .hold(answer: nil))
        XCTAssertEqual(asked.count, 2, "the question opens again")
        _ = bridge.refusedFrame(show(id: 9), from: egoIdentity)
        XCTAssertEqual(asked.count, 2, "one question at a time")

        // Don't Allow again: the 10 seconds start again.
        answerQuestion?(false)
        _ = bridge.refusedFrame(show(id: 10), from: egoIdentity)
        XCTAssertEqual(asked.count, 2)
        clock += BrowserBridge.askAgainAfter
        _ = bridge.refusedFrame(show(id: 11), from: egoIdentity)
        XCTAssertEqual(asked.count, 3)

        // Allow: the next frame is served like any connection's.
        answerQuestion?(true)
        XCTAssertEqual(bridge.refusedFrame(show(id: 12), from: egoIdentity), .admit)
        XCTAssertEqual(bridge.refusedFrame(Data(#"{"type":"tab","id":13}"#.utf8), from: egoIdentity), .admit)
        XCTAssertEqual(asked.count, 3)
    }

    func testABrowserWithNoAnswerOnRecordIsNotHeld() {
        let (bridge, _) = bridge()
        // Refused without a question: it calls itself Google's under another team. Nothing is kept, so nothing is held.
        let fake = ChromiumBrowserIdentity(bundleID: "com.google.Chrome", teamID: "ZZZZZZZZZZ", bundleURL: egoIdentity.bundleURL, name: "Google Chrome", signer: nil)
        var answers: [Bool] = []
        bridge.approve(fake) { answers.append($0) }
        XCTAssertEqual(answers, [false])
        XCTAssertEqual(bridge.refusedFrame(show(id: 1), from: fake), .close)
        XCTAssertTrue(asked.isEmpty, "its toolbar button asks nothing")
        bridge.askAgain(fake)
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: The question window (docs/UX.md, "Other browsers built on Chrome")

    func testTheQuestionNamesTheBrowserAndWhoSignedIt() {
        // The browser's name never breaks across lines: its spaces are non-breaking.
        XCTAssertEqual(BrowserApprovalPrompt.title(egoIdentity), "Allow “ego\u{A0}lite” to fill passwords?")
        XCTAssertEqual(BrowserApprovalPrompt.signerLine(egoIdentity), "Signed by CITRO LABS PTE. LIMITED")
        XCTAssertEqual(BrowserApprovalPrompt.effect, "It gets the username and password of each account you pick.")
        XCTAssertEqual(
            BrowserApprovalPrompt.condition(egoIdentity),
            "Only allow it if you added the PasswordPie extension to ego\u{A0}lite yourself."
        )
        XCTAssertEqual(BrowserApprovalPrompt.changeNote, "You can change this in Preferences > Browsers.")
        XCTAssertEqual(BrowserApprovalPrompt.denyTitle, "Don't Allow")
        XCTAssertEqual(BrowserApprovalPrompt.allowTitle, "Allow")
    }

    func testACertificateWithoutAnOrganizationShowsNoSignerLine() {
        let unnamed = ChromiumBrowserIdentity(bundleID: Self.egoID, teamID: "ZZZZZZZZZZ", bundleURL: egoIdentity.bundleURL, name: "ego lite", signer: nil)
        XCTAssertNil(BrowserApprovalPrompt.signerLine(unnamed))
    }

    func testEachButtonAnswersOnceAndClosesTheWindow() {
        var answers: [Bool] = []
        var closed = 0
        let allowing = BrowserApprovalModel(identity: egoIdentity) { answers.append($0) }
        allowing.onAnswered = { closed += 1 }
        allowing.allow()
        allowing.deny()
        XCTAssertEqual(answers, [true], "a second press answers nothing")
        XCTAssertEqual(closed, 1)

        let denying = BrowserApprovalModel(identity: egoIdentity) { answers.append($0) }
        denying.deny()
        denying.allow()
        XCTAssertEqual(answers, [true, false])
    }

    func testNoKeyAnswersTheQuestion() throws {
        var answers: [Bool] = []
        let model = BrowserApprovalModel(identity: egoIdentity) { answers.append($0) }
        let panel = BrowserApprovalPrompt.panel(for: model)
        defer { panel.close() }
        panel.layoutIfNeeded()
        XCTAssertNil(panel.defaultButtonCell, "neither button is the default")
        XCTAssertFalse(panel.styleMask.contains(.closable), "no close button: Escape has nothing to press")
        for (characters, code) in [("\r", UInt16(36)), ("\u{1B}", UInt16(53)), (" ", UInt16(49))] {
            let key = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
            XCTAssertFalse(panel.performKeyEquivalent(with: key), "key code \(code)")
        }
        XCTAssertTrue(answers.isEmpty, "a key pressed by accident neither lets a browser in nor shuts it out")
    }

    func testTheWindowIsOneWidthAndGrowsForALongName() {
        let short = NSHostingView(rootView: BrowserApprovalView(model: BrowserApprovalModel(identity: egoIdentity) { _ in }))
        XCTAssertEqual(short.fittingSize.width, BrowserApprovalPrompt.width)
        XCTAssertGreaterThan(short.fittingSize.height, 200)
        XCTAssertLessThan(short.fittingSize.height, 320)

        let long = ChromiumBrowserIdentity(
            bundleID: "com.example.long", teamID: "ZZZZZZZZZZ", bundleURL: URL(fileURLWithPath: "/tmp/Long.app"),
            name: "Microsoft Edge Canary for Enterprise Preview", signer: "Microsoft Corporation"
        )
        let tall = NSHostingView(rootView: BrowserApprovalView(model: BrowserApprovalModel(identity: long) { _ in }))
        XCTAssertEqual(tall.fittingSize.width, BrowserApprovalPrompt.width)
        XCTAssertGreaterThan(tall.fittingSize.height, short.fittingSize.height, "a long name wraps instead of being cut")

        // The hidden title bar adds no band of its own: the window is exactly as tall as what it shows.
        let panel = BrowserApprovalPrompt.panel(for: BrowserApprovalModel(identity: egoIdentity) { _ in })
        defer { panel.close() }
        XCTAssertEqual(panel.frame.size, short.fittingSize)
    }

    func testTheQuestionSaysWhatItShowsForTheStatusFile() {
        let model = BrowserApprovalModel(identity: egoIdentity) { _ in }
        XCTAssertEqual(model.debugSummary["title"] as? String, "Allow “ego\u{A0}lite” to fill passwords?")
        XCTAssertEqual(model.debugSummary["signer"] as? String, "Signed by CITRO LABS PTE. LIMITED")
        XCTAssertEqual(model.debugSummary["buttons"] as? [String], ["Don't Allow", "Allow"])
    }
}

/// Where each browser built on Chromium keeps its profiles, and the host manifests written there.
final class ChromiumFoldersTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private var support: URL { ChromiumBrowsers.supportFolder(home: home) }

    /// A browser bundle with the given Info.plist values.
    private func makeApp(_ name: String, _ info: [String: Any]) throws -> URL {
        let app = home.appendingPathComponent("Apps/\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testTheBrowserSaysWhereItsProfilesAre() {
        let ego = ChromiumBrowsers.folder(bundleID: "com.citrolabs.ego.lite", info: ["CrProductDirName": "Citro Labs/ego lite"], home: home)
        XCTAssertEqual(ego?.path, support.appendingPathComponent("Citro Labs/ego lite").path)
        let brave = ChromiumBrowsers.folder(bundleID: "com.brave.Browser", info: [:], home: home)
        XCTAssertEqual(brave?.path, support.appendingPathComponent("BraveSoftware/Brave-Browser").path)
        XCTAssertNil(ChromiumBrowsers.folder(bundleID: "com.example.unknown", info: [:], home: home))
    }

    func testAFolderNameNeverLeavesApplicationSupport() {
        XCTAssertNil(ChromiumBrowsers.folder(bundleID: "x", info: ["CrProductDirName": "../../Desktop"], home: home))
        XCTAssertNil(ChromiumBrowsers.folder(bundleID: "x", info: ["CrProductDirName": "/etc"], home: home))
        XCTAssertNil(ChromiumBrowsers.folder(bundleID: "x", info: ["CrProductDirName": ""], home: home))
    }

    func testARunningBrowserIsFoundByItsLock() throws {
        let folder = support.appendingPathComponent("Some Vendor/Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("SingletonLock").path, withDestinationPath: "Mac-mini.local-4242")
        let other = support.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("SingletonLock").path, withDestinationPath: "Mac-mini.local-14242")

        XCTAssertEqual(ChromiumBrowsers.runningFolder(pid: 4242, home: home)?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertNil(ChromiumBrowsers.runningFolder(pid: 424, home: home))
    }

    func testTheFoldersAreThoseOfChromiumBrowsersThatWereOpened() throws {
        let ego = try makeApp("ego lite", ["CFBundleIdentifier": "com.citrolabs.ego.lite", "NSPrincipalClass": "BrowserCrApplication", "CrProductDirName": "Citro Labs/ego lite"])
        let neverOpened = try makeApp("Vivaldi", ["CFBundleIdentifier": "com.vivaldi.Vivaldi", "NSPrincipalClass": "BrowserCrApplication"])
        let electron = try makeApp("Some Electron App", ["CFBundleIdentifier": "com.example.electron", "NSPrincipalClass": "AtomApplication", "CrProductDirName": "Electron"])
        for name in ["Citro Labs/ego lite", "Google/Chrome", "Electron"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let folders = ChromiumBrowsers.folders(home: home, installed: [ego, neverOpened, electron, ego], running: [])
        XCTAssertEqual(folders.map(\.lastPathComponent), ["Chrome", "ego lite"], "no Electron app, no folder created for a browser never opened, once each")
    }
}

#if PP_DIRECT
final class ChromiumHostManifestTests: XCTestCase {
    func testTheManifestsGoToEachBrowsersFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let ego = home.appendingPathComponent("Library/Application Support/Citro Labs/ego lite")
        let missing = home.appendingPathComponent("Library/Application Support/Never Opened")
        try FileManager.default.createDirectory(at: ego, withIntermediateDirectories: true)
        let app = home.appendingPathComponent("PasswordPie.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.passwordpie.tests.bundle", "CFBundleExecutable": "PasswordPie", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        for name in ["PasswordPie", "PasswordPieBrowserHost"] {
            let file = macOS.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let bundle = try XCTUnwrap(Bundle(url: app))

        ChromeHostManifest.install(bundle: bundle, home: home, folders: [ego, missing])

        for name in BridgeConstants.nativeHostNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: ego.appendingPathComponent("NativeMessagingHosts/\(name).json").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "a browser never opened gets no folder")
    }
}
#endif
