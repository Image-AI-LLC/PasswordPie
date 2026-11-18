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
        var environment = ProcessInfo.processInfo.environment.merging(inherited) { _, new in new }
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
