import Foundation
import XCTest
@testable import PasswordPieAgent
@testable import PasswordPieCLI

/// A folder as a reader found it, scripted.
private final class ScriptedFolders: AgentFolderReader, @unchecked Sendable {
    var subjects: [AgentCheckSubject] = []
    var problem: AgentFolderProblem?
    private(set) var asked: [(folder: String, inside: [String])] = []

    func subjects(folder: String, inside: [String]) throws -> [AgentCheckSubject] {
        asked.append((folder, inside))
        if let problem { throw problem }
        return subjects.map { subject in
            var placed = subject
            placed.folder = inside + subject.folder
            return placed
        }
    }
}

/// `check`: a folder of dotenv files compared with the vault inside the app (docs/AGENTS.md, "Checking a folder against
/// the vault"). Every value here starts with "PLANTED-", so a test can look for one where it must not be.
@MainActor
final class CheckImportTests: XCTestCase {
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var folders: ScriptedFolders!
    private let pem = Data("-----BEGIN PRIVATE KEY-----\nPLANTED-pem\n-----END PRIVATE KEY-----\n".utf8)

    override func setUp() async throws {
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        folders = ScriptedFolders()
        // What an import of the folder left, shared with agents.
        vault.add("work", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "PLANTED-stripe-work", "STRIPE_ACCOUNT": "PLANTED-acct"])
        vault.add("personal", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "PLANTED-stripe-personal"])
        vault.add("work", folder: ["google"], password: "", fields: ["GOOGLE_API_KEY": "PLANTED-google"], attachments: ["work.pem": pem])
        vault.add("work", folder: ["private"], password: "", fields: ["PRIVATE_KEY": "PLANTED-unshared"], shared: false)
        folders.subjects = [
            subject("stripe/work.env", "STRIPE_SECRET_KEY", ["stripe"], "work", "PLANTED-stripe-work"),
            subject("stripe/work.env", "STRIPE_ACCOUNT", ["stripe"], "work", "PLANTED-acct"),
            subject("stripe/personal.env", "STRIPE_SECRET_KEY", ["stripe"], "personal", "PLANTED-stripe-personal"),
            subject("google/work.env", "GOOGLE_API_KEY", ["google"], "work", "PLANTED-google"),
            AgentCheckSubject(file: "google/work.pem", name: "work.pem", folder: ["google"], title: "work", field: .attachment("work.pem"), expected: pem),
        ]
    }

    private func subject(_ file: String, _ name: String, _ folder: [String], _ title: String, _ value: String) -> AgentCheckSubject {
        AgentCheckSubject(file: file, name: name, folder: folder, title: title, field: .custom(name), expected: Data(value.utf8))
    }

    private func broker(grants: AgentGrantStore? = nil) -> VaultBroker {
        let broker = VaultBroker(vault: vault, approver: approver, grants: grants ?? NoAgentGrants(), activity: activity) { true }
        broker.folders = folders
        return broker
    }

    private func request(_ folder: String = "/Users/me/keys", inside: String? = nil) -> AgentRequest {
        var request = AgentRequest(type: .check, id: 9)
        request.folder = folder
        request.inside = inside
        request.wait = 0
        request.reason = "Before deleting the files"
        return request
    }

    private func statuses(_ answer: AgentResponse) -> [String] {
        (answer.checks ?? []).map { "\($0.file) \($0.name) \($0.status.rawValue)" }
    }

    private func allowAll() {
        approver.onPresent = { [unowned self] prompt in
            let all = Set(prompt.rows.indices)
            DispatchQueue.main.async { self.approver.answer(.allow(all)) }
        }
    }

    // MARK: The acceptance

    func testEverythingIsTheSameAfterAnImportAndDiffersAfterOneValueChanges() async throws {
        allowAll()
        let answer = await broker().handle(request(), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(statuses(answer), [
            "stripe/work.env STRIPE_SECRET_KEY same", "stripe/work.env STRIPE_ACCOUNT same", "stripe/personal.env STRIPE_SECRET_KEY same",
            "google/work.env GOOGLE_API_KEY same", "google/work.pem work.pem same",
        ])
        // One value changes in the folder, and one key file.
        folders.subjects[1].expected = Data("PLANTED-acct-changed".utf8)
        folders.subjects[4].expected = Data("PLANTED-another-key".utf8)
        let changed = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual(statuses(changed), [
            "stripe/work.env STRIPE_SECRET_KEY same", "stripe/work.env STRIPE_ACCOUNT differs", "stripe/personal.env STRIPE_SECRET_KEY same",
            "google/work.env GOOGLE_API_KEY same", "google/work.pem work.pem differs",
        ])
        XCTAssertEqual(folders.asked.map(\.folder), ["/Users/me/keys", "/Users/me/keys"])
    }

    func testNoValueIsInTheAnswerTheWindowOrTheLog() async throws {
        allowAll()
        folders.subjects[0].expected = Data("PLANTED-not-the-same".utf8)
        let answer = await broker().handle(request(), from: Callers.make())
        let everything = String(decoding: AgentCoding.encode(answer), as: UTF8.self)
            + String(describing: approver.prompts)
            + String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(everything.contains("PLANTED"), everything)
        XCTAssertNil(answer.secrets, "a check hands nothing out")
        let record = try XCTUnwrap(activity.records.last)
        XCTAssertEqual(record.kind, "check")
        XCTAssertEqual(record.outcome, .compared)
        XCTAssertEqual(record.command, "/Users/me/keys", "the line names the folder")
        XCTAssertEqual(record.items.first, "stripe/work › field STRIPE_SECRET_KEY")
        XCTAssertEqual(record.items.last, "google/work › attachment work.pem")
        XCTAssertEqual(record.delivery, ["compare"])
        XCTAssertEqual(record.reason, "Before deleting the files")
    }

    // MARK: The window

    func testTheOwnerIsAskedEveryTimeAndNeverOfferedALastingChoice() async throws {
        allowAll()
        let grants = GrantEverything()
        _ = await broker(grants: grants).handle(request(), from: Callers.make())
        _ = await broker(grants: grants).handle(request(), from: Callers.make())
        XCTAssertEqual(approver.prompts.count, 2, "a standing permission never covers a check")
        XCTAssertEqual(grants.asked, 0)
        let prompt = try XCTUnwrap(approver.prompts.first)
        XCTAssertEqual(prompt.kind, .check)
        XCTAssertEqual(prompt.lasting, .notOffered)
        XCTAssertFalse(prompt.raw)
        XCTAssertEqual(prompt.folder, "/Users/me/keys")
        XCTAssertNil(prompt.command)
        XCTAssertEqual(prompt.rows.map(\.delivery), Array(repeating: .compare, count: 5))
        XCTAssertEqual(prompt.rows.map(\.field), ["field STRIPE_SECRET_KEY", "field STRIPE_ACCOUNT", "field STRIPE_SECRET_KEY", "field GOOGLE_API_KEY", "attachment work.pem"])
        XCTAssertEqual(Set(prompt.rows.compactMap(\.item)).count, 3, "the rows of one item go together in the window")
        XCTAssertEqual(prompt.reason, "Before deleting the files")
    }

    func testDenyAnswersDeniedComparesNothingAndCountsTowardTheLimit() async {
        approver.script = [.deny, .deny, .deny]
        let broker = broker()
        for _ in 0..<3 {
            let answer = await broker.handle(request(), from: Callers.make())
            XCTAssertEqual(answer.errorCode, .denied)
            XCTAssertNil(answer.checks)
        }
        XCTAssertEqual(vault.secretReads, 0, "nothing is read before the owner allows")
        let blocked = await broker.handle(request(), from: Callers.make())
        XCTAssertEqual(blocked.errorCode, .tooManyRequests)
        XCTAssertEqual(folders.asked.count, 3, "a blocked session's folder is not even read")
        XCTAssertEqual(approver.prompts.count, 3)
        XCTAssertEqual(activity.records.map(\.outcome), [.denied, .denied, .denied, .tooManyRequests])
    }

    func testAnUntickedSecretIsNotComparedAndSaysSo() async {
        approver.script = [.allow([0, 3])]
        let answer = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual((answer.checks ?? []).map(\.status), [.same, .notChecked, .notChecked, .same, .notChecked])
        XCTAssertEqual(vault.secretReads, 2)
        XCTAssertEqual(activity.records.last?.items, ["stripe/work › field STRIPE_SECRET_KEY", "google/work › field GOOGLE_API_KEY"])
    }

    func testNobodyAnsweringTimesOutAndALockedVaultSaysLocked() async {
        let slow = broker()
        slow.approvalSeconds = 0.05
        let timedOut = await slow.handle(request(), from: Callers.make())
        XCTAssertEqual(timedOut.errorCode, .timeout)
        vault.locked = true
        let locked = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual(locked.errorCode, .locked)
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testALockedVaultIsWaitedForAndTheLockScreenSaysHowMany() async {
        allowAll()
        vault.locked = true
        let broker = broker()
        var lines: [String?] = []
        broker.onWaitingChanged = { lines.append(AgentWaiting.lockScreenLine($0)) }
        var waiting = request()
        waiting.wait = 30
        let task = Task { await broker.handle(waiting, from: Callers.make()) }
        for _ in 0..<400 where broker.waiting.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(lines.last, "Claude Code is waiting for 5 secrets.")
        XCTAssertTrue(approver.prompts.isEmpty, "nobody is asked while it is locked")
        vault.locked = false
        broker.vaultStateChanged()
        let answer = await task.value
        XCTAssertEqual(Set((answer.checks ?? []).map(\.status)), [.same])
    }

    // MARK: What is not there

    /// Not shared and not there are one answer, so a check cannot be used to find out what the owner keeps to themselves.
    func testAnUnsharedItemAndOneThatDoesNotExistAreBothMissing() async {
        allowAll()
        folders.subjects += [
            subject("private/work.env", "PRIVATE_KEY", ["private"], "work", "PLANTED-unshared"),
            subject("nowhere/work.env", "NOWHERE_KEY", ["nowhere"], "work", "PLANTED-nowhere"),
            subject("stripe/work.env", "STRIPE_NEW", ["stripe"], "work", "PLANTED-new"),
        ]
        let answer = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual((answer.checks ?? []).suffix(3).map(\.status), [.missing, .missing, .missing])
        XCTAssertEqual(approver.prompts.first?.rows.count, 5, "only what is shared is in the window")
        XCTAssertFalse(String(describing: approver.prompts).contains("PRIVATE_KEY"))
    }

    func testWithNothingSharedThereIsNoWindowAndEverythingIsMissing() async {
        vault.shared = []
        let answer = await broker().handle(request(), from: Callers.make())
        XCTAssertNil(answer.errorCode)
        XCTAssertEqual(Set((answer.checks ?? []).map(\.status)), [.missing])
        XCTAssertTrue(approver.prompts.isEmpty)
        XCTAssertEqual(vault.secretReads, 0)
        XCTAssertEqual(activity.records.last?.outcome, .notAvailable)
    }

    func testAnEmptyValueIsTheSameAsAFieldWithNothingInItAndTwoItemsInOnePlaceAreAmbiguous() async {
        allowAll()
        // The app does not list a field with nothing in it, and answers nothing for it.
        folders.subjects = [subject("stripe/work.env", "EMPTY", ["stripe"], "work", ""), subject("stripe/work.env", "STRIPE_ACCOUNT", ["stripe"], "work", "")]
        let empty = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual((empty.checks ?? []).map(\.status), [.same, .differs])
        vault.add("work", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "PLANTED-twin"])
        folders.subjects = [subject("stripe/work.env", "STRIPE_SECRET_KEY", ["stripe"], "work", "PLANTED-stripe-work")]
        let twins = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual((twins.checks ?? []).map(\.status), [.ambiguous])
    }

    func testInsideIsWhereTheImportPutEverything() async {
        allowAll()
        vault.add("work", folder: ["Agents", "stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "PLANTED-inside"])
        folders.subjects = [subject("stripe/work.env", "STRIPE_SECRET_KEY", ["stripe"], "work", "PLANTED-inside")]
        let answer = await broker().handle(request(inside: " Agents "), from: Callers.make())
        XCTAssertEqual((answer.checks ?? []).map(\.status), [.same])
        XCTAssertEqual(folders.asked.last?.inside, ["Agents"])
        XCTAssertEqual(approver.prompts.last?.rows.first?.folder, "Agents/stripe")
    }

    // MARK: Mistakes

    func testMistakesAreUsageErrorsAndAskNobody() async {
        for bad in ["relative/keys", ""] {
            let answer = await broker().handle(request(bad), from: Callers.make())
            XCTAssertEqual(answer.errorCode, .usage, bad)
        }
        folders.problem = AgentFolderProblem("/Users/me/keys is not a folder.")
        let unreadable = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual(unreadable.errorCode, .usage)
        XCTAssertEqual(unreadable.detail, "/Users/me/keys is not a folder.")
        folders.problem = nil
        folders.subjects = []
        let empty = await broker().handle(request(), from: Callers.make())
        XCTAssertEqual(empty.detail, "No .env files or key files in /Users/me/keys.")
        let without = VaultBroker(vault: vault, approver: approver, grants: NoAgentGrants(), activity: activity) { true }
        let noReader = await without.handle(request(), from: Callers.make())
        XCTAssertEqual(noReader.errorCode, .usage)
        XCTAssertTrue(approver.prompts.isEmpty)
        // "compare" is not a way to hand a value to a command.
        let use = await broker().handle(.use([AgentSecretRequest(name: "T", ref: "pp://stripe/work/STRIPE_ACCOUNT", delivery: .compare)]), from: Callers.make())
        XCTAssertEqual(use.errorCode, .usage)
    }

    // MARK: The tool's words

    func testTheReportNamesFilesNamesAndWords() {
        let lines = [
            AgentCheckLine(file: "stripe/work.env", name: "STRIPE_SECRET_KEY", status: .same),
            AgentCheckLine(file: "stripe/work.env", name: "STRIPE_ACCOUNT", status: .differs),
            AgentCheckLine(file: "google/work.env", name: "GOOGLE_API_KEY", status: .missing),
            AgentCheckLine(file: "google/work.pem", name: "work.pem", status: .notChecked),
        ]
        XCTAssertEqual(CheckImport.report(lines), """
        stripe/work.env
          STRIPE_SECRET_KEY  same
          STRIPE_ACCOUNT     differs
        google/work.env
          GOOGLE_API_KEY     missing
        google/work.pem
          work.pem           not checked
        1 same, 1 differs, 1 missing, 1 not checked.

        """)
        XCTAssertEqual(CheckImport.summary([AgentCheckLine(file: "a", name: "A", status: .same), AgentCheckLine(file: "a", name: "B", status: .same)]), "2 same.")
        let failure = CheckImport.failureLine(lines)
        XCTAssertTrue(failure.hasPrefix("PasswordPie: the folder and PasswordPie do not hold the same. Do not delete the files yet."))
        XCTAssertTrue(failure.contains("not imported, or not shared with agents"))
        XCTAssertTrue(failure.hasSuffix(AgentConstants.pasteWarning))
    }

    func testArguments() throws {
        XCTAssertEqual(try Arguments.parse(["check-import", "keys"]), .checkImport(CheckImportOptions(folder: "keys")))
        XCTAssertEqual(
            try Arguments.parse(["check-import", "--inside", "Agents", "keys", "--json", "--wait=5", "--reason", "Before deleting"]),
            .checkImport(CheckImportOptions(folder: "keys", inside: "Agents", reason: "Before deleting", wait: 5, json: true))
        )
        XCTAssertThrowsError(try Arguments.parse(["check-import"]))
        XCTAssertThrowsError(try Arguments.parse(["check-import", "a", "b"]))
        XCTAssertThrowsError(try Arguments.parse(["check-import", "a", "--frob"]))
        XCTAssertTrue(Arguments.usageText.contains("passwordpie check-import FOLDER [--inside FOLDER] [--reason TEXT] [--wait SECONDS] [--json]"))
        XCTAssertEqual(AgentConstants.checkFailedExitCode, 78)
        XCTAssertFalse(AgentErrorCode.allCases.map(\.exitCode).contains(78), "its own code")
    }
}
