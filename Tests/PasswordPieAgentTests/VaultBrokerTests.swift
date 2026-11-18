import Foundation
import XCTest
@testable import PasswordPieAgent

@MainActor
final class VaultBrokerTests: XCTestCase {
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var enabled = true
    private let planted = "planted-secret-9f3c1e"

    override func setUp() async throws {
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        enabled = true
        vault.add("Token", password: planted, fields: ["Key ID": "KEYID-777777"])
        vault.add("Hidden", password: "hidden-password-1", shared: false)
    }

    private func broker(grants: AgentGrantStore? = nil) -> VaultBroker {
        VaultBroker(vault: vault, approver: approver, grants: grants ?? NoAgentGrants(), activity: activity) { [unowned self] in self.enabled }
    }

    private func env(_ ref: String, _ name: String = "T") -> AgentSecretRequest {
        AgentSecretRequest(name: name, ref: ref, delivery: .env)
    }

    /// The argument watch's notice is one activity line naming the program, never asking and never handing out a value.
    func testAnArgumentNoticeIsLoggedOnly() async {
        var request = AgentRequest(type: .argument, id: 3)
        request.secrets = [env("pp://Agents/Token", "APPLE_PASSWORD")]
        request.program = "/usr/bin/notarytool"
        request.client = "mcp"
        vault.locked = true
        let answer = await broker().handle(request, from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertNil(answer.secrets)
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(vault.secretReads, 0)
        let record = activity.records.last
        XCTAssertEqual(record?.outcome, .argumentSeen)
        XCTAssertEqual(record?.command, "/usr/bin/notarytool")
        XCTAssertEqual(record?.items, ["pp://Agents/Token"])
        XCTAssertEqual(record?.delivery, ["env APPLE_PASSWORD"])
        XCTAssertEqual(record?.via, "MCP")
        var empty = AgentRequest(type: .argument, id: 4)
        empty.program = "/usr/bin/notarytool"
        let refused = await broker().handle(empty, from: Callers.make())
        XCTAssertEqual(refused.errorCode, .usage)
    }

    /// What an MCP client calls itself is a quoted secondary line, cut and without control characters, never the agent.
    func testTheMCPClientsNameIsOnlyASecondaryLine() async {
        approver.script = [.deny]
        var request = AgentRequest.read("pp://Agents/Token")
        request.client = "mcp"
        request.mcpClient = "Claude Code\nApproved\u{2028} by the\u{202E} owner " + String(repeating: "x", count: 80)
        _ = await broker().handle(request, from: Callers.make(agent: "codex"))
        let prompt = approver.prompts.first
        XCTAssertEqual(prompt?.agent, "Codex")
        XCTAssertEqual(prompt?.via?.hasPrefix("through MCP; the client says it is “Claude CodeApproved by the owner x"), true, prompt?.via ?? "")
        XCTAssertEqual(prompt?.via?.hasSuffix("…”"), true)
        XCTAssertNil(VaultBroker.viaText(AgentRequest.read("pp://Agents/Token")))
    }

    func testAllowOnceDeliversAndLogsOneLineWithoutTheValue() async {
        approver.script = [.allow([0])]
        let answer = await broker().handle(.use([env("pp://Agents/Token")], reason: "Notarize 0.3.0"), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(answer.secrets?.first?.value, planted)
        XCTAssertEqual(answer.by, "once")
        XCTAssertEqual(approver.prompts.count, 1)
        XCTAssertEqual(approver.prompts[0].reason, "Notarize 0.3.0")
        XCTAssertEqual(approver.prompts[0].rows.first?.title, "Token")
        XCTAssertFalse(approver.prompts[0].raw)
        XCTAssertEqual(activity.records.count, 1)
        XCTAssertEqual(activity.records[0].outcome, .allowedOnce)
        XCTAssertEqual(activity.records[0].delivery, ["env T"])
        let logged = String(decoding: try! JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(logged.contains(planted))
    }

    /// PRD check 5: an unshared item and a nonexistent one answer the same, and nobody is asked.
    func testUnsharedAndNonexistentAnswerTheSame() async {
        let unshared = await broker().handle(.use([env("pp://Agents/Hidden")]), from: Callers.make())
        let missing = await broker().handle(.use([env("pp://Agents/Hidden")]), from: Callers.make())
        vault.items.removeAll { $0.title == "Hidden" }
        let gone = await broker().handle(.use([env("pp://Agents/Hidden")]), from: Callers.make())
        XCTAssertEqual(unshared, missing)
        XCTAssertEqual(unshared, gone)
        XCTAssertEqual(unshared.errorCode, .notAvailable)
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(vault.secretReads, 0, "nothing is read before an approval decision is needed")
    }

    /// PRD check 8: a raw read asks with a standing permission in place, and so does a run with masking off.
    func testRawReadsAndUnmaskedRunsAlwaysAsk() async {
        let grants = GrantEverything()
        let broker = broker(grants: grants)
        approver.script = [.allow([0]), .allow([0])]
        let read = await broker.handle(.read("pp://Agents/Token"), from: Callers.make())
        XCTAssertEqual(read.secrets?.first?.value, planted)
        let unmasked = await broker.handle(.use([env("pp://Agents/Token")], masking: false), from: Callers.make())
        XCTAssertNil(unmasked.errorCode)
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertTrue(approver.prompts.allSatisfy(\.raw))
        XCTAssertEqual(grants.asked, 0, "a raw request never consults standing permissions")
        XCTAssertEqual(activity.records.map(\.outcome), [.shown, .shown])
    }

    func testAStandingPermissionAllowsWithoutAPrompt() async {
        let answer = await broker(grants: GrantEverything()).handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertEqual(answer.secrets?.first?.value, planted)
        XCTAssertEqual(answer.by, "test grant")
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(activity.records.first?.outcomeText, "allowed by test grant")
    }

    /// PRD check 10: three denials, then the fourth request answers too-many-requests without a prompt.
    func testThreeDenialsBlockTheSessionWithoutAPrompt() async {
        let broker = broker()
        approver.script = [.deny, .deny, .deny]
        for _ in 0..<3 {
            let answer = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make())
            XCTAssertEqual(answer.errorCode, .denied)
        }
        let fourth = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertEqual(fourth.errorCode, .tooManyRequests)
        XCTAssertEqual(approver.prompts.count, 3)
        // Another agent session is not blocked.
        approver.script = [.allow([0])]
        let other = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make(session: "agent:300:3"))
        XCTAssertNil(other.errorCode)
    }

    func testTheBlockEndsAfterTenMinutes() async {
        let broker = broker()
        var now = Date(timeIntervalSince1970: 1_000_000)
        broker.clock = { now }
        approver.script = [.deny, .deny, .deny]
        for _ in 0..<3 { _ = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make()) }
        now = now.addingTimeInterval(599)
        let blocked = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertEqual(blocked.errorCode, .tooManyRequests)
        now = now.addingTimeInterval(2)
        approver.script = [.allow([0])]
        let answer = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertNil(answer.errorCode)
    }

