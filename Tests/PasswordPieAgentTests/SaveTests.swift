import Foundation
import XCTest
@testable import PasswordPieAgent

/// `save` through the broker with a scripted vault, window and store (docs/AGENTS.md, "Saving a secret"). Every value an
/// agent hands over here starts with "PLANTED-", so a test can look for one where it must not be.
@MainActor
final class SaveTests: XCTestCase {
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var saves: FakeSaves!
    private let value = "PLANTED-sk_live_7f3a91"
    private var stripe: AgentItem!

    override func setUp() async throws {
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        saves = FakeSaves(vault: vault)
        stripe = vault.add("Stripe", password: "", fields: ["API key": "PLANTED-old-key"])
        vault.add("Hidden", password: "PLANTED-hidden", shared: false)
    }

    private func broker(grants: AgentGrantStore? = nil) -> VaultBroker {
        let broker = VaultBroker(vault: vault, approver: approver, grants: grants ?? NoAgentGrants(), activity: activity) { true }
        broker.saves = saves
        broker.mac = "this-mac"
        return broker
    }

    private func answerWith(_ decision: AgentApprovalDecision) {
        approver.onPresent = { [unowned self] _ in
            DispatchQueue.main.async { self.approver.answer(decision) }
        }
    }

    /// Everything the agent, the owner's window and Activity were given, as text.
    private func everything(_ answers: [AgentResponse]) -> String {
        let answerText = answers.map { String(decoding: AgentCoding.encode($0), as: UTF8.self) }.joined()
        let promptText = approver.prompts.map { String(describing: $0) }.joined()
        let encoder = JSONEncoder()
        let logText = activity.records.map { String(decoding: (try? encoder.encode($0)) ?? Data(), as: UTF8.self) }.joined()
        return answerText + promptText + logText
    }

    // MARK: A new item, a change

    func testANewItemIsProposedShownWithoutItsValueAndSavedOnSave() async throws {
        answerWith(.allow([0]))
        let answer = await broker().handle(.save("pp://Agents/Cloudflare/API token", value: value, reason: "Deploy token"), from: Callers.make())
        XCTAssertNil(answer.errorCode, answer.detail ?? "")
        XCTAssertEqual(answer.save?.outcome, .saved)
        XCTAssertEqual(answer.save?.change, .newItem)
        let prompt = try XCTUnwrap(approver.prompts.first)
        XCTAssertEqual(prompt.kind, .save)
        XCTAssertEqual(prompt.rows.map(\.title), ["Cloudflare"])
        XCTAssertEqual(prompt.rows.map(\.folder), ["Agents"])
        XCTAssertEqual(prompt.rows.map(\.field), ["field API token"])
        XCTAssertEqual(prompt.rows.map(\.note), ["a new item"])
        XCTAssertEqual(prompt.reason, "Deploy token")
        let made = try XCTUnwrap(vault.agentSharedItems().first { $0.title == "Cloudflare" })
        XCTAssertEqual(vault.values[made.id]?[.custom("API token")], Data(value.utf8), "saved into the item")
        XCTAssertEqual(answer.save?.ref, AgentReference.id(made.id, field: .custom("API token")))
        XCTAssertEqual(saves.kept.map(\.state), [.saved])
        XCTAssertNil(saves.kept[0].value, "a saved proposal keeps no value")
        XCTAssertEqual(activity.records.map(\.outcome), [.saved])
        XCTAssertEqual(activity.records.first?.kind, "save")
        XCTAssertEqual(activity.records.first?.items, ["Agents/Cloudflare › field API token"])
        XCTAssertEqual(activity.records.first?.delivery, ["save: new item"])
        XCTAssertFalse(everything([answer]).contains("PLANTED-sk"), "no value in the answer, the window or Activity")
    }

    func testAChangeToASharedItemSaysSoAndNamesTheItem() async throws {
        answerWith(.allow([0]))
        let answer = await broker().handle(.save("pp://Agents/Stripe/API key", value: value), from: Callers.make())
        XCTAssertEqual(answer.save?.change, .changed)
        XCTAssertEqual(approver.prompts.first?.rows.first?.note, "changes it: the value it has now goes into the item's history")
        XCTAssertEqual(approver.prompts.first?.rows.first?.item, stripe.id)
        XCTAssertEqual(saves.kept.first?.item, stripe.id)
        XCTAssertEqual(vault.values[stripe.id]?[.custom("API key")], Data(value.utf8))
        XCTAssertFalse(everything([answer]).contains("PLANTED"), "neither the new value nor the old one")
    }

