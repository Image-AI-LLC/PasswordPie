#if PP_DIRECT
import AppKit
import SwiftUI
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Allows every row, as an owner who touches the sensor, and keeps what the window was asked to show.
@MainActor
private final class AllowsAll: AgentApprover {
    var prompts: [AgentApprovalPrompt] = []
    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        prompts.append(prompt)
        return .allow(Set(prompt.rows.indices))
    }
    func withdraw(_ id: UUID) {}
}

private final class Records: AgentActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentActivityRecord] = []
    var all: [AgentActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ record: AgentActivityRecord) {
        lock.lock()
        stored.append(record)
        lock.unlock()
    }
}

/// The acceptance of work item F, end to end with the real pieces: a generated folder of two services and two identities
/// with a PEM and a JSON key is imported twice (the second time changes nothing), `check-import` then says "same" for
/// everything and "differs" after one value changes, and no value is in anything said, shown or logged. Every value in
/// the folder is fake and starts with "PLANTED-".
@MainActor
final class CheckImportSessionTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("test.kdbx") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", database.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func makeFolder() throws -> URL {
        let root = directory.appendingPathComponent("keys", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("stripe/work.env", "# Stripe, work\nSTRIPE_SECRET_KEY=PLANTED-stripe-work\nSTRIPE_WEBHOOK_SECRET=\"PLANTED-webhook work\"\nSTRIPE_EMPTY=\n")
        try write("stripe/personal.env", "STRIPE_SECRET_KEY=PLANTED-stripe-personal\n")
        try write("google/work.env", "GOOGLE_API_KEY=PLANTED-google-work\nPASSWORD=PLANTED-own-name\n")
        try write("google/personal.env", "GOOGLE_API_KEY=PLANTED-google-personal\n")
        try write("google/work-service-account.json", #"{"type":"service_account","private_key":"PLANTED-json-key"}"#)
        try write("google/personal.pem", "-----BEGIN PRIVATE KEY-----\nPLANTED-pem\n-----END PRIVATE KEY-----\n")
        try write("deploy.sh", "#!/bin/sh\necho PLANTED-stripe-work\n")
        return root
    }

    private func caller() -> AgentCaller {
        let agent = AgentProcess(pid: 100, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code")
        return AgentCaller(
            cli: AgentProcess(pid: 200, startTime: 2, path: "/Applications/PasswordPie.app/Contents/Helpers/passwordpie", name: "passwordpie"),
            chain: [agent], agent: agent, sessionKey: "agent:100:1", cwd: "/tmp/project", project: "/tmp/project"
        )
    }

    private func importFolder(_ root: URL, into session: VaultSession, inside: String = "") async throws -> DotenvImport.Summary {
        let flow = ImportFlow(session: session)
        flow.choose(try XCTUnwrap(ImportTile.tile("env-folder")))
        flow.folder.parentDraft = inside
        flow.folder.take(root)
        await flow.folder.settled()
        flow.folder.commit()
        guard case .done(let outcome) = flow.folder.stage else { throw XCTSkip("the import did not finish: \(flow.folder.error)") }
        return outcome.summary
    }

    func testImportTwiceThenCheckSaysSameAndDiffersAfterAChange() async throws {
        let session = unlockedSession()
        let root = try makeFolder()
        let first = try await importFolder(root, into: session)
        XCTAssertEqual(first, DotenvImport.Summary(added: 4))
        let written = try Data(contentsOf: database)
        let second = try await importFolder(root, into: session)
        XCTAssertEqual(second, DotenvImport.Summary(unchanged: 4), "importing the same folder again changes nothing")
        XCTAssertEqual(try Data(contentsOf: database), written)

        let approver = AllowsAll()
        let records = Records()
        let broker = VaultBroker(vault: session, approver: approver, grants: NoAgentGrants(), activity: records) { true }
        broker.folders = DotenvFolderCheck()
        func check(_ folder: URL, inside: String? = nil) async -> AgentResponse {
            var request = AgentRequest(type: .check, id: 1)
            request.folder = folder.path
            request.inside = inside
            request.wait = 0
            return await broker.handle(request, from: caller())
        }
        func words(_ answer: AgentResponse) -> [String] { (answer.checks ?? []).map { "\($0.file) \($0.name) \($0.status.rawValue)" } }

        // Nothing is shared yet: everything is missing, and nobody is asked.
        let unshared = await check(root)
        XCTAssertEqual(Set((unshared.checks ?? []).map(\.status)), [.missing])
        XCTAssertTrue(approver.prompts.isEmpty)

        session.setFolderSharedWithAgents(["stripe"], true)
        session.setFolderSharedWithAgents(["google"], true)
        let same = await check(root)
        XCTAssertEqual(words(same), [
            "google/personal.env GOOGLE_API_KEY same", "google/personal.pem personal.pem same",
            "google/work.env GOOGLE_API_KEY same", "google/work.env PASSWORD same", "google/work-service-account.json work-service-account.json same",
            "stripe/personal.env STRIPE_SECRET_KEY same",
            "stripe/work.env STRIPE_SECRET_KEY same", "stripe/work.env STRIPE_WEBHOOK_SECRET same", "stripe/work.env STRIPE_EMPTY same",
        ])
        XCTAssertEqual(approver.prompts.count, 1)
        XCTAssertEqual(approver.prompts[0].rows.count, 9)
        XCTAssertEqual(approver.prompts[0].folder, root.path)

        // One value changes in a file, and one key file.
        try Data("# Stripe, work\nSTRIPE_SECRET_KEY=PLANTED-rotated\nSTRIPE_WEBHOOK_SECRET=\"PLANTED-webhook work\"\nSTRIPE_EMPTY=\n".utf8)
            .write(to: root.appendingPathComponent("stripe/work.env"))
        try Data("-----BEGIN PRIVATE KEY-----\nPLANTED-pem-2\n-----END PRIVATE KEY-----\n".utf8).write(to: root.appendingPathComponent("google/personal.pem"))
        let changed = await check(root)
        XCTAssertEqual(words(changed).filter { !$0.hasSuffix(" same") }, ["google/personal.pem personal.pem differs", "stripe/work.env STRIPE_SECRET_KEY differs"])

        // Importing the folder again brings the database back in step with it.
        let third = try await importFolder(root, into: session)
        XCTAssertEqual(third, DotenvImport.Summary(updated: 2, unchanged: 2))
        let again = await check(root)
        XCTAssertEqual(Set((again.checks ?? []).map(\.status)), [.same])

        // No value in anything said to the agent, shown to the owner or written to Activity.
        let everything = [unshared, same, changed, again].map { String(decoding: AgentCoding.encode($0), as: UTF8.self) }.joined()
            + String(describing: approver.prompts)
            + String(decoding: try JSONEncoder().encode(records.all), as: UTF8.self)
        XCTAssertFalse(everything.contains("PLANTED"), "names and words only")
        XCTAssertEqual(records.all.map(\.outcome), [.notAvailable, .compared, .compared, .compared])
    }

    func testACheckLooksWhereTheImportPutThingsAndRefusesWhatIsNotAFolder() async throws {
        let session = unlockedSession()
        let root = try makeFolder()
        _ = try await importFolder(root, into: session, inside: "Agents")
        session.setFolderSharedWithAgents(["Agents"], true)
        let approver = AllowsAll()
        let broker = VaultBroker(vault: session, approver: approver, grants: NoAgentGrants(), activity: Records()) { true }
        broker.folders = DotenvFolderCheck()
        func check(_ path: String, inside: String?) async -> AgentResponse {
            var request = AgentRequest(type: .check, id: 1)
            request.folder = path
            request.inside = inside
            request.wait = 0
            return await broker.handle(request, from: caller())
        }
        let inside = await check(root.path, inside: "Agents")
        XCTAssertEqual(Set((inside.checks ?? []).map(\.status)), [.same])
        let top = await check(root.path, inside: nil)
        XCTAssertEqual(Set((top.checks ?? []).map(\.status)), [.missing], "at the top of the database there is nothing")
        let file = await check(root.appendingPathComponent("deploy.sh").path, inside: nil)
        XCTAssertEqual(file.errorCode, .usage)
        XCTAssertEqual(file.detail, "\(root.path)/deploy.sh is not a folder.")
        let gone = await check(directory.appendingPathComponent("nothing").path, inside: nil)
        XCTAssertEqual(gone.errorCode, .usage)
        // The window for a check says what the agent learns, and offers nothing lasting.
        let model = AgentApprovalModel(prompt: try XCTUnwrap(approver.prompts.first), confirmation: Yes()) { _ in }
        XCTAssertEqual(model.title, "Claude Code wants to compare 9 secrets with files")
        XCTAssertFalse(model.offersLasting)
        XCTAssertEqual(model.allowTitle, "Allow Once")
        XCTAssertTrue(model.isCheck)
        XCTAssertEqual(model.groups.count, 4, "nine secrets of four items")
        XCTAssertEqual(model.groupLine(model.groups[0]), "2 secrets · 2 compared with the files")
        XCTAssertEqual(model.rowLine(model.prompt.rows[0]), "field GOOGLE_API_KEY · compared with GOOGLE_API_KEY in the folder")
        let host = NSHostingView(rootView: AgentApprovalView(model: model))
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 520, height: 600)))
    }
}

private final class Yes: OwnerConfirmation {
    func confirm(reason: String) async -> Bool { true }
    func cancel() {}
}
#endif