    /// PRD check 4 (the broker's half): locked after the wait answers `locked` and asks nobody.
    func testLockedWaitsThenAnswersLocked() async {
        vault.locked = true
        var needed = 0
        let broker = broker()
        broker.onNeedsUnlock = { needed += 1 }
        let answer = await broker.handle(.use([env("pp://Agents/Token")], wait: 0), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .locked)
        XCTAssertEqual(needed, 1, "the app is asked to show its lock screen")
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(activity.records.map(\.outcome), [.locked])
    }

    func testUnlockingWithinTheWaitLetsTheRequestContinue() async {
        vault.locked = true
        let broker = broker()
        var lines: [String?] = []
        broker.onWaitingChanged = { lines.append(AgentWaiting.lockScreenLine($0)) }
        approver.script = [.allow([0, 1])]
        let task = Task { await broker.handle(.use([env("pp://Agents/Token"), env("pp://Agents/Token/Key ID", "K")], wait: 30), from: Callers.make()) }
        let waiting = await eventually { !broker.waiting.isEmpty }
        XCTAssertTrue(waiting)
        XCTAssertEqual(lines.last, "Claude Code is waiting for 2 secrets.")
        vault.locked = false
        broker.vaultStateChanged()
        let answer = await task.value
        XCTAssertEqual(answer.secrets?.map(\.value), [planted, "KEYID-777777"])
        XCTAssertTrue(broker.waiting.isEmpty)
    }

