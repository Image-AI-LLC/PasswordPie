import Darwin
import Foundation
import PasswordPieAgent

/// `passwordpie mcp`: an MCP server on standard input and output (JSON-RPC 2.0, one message per line), started by an
/// agent from its MCP configuration. It is the command-line tool in another form: the same binary, the same socket, so
/// the same broker, prompts, permissions and Activity. One server process is one agent session.
///
/// It holds no vault and no token. No tool creates, widens or extends a standing permission, shares an item or unlocks:
/// those exist only in PasswordPie, behind Touch ID. The agent in the approval window is the app's reading of the process
/// tree; the client's own name (`clientInfo`) is only shown beside it as the client's claim. See docs/AGENTS.md, "MCP".
final class MCPServer: @unchecked Sendable {
    /// Protocol versions this server speaks, newest first. A client asking for another gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let toolNames = ["passwordpie_status", "passwordpie_list", "passwordpie_run", "passwordpie_read"]

    private let output = NSLock()
    /// One request to the app at a time: the app reads this process's working folder as the project, so the server moves
    /// to the folder a tool call names for as long as the app takes to answer it.
    private let appLock = NSLock()
    private let state = NSLock()
    private var clientName: String?
    private var calls: [String: Cancellation] = [:]
    private let running = DispatchGroup()
    /// The folder the agent started the server in: the project for the tools that name none.
    private let home = FileManager.default.currentDirectoryPath

