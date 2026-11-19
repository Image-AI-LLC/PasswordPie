import Darwin
import Foundation
import XCTest
@testable import PasswordPieAgent
import PasswordPieBridge

/// The real `passwordpie` binary against an in-process server with a scripted vault and approver. The server's peer check
/// is off here (the test binary is not signed by our team); `AgentSocketPeerTests` covers it. The tool reads
/// `PASSWORDPIE_AGENT_SOCKET` only in debug builds.
@MainActor
final class CommandLineToolTests: XCTestCase {
    private var folder: URL!
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var broker: VaultBroker!
    private var server: AgentServer!
    private let planted = "planted-secret-4b7d2a"
    private let plantedID = "KEYID-PLANTED-551"

    private var socketPath: String { folder.appendingPathComponent("a.sock").path }
    private var temporary: URL { folder.appendingPathComponent("tmp", isDirectory: true) }

    override func setUp() async throws {
        folder = try shortTemporaryFolder("ppcli")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        vault.add("Token", password: planted, fields: ["Key ID": plantedID], attachments: [
            "AuthKey.p8": Data("-----BEGIN PRIVATE KEY-----planted".utf8),
            "multi.pem": Data("-----BEGIN KEY-----\nline-two-planted\n-----END KEY-----\n".utf8),
        ])
        vault.add("Hidden", password: "hidden-password-2", shared: false)
        try startServer(grants: NoAgentGrants())
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func startServer(grants: AgentGrantStore) throws {
        server?.stop()
        let broker = VaultBroker(vault: vault, approver: approver, grants: grants, activity: activity) { true }
        self.broker = broker
        server = AgentServer(handler: { request, caller in await broker.handle(request, from: caller) }, peerCheck: { _ in true })
        try server.start(path: socketPath)
    }

    private var tool: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("PasswordPieCLI")
    }

    private struct Ran {
        var code: Int32
        var out: String
        var err: String
    }

    /// Variables the tool itself was started with, as an agent's shell may have them.
    private var inherited: [String: String] = [:]

    private func environment() -> [String: String] {
        // The test runner's own loader variables (DYLD_…) would make every run ask, as they should for an agent.
        var environment = ProcessInfo.processInfo.environment.filter { !AgentProgramRule.isCodeLoading($0.key) }.merging(inherited) { _, new in new }
        environment["PASSWORDPIE_AGENT_SOCKET"] = socketPath
        environment["TMPDIR"] = temporary.path + "/"
        return environment
    }

