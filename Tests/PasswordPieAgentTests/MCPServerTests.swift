import Darwin
import Foundation
import XCTest
@testable import PasswordPieAgent
import PasswordPieBridge

/// `passwordpie mcp`, the real binary, driven by a scripted MCP client over its standard input and output, against an
/// in-process server with a scripted vault and approver (as `CommandLineToolTests`). These are the PRD's phase 2 checks:
/// list shows shared items only, run masks, read asks every time, no tool changes a grant, and the argument watch
/// catches a planted `--password` within a second.
@MainActor
final class MCPServerTests: XCTestCase {
    private var folder: URL!
    private var vault: FakeVault!
    private var approver: FakeApprover!
    private var activity: MemoryActivity!
    private var server: AgentServer!
    private var client: MCPTestClient?
    /// The browser side for `passwordpie_login`.
    private var logins = FakeLogins()
    /// Where `passwordpie_save` proposals go.
    private var saves: FakeSaves!
    /// Every request the MCP server sent to the app.
    private var sent: [AgentRequest] = []
    private let planted = "planted-secret-4b7d2a"
    private let hidden = "hidden-password-77c1"

    private var socketPath: String { folder.appendingPathComponent("m.sock").path }
    /// A project with `.git`, and a folder inside it, both real paths (`/tmp` is a link to `/private/tmp`).
    private var project: URL { folder.appendingPathComponent("project", isDirectory: true).resolvingSymlinksInPath() }
    private var inside: URL { project.appendingPathComponent("sub", isDirectory: true) }

    override func setUp() async throws {
        folder = try shortTemporaryFolder("ppmcp")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        vault = FakeVault()
        approver = FakeApprover()
        activity = MemoryActivity()
        vault.add("Token", password: planted, fields: ["Key ID": "KEYID-PLANTED-551"])
        vault.add("Hidden", password: hidden, shared: false)
        saves = FakeSaves(vault: vault)
        try startServer(grants: NoAgentGrants())
    }

    override func tearDown() async throws {
        client?.close()
        client?.process.waitUntilExit()
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func startServer(grants: AgentGrantStore) throws {
        server?.stop()
        let broker = VaultBroker(vault: vault, approver: approver, grants: grants, activity: activity) { true }
        broker.logins = logins
        broker.saves = saves
        server = AgentServer(handler: { [unowned self] request, caller in
            sent.append(request)
            return await broker.handle(request, from: caller)
        }, peerCheck: { _ in true })
        try server.start(path: socketPath)
    }

    private var tool: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("PasswordPieCLI")
    }