    /// The agent hears the same whether the value it hands over is the one the item holds or another: a save is not a way
    /// to test a guess.
    func testTheAnswerDoesNotDependOnWhatTheItemHolds() async throws {
        answerWith(.allow([0]))
        let same = await broker().handle(.save("pp://Agents/Stripe/API key", value: "PLANTED-old-key"), from: Callers.make())
        let other = await broker().handle(.save("pp://Agents/Stripe/API key", value: "PLANTED-guess"), from: Callers.make(session: "agent:101:1"))
        XCTAssertEqual(same.save?.outcome, other.save?.outcome)
        XCTAssertEqual(same.save?.change, other.save?.change)
        XCTAssertEqual(same.save?.ref, other.save?.ref)
        XCTAssertEqual(approver.prompts.count, 2, "the same value is asked about too")
    }

    // MARK: Asking, every time

    func testNoStandingPermissionCoversASave() async throws {
        let grants = GrantEverything()
        answerWith(.allow([0]))
        _ = await broker(grants: grants).handle(.save("pp://Agents/Stripe/API key", value: value), from: Callers.make())
        XCTAssertEqual(approver.prompts.count, 1, "the window opens with a grant that would cover anything")
        XCTAssertEqual(grants.asked, 0, "no grant is consulted")
        XCTAssertEqual(approver.prompts.first?.lasting, .notOffered, "and the window offers none")
    }