    private func start(_ arguments: [String], executable: URL? = nil) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = executable ?? tool
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = folder
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return (process, out, err)
    }

    /// Runs the tool to the end without blocking the main actor, where the broker answers.
    private func run(_ arguments: [String], executable: URL? = nil) async throws -> Ran {
        let (process, out, err) = try start(arguments, executable: executable)
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Ran(
                    code: process.terminationStatus,
                    out: String(decoding: stdout, as: UTF8.self),
                    err: String(decoding: stderr, as: UTF8.self)
                ))
            }
        }
    }

    private func allowEverything() {
        approver.onPresent = { [unowned self] prompt in
            let all = Set(prompt.rows.indices)
            DispatchQueue.main.async { self.approver.answer(.allow(all)) }
        }
    }

    // MARK: PRD phase 1 checks

    /// Check 1: the value reaches the command and is concealed in its output; the command's exit code is the tool's.
    func testRunMasksTheValueAndPassesTheExitCode() async throws {
        allowEverything()
        let echoed = try await run(["run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "echo \"$T\""])
        XCTAssertEqual(echoed.code, 0, echoed.err)
        XCTAssertEqual(echoed.out, "\(AgentConstants.concealed)\n")
        let exited = try await run(["run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "exit 3"])
        XCTAssertEqual(exited.code, 3)
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertEqual(approver.prompts[0].command, "sh -c 'echo \"$T\"'")
    }

    func testTheCommandGetsTheExactValue() async throws {
        allowEverything()
        let ran = try await run(["run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "[ \"$T\" = '\(planted)' ] && echo same"])
        XCTAssertEqual(ran.out, "same\n")
    }

    /// Check 2: while the command runs, no command line on the Mac holds the value.
    func testNoValueOnAnyCommandLine() async throws {
        allowEverything()
        let marker = folder.appendingPathComponent("started")
        let (process, _, _) = try start(["run", "--env", "T=pp://Agents/Token", "--stdin", "pp://Agents/Token/Key ID", "--",
                                         "sh", "-c", "touch '\(marker.path)'; sleep 3"])
        defer { process.terminate() }
        let started = await eventually(timeout: 10) { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(started)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "args"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        XCTAssertTrue(listing.contains("sleep 3"), "the command is running")
        XCTAssertFalse(listing.contains(planted))
        XCTAssertFalse(listing.contains(plantedID))
    }

    /// Check 3: the file is 0600 in a 0700 folder during the run and gone after a normal exit.
    func testFilesAreOwnerOnlyAndRemovedAfterTheRun() async throws {
        allowEverything()
        let record = folder.appendingPathComponent("path")
        let ran = try await run(["run", "--file", "K=pp://Agents/Token/attachment/AuthKey.p8", "--",
                                 "sh", "-c", "echo \"$K\" > '\(record.path)'; stat -f %Lp \"$K\"; stat -f %Lp \"$(dirname \"$K\")\"; cat \"$K\""])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertEqual(ran.out, "600\n700\n\(AgentConstants.concealed)")
        let path = try String(contentsOf: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasSuffix("/K.p8"), path)
        XCTAssertTrue(path.hasPrefix(temporary.path), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    /// Check 3: gone after the command is killed with SIGKILL.
    func testFilesAreRemovedWhenTheCommandIsKilled() async throws {
        allowEverything()
        let record = folder.appendingPathComponent("path")
        let ran = try await run(["run", "--file", "K=pp://Agents/Token", "--", "sh", "-c", "echo \"$K\" > '\(record.path)'; kill -9 $$"])
        XCTAssertEqual(ran.code, 128 + SIGKILL)
        let path = try String(contentsOf: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Check 3: when the tool itself is killed, the next run removes what it left.
    func testTheNextRunRemovesWhatAKilledToolLeft() async throws {
        allowEverything()
        let record = folder.appendingPathComponent("path")
        let shell = folder.appendingPathComponent("shell")
        let (process, _, _) = try start(["run", "--file", "K=pp://Agents/Token", "--",
                                         "sh", "-c", "echo $$ > '\(shell.path)'; echo \"$K\" > '\(record.path)'; sleep 30"])
        let wrote = await eventually(timeout: 10) { FileManager.default.fileExists(atPath: record.path) && FileManager.default.fileExists(atPath: shell.path) }
        XCTAssertTrue(wrote)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        if let pid = Int32(try String(contentsOf: shell, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        let path = try String(contentsOf: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let left = (path as NSString).deletingLastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: left), "the killed tool could not clean up")
        let next = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        XCTAssertEqual(next.code, 0, next.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left))
    }

    /// Check 4: locked after --wait exits 69 and the command never starts.
    func testLockedExitsAfterTheWaitWithoutStartingTheCommand() async throws {
        vault.locked = true
        let marker = folder.appendingPathComponent("ran")
        let ran = try await run(["run", "--wait", "1", "--env", "T=pp://Agents/Token", "--", "touch", marker.path])
        XCTAssertEqual(ran.code, 69)
        XCTAssertTrue(ran.err.contains("locked"), ran.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// Check 4: unlocking within the wait lets the request continue.
    func testUnlockingWithinTheWaitContinues() async throws {
        vault.locked = true
        allowEverything()
        let marker = folder.appendingPathComponent("ran")
        let running = Task { try await self.run(["run", "--wait", "20", "--env", "T=pp://Agents/Token", "--", "touch", marker.path]) }
        let waiting = await eventually(timeout: 10) { !self.broker.waiting.isEmpty }
        XCTAssertTrue(waiting)
        vault.locked = false
        broker.vaultStateChanged()
        let ran = try await running.value
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Check 5: an unshared item and a nonexistent one give byte-identical output and exit 65.
    func testUnsharedAndNonexistentAreIdentical() async throws {
        let unshared = try await run(["run", "--env", "T=pp://Agents/Hidden", "--", "true"])
        vault.items.removeAll { $0.title == "Hidden" }
        let missing = try await run(["run", "--env", "T=pp://Agents/Hidden", "--", "true"])
        XCTAssertEqual(unshared.code, 65)
        XCTAssertEqual(missing.code, 65)
        XCTAssertEqual(Data(unshared.err.utf8), Data(missing.err.utf8))
        XCTAssertEqual(unshared.out, missing.out)
        XCTAssertTrue(unshared.err.hasSuffix(AgentConstants.pasteWarning + "\n"))
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// Check 8: a raw read asks even with a standing permission in place, and so does --no-masking.
    func testReadAndNoMaskingAskEvenWithAStandingPermission() async throws {
        try startServer(grants: GrantEverything())
        allowEverything()
        let read = try await run(["read", "pp://Agents/Token"])
        XCTAssertEqual(read.code, 0, read.err)
        XCTAssertEqual(read.out, planted + "\n")
        let unmasked = try await run(["run", "--no-masking", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "echo \"$T\""])
        XCTAssertEqual(unmasked.out, planted + "\n", "masking off means raw")
        let granted = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        XCTAssertEqual(granted.code, 0)
        XCTAssertEqual(approver.prompts.count, 2, "only the read and the unmasked run asked")
        XCTAssertTrue(approver.prompts.allSatisfy(\.raw))
    }

    /// Check 10: three denials, then the fourth request is refused without a prompt.
    func testThreeDenialsThenTooManyRequests() async throws {
        approver.script = [.deny, .deny, .deny]
        for _ in 0..<3 {
            let denied = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
            XCTAssertEqual(denied.code, 67)
        }
        let fourth = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        XCTAssertEqual(fourth.code, 72)
        XCTAssertEqual(approver.prompts.count, 3)
    }

    /// Phase 2, the argument watch: a value on the command line of a process under the run is reported on standard
    /// error and in Activity within a second (the planted process lives one second), without the value. The same value
    /// in the environment, where it belongs, is not reported.
    func testArgumentWatchWarnsAboutAValueOnACommandLine() async throws {
        allowEverything()
        let quiet = try await run(["run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "/bin/sh -c 'sleep 1; true'; true"])
        XCTAssertEqual(quiet.code, 0)
        XCTAssertFalse(quiet.err.contains("appeared on the command line"), quiet.err)
        let planted = try await run(["run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "/bin/sh -c 'sleep 1; true' planted --password \"$T\"; true"])
        XCTAssertEqual(planted.code, 0)
        XCTAssertTrue(planted.err.contains("PasswordPie: the value of T (pp://Agents/Token) appeared on the command line of "), planted.err)
        XCTAssertFalse((planted.out + planted.err).contains(self.planted))
        let seen = await eventually { self.activity.records.contains { $0.outcome == .argumentSeen } }
        XCTAssertTrue(seen)
        XCTAssertEqual(activity.records.filter { $0.outcome == .argumentSeen }.count, 1)
        let record = try XCTUnwrap(activity.records.first { $0.outcome == .argumentSeen })
        XCTAssertEqual(record.items, ["pp://Agents/Token"])
        XCTAssertNil(record.via)
        let everything = String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(everything.contains(self.planted))
    }

    /// Check 11: one activity line per request, and no planted value in the activity or in the tool's own output.
    func testActivityAndToolOutputHoldNoValue() async throws {
        approver.script = [.allow([0, 1]), .deny]
        let allowed = try await run(["run", "--env", "T=pp://Agents/Token", "--file", "K=pp://Agents/Token/Key ID", "--", "true"])
        let denied = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        vault.locked = true
        let locked = try await run(["run", "--wait", "0", "--env", "T=pp://Agents/Token", "--", "true"])
        vault.locked = false
        let missing = try await run(["run", "--env", "T=pp://Agents/Nope", "--", "true"])
        XCTAssertEqual([allowed.code, denied.code, locked.code, missing.code], [0, 67, 69, 65])
        XCTAssertEqual(activity.records.map(\.outcome), [.allowedOnce, .denied, .locked, .notAvailable])
        let everything = String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
            + [allowed, denied, locked, missing].map { $0.out + $0.err }.joined()
        XCTAssertFalse(everything.contains(planted))
        XCTAssertFalse(everything.contains(plantedID))
        XCTAssertTrue(activity.records[0].chain.contains { $0.pid == getpid() }, "the walked chain includes the test runner")
    }

    /// The agent kills the tool while the prompt is up: the prompt goes away and nothing is handed out.
    func testAKilledToolWithdrawsItsPrompt() async throws {
        let (process, _, _) = try start(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        let shown = await eventually(timeout: 10) { self.approver.showing == 1 }
        XCTAssertTrue(shown)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        let withdrawn = await eventually(timeout: 5) { self.approver.withdrawn.count == 1 }
        XCTAssertTrue(withdrawn)
        XCTAssertEqual(activity.records.map(\.outcome), [.timedOut])
        XCTAssertEqual(vault.secretReads, 2, "only the size check and the prompt's row read the value; nothing was handed out")
    }

    // MARK: Delivery

    func testStandardInputIsWrittenThenClosed() async throws {
        allowEverything()
        let ran = try await run(["run", "--stdin", "pp://Agents/Token", "--", "sh", "-c", "v=$(cat); [ \"$v\" = '\(planted)' ] && echo same; echo \"$v\""])
        XCTAssertEqual(ran.out, "same\n\(AgentConstants.concealed)\n")
    }

    func testEnvFileReferencesFilesAndLiterals() async throws {
        allowEverything()
        let envFile = folder.appendingPathComponent(".env.pp")
        try """
        NOTARY_KEY=file:pp://Agents/Token/attachment/AuthKey.p8
        NOTARY_KEY_ID=pp://Agents/Token/Key ID
        SIGNING_TEAM=2S468LUF8V
        """.write(to: envFile, atomically: true, encoding: .utf8)
        let ran = try await run(["run", "--env-file", envFile.path, "--", "sh", "-c", "echo \"$NOTARY_KEY_ID $SIGNING_TEAM\"; test -f \"$NOTARY_KEY\" && echo file"])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertEqual(ran.out, "\(AgentConstants.concealed) 2S468LUF8V\nfile\n")
        XCTAssertEqual(approver.prompts.first?.rows.map(\.delivery), [.file, .env])
    }

    /// Two `--env-file`s through the real tool: the second, kept on this Mac only, adds a path and replaces a line.
    func testASecondEnvFileAddsAndOverrides() async throws {
        allowEverything()
        let committed = folder.appendingPathComponent(".env.pp")
        let local = folder.appendingPathComponent(".env.local")
        try "TOKEN=pp://Agents/Token\nREGION=eu\nKEY_ID=pp://Agents/Hidden\n".write(to: committed, atomically: true, encoding: .utf8)
        try "REGION=us\nCONFIGS_DIR=/Users/me/configs\nKEY_ID=pp://Agents/Token/Key ID\n".write(to: local, atomically: true, encoding: .utf8)
        let ran = try await run(["run", "--env-file", committed.path, "--env-file", local.path, "--", "sh", "-c", "echo \"$TOKEN $REGION $CONFIGS_DIR $KEY_ID\""])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertEqual(ran.out, "\(AgentConstants.concealed) us /Users/me/configs \(AgentConstants.concealed)\n")
        XCTAssertEqual(approver.prompts.first?.rows.map(\.name), ["TOKEN", "KEY_ID"], "the line the second file replaced is not asked for")
        XCTAssertEqual(approver.prompts.first?.rows.map(\.field), ["password", "field Key ID"])
    }

    /// `check-import` through the real tool: names and a word each, exit 78 when one differs, and no value in what it
    /// prints. The app's reader is scripted here; the real one is run in PasswordPieAppTests.
    func testCheckImportPrintsNamesAndWordsAndExitsBySameness() async throws {
        final class Folders: AgentFolderReader, @unchecked Sendable {
            var value = "planted-stripe-work-8842"
            var asked: [String] = []
            func subjects(folder: String, inside: [String]) throws -> [AgentCheckSubject] {
                asked.append(folder)
                guard folder.hasSuffix("/keys") else { throw AgentFolderProblem("\(folder) is not a folder.") }
                return [
                    AgentCheckSubject(file: "stripe/work.env", name: "STRIPE_SECRET_KEY", folder: inside + ["stripe"], title: "work", field: .custom("STRIPE_SECRET_KEY"), expected: Data(value.utf8)),
                    AgentCheckSubject(file: "stripe/work.env", name: "NOT_IMPORTED", folder: inside + ["stripe"], title: "work", field: .custom("NOT_IMPORTED"), expected: Data("planted-not-imported".utf8)),
                    AgentCheckSubject(file: "stripe/work.pem", name: "work.pem", folder: inside + ["stripe"], title: "work", field: .attachment("work.pem"), expected: Data("planted-pem".utf8)),
                ]
            }
        }
        let folders = Folders()
        broker.folders = folders
        allowEverything()
        vault.add("work", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "planted-stripe-work-8842"], attachments: ["work.pem": Data("planted-pem".utf8)])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keys"), withIntermediateDirectories: true)

        // A relative folder: the tool sends the whole path, since the app reads the folder itself.
        let differs = try await run(["check-import", "keys", "--reason", "Before deleting"])
        XCTAssertEqual(differs.code, AgentConstants.checkFailedExitCode, differs.err)
        XCTAssertEqual(differs.out, """
        stripe/work.env
          STRIPE_SECRET_KEY  same
          NOT_IMPORTED       missing
        stripe/work.pem
          work.pem           same
        2 same, 1 missing.

        """)
        XCTAssertTrue(differs.err.contains("Do not delete the files yet."), differs.err)
        XCTAssertTrue(differs.err.contains("not imported, or not shared with agents"), differs.err)
        let keys = folder.appendingPathComponent("keys").resolvingSymlinksInPath().path
        XCTAssertEqual(folders.asked, [keys, keys], "read for the window, and again once the owner allowed")
        XCTAssertEqual(approver.prompts.last?.kind, .check)
        XCTAssertEqual(approver.prompts.last?.rows.count, 2, "what is missing is not in the window")
        XCTAssertEqual(approver.prompts.last?.reason, "Before deleting")

        vault.add("work", folder: ["Agents", "stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "planted-stripe-work-8842", "NOT_IMPORTED": "planted-not-imported"], attachments: ["work.pem": Data("planted-pem".utf8)])
        let same = try await run(["check-import", folder.appendingPathComponent("keys").path, "--inside", "Agents", "--json"])
        XCTAssertEqual(same.code, 0, same.err)
        XCTAssertEqual(same.err, "")
        let lines = try JSONDecoder().decode([AgentCheckLine].self, from: Data(same.out.utf8))
        XCTAssertEqual(lines.map(\.status), [.same, .same, .same])

        folders.value = "planted-changed-in-the-file"
        let changed = try await run(["check-import", folder.appendingPathComponent("keys").path, "--inside", "Agents"])
        XCTAssertEqual(changed.code, AgentConstants.checkFailedExitCode)
        XCTAssertTrue(changed.out.contains("STRIPE_SECRET_KEY  differs"), changed.out)
        XCTAssertTrue(changed.out.hasSuffix("2 same, 1 differs.\n"), changed.out)

        approver.onPresent = { [unowned self] _ in DispatchQueue.main.async { self.approver.answer(.deny) } }
        let denied = try await run(["check-import", folder.appendingPathComponent("keys").path, "--inside", "Agents"])
        XCTAssertEqual(denied.code, AgentErrorCode.denied.exitCode)
        XCTAssertEqual(denied.out, "")
        let notAFolder = try await run(["check-import", folder.appendingPathComponent("nothing").path])
        XCTAssertEqual(notAFolder.code, AgentErrorCode.usage.exitCode)
        XCTAssertTrue(notAFolder.err.contains("nothing is not a folder."), notAFolder.err)

        let everything = [differs, same, changed, denied, notAFolder].map { $0.out + $0.err }.joined()
            + String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(everything.contains("planted"), "names and words, never a value")
    }

    /// An answer that compared nothing is not "everything is the same": no lines is a failure, with nothing printed.
    func testCheckImportWithoutLinesFailsAndPrintsNothing() async throws {
        server.stop()
        let broker = self.broker!
        server = AgentServer(handler: { request, caller in
            request.type == .check ? AgentResponse(type: request.type.rawValue, id: request.id) : await broker.handle(request, from: caller)
        }, peerCheck: { _ in true })
        try server.start(path: socketPath)
        let ran = try await run(["check-import", folder.path])
        XCTAssertEqual(ran.code, AgentErrorCode.appUnavailable.exitCode, ran.err)
        XCTAssertEqual(ran.out, "")
        XCTAssertTrue(ran.err.contains("PasswordPie gave no answer about the check."), ran.err)
    }

    /// `write-env` through the real tool: it shows the project's `.env.pp` and writes nothing, writes with `--write`,
    /// keeps a file that is there, and what it wrote runs the project. No prompt, and no value anywhere in its output.
    func testWriteEnvShowsThenWritesAndWhatItWroteRuns() async throws {
        allowEverything()
        vault.add("work", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "planted-stripe-work-8842", "STRIPE_ACCOUNT": "acct_planted"])
        vault.add("personal", folder: ["stripe"], password: "", fields: ["STRIPE_SECRET_KEY": "planted-stripe-personal-17"])
        vault.add("work", folder: ["google"], password: "", fields: ["GOOGLE_PROJECT": "planted-project"], attachments: ["key.json": Data("{\"planted\":1}".utf8)])
        vault.add("unshared", folder: ["stripe"], password: "", fields: ["UNSHARED_KEY": "planted-unshared"], shared: false)
        let project = folder.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "const a = process.env.STRIPE_SECRET_KEY, b = process.env.UNSHARED_KEY, c = process.env.HOME\n".write(to: project.appendingPathComponent("src/pay.js"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"$STRIPE_SECRET_KEY $GOOGLE_PROJECT\"\n".write(to: project.appendingPathComponent("deploy.sh"), atomically: true, encoding: .utf8)
        try "STRIPE_SECRET_KEY=x\nSTRIPE_ACCOUNT=y\nUNSHARED_KEY=z\n".write(to: project.appendingPathComponent(".env.work"), atomically: true, encoding: .utf8)
        let written = project.appendingPathComponent(".env.work.pp")

        let shown = try await run(["write-env", project.path])
        XCTAssertEqual(shown.code, 0, shown.err)
        XCTAssertEqual(shown.out, """
        .env.work.pp, from the items named work:
          # References to secrets in PasswordPie, not the values: safe to commit.
          # Use: passwordpie run --env-file .env.work.pp -- <command>
          STRIPE_SECRET_KEY=pp://stripe/work/STRIPE_SECRET_KEY
          GOOGLE_PROJECT=pp://google/work/GOOGLE_PROJECT

        """)
        XCTAssertTrue(shown.err.contains("in no item shared with agents: UNSHARED_KEY."), shown.err)
        XCTAssertTrue(shown.err.contains("not found in the code, so left out: STRIPE_ACCOUNT."), shown.err)
        XCTAssertTrue(shown.err.contains("nothing was written. Run it again with --write to write .env.work.pp."), shown.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path), "shown before it is written")
        XCTAssertFalse((shown.out + shown.err).contains("planted"))
        XCTAssertTrue(approver.prompts.isEmpty, "names only: nobody is asked")

        let wrote = try await run(["write-env", project.path, "--write"])
        XCTAssertEqual(wrote.code, 0, wrote.err)
        XCTAssertTrue(wrote.err.contains("wrote .env.work.pp."))
        let text = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("STRIPE_SECRET_KEY=pp://stripe/work/STRIPE_SECRET_KEY\nGOOGLE_PROJECT=pp://google/work/GOOGLE_PROJECT\n"))

        // A file that is there is never replaced without being asked: here nobody is at a terminal to say yes.
        try "MINE=1\n".write(to: written, atomically: true, encoding: .utf8)
        let kept = try await run(["write-env", project.path, "--write"])
        XCTAssertEqual(kept.code, AgentErrorCode.usage.exitCode)
        XCTAssertTrue(kept.err.contains(".env.work.pp is already there and was not replaced. Add --force to replace it."), kept.err)
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "MINE=1\n")
        let forced = try await run(["write-env", project.path, "--write", "--force"])
        XCTAssertEqual(forced.code, 0, forced.err)
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), text)

        // What it wrote runs the project's script with the values, concealed in the output.
        let ran = try await run(["run", "--env-file", written.path, "--", "sh", project.appendingPathComponent("deploy.sh").path])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertEqual(ran.out, "\(AgentConstants.concealed) \(AgentConstants.concealed)\n")
        XCTAssertEqual(approver.prompts.last?.rows.map(\.name), ["STRIPE_SECRET_KEY", "GOOGLE_PROJECT"])

        // Nothing shared holds what a project reads: said, with the code of an item that is not there.
        let empty = folder.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "echo $NOTHING_OF_OURS\n".write(to: empty.appendingPathComponent("a.sh"), atomically: true, encoding: .utf8)
        let none = try await run(["write-env", empty.path])
        XCTAssertEqual(none.code, AgentErrorCode.notAvailable.exitCode)
        XCTAssertEqual(none.out, "")
        let missing = try await run(["write-env", folder.appendingPathComponent("no-such").path])
        XCTAssertEqual(missing.code, AgentErrorCode.usage.exitCode)
        let everything = String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(everything.contains("planted-stripe"))
    }

    /// A standing permission through the real tool: the next identical run asks nothing, and a run started with a
    /// variable that makes programs load other code asks again, whether the agent's shell set it or the `.env.pp` did.
    @MainActor
    func testAStandingPermissionAndCodeLoadingVariables() async throws {
        let database = FakeGrantDatabase()
        let store = StandingPermissions(mac: "test-mac", hasPremium: { true }, read: { database.read() }, write: { database.write($0, $1) })
        store.sessionAlive = { _ in true }
        try startServer(grants: store)
        try "echo \"$T\"\n".write(to: folder.appendingPathComponent("deploy.sh"), atomically: true, encoding: .utf8)
        approver.onPresent = { [unowned self] prompt in
            let decision: AgentApprovalDecision = prompt.lasting == .offered ? .allowLasting([0], .days7) : .allow([0])
            DispatchQueue.main.async { self.approver.answer(decision) }
        }
        let command = ["run", "--env", "T=pp://Agents/Token", "--", "sh", "deploy.sh"]
        let first = try await run(command)
        XCTAssertEqual(first.code, 0, first.err)
        XCTAssertEqual(approver.prompts.last?.lasting, .offered)
        XCTAssertEqual(store.inForce.count, 1)
        let second = try await run(command)
        XCTAssertEqual(second.out, "\(AgentConstants.concealed)\n")
        XCTAssertEqual(approver.prompts.count, 1, "no window the second time")
        inherited = ["BASH_ENV": folder.appendingPathComponent("evil.sh").path]
        _ = try await run(command)
        inherited = [:]
        XCTAssertEqual(approver.prompts.count, 2, "BASH_ENV in the tool's environment asks")
        XCTAssertEqual(approver.prompts.last?.lasting, .unavailable("Started with BASH_ENV set, which makes programs load other code."))
        let envFile = folder.appendingPathComponent("x.env.pp")
        try "T=pp://Agents/Token\nBASH_ENV=\(folder.appendingPathComponent("evil.sh").path)\n".write(to: envFile, atomically: true, encoding: .utf8)
        _ = try await run(["run", "--env-file", envFile.path, "--", "sh", "deploy.sh"])
        XCTAssertEqual(approver.prompts.count, 3, "BASH_ENV from the .env.pp asks")
        XCTAssertEqual(approver.prompts.last?.lasting, .unavailable("Started with BASH_ENV set, which makes programs load other code."))
    }

    /// Output to a terminal: the command gets a pseudo-terminal, and its output is still masked.
    func testAPseudoTerminalWhenOutputIsATerminal() async throws {
        allowEverything()
        let ran = try await run(["-q", "/dev/null", tool.path, "run", "--env", "T=pp://Agents/Token", "--", "sh", "-c", "[ -t 1 ] && echo \"tty $T\""],
                                executable: URL(fileURLWithPath: "/usr/bin/script"))
        XCTAssertTrue(ran.out.contains("tty \(AgentConstants.concealed)"), ran.out)
        XCTAssertFalse(ran.out.contains(planted))
    }

    /// A key file with line breaks is still masked through a pseudo-terminal, which would otherwise turn `\n` into `\r\n`.
    func testAMultiLineValueIsMaskedThroughAPseudoTerminal() async throws {
        allowEverything()
        let ran = try await run(["-q", "/dev/null", tool.path, "run", "--file", "K=pp://Agents/Token/attachment/multi.pem", "--", "sh", "-c", "cat \"$K\""],
                                executable: URL(fileURLWithPath: "/usr/bin/script"))
        XCTAssertTrue(ran.out.contains(AgentConstants.concealed), ran.out)
        XCTAssertFalse(ran.out.contains("line-two-planted"), ran.out)
    }

    /// A reader that stops early ends the command, as in any pipeline, instead of the tool draining it forever.
    func testAReaderThatStopsEndsTheCommand() async throws {
        allowEverything()
        let started = Date()
        let ran = try await run(["-c", "'\(tool.path)' run --env T=pp://Agents/Token -- yes | head -1"], executable: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertEqual(ran.out, "y\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testReadWritesAnAttachmentWithoutANewline() async throws {
        allowEverything()
        let ran = try await run(["read", "pp://Agents/Token/attachment/AuthKey.p8"])
        XCTAssertEqual(ran.out, "-----BEGIN PRIVATE KEY-----planted")
    }

    func testADeclinedStandardInputIsEmpty() async throws {
        approver.script = [.allow([0])]
        let ran = try await run(["run", "--env", "T=pp://Agents/Token", "--stdin", "pp://Agents/Token/Key ID", "--", "sh", "-c", "echo \"[$(cat)]\""])
        XCTAssertEqual(ran.out, "[]\n")
    }

    /// A folder whose pid now belongs to another process (a different start time) is left over, and removed.
    func testAFolderOfAReusedPIDIsRemoved() async throws {
        allowEverything()
        let left = temporary.appendingPathComponent("passwordpie-run.\(getpid()).1.abcdefgh")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        let ran = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
    }

    func testDeclinedSecretsAreLeftOutAndSaidSo() async throws {
        approver.script = [.allow([1])]
        inherited = ["T": "inherited-from-the-agent"]
        let ran = try await run(["run", "--env", "T=pp://Agents/Token", "--env", "K=pp://Agents/Token/Key ID", "--", "sh", "-c", "echo \"[${T:-unset}]\""])
        XCTAssertEqual(ran.out, "[unset]\n")
        XCTAssertTrue(ran.err.contains("did not allow T"), ran.err)
    }

    func testListAndStatus() async throws {
        let list = try await run(["list", "--json"])
        XCTAssertEqual(list.code, 0, list.err)
        let items = try JSONDecoder().decode([AgentListedItem].self, from: Data(list.out.utf8))
        XCTAssertEqual(items.map(\.ref), ["pp://Agents/Token"])
        XCTAssertFalse(list.out.contains(planted))
        let status = try await run(["status"])
        XCTAssertEqual(status.code, 0, status.err)
        XCTAssertTrue(status.out.contains("Agent access: on"), status.out)
    }

    func testUsageErrorsExit64() async throws {
        for arguments in [["run", "--", "true"], ["run", "--env", "T=nope", "--", "true"], ["read"], ["frobnicate"], ["run", "--env", "T=pp://A/B", "--", "/no/such/program"]] {
            let ran = try await run(arguments)
            XCTAssertEqual(ran.code, 64, arguments.joined(separator: " "))
            XCTAssertTrue(ran.err.hasSuffix(AgentConstants.pasteWarning + "\n"), ran.err)
        }
    }

    func testNoAppAnswersAppUnavailable() async throws {
        server.stop()
        let ran = try await run(["run", "--env", "T=pp://Agents/Token", "--", "true"])
        XCTAssertEqual(ran.code, 70)
    }

    // MARK: login

    private func browserSide() -> FakeLogins {
        let logins = FakeLogins()
        let token = vault.items.first { $0.title == "Token" }!
        logins.websites[token.id] = ["https://github.com/login"]
        logins.usernames[token.id] = "octocat"
        broker.logins = logins
        return logins
    }

    /// The tool prints the outcome and the item's overview, never the password, and exits 0.
    func testLoginPrintsTheOutcomeAndNeverThePassword() async throws {
        let logins = browserSide()
        allowEverything()
        let ran = try await run(["login", "pp://Agents/Token", "--submit", "--reason", "Open billing"])
        XCTAssertEqual(ran.code, 0, ran.err)
        XCTAssertEqual(ran.out, "PasswordPie: filled Token (octocat) on github.com in Google Chrome and pressed the form's sign-in button. Check the page to see whether the site accepted it.\n")
        XCTAssertEqual(ran.err, "")
        XCTAssertEqual(logins.plans.first?.submit, true)
        XCTAssertEqual(approver.prompts.first?.reason, "Open billing")
        let json = try await run(["login", "pp://Agents/Token", "--json"])
        XCTAssertEqual(json.code, 0, json.err)
        let answer = try XCTUnwrap(AgentCoding.decode(AgentLoginAnswer.self, from: Data(json.out.utf8)))
        XCTAssertEqual(answer.item?.username, "octocat")
        XCTAssertEqual(logins.plans.last?.submit, false)
        for output in [ran.out, ran.err, json.out, json.err] { XCTAssertFalse(output.contains(planted)) }
    }

    func testLoginOutcomesHaveTheirExitCodes() async throws {
        let logins = browserSide()
        let mismatch = try await run(["login", "pp://Agents/Token", "--url", "https://gitlab.com/"])
        XCTAssertEqual(mismatch.code, 75, mismatch.err)
        XCTAssertTrue(mismatch.err.hasSuffix(AgentConstants.pasteWarning + "\n"), mismatch.err)
        XCTAssertEqual(mismatch.out, "")
        logins.target = nil
        let noTab = try await run(["login", "pp://Agents/Token"])
        XCTAssertEqual(noTab.code, 74, noTab.err)
        logins.target = AgentLoginTarget(browser: .chrome, profile: nil, link: 1, page: .unknown)
        allowEverything()
        for (end, code) in [(AgentLoginOutcome.timedOut, Int32(76)), (.noFields, 77), (.filled, 0)] {
            logins.end = .finished(end, code: nil, detail: nil)
            let ran = try await run(["login", "pp://Agents/Token"])
            XCTAssertEqual(ran.code, code, ran.err)
            XCTAssertFalse((ran.out + ran.err).contains(planted))
        }
        XCTAssertTrue(approver.prompts.allSatisfy { $0.kind == .login })
    }

    func testLoginArgumentMistakesAreUsage() async throws {
        _ = browserSide()
        for arguments in [["login"], ["login", "nope"], ["login", "pp://Agents/Token", "--browser", "firefox"], ["login", "--submit"]] {
            let ran = try await run(arguments)
            XCTAssertEqual(ran.code, 64, arguments.joined(separator: " "))
        }
        XCTAssertTrue(approver.prompts.isEmpty)
    }
}

/// Check 6: the socket serves only `com.passwordpie.cli` signed by our team. This test process is not, so it is refused.
final class AgentSocketPeerTests: XCTestCase {
    func testAClientNotSignedAsTheToolIsRefused() async throws {
        let folder = try shortTemporaryFolder("pppeer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.sock").path
        let handled = Counter()
        let server = AgentServer(handler: { request, _ in
            handled.increment()
            return AgentResponse(type: "hello", id: request.id)
        })
        try server.start(path: path)
        defer { server.stop() }
        let fd = try BridgeSocket.connect(path: path)
        defer { close(fd) }
        BridgeSocket.setTimeout(fd, seconds: 3)
        try? BridgeSocket.writeAll(fd, BridgeFrame.encode(AgentCoding.encode(AgentRequest(type: .hello, id: 1))))
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        XCTAssertThrowsError(try BridgeSocket.readFrame(fd, reader: &reader, pending: &pending), "the connection is closed unanswered")
        XCTAssertEqual(handled.value, 0)
    }

    func testTheSocketIsOwnerOnlyAndGoneWhenStopped() throws {
        let folder = try shortTemporaryFolder("pppeer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.sock").path
        let server = AgentServer(handler: { request, _ in AgentResponse(type: "hello", id: request.id) })
        try server.start(path: path)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try BridgeSocket.connect(path: path))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