    /// Starts `passwordpie mcp` in `folder` and initializes it, saying it is `clientName`.
    @discardableResult
    private func connect(clientName: String = "test-client") async throws -> MCPTestClient {
        // The test runner's own loader variables (DYLD_…) would keep every run from a standing permission, as they should.
        var environment = ProcessInfo.processInfo.environment.filter { !AgentProgramRule.isCodeLoading($0.key) }
        environment["PASSWORDPIE_AGENT_SOCKET"] = socketPath
        environment["TMPDIR"] = folder.appendingPathComponent("tmp").path + "/"
        let client = try MCPTestClient(tool: tool, environment: environment, cwd: folder)
        self.client = client
        let id = client.request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": clientName, "version": "9.9"],
        ])
        let answer = await response(id)
        XCTAssertEqual((answer?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        client.notify("notifications/initialized", [:])
        return client
    }

    private func response(_ id: Int, timeout: TimeInterval = 20) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = client?.response(id) { return found }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// A tool call's result: `structuredContent`, `isError`, and the text content.
    private struct ToolResult {
        var structured: [String: Any]
        var isError: Bool
        var text: String
        /// The whole response line, as the client read it.
        var raw: String
    }

    private func call(_ name: String, _ arguments: [String: Any]) async throws -> ToolResult {
        let client = try XCTUnwrap(client)
        let id = client.request("tools/call", ["name": name, "arguments": arguments])
        let waited = await response(id, timeout: 30)
        let answer = try XCTUnwrap(waited, "no answer to \(name)")
        let result = try XCTUnwrap(answer["result"] as? [String: Any], "\(answer)")
        let content = result["content"] as? [[String: Any]] ?? []
        return ToolResult(
            structured: result["structuredContent"] as? [String: Any] ?? [:],
            isError: result["isError"] as? Bool ?? false,
            text: content.compactMap { $0["text"] as? String }.joined(),
            raw: client.rawLine(id) ?? ""
        )
    }

    private func allowEverything() {
        approver.onPresent = { [unowned self] prompt in
            let all = Set(prompt.rows.indices)
            DispatchQueue.main.async { self.approver.answer(.allow(all)) }
        }
    }

    // MARK: Tools

    /// No tool creates, widens or extends a standing permission, shares an item or unlocks: the server offers exactly
    /// these six, each description carries the guidance, and the read tool says the value enters the conversation.
    func testTheToolsAreExactlyTheSixWithTheGuidance() async throws {
        let client = try await connect()
        let id = client.request("tools/list", [:])
        let listed = await response(id)
        let tools = try XCTUnwrap((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["passwordpie_status", "passwordpie_list", "passwordpie_run", "passwordpie_read", "passwordpie_save", "passwordpie_login"])
        for tool in tools {
            let description = tool["description"] as? String ?? ""
            XCTAssertTrue(description.contains(AgentConstants.mcpGuidance), "\(tool["name"] ?? "")")
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = (schema["properties"] as? [String: Any] ?? [:]).keys.map { $0.lowercased() }
            for word in ["grant", "share", "unlock", "permission", "masking", "duration", "allow"] {
                XCTAssertFalse(properties.contains { $0.contains(word) }, "\(tool["name"] ?? "") takes \(word)")
            }
        }
        let read = tools.first { $0["name"] as? String == "passwordpie_read" }?["description"] as? String ?? ""
        XCTAssertTrue(read.contains("enters this conversation"))
        XCTAssertTrue(read.contains("prefer passwordpie_run"))
        XCTAssertTrue(read.contains("asks the owner every time"))
    }

    // MARK: passwordpie_save

    /// The command's output is the value: it goes to the app as a save, and the result never holds it, nor does anything
    /// the window or Activity was given. Its standard error is returned with the value concealed.
    func testSaveRunsTheCommandAndStoresWhatItPrintsWithoutReturningIt() async throws {
        let made = "PLANTED-mcp-made-\(UUID().uuidString.prefix(8))"
        approver.onPresent = { [unowned self] _ in DispatchQueue.main.async { self.approver.answer(.allow([0])) } }
        try await connect()
        let result = try await call("passwordpie_save", [
            "ref": "pp://Agents/Shop/API key", "cwd": inside.path, "reason": "new key",
            "command": ["sh", "-c", "printf '%s\\n' '\(made)'; echo \"made \(made)\" >&2"],
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.structured["outcome"] as? String, "saved")
        XCTAssertEqual(result.structured["change"] as? String, "new item")
        XCTAssertEqual(result.structured["exitCode"] as? Int, 0)
        XCTAssertEqual(result.structured["stderr"] as? String, "made \(AgentConstants.concealed)\n")
        XCTAssertFalse(result.raw.contains(made), "the value is not in the result")
        let item = try XCTUnwrap(vault.agentSharedItems().first { $0.title == "Shop" })
        XCTAssertEqual(vault.values[item.id]?[.custom("API key")], Data(made.utf8), "stored without its line break")
        XCTAssertEqual(sent.map(\.type), [.hello, .save])
        XCTAssertEqual(sent.last?.client, "mcp")
        XCTAssertNil(sent.last?.argv, "the command is not part of the request")
        XCTAssertEqual(approver.prompts.first?.via, "through MCP; the client says it is “test-client 9.9”")
        let everything = approver.prompts.map { String(describing: $0) }.joined()
            + activity.records.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) }.joined()
        XCTAssertFalse(everything.contains(made))
    }

    func testSaveRunsNothingWhileLocked() async throws {
        vault.locked = true
        let marker = folder.appendingPathComponent("ran")
        try await connect()
        let result = try await call("passwordpie_save", [
            "ref": "pp://Agents/Shop/API key", "cwd": inside.path, "command": ["sh", "-c", "touch '\(marker.path)'; echo PLANTED-x"],
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("locked: "), result.text)
        XCTAssertTrue(result.text.contains("Nothing was run."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the command did not run")
        XCTAssertEqual(sent.map(\.type), [.hello])
    }

    func testAFailingCommandSavesNothing() async throws {
        try await connect()
        let failed = try await call("passwordpie_save", [
            "ref": "pp://Agents/Shop/API key", "cwd": inside.path, "command": ["sh", "-c", "echo PLANTED-half; echo 'went wrong: PLANTED-half' >&2; exit 3"],
        ])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("exited with 3"), failed.text)
        XCTAssertFalse(failed.raw.contains("PLANTED-half"), "what it printed is concealed in its error output too")
        let empty = try await call("passwordpie_save", ["ref": "pp://Agents/Shop/API key", "cwd": inside.path, "command": ["true"]])
        XCTAssertTrue(empty.isError)
        XCTAssertEqual(sent.map(\.type), [.hello, .hello], "no save reached the app")
        XCTAssertTrue(saves.kept.isEmpty)
    }

    func testASaveNobodyAnswersIsPendingAndStatusListsIt() async throws {
        approver.onPresent = { [unowned self] _ in DispatchQueue.main.async { self.approver.answer(.dismissed) } }
        try await connect()
        let result = try await call("passwordpie_save", ["ref": "pp://Agents/Later", "cwd": inside.path, "command": ["echo", "PLANTED-later"]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.structured["outcome"] as? String, "pending")
        let id = try XCTUnwrap(result.structured["proposal"] as? String)
        XCTAssertTrue((result.structured["message"] as? String ?? "").hasPrefix("pending: "))
        let status = try await call("passwordpie_status", [:])
        let proposals = status.structured["proposals"] as? [[String: Any]] ?? []
        XCTAssertEqual(proposals.compactMap { $0["id"] as? String }, [id])
        XCTAssertEqual(proposals.first?["state"] as? String, "pending")
        XCTAssertFalse(status.raw.contains("PLANTED"))
    }

    func testUnknownToolsAndOptionsAreRefused() async throws {
        try await connect()
        for name in ["passwordpie_grant", "passwordpie_share", "passwordpie_unlock"] {
            let id = client!.request("tools/call", ["name": name, "arguments": [String: Any]()])
            let error = (await response(id))?["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32602, name)
        }
        // An option that would widen anything is not ignored but refused, before the app is asked.
        let widened = try await call("passwordpie_run", [
            "command": ["sh", "-c", "true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"], "grant": "30 days",
        ])
        XCTAssertTrue(widened.isError)
        XCTAssertTrue(widened.text.hasPrefix("usage: "), widened.text)
        let unmasked = try await call("passwordpie_run", [
            "command": ["sh", "-c", "true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"], "masking": false,
        ])
        XCTAssertTrue(unmasked.isError)
        XCTAssertTrue(sent.isEmpty, "\(sent.map(\.type))")
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// Every message the server sends the app is one of the four tools' requests (or the argument watch's notice):
    /// nothing that shares, grants or unlocks exists to send.
    func testOnlyRequestsThatChangeNothingReachTheApp() async throws {
        allowEverything()
        try await connect()
        _ = try await call("passwordpie_status", [:])
        _ = try await call("passwordpie_list", ["cwd": inside.path])
        _ = try await call("passwordpie_read", ["ref": "pp://Agents/Token"])
        _ = try await call("passwordpie_run", ["command": ["sh", "-c", "true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"]])
        XCTAssertEqual(sent.map(\.type), [.status, .list, .read, .use])
        XCTAssertTrue(sent.allSatisfy { $0.client == "mcp" })
        XCTAssertTrue(sent.allSatisfy { $0.masking != false })
        XCTAssertEqual(vault.shared.count, 1, "nothing was shared")
    }

    /// `passwordpie_login`: the same request as `passwordpie login`, the window says "through MCP", and the result is the
    /// outcome and the overview, never the password.
    func testLoginFillsThroughTheBrowserAndAnswersWithoutThePassword() async throws {
        let token = try XCTUnwrap(vault.items.first { $0.title == "Token" })
        logins.websites[token.id] = ["https://github.com/login"]
        logins.usernames[token.id] = "octocat"
        allowEverything()
        try await connect(clientName: "claude-code")
        let done = try await call("passwordpie_login", ["ref": "pp://Agents/Token", "submit": true, "reason": "Open billing"])
        XCTAssertFalse(done.isError, done.text)
        XCTAssertEqual(done.structured["outcome"] as? String, "submitted")
        XCTAssertEqual((done.structured["item"] as? [String: Any])?["username"] as? String, "octocat")
        XCTAssertFalse(done.raw.contains(planted))
        XCTAssertEqual(logins.plans.first?.submit, true)
        XCTAssertEqual(sent.last?.type, .login)
        XCTAssertEqual(sent.last?.client, "mcp")
        XCTAssertEqual(approver.prompts.first?.via, "through MCP; the client says it is “claude-code 9.9”")
        XCTAssertEqual(approver.prompts.first?.reason, "Open billing")

        let mismatch = try await call("passwordpie_login", ["ref": "pp://Agents/Token", "url": "https://gitlab.com/"])
        XCTAssertTrue(mismatch.isError)
        XCTAssertEqual(mismatch.structured["outcome"] as? String, "site-mismatch")
        let message = mismatch.structured["message"] as? String ?? ""
        XCTAssertTrue(message.hasSuffix(AgentConstants.mcpGuidance), message)
        XCTAssertTrue(message.contains("passwordpie_list"), message)
        XCTAssertFalse(message.contains("`passwordpie "), "no command-line advice to an MCP agent: \(message)")
        XCTAssertEqual(approver.prompts.count, 1, "no window for a site the item does not list")
    }

    func testLoginArgumentMistakesAreRefusedBeforeTheApp() async throws {
        try await connect()
        for arguments: [String: Any] in [[:], ["ref": "nope"], ["ref": "pp://Agents/Token", "browser": "firefox"], ["ref": "pp://Agents/Token", "submit": "yes"], ["url": "https://a.example/", "grant": true]] {
            let refused = try await call("passwordpie_login", arguments)
            XCTAssertTrue(refused.isError, "\(arguments)")
            XCTAssertTrue(refused.text.hasPrefix("usage: "), refused.text)
        }
        XCTAssertTrue(sent.isEmpty)
    }

    /// Phase 2: list shows shared items only, and never a value.
    func testListShowsSharedItemsOnly() async throws {
        try await connect()
        let listed = try await call("passwordpie_list", ["cwd": inside.path])
        XCTAssertFalse(listed.isError, listed.text)
        let items = listed.structured["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.compactMap { $0["title"] as? String }, ["Token"])
        XCTAssertEqual(items.first?["ref"] as? String, "pp://Agents/Token")
        XCTAssertFalse(listed.raw.contains("Hidden"))
        XCTAssertFalse(listed.raw.contains(planted))
        XCTAssertFalse(listed.raw.contains(hidden))
        XCTAssertTrue(approver.prompts.isEmpty)
    }

    /// Phase 2: run masks, in both streams, says how many it concealed, and passes the exit code. The project is the
    /// folder the agent named, read by the app from the kernel, not from the request.
    func testRunMasksBothStreamsInTheNamedFolder() async throws {
        allowEverything()
        try await connect()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "echo \"$T\"; echo \"x$T\" >&2; pwd; exit 4"],
            "cwd": inside.path,
            "env": ["T": "pp://Agents/Token"],
            "reason": "Deploy",
        ])
        XCTAssertFalse(ran.isError, ran.text)
        XCTAssertEqual(ran.structured["exitCode"] as? Int, 4)
        let real = realpath(inside.path, nil).map { String(cString: $0) } ?? inside.path
        XCTAssertEqual(ran.structured["stdout"] as? String, "\(AgentConstants.concealed)\n\(real)\n")
        XCTAssertEqual(ran.structured["stderr"] as? String, "x\(AgentConstants.concealed)\n")
        XCTAssertEqual(ran.structured["concealed"] as? Int, 2)
        XCTAssertEqual(ran.structured["truncated"] as? Bool, false)
        XCTAssertFalse(ran.raw.contains(planted))
        let prompt = try XCTUnwrap(approver.prompts.first)
        XCTAssertEqual(prompt.command, "sh -c 'echo \"$T\"; echo \"x$T\" >&2; pwd; exit 4'")
        XCTAssertEqual(prompt.project, project.path)
        XCTAssertEqual(prompt.reason, "Deploy")
    }

    func testRunCutsEachStreamTo64KiB() async throws {
        allowEverything()
        try await connect()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "head -c 200000 /dev/zero | tr '\\0' a; printf END"],
            "cwd": inside.path,
            "env": ["T": "pp://Agents/Token"],
        ])
        let stdout = ran.structured["stdout"] as? String ?? ""
        XCTAssertEqual(ran.structured["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(stdout.utf8.count, 64 * 1024 + 80)
        XCTAssertTrue(stdout.hasSuffix("END"), "the end of the output is kept")
        XCTAssertTrue(stdout.hasPrefix("aaaa"))
        XCTAssertTrue(stdout.contains("bytes cut by PasswordPie"))
    }

    func testRunTimesOutAndEndsTheCommand() async throws {
        allowEverything()
        try await connect()
        let started = Date()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "sleep 30"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"], "timeoutSeconds": 1,
        ])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(ran.structured["timedOut"] as? Bool, true)
        XCTAssertEqual(ran.structured["exitCode"] as? Int, 128 + Int(SIGTERM))
        // Cut off in the middle of a value: its start is concealed, not handed to the agent.
        let cut = try await call("passwordpie_run", [
            "command": ["sh", "-c", "printf 'key: %s' \"${T%???}\"; sleep 30"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"],
            "timeoutSeconds": 1,
        ])
        XCTAssertEqual(cut.structured["stdout"] as? String, "key: \(AgentConstants.concealed)")
        XCTAssertFalse(cut.raw.contains("planted-secret"))
        let over = try await call("passwordpie_run", [
            "command": ["true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"], "timeoutSeconds": 3601,
        ])
        XCTAssertTrue(over.isError)
        XCTAssertTrue(over.text.contains("3600"))
    }

    /// Files and standard input reach the command; the file is gone after the run.
    func testFilesAndStandardInput() async throws {
        allowEverything()
        try await connect()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "[ \"$(cat \"$F\")\" = '\(planted)' ] && echo file-ok; [ \"$(cat)\" = 'KEYID-PLANTED-551' ] && echo stdin-ok; echo \"$F\""],
            "cwd": inside.path,
            "files": ["F": "pp://Agents/Token"],
            "stdin": "pp://Agents/Token/Key ID",
        ])
        let lines = (ran.structured["stdout"] as? String ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(2)), ["file-ok", "stdin-ok"], ran.text)
        let path = try XCTUnwrap(lines.last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Without a secret for it, the command's standard input is empty: never the server's, which carries MCP messages.
    func testTheCommandNeverReadsTheServersInput() async throws {
        allowEverything()
        try await connect()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "wc -c | tr -d ' '"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"],
        ])
        XCTAssertEqual(ran.structured["stdout"] as? String, "0\n")
    }

    /// `envFiles`: more `.env.pp` files after `envFile`, a later one replacing an earlier one's line, and `env` over both.
    @MainActor
    func testEnvFilesAreReadInOrderAndALaterOneOverrides() async throws {
        try startServer(grants: NoAgentGrants())
        allowEverything()
        try await connect()
        try "TOKEN=pp://Agents/Hidden\nREGION=eu\nID=pp://Agents/Hidden\n".write(to: inside.appendingPathComponent(".env.pp"), atomically: true, encoding: .utf8)
        try "TOKEN=pp://Agents/Token\nREGION=us\n".write(to: inside.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try "WHERE=here\n".write(to: inside.appendingPathComponent("third.pp"), atomically: true, encoding: .utf8)
        let result = try await call("passwordpie_run", [
            "command": ["sh", "-c", "echo \"$TOKEN $REGION $WHERE $ID\""], "cwd": inside.path,
            "envFile": ".env.pp", "envFiles": [".env.local", "third.pp"], "env": ["ID": "pp://Agents/Token/Key ID"],
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.structured["stdout"] as? String, "\(AgentConstants.concealed) us here \(AgentConstants.concealed)\n")
        XCTAssertEqual(approver.prompts.last?.rows.map(\.name), ["ID", "TOKEN"])
        let twice = try await call("passwordpie_run", ["command": ["true"], "cwd": inside.path, "envFiles": ["missing.pp"]])
        XCTAssertTrue(twice.isError)
        XCTAssertTrue(twice.text.contains("Could not read missing.pp."), twice.text)
        let wrong = try await call("passwordpie_run", ["command": ["true"], "cwd": inside.path, "envFiles": ".env.pp"])
        XCTAssertTrue(wrong.isError, "envFiles is an array")
    }

    /// Phase 2: read asks every time, even with a standing permission in place, and says the agent will see it.
    /// A standing permission covers a repeated `passwordpie_run`; an `envFile` that sets a variable that makes programs load
    /// other code asks again, as it does through the command-line tool.
    @MainActor
    func testAStandingPermissionCoversARepeatRunAndAnEnvFileVariableAsks() async throws {
        let database = FakeGrantDatabase()
        let store = StandingPermissions(mac: "test-mac", hasPremium: { true }, read: { database.read() }, write: { database.write($0, $1) })
        store.sessionAlive = { _ in true }
        try startServer(grants: store)
        try "echo \"$T\" | wc -c\n".write(to: inside.appendingPathComponent("deploy.sh"), atomically: true, encoding: .utf8)
        approver.onPresent = { [unowned self] prompt in
            let decision: AgentApprovalDecision = prompt.lasting == .offered ? .allowLasting([0], .days7) : .allow([0])
            DispatchQueue.main.async { self.approver.answer(decision) }
        }
        try await connect()
        let arguments: [String: Any] = ["command": ["sh", "deploy.sh"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"]]
        let first = try await call("passwordpie_run", arguments)
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(approver.prompts.last?.lasting, .offered)
        XCTAssertEqual(store.inForce.count, 1)
        let second = try await call("passwordpie_run", arguments)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(approver.prompts.count, 1, "no window the second time")
        try "BASH_ENV=\(folder.path)/evil.sh\n".write(to: inside.appendingPathComponent("x.env.pp"), atomically: true, encoding: .utf8)
        var withEnvFile = arguments
        withEnvFile["envFile"] = "x.env.pp"
        _ = try await call("passwordpie_run", withEnvFile)
        XCTAssertEqual(approver.prompts.count, 2, "BASH_ENV from the envFile asks")
        XCTAssertEqual(approver.prompts.last?.lasting, .unavailable("Started with BASH_ENV set, which makes programs load other code."))
    }

    func testReadAsksEveryTimeEvenWithAStandingPermission() async throws {
        let grants = GrantEverything()
        try startServer(grants: grants)
        allowEverything()
        try await connect()
        for _ in 0..<2 {
            let read = try await call("passwordpie_read", ["ref": "pp://Agents/Token", "reason": "Compare"])
            XCTAssertEqual(read.structured["value"] as? String, planted)
        }
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertTrue(approver.prompts.allSatisfy(\.raw))
        XCTAssertEqual(grants.asked, 0)
        // The same store lets a run through without a prompt: it is the read that always asks.
        _ = try await call("passwordpie_run", ["command": ["true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"]])
        XCTAssertEqual(approver.prompts.count, 2)
        XCTAssertEqual(grants.asked, 1)
    }

    /// The approval window's agent is the process tree's; what the client calls itself is only a quoted second line.
    func testTheAgentComesFromTheProcessTreeNotClientInfo() async throws {
        allowEverything()
        try await connect(clientName: "Totally Trusted Agent")
        _ = try await call("passwordpie_read", ["ref": "pp://Agents/Token"])
        let prompt = try XCTUnwrap(approver.prompts.first)
        XCTAssertFalse(prompt.agent.contains("Totally Trusted"))
        XCTAssertFalse(prompt.signature.contains("Totally Trusted"))
        XCTAssertEqual(prompt.via, "through MCP; the client says it is “Totally Trusted Agent 9.9”")
        XCTAssertEqual(activity.records.last?.via, "MCP")
        XCTAssertFalse(activity.records.last?.agent.contains("Totally Trusted") ?? true)
    }

    /// Errors start with the code's name, say what to do in MCP terms, and end with the guidance. Unshared and
    /// nonexistent read the same.
    func testErrorsNameTheCodeAndCarryTheGuidance() async throws {
        try await connect()
        let unshared = try await call("passwordpie_read", ["ref": "pp://Agents/Hidden"])
        let missing = try await call("passwordpie_read", ["ref": "pp://Agents/Absent9"])
        XCTAssertTrue(unshared.isError)
        XCTAssertTrue(unshared.text.hasPrefix("not-available: "), unshared.text)
        XCTAssertTrue(unshared.text.hasSuffix(AgentConstants.mcpGuidance))
        XCTAssertTrue(unshared.text.contains("passwordpie_list"))
        XCTAssertEqual(unshared.text.replacingOccurrences(of: "pp://Agents/Hidden", with: "REF"), missing.text.replacingOccurrences(of: "pp://Agents/Absent9", with: "REF"))
        XCTAssertEqual(unshared.structured["error"] as? String, "not-available")
        approver.script = [.deny]
        let denied = try await call("passwordpie_run", ["command": ["true"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"]])
        XCTAssertTrue(denied.text.hasPrefix("denied: "), denied.text)
        XCTAssertTrue(denied.text.contains(AgentConstants.mcpGuidance))
    }

    /// Phase 2: the argument watch catches a value on a command line under the run within a second (the planted process
    /// lives one second), warns in the result and writes it to Activity, without the value anywhere.
    func testArgumentWatchCatchesAPlantedPassword() async throws {
        allowEverything()
        try await connect()
        let ran = try await call("passwordpie_run", [
            "command": ["sh", "-c", "/bin/sh -c 'sleep 1; true' planted --password \"$T\"; true"],
            "cwd": inside.path,
            "env": ["T": "pp://Agents/Token"],
        ])
        let warnings = ran.structured["warnings"] as? [String] ?? []
        XCTAssertEqual(warnings.count, 1, ran.text)
        // macOS's /bin/sh runs bash or another shell in its place, so the program is named by what the kernel runs.
        XCTAssertTrue(warnings.first?.contains("the value of T (pp://Agents/Token) appeared on the command line of ") ?? false, "\(warnings)")
        XCTAssertFalse(ran.raw.contains(planted))
        let seen = await eventually { self.activity.records.contains { $0.outcome == .argumentSeen } }
        XCTAssertTrue(seen)
        let record = try XCTUnwrap(activity.records.first { $0.outcome == .argumentSeen })
        XCTAssertEqual(record.items, ["pp://Agents/Token"])
        XCTAssertEqual(record.delivery, ["env T"])
        XCTAssertEqual(record.command?.hasSuffix("sh"), true, record.command ?? "")
        XCTAssertEqual(record.via, "MCP")
        let everything = String(decoding: try JSONEncoder().encode(activity.records), as: UTF8.self)
        XCTAssertFalse(everything.contains(planted))
    }

    /// A cancelled call gets no answer and its command ends; so does a running command when the client goes away.
    func testCancellingOrLeavingEndsTheCommand() async throws {
        allowEverything()
        let client = try await connect()
        let pidFile = folder.appendingPathComponent("pid")
        let id = client.request("tools/call", ["name": "passwordpie_run", "arguments": [
            "command": ["sh", "-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"],
        ]])
        let pid = try await childPID(pidFile)
        client.notify("notifications/cancelled", ["requestId": id, "reason": "test"])
        let ended = await eventually(timeout: 5) { kill(pid, 0) != 0 }
        XCTAssertTrue(ended)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(client.response(id), "a cancelled call is not answered")

        try FileManager.default.removeItem(at: pidFile)
        _ = client.request("tools/call", ["name": "passwordpie_run", "arguments": [
            "command": ["sh", "-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"],
        ]])
        let second = try await childPID(pidFile)
        client.close()
        let gone = await eventually(timeout: 8) { kill(second, 0) != 0 && !client.process.isRunning }
        XCTAssertTrue(gone)
    }

    /// A request id still in use is refused: it would otherwise take over the first call's cancellation.
    func testAnIdInUseIsRefused() async throws {
        allowEverything()
        let client = try await connect()
        let pidFile = folder.appendingPathComponent("pid")
        let first: [String: Any] = ["jsonrpc": "2.0", "id": 77, "method": "tools/call", "params": ["name": "passwordpie_run", "arguments": [
            "command": ["sh", "-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"], "cwd": inside.path, "env": ["T": "pp://Agents/Token"],
        ]]]
        client.raw(first)
        let pid = try await childPID(pidFile)
        client.raw(["jsonrpc": "2.0", "id": 77, "method": "tools/call", "params": ["name": "passwordpie_status", "arguments": [String: Any]()]])
        let refused = await response(77)
        XCTAssertEqual((refused?["error"] as? [String: Any])?["code"] as? Int, -32600)
        client.notify("notifications/cancelled", ["requestId": 77])
        let ended = await eventually(timeout: 5) { kill(pid, 0) != 0 }
        XCTAssertTrue(ended, "the first call can still be cancelled")
    }

    private func childPID(_ file: URL) async throws -> pid_t {
        let written = await eventually(timeout: 10) {
            (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        XCTAssertTrue(written)
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    func testStatusSaysWhoIsAskingAndNeverStartsTheApp() async throws {
        try await connect()
        let status = try await call("passwordpie_status", [:])
        XCTAssertEqual(status.structured["running"] as? Bool, true)
        XCTAssertEqual(status.structured["locked"] as? Bool, false)
        XCTAssertEqual(status.structured["agentAccess"] as? Bool, true)
        XCTAssertNotNil(status.structured["agent"] as? String)
        server.stop()
        let off = try await call("passwordpie_status", [:])
        XCTAssertFalse(off.isError)
        XCTAssertEqual(off.structured["running"] as? Bool, false)
    }
}

/// A minimal MCP client: JSON-RPC lines to the server's standard input, answers read from its standard output on a
/// thread of their own.
final class MCPTestClient: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var answers: [Int: [String: Any]] = [:]
    private var lines: [Int: String] = [:]
    private var nextID = 1
    private var closed = false

    init(tool: URL, environment: [String: String], cwd: URL) throws {
        process.executableURL = tool
        process.arguments = ["mcp"]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = output.fileHandleForReading
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = object["id"] as? Int else { continue }
                    lock.lock()
                    answers[id] = object
                    lines[id] = String(decoding: line, as: UTF8.self)
                    lock.unlock()
                }
            }
        }
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any]) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    /// A message as given, with its own id.
    func raw(_ message: [String: Any]) {
        write(message)
    }

    func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func response(_ id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return answers[id]
    }

    func rawLine(_ id: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lines[id]
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if !already { try? input.fileHandleForWriting.close() }
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }
}