    func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var signals: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [self] in finish() }
            source.resume()
            signals.append(source)
        }
        while let line = readLine(strippingNewline: true) {
            handle(line)
        }
        finish()
    }

    /// The client went away: every call is cancelled, its command ended and its files removed, then the server exits.
    private func finish() -> Never {
        state.lock()
        let open = Array(calls.values)
        state.unlock()
        open.forEach { $0.cancel() }
        if running.wait(timeout: .now() + 3) == .timedOut { open.forEach { $0.forceEnd() } }
        _ = running.wait(timeout: .now() + 1)
        ArgumentNotice.wait()
        exit(0)
    }

    // MARK: JSON-RPC

    func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let message = parsed as? [String: Any] else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Batches are not supported; send one message per line."]])
        }
        // A response to something this server asked: it asks nothing.
        guard let method = message["method"] as? String else { return }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any] {
                let name = [info["name"] as? String, info["version"] as? String].compactMap { $0 }.joined(separator: " ")
                state.lock()
                clientName = name.isEmpty ? nil : name
                state.unlock()
            }
            let asked = params["protocolVersion"] as? String
            reply(id, result: [
                "protocolVersion": asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "passwordpie", "title": "PasswordPie", "version": AppConnection.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": Self.tools])
        case "tools/call":
            guard let id else { return }
            let name = params["name"] as? String ?? ""
            guard Self.toolNames.contains(name) else {
                return send(["jsonrpc": "2.0", "id": id, "error": [
                    "code": -32602,
                    "message": "Unknown tool \(name). PasswordPie's tools are \(Self.toolNames.joined(separator: ", ")).",
                ]])
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let cancellation = Cancellation()
            let key = Self.key(id)
            state.lock()
            calls[key] = cancellation
            state.unlock()
            running.enter()
            Thread.detachNewThread { [self] in
                let result = call(name, arguments, cancellation: cancellation)
                state.lock()
                calls[key] = nil
                state.unlock()
                // A cancelled call gets no answer (MCP's rule); its command has been ended.
                if !cancellation.isCancelled { reply(id, result: result) }
                running.leave()
            }
        case "notifications/cancelled":
            guard let requestID = params["requestId"] else { return }
            state.lock()
            let cancellation = calls[Self.key(requestID)]
            state.unlock()
            cancellation?.cancel()
        default:
            // Notifications this server has no use for are ignored; a request it does not know is answered.
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]) }
        }
    }

    private static func key(_ id: Any) -> String {
        if let number = id as? NSNumber { return "n:\(number.stringValue)" }
        return "s:\(id)"
    }

    private func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        output.lock()
        defer { output.unlock() }
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(0)
        }
    }

    // MARK: Tools

    func call(_ name: String, _ arguments: [String: Any], cancellation: Cancellation) -> [String: Any] {
        do {
            let structured: [String: Any]
            switch name {
            case "passwordpie_status": structured = try status(arguments, cancellation: cancellation)
            case "passwordpie_list": structured = try list(arguments, cancellation: cancellation)
            case "passwordpie_run": structured = try run(arguments, cancellation: cancellation)
            default: structured = try read(arguments, cancellation: cancellation)
            }
            return ["content": [["type": "text", "text": Self.text(structured)]], "structuredContent": structured, "isError": false]
        } catch let refusal as Refusal {
            return [
                "content": [["type": "text", "text": refusal.mcpText]],
                "structuredContent": ["error": refusal.code.rawValue],
                "isError": true,
            ]
        } catch {
            let refusal = Refusal(.appUnavailable)
            return ["content": [["type": "text", "text": refusal.mcpText]], "structuredContent": ["error": refusal.code.rawValue], "isError": true]
        }
    }

    private static func text(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private var mcpClient: String? {
        state.lock()
        defer { state.unlock() }
        return clientName
    }

    private func request(_ type: AgentRequestKind) -> AgentRequest {
        var request = AgentRequest(type: type, id: 1)
        request.version = AgentConstants.protocolVersion
        request.client = "mcp"
        request.mcpClient = mcpClient
        return request
    }

    /// Sends `request` from `folder`, which the app reads as this process's working folder.
    private func exchange(_ request: AgentRequest, in folder: String, cancellation: Cancellation) throws -> Result<AgentResponse, AppConnection.Failure> {
        appLock.lock()
        defer { appLock.unlock() }
        guard chdir(folder) == 0 else { throw Refusal(.usage, detail: "Cannot use the folder \(folder).") }
        return AppConnection.send(request, cancellation: cancellation)
    }

    private func ask(_ request: AgentRequest, in folder: String, cancellation: Cancellation) throws -> AgentResponse {
        switch try exchange(request, in: folder, cancellation: cancellation) {
        case .failure(let failure):
            throw Refusal(failure.code, detail: failure.detail)
        case .success(let answer):
            if let code = answer.errorCode { throw Refusal(code, ref: answer.ref, refs: answer.refs ?? [], detail: answer.detail) }
            return answer
        }
    }

    private func status(_ arguments: [String: Any], cancellation: Cancellation) throws -> [String: Any] {
        try Input(arguments, allowed: []).done()
        switch try exchange(request(.status), in: home, cancellation: cancellation) {
        case .failure(let failure):
            let running = failure.code == .accessOff
            return [
                "running": running,
                "agentAccess": false,
                "message": running
                    ? "PasswordPie is running with agent access off. Ask the owner to turn it on in PasswordPie > Preferences > Agents."
                    : "PasswordPie is not running. passwordpie_list, passwordpie_run and passwordpie_read start it.",
            ]
        case .success(let answer):
            if let code = answer.errorCode { throw Refusal(code) }
            guard let status = answer.status else { throw Refusal(.appUnavailable) }
            return [
                "running": true,
                "locked": status.locked,
                "agentAccess": status.access,
                "agent": status.agent,
                "project": status.project,
                "grants": status.grants,
            ]
        }
    }

    private func list(_ arguments: [String: Any], cancellation: Cancellation) throws -> [String: Any] {
        let input = Input(arguments, allowed: ["query", "cwd"])
        let query = try input.string("query")
        let cwd = try input.folder("cwd")
        try input.done()
        var request = request(.list)
        request.query = query.flatMap { $0.isEmpty ? nil : $0 }
        let items = try ask(request, in: cwd, cancellation: cancellation).items ?? []
        let listed = (try? JSONSerialization.jsonObject(with: AgentCoding.encode(items))) ?? []
        return ["items": listed]
    }

    private func read(_ arguments: [String: Any], cancellation: Cancellation) throws -> [String: Any] {
        let input = Input(arguments, allowed: ["ref", "reason"])
        guard let ref = try input.string("ref") else { throw Refusal(.usage, detail: "ref is required: pp://folder/item[/field].") }
        try Input.check(reference: ref)
        let reason = try input.string("reason")
        try input.done()
        var request = request(.read)
        request.secrets = [AgentSecretRequest(name: nil, ref: ref, delivery: .shown)]
        request.reason = reason
        let answer = try ask(request, in: home, cancellation: cancellation)
        guard let value = answer.secrets?.first, value.bytes != nil else { throw Refusal(.denied) }
        if let text = value.value { return ["value": text] }
        return ["base64": value.base64 ?? ""]
    }

    private func run(_ arguments: [String: Any], cancellation: Cancellation) throws -> [String: Any] {
        let input = Input(arguments, allowed: ["command", "cwd", "env", "files", "stdin", "envFile", "reason", "timeoutSeconds"])
        let command = try input.strings("command")
        guard !command.isEmpty, !command[0].isEmpty else { throw Refusal(.usage, detail: "command is required: the program and its arguments, as an array.") }
        let cwd = try input.folder("cwd")
        var secrets: [AgentSecretRequest] = []
        var literals: [(String, String)] = []
        var names: Set<String> = []
        func add(_ secret: AgentSecretRequest) throws {
            if let name = secret.name {
                guard AgentEnvFile.isVariableName(name) else { throw Refusal(.usage, detail: "\"\(name)\" is not a variable name.") }
                guard names.insert(name).inserted else { throw Refusal(.usage, detail: "\(name) is given twice.") }
            }
            try Input.check(reference: secret.ref)
            secrets.append(secret)
        }
        for (name, ref) in try input.map("env") { try add(AgentSecretRequest(name: name, ref: ref, delivery: .env)) }
        for (name, ref) in try input.map("files") { try add(AgentSecretRequest(name: name, ref: ref, delivery: .file)) }
        if let ref = try input.string("stdin") { try add(AgentSecretRequest(name: nil, ref: ref, delivery: .stdin)) }
        if let path = try input.string("envFile") {
            let full = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { throw Refusal(.usage, detail: "Could not read \(path).") }
            let lines: [AgentEnvFile.Line]
            do {
                lines = try AgentEnvFile.parse(text)
            } catch let problem as AgentEnvFile.Problem {
                throw Refusal(.usage, detail: "\(path), \(problem.description).")
            }
            for line in lines {
                switch line {
                case .secret(let name, let ref, let delivery):
                    try add(AgentSecretRequest(name: name, ref: ref, delivery: delivery))
                case .literal(let name, let value):
                    guard names.insert(name).inserted else { throw Refusal(.usage, detail: "\(name) is given twice.") }
                    literals.append((name, value))
                }
            }
        }
        let reason = try input.string("reason")
        let timeout = try input.integer("timeoutSeconds", in: 1...MCPLimits.maxTimeoutSeconds) ?? MCPLimits.defaultTimeoutSeconds
        try input.done()
        guard !secrets.isEmpty else {
            throw Refusal(.usage, detail: "passwordpie_run needs at least one secret in env, files, stdin or envFile.")
        }

        var environment = ProcessInfo.processInfo.environment
        guard let program = ProgramPath.resolve(command[0], path: environment["PATH"], cwd: cwd) else {
            throw Refusal(.usage, detail: "Command not found: \(command[0]).")
        }
        var request = request(.use)
        request.secrets = secrets
        request.program = program
        request.argv = command
        request.reason = reason
        request.masking = true
        let answer = try ask(request, in: cwd, cancellation: cancellation)

        for (name, value) in literals { environment[name] = value }
        let prepared = try PreparedRun.make(secrets: secrets, answer: answer, environment: environment, masking: true)
        defer { prepared.removeFiles() }
        let warnings = Lines(prepared.notes)
        let client = mcpClient
        let outcome = try CapturedRun.run(CapturedRun.Plan(
            path: program,
            argv: command,
            environment: prepared.environment,
            cwd: cwd,
            stdin: prepared.stdin,
            mask: prepared.values,
            timeout: TimeInterval(timeout),
            watched: prepared.watched,
            report: { finding in
                warnings.append(finding.warning)
                FileHandle.standardError.write(Data((finding.warning + "\n").utf8))
                ArgumentNotice.send(finding, client: "mcp", mcpClient: client)
            }
        ), cancellation: cancellation)
        var result: [String: Any] = [
            "exitCode": Int(outcome.exitCode),
            "stdout": outcome.stdout,
            "stderr": outcome.stderr,
            "concealed": outcome.concealed,
            "truncated": outcome.truncated,
        ]
        if outcome.timedOut {
            result["timedOut"] = true
            warnings.append("PasswordPie: the command did not finish in \(timeout) seconds and was ended.")
        }
        let all = warnings.all
        if !all.isEmpty { result["warnings"] = all }
        return result
    }

    // MARK: What the agent sees

    static let instructions = """
    PasswordPie keeps the owner's passwords and keys on this Mac. Use passwordpie_run to run a command with secrets: \
    PasswordPie gives the values to the command, not to you, and conceals them in its output. passwordpie_list shows \
    what the owner shared with agents. Each use asks the owner, who approves with Touch ID. \
    \(AgentConstants.mcpGuidance)
    """

    static var tools: [[String: Any]] {
        let reference = "A reference: pp://<folder>/<item>[/<field>] or pp://id/<UUID>[/<field>]; the field is password (the default), username, url, notes, a custom field's name, or attachment/<name>."
        let guidance = " " + AgentConstants.mcpGuidance
        return [
            [
                "name": "passwordpie_status",
                "title": "PasswordPie status",
                "description": "Whether PasswordPie is running and unlocked, whether agent access is on, who PasswordPie sees asking (worked out from the process tree) and the project, and the standing permissions that apply. No values and no items." + guidance,
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "passwordpie_list",
                "title": "List shared secrets",
                "description": "The items the owner shared with agents: their references (pp://…), titles, folders, field and attachment names, and whether a standing permission covers this agent and project. Never a value. Use a reference from here in passwordpie_run." + guidance,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to match in titles, folders, fields and attachments. Leave out to list everything shared."],
                        "cwd": ["type": "string", "description": "The absolute path of the project folder you work in."],
                    ],
                    "required": ["cwd"],
                    "additionalProperties": false,
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
            [
                "name": "passwordpie_run",
                "title": "Run a command with secrets",
                "description": "Runs a command with secrets from PasswordPie without you seeing them, after the owner approves with Touch ID. `command` is the program and its arguments as an array, run without a shell; to use a shell, pass [\"sh\", \"-c\", \"…\"], where $NAME then expands inside the command. `env` sets variables to values, `files` writes values to short-lived files (0600, removed when the command ends) and sets the variables to their paths, `stdin` writes one value to standard input. Every value in the output is replaced with [concealed by PasswordPie]; each of stdout and stderr is cut to 64 KiB (the start and the end). Never put a value on the command line: PasswordPie warns when one appears on a command line under the command. The result has the exit code, the output, how many values were concealed, and any warnings." + guidance,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "The program and its arguments, for example [\"npm\", \"run\", \"deploy\"]."],
                        "cwd": ["type": "string", "description": "The absolute path of the folder to run the command in: your project."],
                        "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables to set to secrets: {\"NAME\": \"pp://…\"}. " + reference],
                        "files": ["type": "object", "additionalProperties": ["type": "string"], "description": "Secrets to write to short-lived files: {\"NAME\": \"pp://…\"}; NAME holds the file's path."],
                        "stdin": ["type": "string", "description": "A reference whose value is written to the command's standard input."],
                        "envFile": ["type": "string", "description": "A .env.pp file of NAME=pp://… lines (NAME=file:pp://… for a file), relative to cwd."],
                        "reason": ["type": "string", "description": "Why, in a few words, for the owner's approval window."],
                        "timeoutSeconds": ["type": "integer", "minimum": 1, "maximum": MCPLimits.maxTimeoutSeconds, "description": "How long the command may run once approved, in seconds. Default \(MCPLimits.defaultTimeoutSeconds), at most \(MCPLimits.maxTimeoutSeconds)."],
                    ],
                    "required": ["command", "cwd"],
                    "additionalProperties": false,
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
            ],
            [
                "name": "passwordpie_read",
                "title": "Show a secret to the agent",
                "description": "Returns the value itself. It enters this conversation, and the model provider's records, and stays there: prefer passwordpie_run, which gives the value to a command without you seeing it. Use this only when you must see the value. It asks the owner every time, saying you will see it; no standing permission covers it." + guidance,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": reference],
                        "reason": ["type": "string", "description": "Why you need to see the value, for the owner's approval window."],
                    ],
                    "required": ["ref"],
                    "additionalProperties": false,
                ],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
            ],
        ]
    }
}

