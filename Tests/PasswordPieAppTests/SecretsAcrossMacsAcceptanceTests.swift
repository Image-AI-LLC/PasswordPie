#if PP_DIRECT
import AppKit
import Combine
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The owner's acceptance list for secrets on more than one Mac, run with the real pieces (the session, the merge, the
/// importer, the broker, agent access and the proposals list) and two copies of one agents database standing in for the
/// two Macs: `macbook/Agents.kdbx`, where the owner sits, and `m2/Agents.kdbx`, where agents work alone. The sync tool is
/// this test copying a file from one folder to the other. Each test names the item of the list it covers; what only the
/// owner can do (Touch ID, Screen Sharing, a real sync tool, the real folder) is in docs/MIGRATING_DOTENV.md.
///
/// Every secret is one planted value (`PASSWORDPIE_ACCEPTANCE_VALUE`, else a random one), and every test ends by looking
/// for it in every file the two Macs wrote: only the encrypted databases may hold it. With `PASSWORDPIE_ACCEPTANCE_KEEP`
/// set to a folder, the files are left there for a search of the whole home folder.
@MainActor
final class SecretsAcrossMacsAcceptanceTests: XCTestCase {
    private var directory: URL!
    private var socketFolder: URL!
    private var cancellables: Set<AnyCancellable> = []
    private var macbookPrompts: ScriptedMergePrompts!
    private var m2Prompts: ScriptedMergePrompts!
    private let planted = ProcessInfo.processInfo.environment["PASSWORDPIE_ACCEPTANCE_VALUE"]
        ?? "PLANTED-\(UUID().uuidString)"
    private var macbookFile: URL { directory.appendingPathComponent("macbook/Agents.kdbx") }
    private var m2File: URL { directory.appendingPathComponent("m2/Agents.kdbx") }

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["PASSWORDPIE_ACCEPTANCE_KEEP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        directory = root.appendingPathComponent("across-macs-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for folder in ["macbook", "m2"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        socketFolder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ppx-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        for url in [macbookFile, m2File] { UserDefaults.standard.set(true, forKey: "touchIDDeclined.\(url.path)") }
        UserDefaults.standard.removeObject(forKey: VaultSession.agentDatabaseKey)
        UserDefaults.standard.removeObject(forKey: VaultSession.agentKeepUnlockedKey)
        macbookPrompts = ScriptedMergePrompts()
        m2Prompts = ScriptedMergePrompts()
    }

    override func tearDownWithError() throws {
        cancellables = []
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        for url in [macbookFile, m2File] {
            for key in ["touchIDDeclined", "touchIDEnabled", "touchIDUnlockedAt", "touchIDStale"] {
                UserDefaults.standard.removeObject(forKey: "\(key).\(url.path)")
            }
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("mergeSeenChanges.") || key.hasPrefix("mergeHandledCopies.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: VaultSession.agentDatabaseKey)
        UserDefaults.standard.removeObject(forKey: VaultSession.agentKeepUnlockedKey)
        if ProcessInfo.processInfo.environment["PASSWORDPIE_ACCEPTANCE_KEEP"] == nil {
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.removeItem(at: socketFolder)
    }

    // MARK: The two Macs

    private func entry(_ title: String, password: String = "", field: (String, String)? = nil) -> VaultEntry {
        var entry = VaultEntry(groupPath: ["Agents"])
        entry.title = title
        entry.password = password
        if let field { entry.setValue(field.1, for: field.0, protected: true) }
        return entry
    }

    /// The MacBook Pro makes the agents database (Agents/Stripe, Agents/Cloudflare, Agents/Resend, the folder shared with
    /// agents), and the file is copied once to the M2, which unlocks its copy. Both are unlocked when this returns.
    private func twoMacs() async throws -> (macbook: VaultSession, m2: VaultSession) {
        setenv("PASSWORDPIE_DB", macbookFile.path, 1)
        let macbook = VaultSession(writes: .inline)
        macbook.mergePrompts = macbookPrompts
        macbook.restore()
        macbook.passwordDraft = "pw"
        macbook.confirmDraft = "pw"
        macbook.unlock()
        macbook.saveEditing(entry("Stripe", field: ("API key", "stripe-first")))
        macbook.saveEditing(entry("Cloudflare", password: "cloudflare-first"))
        macbook.saveEditing(entry("Resend", password: "resend-first"))
        macbook.setFolderSharedWithAgents(["Agents"], true)
        try FileManager.default.copyItem(at: macbookFile, to: m2File)

        setenv("PASSWORDPIE_DB", m2File.path, 1)
        let m2 = VaultSession(writes: .inline)
        m2.mergePrompts = m2Prompts
        m2.restore()
        m2.passwordDraft = "pw"
        m2.unlock()
        try await until({ !m2.locked && !m2.unlocking }, "the M2 unlocks its copy")
        XCTAssertEqual(titles(m2), ["Cloudflare", "Resend", "Stripe"])
        return (macbook, m2)
    }

    /// The sync tool: the file of one Mac replaces the other's, as Dropbox and iCloud Drive do, and the other Mac's
    /// watcher tells its session.
    private func carry(from source: URL, to destination: URL, then session: VaultSession) throws {
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        session.filesChangedOnDisk()
    }

    private func titles(_ session: VaultSession) -> [String] {
        session.entries.filter { !$0.trashed }.map(\.title).sorted()
    }

    private func live(_ title: String, in session: VaultSession) -> VaultEntry? {
        session.entries.first { $0.title == title && !$0.trashed }
    }

    private func onDisk(_ url: URL) throws -> Vault {
        try KDBX.load(data: Data(contentsOf: url), password: "pw", keyFile: nil)
    }

    private func change(_ title: String, in session: VaultSession, _ edit: @escaping (inout VaultEntry) -> Void) throws {
        let id = try XCTUnwrap(live(title, in: session)?.id)
        var written = false
        session.changeEntry(id, { entry in
            edit(&entry)
            return true
        }, then: { written = $0 })
        XCTAssertTrue(written, "\(title) is saved")
    }

    private struct Timeout: Error {}

    private func until(_ condition: () -> Bool, _ what: String, seconds: Double = 15) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out: \(what)")
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Agent access on one Mac, wired as the app wires it, with a window that `choose` answers. `shown` counts windows.
    private func access(_ session: VaultSession, mac: String, choose: @escaping (AgentApprovalModel) -> Void) throws -> (AgentAccess, () -> Int) {
        let suite = "across-macs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var shown = 0
        let approver = AgentApprovalController(confirmation: Confirms(), lasting: AgentLastingOptions(
            hasPremium: { true }, showPremium: {}, lastLength: { .days7 }, rememberLength: { _ in }
        ), show: { model in
            shown += 1
            DispatchQueue.main.async { choose(model) }
            return {}
        })
        let access = AgentAccess(
            session: session, defaults: defaults, socketPath: socketFolder.appendingPathComponent("\(mac).sock").path,
            logURL: session.databaseURL.deletingLastPathComponent().appendingPathComponent("agent-activity.jsonl"),
            approver: approver, confirmation: Confirms(), hasPremium: { true }, mac: mac,
            linkFolder: directory.appendingPathComponent("\(mac)-bin")
        )
        access.setEnabled(true)
        access.grants.sessionAlive = { _ in true }
        session.agentStateChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak access] in access?.agentStateChanged() }
            .store(in: &cancellables)
        addTeardownBlock { @MainActor in access.stop() }
        return (access, { shown })
    }

    /// A project on the M2 with a script that a night job runs.
    private func project(_ name: String) throws -> URL {
        let project = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho nightly\n".write(to: project.appendingPathComponent("Scripts/nightly.sh"), atomically: true, encoding: .utf8)
        return project
    }

    private func caller(in project: URL, agent pid: Int32 = 10) -> AgentCaller {
        let agent = AgentProcess(pid: pid, startTime: 1, path: "/usr/local/bin/claude", name: "Claude Code")
        return AgentCaller(cli: AgentProcess(pid: pid + 1, startTime: 2, path: "/x/passwordpie", name: "passwordpie"), chain: [agent],
                           agent: agent, sessionKey: "agent:\(pid):1", cwd: project.path, project: project.path)
    }

    private func use(_ secrets: [AgentSecretRequest], in project: URL, environment: [String] = []) -> AgentRequest {
        var request = AgentRequest(type: .use, id: 1)
        request.secrets = secrets
        request.program = project.appendingPathComponent("Scripts/nightly.sh").path
        request.argv = ["Scripts/nightly.sh"]
        request.masking = true
        request.wait = 0
        request.environment = environment
        return request
    }

    /// Item 4 of the list, for what these Macs wrote: no file in either Mac's folder, Activity or the usage file holds
    /// the planted value, and neither do this process's preferences. Only the databases do, encrypted.
    private func assertPlantedValueOnlyEncrypted(file: StaticString = #filePath, line: UInt = #line) throws {
        let needle = Data(planted.utf8)
        var found: [String] = []
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let data = try? Data(contentsOf: url), data.range(of: needle) != nil { found.append(url.lastPathComponent) }
        }
        XCTAssertEqual(found, [], "a planted value in plain text", file: file, line: line)
        XCTAssertFalse(String(describing: UserDefaults.standard.dictionaryRepresentation()).contains(planted), file: file, line: line)
    }

    // MARK: 1. Different items, offline from each other

    /// Offline from each other, a key is added on the M2 and a different item changed on the MacBook Pro. After the file
    /// travels, both Macs have both, and nothing was asked.
    func testOneDifferentItemsChangedOfflineAreOnBothMacsAndNothingIsAsked() async throws {
        let (macbook, m2) = try await twoMacs()
        m2.saveEditing(entry("RunPod", field: ("API key", planted)))
        try change("Cloudflare", in: macbook) { $0.password = "cloudflare-from-the-macbook" }

        // The M2's file reaches the MacBook Pro first: it lacks the MacBook Pro's change, so that Mac merges and writes.
        try carry(from: m2File, to: macbookFile, then: macbook)
        // The merged file goes back to the M2, which has nothing the file lacks.
        try carry(from: macbookFile, to: m2File, then: m2)

        for (mac, session) in [("MacBook Pro", macbook), ("M2", m2)] {
            XCTAssertEqual(titles(session), ["Cloudflare", "Resend", "RunPod", "Stripe"], mac)
            XCTAssertEqual(live("RunPod", in: session)?.value(for: "API key"), planted, mac)
            XCTAssertEqual(live("Cloudflare", in: session)?.password, "cloudflare-from-the-macbook", mac)
            XCTAssertNil(session.mergeNotice, "\(mac): different items, nothing to say")
            XCTAssertFalse(session.hasItemsChangedOnBoth, mac)
        }
        XCTAssertEqual(macbookPrompts.shown.count + macbookPrompts.asked.count + m2Prompts.shown.count + m2Prompts.asked.count, 0,
                       "nobody was asked")
        XCTAssertEqual(try Data(contentsOf: m2File), try Data(contentsOf: macbookFile), "the M2 left the merged file as it came")
        // The new key is shared with agents on both, by its folder: sharing travels with the item.
        for session in [macbook, m2] {
            XCTAssertTrue(session.agentSharedItems().contains { $0.title == "RunPod" })
        }
        try assertPlantedValueOnlyEncrypted()
    }

    // MARK: 2. The same item on both

    /// The same item changed on both Macs (here through a sync tool's conflict copy, as Syncthing leaves one). The newer
    /// value is current on both, the older is in its history, and the list of items changed on both Macs names it, on
    /// each Mac.
    func testTwoTheSameItemChangedOnBothNewerIsCurrentOlderInHistoryAndListedOnBoth() async throws {
        let (macbook, m2) = try await twoMacs()
        try change("Cloudflare", in: macbook) { $0.password = "older, from the macbook" }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try change("Cloudflare", in: m2) { [planted] in $0.password = planted }

        // Syncthing on the MacBook Pro keeps its own file and puts the M2's beside it as a conflict copy.
        let copy = directory.appendingPathComponent("macbook/Agents.sync-conflict-20261120-031800-M2M2M2M.kdbx")
        try FileManager.default.copyItem(at: m2File, to: copy)
        macbook.lookForCopies()
        try carry(from: macbookFile, to: m2File, then: m2)

        for (mac, session) in [("MacBook Pro", macbook), ("M2", m2)] {
            XCTAssertEqual(live("Cloudflare", in: session)?.password, planted, "\(mac): the newer change is the item")
            let id = try XCTUnwrap(live("Cloudflare", in: session)?.id)
            let history = try onDisk(session.databaseURL).versions(of: id).compactMap { $0.fields.first { $0.key == "Password" }?.value }
            XCTAssertTrue(history.contains("older, from the macbook"), "\(mac): the older one is in the history")
            XCTAssertEqual(session.itemsChangedOnBoth().map(\.title), ["Cloudflare"], "\(mac): listed")
            XCTAssertEqual(session.mergeNotice?.summary, "1 item was changed on both Macs", mac)
        }
        XCTAssertEqual(macbookPrompts.asked.count + m2Prompts.asked.count, 0, "a sync tool's copy is merged without asking")
        try assertPlantedValueOnlyEncrypted()
    }

    // MARK: 3. A deletion

    /// An item deleted on one Mac is gone on the other, also for agents.
    func testThreeAnItemDeletedOnOneMacIsGoneOnTheOther() async throws {
        let (macbook, m2) = try await twoMacs()
        try change("Resend", in: macbook) { $0.trashed = true }
        try carry(from: macbookFile, to: m2File, then: m2)

        XCTAssertEqual(titles(m2), ["Cloudflare", "Stripe"])
        XCTAssertFalse(m2.agentSharedItems().contains { $0.title == "Resend" }, "agents on the M2 no longer reach it")
        XCTAssertNil(m2.mergeNotice)

        // On both it is in the Recycle Bin, where it can be put back. Deleted for good by another KeePass app (its
        // DeletedObjects list) is KDBXMergeTests' and KeePassXCMergeTests'.
        XCTAssertTrue(macbook.entries.contains { $0.title == "Resend" && $0.trashed })
        XCTAssertTrue(m2.entries.contains { $0.title == "Resend" && $0.trashed })
        try assertPlantedValueOnlyEncrypted()
    }

    // MARK: 5. A night job on the M2

    /// On the M2 only the agents database is open and kept unlocked. A job under a standing permission given on the M2 runs
    /// with nobody there; one the permission does not cover opens the approval window there (approved over Screen
    /// Sharing: docs/MIGRATING_DOTENV.md). A standing permission given on the MacBook Pro travels in the file but does not
    /// count on the M2, and the M2's survives the merge.
    func testFiveANightJobOnTheM2RunsUnderAStandingPermissionGivenThere() async throws {
        let (macbook, m2) = try await twoMacs()
        m2.agentAccessOn = true
        m2.setKeepAgentDatabaseUnlocked(true)
        XCTAssertTrue(m2.keepsAgentDatabaseUnlocked, "the agents database alone: kept unlocked")

        let nightly = try project("nightly")
        let token = [AgentSecretRequest(name: "TOKEN", ref: "pp://Agents/Cloudflare", delivery: .env)]
        let (m2Access, m2Shown) = try access(m2, mac: "m2") { $0.allow(for: .days7) }
        let first = await m2Access.broker.handle(use(token, in: nightly), from: caller(in: nightly))
        XCTAssertEqual(first.secrets?.first?.value, "cloudflare-first")
        XCTAssertEqual(m2Shown(), 1, "the first use is approved at the M2")
        let night = await m2Access.broker.handle(use(token, in: nightly), from: caller(in: nightly))
        XCTAssertEqual(night.secrets?.first?.value, "cloudflare-first")
        XCTAssertEqual(night.by, "7 days, this project")
        XCTAssertEqual(m2Shown(), 1, "at night: no window")

        // Another secret, not covered: the window opens on the M2.
        let other = [AgentSecretRequest(name: "RESEND", ref: "pp://Agents/Resend", delivery: .env)]
        _ = await m2Access.broker.handle(use(other, in: nightly), from: caller(in: nightly))
        XCTAssertEqual(m2Shown(), 2, "a use no permission covers asks")

        // The MacBook Pro gets the M2's file: the grant is there, but it is the M2's, so the MacBook Pro asks.
        await m2.savesSettled()
        try carry(from: m2File, to: macbookFile, then: macbook)
        let (macbookAccess, macbookShown) = try access(macbook, mac: "macbook") { $0.allow(for: .days7) }
        _ = await macbookAccess.broker.handle(use(token, in: nightly), from: caller(in: nightly))
        XCTAssertEqual(macbookShown(), 1, "a grant counts only on the Mac it was given on")
        await macbook.savesSettled()

        // Both files now hold a grant each; merged back on the M2, the M2's still lets the job through.
        try carry(from: macbookFile, to: m2File, then: m2)
        let grants = AgentGrants(customData: try onDisk(m2File).customData).all
        XCTAssertEqual(grants.filter { $0.mac == "m2" }.count, 2, "the M2's two grants are kept")
        XCTAssertEqual(grants.filter { $0.mac == "macbook" }.count, 1, "and the MacBook Pro's")
        let after = await m2Access.broker.handle(use(token, in: nightly), from: caller(in: nightly))
        XCTAssertEqual(after.by, "7 days, this project")
        XCTAssertEqual(m2Shown(), 2)
        XCTAssertTrue(m2.keepsAgentDatabaseUnlocked, "reading the MacBook Pro's file did not lock it")
        try assertPlantedValueOnlyEncrypted()
    }

    // MARK: 6. A key made on the M2

    /// An agent on the M2 makes a key and saves it while nobody is there: it waits, in the file. The file travels to the
    /// MacBook Pro, where the owner saves it from the list; back on the M2 it is an item agents can use, and the value
    /// was in no answer, window or Activity line.
    func testSixAKeySavedOnTheM2WaitsAndIsSavedOnTheMacBookPro() async throws {
        let (macbook, m2) = try await twoMacs()
        let shop = try project("shop")
        // Nobody is at the M2 to save it: the window is left (Decide Later). A use, later, is allowed.
        let (m2Access, _) = try access(m2, mac: "m2") { $0.isSave ? $0.later() : $0.allow() }
        var save = AgentRequest(type: .save, id: 1)
        save.secrets = [AgentSecretRequest(name: nil, ref: "pp://Agents/OpenAI/API key", delivery: .save)]
        save.setSaved(Data(planted.utf8))
        save.wait = 0
        let answer = await m2Access.broker.handle(save, from: caller(in: shop))
        XCTAssertEqual(answer.save?.outcome, .pending, answer.detail ?? "")
        let id = try XCTUnwrap(answer.save?.proposal)

        // Not usable on the M2 before the owner saved it.
        let early = await m2Access.broker.handle(use([AgentSecretRequest(name: "K", ref: "pp://Agents/OpenAI/API key", delivery: .env)], in: shop),
                                                 from: caller(in: shop))
        XCTAssertEqual(early.code, AgentErrorCode.notAvailable.rawValue)

        await m2.savesSettled()
        try carry(from: m2File, to: macbookFile, then: macbook)
        let (macbookAccess, _) = try access(macbook, mac: "macbook") { $0.allow() }
        macbookAccess.refreshSaves()
        XCTAssertEqual(macbookAccess.waitingSaves.map(\.id), [id], "the M2's proposal waits on the MacBook Pro")
        let waiting = try XCTUnwrap(macbookAccess.waitingSaves.first)
        XCTAssertEqual(macbookAccess.macText(waiting), "on another Mac")
        await macbookAccess.saveProposal(waiting)
        XCTAssertTrue(macbookAccess.waitingSaves.isEmpty)
        await macbook.savesSettled()
        XCTAssertEqual(live("OpenAI", in: macbook)?.value(for: "API key"), planted)

        try carry(from: macbookFile, to: m2File, then: m2)
        XCTAssertEqual(live("OpenAI", in: m2)?.value(for: "API key"), planted, "after approval it is on both Macs")
        let file = try onDisk(m2File)
        XCTAssertEqual(AgentProposals(customData: file.customData).all.map(\.state), [.saved])
        XCTAssertFalse(file.customData.values.joined().contains(planted), "the saved proposal holds no value")
        var status = AgentRequest(type: .status, id: 2)
        status.wait = 0
        let said = await m2Access.broker.handle(status, from: caller(in: shop))
        XCTAssertEqual(said.status?.proposals?.map(\.state), [.saved], "the agent on the M2 sees it was saved")
        let now = await m2Access.broker.handle(use([AgentSecretRequest(name: "K", ref: "pp://Agents/OpenAI/API key", delivery: .env)], in: shop),
                                               from: caller(in: shop))
        XCTAssertEqual(now.secrets?.first?.value, planted)

        let spoken = [answer, early, said].map { String(decoding: AgentCoding.encode($0), as: UTF8.self) }.joined()
        XCTAssertFalse(spoken.contains(planted), "the agent's transcript never holds the value")
        try assertPlantedValueOnlyEncrypted()
    }

    // MARK: 7. The migration

    /// A generated folder in place of the owner's dotenv folder: imported on the MacBook Pro, checked, the project's
    /// `.env.pp` resolved there and, after the file travels, on the M2; then the plaintext is deleted and only the
    /// encrypted databases hold the value (item 4).
    func testSevenAnImportedFolderRunsFromEnvPPOnBothMacsAndThenNoPlaintextIsLeft() async throws {
        let (macbook, m2) = try await twoMacs()
        let configs = directory.appendingPathComponent("configs", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = configs.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("stripe/work.env", "# Stripe, work account\nSTRIPE_SECRET_KEY=\(planted)\nSTRIPE_WEBHOOK_SECRET=whsec-fixture\n")
        try write("stripe/personal.env", "STRIPE_SECRET_KEY=sk-personal-fixture\n")
        try write("google/work.env", "GOOGLE_API_KEY=google-work-fixture\nGOOGLE_APPLICATION_CREDENTIALS=/fixture/work-service-account.json\n")
        try write("google/work-service-account.json", #"{"type":"service_account","private_key":"fixture-json-key"}"#)
        try write("deploy.sh", "#!/bin/sh\necho deploy\n")

        // Import, with the folder shared with agents.
        let flow = ImportFlow(session: macbook)
        flow.choose(try XCTUnwrap(ImportTile.tile("env-folder")))
        flow.folder.parentDraft = "Agents"
        flow.folder.take(configs)
        await flow.folder.settled()
        flow.folder.commit()
        guard case .done(let outcome) = flow.folder.stage else { return XCTFail("the import did not finish: \(flow.folder.error)") }
        XCTAssertEqual(outcome.summary.added, 3)
        XCTAssertEqual(try String(contentsOf: configs.appendingPathComponent("stripe/work.env"), encoding: .utf8).contains(planted), true,
                       "the source files are not changed")

        // check-import: everything the same.
        let shop = try project("shop")
        let (macbookAccess, _) = try access(macbook, mac: "macbook") { $0.allow() }
        macbookAccess.broker.folders = DotenvFolderCheck()
        var check = AgentRequest(type: .check, id: 1)
        check.folder = configs.path
        check.inside = "Agents"
        check.wait = 0
        let checked = await macbookAccess.broker.handle(check, from: caller(in: shop))
        XCTAssertFalse((checked.checks ?? []).isEmpty, checked.detail ?? "")
        XCTAssertEqual(Set((checked.checks ?? []).map(\.status)), [.same])

        // The project's .env.pp names only what it reads, and a second file adds what differs per Mac.
        let envPP = """
        STRIPE_SECRET_KEY=pp://Agents/stripe/work/STRIPE_SECRET_KEY
        GOOGLE_API_KEY=pp://Agents/google/work/GOOGLE_API_KEY
        GOOGLE_APPLICATION_CREDENTIALS=file:pp://Agents/google/work/attachment/work-service-account.json
        """
        try envPP.write(to: shop.appendingPathComponent(".env.pp"), atomically: true, encoding: .utf8)
        let secrets = try AgentEnvFile.parse(envPP).compactMap { line -> AgentSecretRequest? in
            guard case .secret(let name, let ref, let delivery) = line else { return nil }
            return AgentSecretRequest(name: name, ref: ref, delivery: delivery)
        }
        let here = await macbookAccess.broker.handle(use(secrets, in: shop), from: caller(in: shop))
        XCTAssertEqual(here.secrets?.map(\.name), ["STRIPE_SECRET_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"], here.detail ?? "")
        XCTAssertEqual(here.secrets?.first?.value, planted)

        // The file travels; the same .env.pp works on the M2.
        await macbook.savesSettled()
        try carry(from: macbookFile, to: m2File, then: m2)
        let (m2Access, _) = try access(m2, mac: "m2") { $0.allow() }
        let there = await m2Access.broker.handle(use(secrets, in: shop), from: caller(in: shop))
        XCTAssertEqual(there.secrets?.first?.value, planted, there.detail ?? "")
        XCTAssertEqual(there.secrets?.last.flatMap { $0.value.map { Data($0.utf8) } ?? $0.base64.flatMap { Data(base64Encoded: $0) } }, Data(#"{"type":"service_account","private_key":"fixture-json-key"}"#.utf8))

        // Only then is the plaintext deleted, and only the encrypted databases hold the value.
        try FileManager.default.removeItem(at: configs)
        try assertPlantedValueOnlyEncrypted()
        XCTAssertTrue(try String(contentsOf: shop.appendingPathComponent(".env.pp"), encoding: .utf8).contains("pp://"))
    }
}

@MainActor
private final class Confirms: OwnerConfirmation {
    func confirm(reason: String) async -> Bool { true }
    func cancel() {}
}
#endif