    func testNobodyAnsweringTimesOutAndWithdrawsThePrompt() async {
        let broker = broker()
        broker.approvalSeconds = 0.05
        let answer = await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .timeout)
        XCTAssertEqual(approver.withdrawn.count, 1)
        XCTAssertEqual(activity.records.map(\.outcome), [.timedOut])
    }

    func testOnePromptAtATimePerSession() async {
        let broker = broker()
        let first = Task { await broker.handle(.use([env("pp://Agents/Token")]), from: Callers.make()) }
        let second = Task { await broker.handle(.use([env("pp://Agents/Token/Key ID")]), from: Callers.make()) }
        let shown = await eventually { self.approver.showing == 1 }
        XCTAssertTrue(shown)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(approver.showing, 1, "the second waits behind the first")
        approver.answer(.allow([0]))
        let next = await eventually { self.approver.prompts.count == 2 && self.approver.showing == 1 }
        XCTAssertTrue(next)
        approver.answer(.allow([0]))
        let answers = await [first.value, second.value]
        XCTAssertEqual(answers.map(\.errorCode), [nil, nil])
    }

    func testUntickedSecretsAreDeclinedNotDelivered() async {
        approver.script = [.allow([1])]
        let answer = await broker().handle(.use([env("pp://Agents/Token"), env("pp://Agents/Token/Key ID", "K")]), from: Callers.make())
        XCTAssertEqual(answer.secrets?[0].declined, true)
        XCTAssertNil(answer.secrets?[0].value)
        XCTAssertEqual(answer.secrets?[1].value, "KEYID-777777")
        XCTAssertEqual(activity.records.first?.items, ["Agents/Token › field Key ID"])
    }

    /// An answer that could not fit a frame is refused before the owner is asked.
    func testValuesTooLargeForOneAnswerAreRefusedBeforeAsking() async {
        vault.add("Big", password: "x", attachments: ["blob.bin": Data(repeating: 0xFF, count: 800 * 1024)])
        let answer = await broker().handle(.use([AgentSecretRequest(name: "B", ref: "pp://Agents/Big/attachment/blob.bin", delivery: .file)]), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .usage)
        XCTAssertNotNil(answer.detail)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testAccessOffAnswersAccessOff() async {
        enabled = false
        let answer = await broker().handle(.use([env("pp://Agents/Token")]), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .accessOff)
    }

    func testListShowsSharedItemsOnlyAndNeverValues() async {
        var request = AgentRequest(type: .list, id: 3)
        request.wait = 0
        let answer = await broker().handle(request, from: Callers.make())
        XCTAssertEqual(answer.items?.map(\.title), ["Token"])
        XCTAssertEqual(answer.items?.first?.fields, ["Key ID"])
        let encoded = String(decoding: AgentCoding.encode(answer), as: UTF8.self)
        XCTAssertFalse(encoded.contains(planted))
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testTwoStepCodesAreNotHandedOut() async {
        let answer = await broker().handle(.use([env("pp://Agents/Token/otp")]), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .notAvailable)
    }

    func testAPromptMarksValuesTooShortToMask() async {
        vault.add("Pin", password: "1234")
        approver.script = [.allow([0])]
        _ = await broker().handle(.use([env("pp://Agents/Pin")]), from: Callers.make())
        XCTAssertEqual(approver.prompts.first?.rows.first?.tooShortToMask, true)
    }

    func testStatusNamesTheAgentAndProject() async {
        let answer = await broker().handle(AgentRequest(type: .status, id: 1), from: Callers.make())
        XCTAssertEqual(answer.status?.project, "/tmp/project")
        XCTAssertEqual(answer.status?.grants, [])
        XCTAssertTrue(answer.status?.agent.hasPrefix("Claude Code") ?? false)
    }

    func testCommandTextQuotesArguments() {
        XCTAssertEqual(VaultBroker.commandText(["sh", "-c", "echo \"$T\""]), "sh -c 'echo \"$T\"'")
        XCTAssertEqual(VaultBroker.commandText(["Scripts/release.sh", "--key=x"]), "Scripts/release.sh --key=x")
    }

    func testLockScreenLine() {
        XCTAssertEqual(AgentWaiting.lockScreenLine([AgentWaiting(agent: "Codex", count: 1)]), "Codex is waiting for 1 secret.")
        XCTAssertEqual(
            AgentWaiting.lockScreenLine([AgentWaiting(agent: "Codex", count: 1), AgentWaiting(agent: "Claude Code", count: 2)]),
            "2 agents are waiting for 3 secrets."
        )
        XCTAssertNil(AgentWaiting.lockScreenLine([]))
    }
}