    func testNobodyAnsweringLeavesItPendingAndUnreadable() async throws {
        answerWith(.dismissed)
        let broker = broker()
        let answer = await broker.handle(.save("pp://Agents/Cloudflare token", value: value), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(answer.save?.outcome, .pending)
        let id = try XCTUnwrap(answer.save?.proposal)
        XCTAssertEqual(saves.kept.map(\.id), [id])
        XCTAssertEqual(saves.kept.first?.state, .pending)
        XCTAssertEqual(activity.records.map(\.outcome), [.waiting])
        // Not an item until it is saved: the agent cannot use it.
        answerWith(.allow([0]))
        let used = await broker.handle(.use([AgentSecretRequest(name: "T", ref: "pp://Agents/Cloudflare token", delivery: .env)]), from: Callers.make())
        XCTAssertEqual(used.errorCode, .notAvailable)
        let read = await broker.handle(.read("pp://Agents/Cloudflare token"), from: Callers.make())
        XCTAssertEqual(read.errorCode, .notAvailable)
        XCTAssertFalse(everything([answer, used, read]).contains("PLANTED-sk"))
    }

    func testAPendingChangeLeavesTheOldValueInUse() async throws {
        answerWith(.dismissed)
        let broker = broker()
        _ = await broker.handle(.save("pp://Agents/Stripe/API key", value: value), from: Callers.make())
        answerWith(.allow([0]))
        let used = await broker.handle(.use([AgentSecretRequest(name: "K", ref: "pp://Agents/Stripe/API key", delivery: .env)]), from: Callers.make())
        XCTAssertEqual(used.secrets?.first?.value, "PLANTED-old-key")
    }

    func testRejectingIsDeniedAndCountsTowardTheRateLimit() async throws {
        answerWith(.deny)
        let broker = broker()
        let first = await broker.handle(.save("pp://Agents/A", value: value), from: Callers.make())
        XCTAssertEqual(first.errorCode, .denied)
        XCTAssertEqual(saves.kept.first?.state, .rejected)
        XCTAssertNil(saves.kept.first?.value, "a rejected proposal keeps no value")
        XCTAssertEqual(activity.records.last?.outcome, .rejected)
        _ = await broker.handle(.save("pp://Agents/B", value: value), from: Callers.make())
        _ = await broker.handle(.save("pp://Agents/C", value: value), from: Callers.make())
        let blocked = await broker.handle(.save("pp://Agents/D", value: value), from: Callers.make())
        XCTAssertEqual(blocked.errorCode, .tooManyRequests)
        XCTAssertEqual(approver.prompts.count, 3)
        XCTAssertNil(vault.agentSharedItems().first { $0.title == "A" }, "nothing was saved")
    }

    func testLockedWaitsThenAnswersLockedAndKeepsNothing() async throws {
        vault.locked = true
        let answer = await broker().handle(.save("pp://Agents/A", value: value, wait: 0), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .locked)
        XCTAssertTrue(saves.kept.isEmpty)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testAProposalThatCannotBeWrittenIsNotShown() async throws {
        saves.failWrites = true
        let answer = await broker().handle(.save("pp://Agents/A", value: value), from: Callers.make())
        XCTAssertEqual(answer.errorCode, .appUnavailable)
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    func testAtMostTwentyWait() async throws {
        answerWith(.dismissed)
        let broker = broker()
        for index in 0..<AgentProposals.maxPending {
            let answer = await broker.handle(.save("pp://Agents/K\(index)", value: value), from: Callers.make(session: "agent:\(index):1"))
            XCTAssertEqual(answer.save?.outcome, .pending)
        }
        let over = await broker.handle(.save("pp://Agents/Over", value: value), from: Callers.make())
        XCTAssertEqual(over.errorCode, .tooManyRequests)
    }

    // MARK: Where it goes

    func testWhichItemAReferenceNames() {
        func target(_ ref: String) -> String {
            guard let reference = try? AgentReference(ref) else { return "not a reference" }
            switch VaultBroker.saveTarget(reference, in: vault.agentSharedItems()) {
            case .success(.existing(let item, let field)): return "change \(item.title) \(field.label)"
            case .success(.new(let folder, let title, let field)): return "new \((folder + [title]).joined(separator: "/")) \(field.label)"
            case .failure(let failure): return failure.code.rawValue
            }
        }
        XCTAssertEqual(target("pp://Agents/Cloudflare token"), "new Agents/Cloudflare token password")
        XCTAssertEqual(target("pp://Agents/Shop/API key"), "new Agents/Shop field API key")
        XCTAssertEqual(target("pp://Agents/Deep/Shop/password"), "new Agents/Deep/Shop password")
        XCTAssertEqual(target("pp://Shop/username"), "new Shop username")
        XCTAssertEqual(target("pp://Developer/Apple/attachment/AuthKey.p8"), "new Developer/Apple attachment AuthKey.p8")
        XCTAssertEqual(target("pp://Agents/Stripe/API key"), "change Stripe field API key")
        XCTAssertEqual(target("pp://Agents/Stripe/Webhook secret"), "change Stripe field Webhook secret", "a field the item does not have yet")
        XCTAssertEqual(target("pp://Agents/Stripe"), "change Stripe password")
        XCTAssertEqual(target(AgentReference.id(stripe.id, field: .custom("API key"))), "change Stripe field API key")
        XCTAssertEqual(target(AgentReference.id(UUID())), "not-available", "an id never makes a new item")
        vault.add("Stripe", password: "")
        XCTAssertEqual(target("pp://Agents/Stripe/API key"), "ambiguous")
    }

    /// An item that is not shared is not found: a path makes a new item beside it, and an id answers as for one that does
    /// not exist. The agent hears the same for both.
    func testAnUnsharedItemAnswersAsOneThatIsNotThere() async throws {
        answerWith(.dismissed)
        let hidden = try XCTUnwrap(vault.items.first { $0.title == "Hidden" })
        let broker = broker()
        let unshared = await broker.handle(.save(AgentReference.id(hidden.id), value: value), from: Callers.make())
        let missing = await broker.handle(.save(AgentReference.id(UUID()), value: value), from: Callers.make())
        XCTAssertEqual(unshared.errorCode, .notAvailable)
        XCTAssertEqual(missing.errorCode, .notAvailable)
        let byPath = await broker.handle(.save("pp://Agents/Hidden", value: value), from: Callers.make())
        let nowhere = await broker.handle(.save("pp://Agents/Nowhere", value: value), from: Callers.make())
        XCTAssertEqual(byPath.save?.outcome, nowhere.save?.outcome)
        XCTAssertEqual(saves.kept.map(\.change), [.newItem, .newItem])
        XCTAssertNil(saves.kept.first?.item, "never the unshared item")
    }

    func testFieldsASaveCannotWrite() async throws {
        let broker = broker()
        for ref in ["pp://Agents/Stripe/otp", "pp://Agents/Stripe/Title", "pp://Agents/Stripe/Password", "pp://Agents/Stripe/TOTP Seed",
                    "pp://Agents/Stripe/TimeOtp-Secret-Base32", "pp://Agents/Stripe/PasswordPie.PreviousPasswords"] {
            let answer = await broker.handle(.save(ref, value: value), from: Callers.make())
            XCTAssertEqual(answer.errorCode, .usage, ref)
        }
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertTrue(saves.kept.isEmpty)
    }

    func testEmptyTooLargeAndNotTextAreRefusedBeforeAnyoneIsAsked() async throws {
        let broker = broker()
        let empty = await broker.handle(.save("pp://Agents/A", value: ""), from: Callers.make())
        XCTAssertEqual(empty.errorCode, .usage)
        let large = await broker.handle(.save("pp://Agents/A", value: String(repeating: "x", count: AgentConstants.maxSaveBytes + 1)), from: Callers.make())
        XCTAssertEqual(large.errorCode, .usage)
        var binary = AgentRequest.save("pp://Agents/A", value: "")
        binary.setSaved(Data([0xFF, 0xFE, 0x00]))
        let notText = await broker.handle(binary, from: Callers.make())
        XCTAssertEqual(notText.errorCode, .usage)
        var file = AgentRequest.save("pp://Agents/A/attachment/key.bin", value: "")
        file.setSaved(Data([0xFF, 0xFE, 0x00]))
        answerWith(.dismissed)
        let attached = await broker.handle(file, from: Callers.make())
        XCTAssertEqual(attached.save?.outcome, .pending, "an attached file may be any bytes")
        XCTAssertEqual(approver.prompts.count, 1)
    }

    // MARK: Status and the list

    func testStatusListsThisAgentsProposalsOnThisMacOnly() async throws {
        answerWith(.dismissed)
        let broker = broker()
        let mine = await broker.handle(.save("pp://Agents/Mine", value: value), from: Callers.make())
        _ = await broker.handle(.save("pp://Agents/Theirs", value: value), from: Callers.make(session: "agent:300:1", agent: "codex"))
        var elsewhere = saves.kept[0]
        elsewhere.id = "ELSEWHERE"
        elsewhere.mac = "another-mac"
        saves.kept.append(elsewhere)
        let status = await broker.handle(AgentRequest(type: .status, id: 3), from: Callers.make())
        XCTAssertEqual(status.status?.proposals?.map(\.id), [mine.save?.proposal].compactMap { $0 })
        XCTAssertEqual(status.status?.proposals?.first?.state, .pending)
        XCTAssertEqual(status.status?.proposals?.first?.ref, "pp://Agents/Mine")
        XCTAssertFalse(String(decoding: AgentCoding.encode(status), as: UTF8.self).contains("PLANTED"))
    }

    func testSavingAndRejectingFromTheListWriteOneLineEach() async throws {
        answerWith(.dismissed)
        let broker = broker()
        let first = await broker.handle(.save("pp://Agents/Later", value: value, reason: "night job"), from: Callers.make())
        let second = await broker.handle(.save("pp://Agents/Never", value: value), from: Callers.make())
        let saved = await broker.saveProposal(try XCTUnwrap(first.save?.proposal))
        guard case .saved(let item, .newItem) = saved else { return XCTFail("\(saved)") }
        XCTAssertEqual(vault.values[item]?[.password], Data(value.utf8))
        let rejected = await broker.rejectProposal(try XCTUnwrap(second.save?.proposal))
        XCTAssertTrue(rejected)
        XCTAssertEqual(activity.records.map(\.outcome), [.waiting, .waiting, .savedFromList, .rejected])
        XCTAssertEqual(activity.records[2].agent, "Claude Code", "the proposing agent's name")
        XCTAssertEqual(activity.records[2].reason, "night job")
        // Answered once: a second answer does nothing.
        let again = await broker.saveProposal(try XCTUnwrap(first.save?.proposal))
        XCTAssertEqual(again, .failed("It is no longer waiting."))
        XCTAssertEqual(activity.records.count, 4)
        XCTAssertFalse(everything([]).contains("PLANTED-sk"))
    }

    // MARK: What is kept

    func testProposalsRoundTripAndEndAfterThirtyDays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let proposal = AgentProposal(
            id: "ABCD1234", created: now, mac: "m", agent: "a", agentName: "Claude Code", signature: "s", project: "/p", reason: nil, via: nil,
            item: nil, folder: ["Agents"], title: "Stripe", field: .attachment("key.p8"), change: .newItem, value: Data([1, 2, 3])
        )
        var custom: [String: String] = [:]
        AgentProposals([proposal]).write(into: &custom)
        let read = AgentProposals(customData: custom)
        XCTAssertEqual(read.all, [proposal])
        XCTAssertEqual(read.all.first?.fieldValue, .attachment("key.p8"))
        XCTAssertEqual(read.all.first?.bytes, Data([1, 2, 3]))
        XCTAssertEqual(read.current(now: now.addingTimeInterval(29 * 86_400)).count, 1)
        XCTAssertEqual(read.current(now: now.addingTimeInterval(31 * 86_400)).count, 0)
        var ended = read
        ended.forgetEnded(now: now.addingTimeInterval(31 * 86_400))
        ended.write(into: &custom)
        XCTAssertNil(custom[AgentProposals.customDataKey], "nothing left: the key goes")
    }

    /// No message deletes, moves, shares or unshares anything: these are every kind a request can be.
    func testNoRequestKindChangesAnythingButASave() {
        let kinds: [AgentRequestKind] = [.hello, .use, .read, .list, .status, .login, .argument, .check, .save]
        let decoded = ["hello", "use", "read", "list", "status", "login", "argument", "check", "save"].compactMap(AgentRequestKind.init(rawValue:))
        XCTAssertEqual(kinds, decoded)
        for word in ["delete", "move", "share", "unshare", "rename", "grant", "unlock"] {
            XCTAssertNil(AgentRequestKind(rawValue: word), word)
        }
    }
}