/// A tool call's arguments, checked: every key known, every value of its type. A key the tool does not take is refused
/// rather than ignored, so nothing the agent sends is taken for an option that does not exist.
struct Input {
    private let arguments: [String: Any]
    private let allowed: Set<String>

    init(_ arguments: [String: Any], allowed: Set<String>) {
        self.arguments = arguments
        self.allowed = allowed
    }

    func done() throws {
        if let unknown = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Refusal(.usage, detail: "Unknown argument \(unknown).")
        }
    }

    func string(_ key: String) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw Refusal(.usage, detail: "\(key) must be a string.") }
        return text
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = arguments[key], !(value is NSNull) else { return [] }
        guard let list = value as? [Any], let texts = list as? [String] else { throw Refusal(.usage, detail: "\(key) must be an array of strings.") }
        guard !texts.contains(where: { $0.contains("\0") }) else { throw Refusal(.usage, detail: "\(key) holds a NUL character.") }
        return texts
    }

    /// `{NAME: ref}`, sorted by name.
    func map(_ key: String) throws -> [(String, String)] {
        guard let value = arguments[key], !(value is NSNull) else { return [] }
        guard let object = value as? [String: Any] else { throw Refusal(.usage, detail: "\(key) must be an object of NAME: \"pp://…\".") }
        return try object.keys.sorted().map { name in
            guard let ref = object[name] as? String else { throw Refusal(.usage, detail: "\(key).\(name) must be a reference string.") }
            return (name, ref)
        }
    }

    func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), let integer = Int(exactly: number.doubleValue), range.contains(integer) else {
            throw Refusal(.usage, detail: "\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return integer
    }

    /// An absolute path of an existing folder, standardized.
    func folder(_ key: String) throws -> String {
        guard let path = try string(key), path.hasPrefix("/") else {
            throw Refusal(.usage, detail: "\(key) is required: the absolute path of an existing folder.")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Refusal(.usage, detail: "\(key) is not an existing folder: \(path).")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func check(reference ref: String) throws {
        guard (try? AgentReference(ref)) != nil else { throw Refusal(.usage, detail: "\(ref) is not a reference (pp://folder/item[/field]).") }
    }
}

/// Warnings gathered from the argument watch's thread and this one.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
