#if PP_DIRECT
import Foundation
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// `passwordpie login` through the app: the broker, the real session and browser bridge, and a scripted extension that
/// answers pokes with tab reports. What the extension gets, what the agent hears, the 30 s expiry, locking, hanging up, and
/// the two-step code with and without Premium. See docs/AGENTS.md, "Website login".
@MainActor
final class AgentLoginBridgeTests: XCTestCase {
    private var directory: URL!
    private var session: VaultSession!
    private var bridge: BrowserBridge!
    private var logins: AgentLoginBridge!
    private var broker: VaultBroker!
    private var approver: AllowFirst!
    /// The tab in front of the scripted Chrome profile; nil: the extension does not answer pokes.
    private var frontTab: String? = "https://github.com/"
    /// Every `tab` answer the extension got, as JSON.
    private var tabAnswers: [String] = []
    /// What the scripted extension does after a fill: a `login-result` to send, or nothing.
    private var reply: String? = "submitted"
    private var premium = false
    private let planted = "planted-login-secret-83"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        bridge = BrowserBridge(session: session)
        bridge.agentPokeWait = 0.5
        bridge.pushToChrome = { [weak self] data, link in
            guard let self, String(decoding: data, as: UTF8.self).contains("poke"), let link else { return }
            // The extension answers a poke with a report of its tab, a moment later.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.extensionReports(link: link) } }
        }
        bridge.connectionsChanged([BridgePeer(.chrome, link: 1)])
        logins = AgentLoginBridge(session: session, bridge: bridge)
        bridge.codeAllowed = { [weak self] in self?.premium ?? false }
        approver = AllowFirst()
        broker = VaultBroker(vault: session, approver: approver, grants: NoAgentGrants(), activity: Activity()) { true }
        broker.logins = logins
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ title: String, url: String, code: Bool = false, shared: Bool = true) throws {
        var entry = VaultEntry(groupPath: ["Web"])
        entry.title = title
        entry.url = url
        entry.username = "octocat"
        entry.password = planted
        if code { entry.otp = "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub" }
        session.saveEditing(entry)
        if shared { session.setSharedWithAgents(try XCTUnwrap(session.entries.first { $0.title == title }?.id), true) }
    }

    private func extensionReports(link: Int) {
        guard let frontTab else { return }
        let frame = Data(#"{"type":"tab","id":1,"url":"\#(frontTab)","reason":"poke","focused":true}"#.utf8)
        guard let data = bridge.answer(frame, from: .chrome, link: link) else { return }
        let answer = String(decoding: data, as: UTF8.self)
        tabAnswers.append(answer)
        guard answer.contains(#""fill""#), let reply,
              let loginId = answer.range(of: #""loginId":"[^"]+""#, options: .regularExpression).map({ String(answer[$0].dropFirst(11).dropLast()) }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = self.bridge.answer(Data(#"{"type":"login-result","id":2,"url":"\#(self.frontTab ?? "")","result":"\#(reply)","loginId":"\#(loginId)"}"#.utf8), from: .chrome, link: link)
            }
        }
    }

    private var caller: AgentCaller {
        let agent = AgentProcess(pid: 100, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code")
        return AgentCaller(
            cli: AgentProcess(pid: 200, startTime: 2, path: "/Applications/PasswordPie.app/Contents/Helpers/passwordpie", name: "passwordpie"),
            chain: [agent], agent: agent, sessionKey: "agent:100:1", cwd: "/tmp", project: "/tmp"
        )
    }

    private func login(_ ref: String?, url: String? = nil, submit: Bool = true) -> AgentRequest {
        var request = AgentRequest(type: .login, id: 4)
        request.secrets = ref.map { [AgentSecretRequest(name: nil, ref: $0, delivery: .fill)] }
        request.url = url
        request.submit = submit
        request.wait = 0
        return request
    }

    private func encoded(_ answer: AgentResponse) -> String {
        String(decoding: AgentCoding.encode(answer), as: UTF8.self)
    }

    func testAnApprovedLoginFillsTheTabAndTheAgentHearsSubmittedWithoutThePassword() async throws {
        try add("GitHub", url: "https://github.com/login")
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertNil(answer.errorCode, encoded(answer))
        XCTAssertEqual(answer.login?.outcome, .submitted)
        XCTAssertEqual(answer.login?.item, AgentLoginOverview(title: "GitHub", username: "octocat", websites: ["https://github.com/login"]))
        XCTAssertEqual(answer.login?.code, AgentLoginCode.none)
        XCTAssertFalse(encoded(answer).contains(planted))
        let fill = try XCTUnwrap(tabAnswers.first { $0.contains(#""fill""#) })
        XCTAssertTrue(fill.contains(#""submit":true"#))
        XCTAssertTrue(fill.contains(#""report":true"#))
        XCTAssertEqual(approver.prompts.first?.site, "github.com")
        XCTAssertNil(bridge.agentLogin)
    }

    /// The tab in front changes to another site after the owner allowed: the fill is never answered there.
    func testATabOnAnotherSiteAfterTheApprovalIsNoMatchingTab() async throws {
        try add("GitHub", url: "https://github.com/login")
        approver.onPresent = { [unowned self] in self.frontTab = "https://gitlab.com/" }
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(answer.login?.outcome, .noMatchingTab)
        XCTAssertEqual(answer.login?.detail, "The tab in front is on another site.")
        XCTAssertFalse(tabAnswers.contains { $0.contains(planted) }, "no fill went to the other site")
        XCTAssertNil(bridge.state.pending.pending)
    }

    /// The pending fill expires when no tab of its site reports in time.
    func testNoTabInTimeIsTimedOutAndTheFillIsGone() async throws {
        try add("GitHub", url: "https://github.com/login")
        bridge.agentFillLifetime = 0.3
        approver.onPresent = { [unowned self] in self.frontTab = nil }
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(answer.login?.outcome, .timedOut)
        XCTAssertNil(bridge.state.pending.pending)
        frontTab = "https://github.com/"
        extensionReports(link: 1)
        XCTAssertFalse(tabAnswers.contains { $0.contains(planted) }, "a tab that reports after the expiry gets nothing")
    }

    func testAnExtensionThatTakesTheFillAndSaysNothingIsFilledWithAWord() async throws {
        try add("GitHub", url: "https://github.com/login")
        reply = nil
        bridge.agentResultLifetime = 0.3
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(answer.login?.outcome, .filled)
        XCTAssertNotNil(answer.login?.detail)
    }

    func testNoFieldsIsReported() async throws {
        try add("GitHub", url: "https://github.com/login")
        reply = "no-fields"
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(answer.login?.outcome, .noFields)
    }

    func testLockingWhileWaitingAnswersLocked() async throws {
        try add("GitHub", url: "https://github.com/login")
        bridge.start()
        approver.onPresent = { [unowned self] in self.frontTab = nil }
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let waiting = await eventually { self.bridge.agentLogin != nil }
        XCTAssertTrue(waiting)
        session.lock()
        let answer = await task.value
        XCTAssertEqual(answer.errorCode, .locked)
        XCTAssertNil(bridge.state.pending.pending)
    }

    /// Turning agent access off withdraws a login that was approved and is waiting for its tab.
    func testTurningAccessOffWithdrawsAWaitingLogin() async throws {
        try add("GitHub", url: "https://github.com/login")
        let defaults = UserDefaults(suiteName: "agent-login-\(UUID().uuidString)")!
        let access = AgentAccess(session: session, defaults: defaults, logURL: directory.appendingPathComponent("activity.jsonl"), approver: AgentApprovalController(show: { _ in {} }))
        access.attachBrowser(bridge)
        approver.onPresent = { [unowned self] in self.frontTab = nil }
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let waiting = await eventually { self.bridge.agentLogin != nil }
        XCTAssertTrue(waiting)
        broker.isEnabled = { false }
        access.setEnabled(false)
        XCTAssertNil(bridge.state.pending.pending)
        let answer = await task.value
        XCTAssertEqual(answer.errorCode, .accessOff)
    }

    /// Turning access off after a tab took the fill leaves it: the page finishes and the outcome stands.
    func testTurningAccessOffKeepsAFillATabAlreadyTook() async throws {
        try add("GitHub", url: "https://github.com/login")
        reply = nil
        bridge.agentResultLifetime = 0.5
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let taken = await eventually { self.bridge.agentLogin?.taken == true }
        XCTAssertTrue(taken)
        // As the app does it: the switch, then the closed socket hangs the request up.
        bridge.withdrawAgentLoginForAccessOff()
        XCTAssertNotNil(bridge.agentLogin, "a taken fill is not withdrawn")
        broker.isEnabled = { false }
        task.cancel()
        let answer = await task.value
        XCTAssertNil(answer.errorCode, "not access-off: the tab took it")
        XCTAssertEqual(answer.login?.outcome, .filled)
    }

    /// An extension that answers the code request but not `login-result` still tells the agent how the code went.
    func testACodeRequestCountsWhenTheResultNeverComes() async throws {
        try add("GitHub", url: "https://github.com/login", code: true)
        premium = true
        reply = nil
        bridge.agentResultLifetime = 0.8
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let taken = await eventually { self.bridge.agentLogin?.taken == true }
        XCTAssertTrue(taken)
        _ = bridge.answer(Data(#"{"type":"code","id":3,"url":"https://github.com/"}"#.utf8), from: .chrome, link: 1)
        let answer = await task.value
        XCTAssertEqual(answer.login?.outcome, .filled)
        XCTAssertEqual(answer.login?.code, .filled)
    }

    /// A newer login does not tell an older one that a tab already took "no tab took it".
    func testANewerLoginEndsATakenOneWithWhatIsKnown() async throws {
        try add("GitHub", url: "https://github.com/login", code: true)
        premium = true
        reply = "submitted"
        bridge.agentCodeLifetime = 0.5
        let first = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let taken = await eventually { self.bridge.agentLogin?.result == .submitted }
        XCTAssertTrue(taken)
        let other = AgentProcess(pid: 300, startTime: 3, path: "/usr/local/bin/codex", name: "Codex")
        let second = AgentCaller(cli: caller.cli, chain: [other], agent: other, sessionKey: "agent:300:3", cwd: "/tmp", project: "/tmp")
        let later = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: second) }
        let answer = await first.value
        XCTAssertEqual(answer.login?.outcome, .submitted)
        XCTAssertEqual(answer.login?.code, .notFilled)
        _ = await later.value
    }

    /// The agent hung up: the fill is withdrawn, so nobody's tab takes it afterwards.
    func testHangingUpWithdrawsTheFill() async throws {
        try add("GitHub", url: "https://github.com/login")
        approver.onPresent = { [unowned self] in self.frontTab = nil }
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let waiting = await eventually { self.bridge.agentLogin != nil }
        XCTAssertTrue(waiting)
        task.cancel()
        // At once, not when the fill's 30 seconds run out.
        let gone = await eventually(timeout: 2) { self.bridge.state.pending.pending == nil && self.bridge.agentLogin == nil }
        XCTAssertTrue(gone)
        _ = await task.value
    }

    /// Without Premium the code is not filled and the agent hears why; with Premium it goes in after the form was sent.
    func testTheTwoStepCodeFollowsPremium() async throws {
        try add("GitHub", url: "https://github.com/login", code: true)
        let without = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(without.login?.outcome, .submitted)
        XCTAssertEqual(without.login?.code, .premiumRequired)
        XCTAssertEqual(approver.prompts.last?.rows.first?.note, "Two-step code not filled: needs PasswordPie Premium.")

        premium = true
        reply = "submitted"
        let task = Task { await self.broker.handle(self.login("pp://Web/GitHub"), from: self.caller) }
        let filled = await eventually { self.tabAnswers.filter { $0.contains(#""fill""#) }.count == 2 && self.bridge.agentLogin?.result != nil }
        XCTAssertTrue(filled)
        // The page shows its code field and asks.
        let code = bridge.answer(Data(#"{"type":"code","id":3,"url":"https://github.com/"}"#.utf8), from: .chrome, link: 1)
        XCTAssertTrue(String(decoding: code ?? Data(), as: UTF8.self).contains(#""otp""#))
        let answer = await task.value
        XCTAssertEqual(answer.login?.code, .filled)
        XCTAssertFalse(encoded(answer).contains("otp\":{"), "the code itself never goes to the agent")
    }

    func testWithoutSubmitTheCodeWaitsForTheSite() async throws {
        try add("GitHub", url: "https://github.com/login", code: true)
        premium = true
        reply = "filled"
        let answer = await broker.handle(login("pp://Web/GitHub", submit: false), from: caller)
        XCTAssertEqual(answer.login?.outcome, .filled)
        XCTAssertEqual(answer.login?.code, .waiting)
    }

    func testNoExtensionConnectedIsNoMatchingTab() async throws {
        try add("GitHub", url: "https://github.com/login")
        bridge.connectionsChanged([])
        let answer = await broker.handle(login("pp://Web/GitHub"), from: caller)
        XCTAssertEqual(answer.login?.outcome, .noMatchingTab)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testAURLOffersOnlySharedItemsOfThatSite() async throws {
        try add("GitHub", url: "https://github.com/login")
        try add("GitHub Old", url: "https://github.com/", shared: false)
        try add("GitLab", url: "https://gitlab.com/")
        _ = await broker.handle(login(nil, url: "https://github.com/login"), from: caller)
        XCTAssertEqual(approver.prompts.first?.rows.map(\.title), ["GitHub"])
    }
}

/// The approval window for a login: one account, picked by the owner when there are several; Touch ID names the site.
@MainActor
final class AgentLoginApprovalTests: XCTestCase {
    private func prompt(rows: Int) -> AgentApprovalPrompt {
        let row = AgentApprovalRow(title: "GitHub", folder: "Web", field: "username and password", delivery: .fill, name: nil, tooShortToMask: false, username: "octocat")
        return AgentApprovalPrompt(
            id: UUID(), kind: .login, raw: false, agent: "Claude Code", signature: "signed by Anthropic PBC", agentPID: 4182, startedIn: nil,
            command: nil, program: nil, project: "/tmp", reason: nil, rows: Array(repeating: row, count: rows),
            site: "github.com", browser: "Google Chrome", submit: true
        )
    }

    func testSeveralAccountsStartWithNoneAndThePickIsExactlyOne() async {
        let confirmation = Remembering()
        var decision: AgentApprovalDecision?
        let model = AgentApprovalModel(prompt: prompt(rows: 2), confirmation: confirmation) { decision = $0 }
        XCTAssertEqual(model.title, "Claude Code wants to log in to github.com")
        XCTAssertTrue(model.ticked.isEmpty)
        XCTAssertFalse(model.canAllow, "nothing is picked for the owner")
        model.toggle(0)
        model.toggle(1)
        XCTAssertEqual(model.ticked, [1])
        XCTAssertEqual(model.rowLine(model.prompt.rows[1]), "octocat · username and password, filled in, then the form is sent")
        model.allow()
        let answered = await eventually { decision != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(decision, .allow([1]))
        XCTAssertEqual(confirmation.reasons, ["let Claude Code log in to github.com"])
    }

    func testOneAccountIsPickedAlready() {
        let model = AgentApprovalModel(prompt: prompt(rows: 1), confirmation: Remembering()) { _ in }
        XCTAssertEqual(model.ticked, [0])
        XCTAssertTrue(model.canAllow)
        XCTAssertEqual(model.allowTitle, "Allow Once")
    }
}

@MainActor
private final class Remembering: OwnerConfirmation {
    var reasons: [String] = []
    func confirm(reason: String) async -> Bool {
        reasons.append(reason)
        return true
    }
    func cancel() {}
}

@MainActor
private final class AllowFirst: AgentApprover {
    var prompts: [AgentApprovalPrompt] = []
    var onPresent: (() -> Void)?

    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        prompts.append(prompt)
        onPresent?()
        return .allow([0])
    }

    func withdraw(_ id: UUID) {}
}

private final class Activity: AgentActivityLogging {
    func append(_ record: AgentActivityRecord) {}
}

@MainActor
private func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
#endif
