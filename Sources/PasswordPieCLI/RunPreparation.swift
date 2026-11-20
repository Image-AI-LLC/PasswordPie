import Darwin
import Foundation
import PasswordPieAgent

/// A refusal on its way to the agent: an exit code and a line on standard error for the command-line tool, an MCP tool
/// error for the MCP server.
struct Refusal: Error, Equatable {
    var code: AgentErrorCode
    var ref: String?
    var refs: [String] = []
    var detail: String?

    init(_ code: AgentErrorCode, ref: String? = nil, refs: [String] = [], detail: String? = nil) {
        self.code = code
        self.ref = ref
        self.refs = refs
        self.detail = detail
    }

    var line: String { AgentRefusal.line(code, ref: ref, refs: refs, detail: detail) }
    var mcpText: String { AgentRefusal.mcp(code, ref: ref, refs: refs, detail: detail) }
}

extension AppConnection {
    /// The app's answer, or its refusal.
    static func ask(_ request: AgentRequest, cancellation: Cancellation? = nil) throws -> AgentResponse {
        switch send(request, cancellation: cancellation) {
        case .failure(let failure):
            throw Refusal(failure.code, detail: failure.detail)
        case .success(let answer):
            if let code = answer.errorCode { throw Refusal(code, ref: answer.ref, refs: answer.refs ?? [], detail: answer.detail) }
            return answer
        }
    }
}

/// What a command starts with once the app answered: its environment, standard input and short-lived files, and the
/// values to mask and watch for. Shared by `passwordpie run` and the MCP server's `passwordpie_run`.
struct PreparedRun {
    var environment: [String: String]
    /// Written to the command's standard input. Nil: no secret was asked for it.
    var stdin: Data?
    var folder: URL?
    var values: [Data] = []
    var watched: [ArgumentWatch.Watched] = []
    /// Lines for the agent: secrets the owner did not allow, values too short to mask.
    var notes: [String] = []

    func removeFiles() {
        if let folder { RunFolder.remove(folder) }
    }

    /// `secrets` as asked, `answer` the app's; `environment` already holds the literal settings. A failure removes any
    /// file already written.
    static func make(secrets: [AgentSecretRequest], answer: AgentResponse, environment: [String: String], masking: Bool) throws -> PreparedRun {
        RunFolder.removeStale()
        var prepared = PreparedRun(environment: environment)
        do {
            for (secret, value) in zip(secrets, answer.secrets ?? []) {
                try prepared.add(secret, value)
            }
        } catch {
            prepared.removeFiles()
            throw error
        }
        let skipped = OutputMasker(values: prepared.values).skipped
        if masking, skipped > 0 {
            prepared.notes.append("PasswordPie: \(skipped == 1 ? "1 value is" : "\(skipped) values are") shorter than \(AgentConstants.minimumMaskedLength) characters and not masked in the output.")
        }
        return prepared
    }

    private mutating func add(_ secret: AgentSecretRequest, _ value: AgentSecretValue) throws {
        guard let bytes = value.bytes else {
            // Not an inherited variable of the same name either: the command runs without it.
            if let name = secret.name { environment[name] = nil }
            // Standard input was asked for: the command reads an empty one, not the agent's.
            if secret.delivery == .stdin { stdin = Data() }
            notes.append("PasswordPie: the owner did not allow \(secret.name ?? "the standard input") (\(secret.ref)); the command runs without it.")
            return
        }
        values.append(bytes)
        watched.append(ArgumentWatch.Watched(name: secret.name, ref: secret.ref, delivery: secret.delivery, value: bytes))
        switch secret.delivery {
        case .fill, .compare:
            // Never asked for by `run` (the app refuses it); nothing goes to the command.
            return
        case .env, .shown:
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                throw Refusal(.usage, detail: "\(secret.ref) is binary and cannot be an environment variable; use a file (--file \(secret.name ?? "NAME")=\(secret.ref)).")
            }
            environment[secret.name ?? ""] = text
        case .file:
            do {
                let current = try folder ?? RunFolder.create()
                folder = current
                let name = secret.name ?? "SECRET"
                environment[name] = try RunFolder.write(bytes, named: RunFolder.fileName(variable: name, ref: secret.ref), in: current).path
            } catch let problem as UsageError {
                throw Refusal(.usage, detail: problem.message)
            }
        case .stdin:
            stdin = bytes
        }
    }
}

/// Tells the app that the argument watch saw a value on a command line, for Activity. Sent on its own connection, in
/// the background; `wait` gives the notices sent so far up to two seconds before the tool exits.
enum ArgumentNotice {
    private static let group = DispatchGroup()

    static func request(_ finding: ArgumentWatch.Finding, client: String, mcpClient: String? = nil) -> AgentRequest {
        var request = AgentRequest(type: .argument, id: 1)
        request.version = AgentConstants.protocolVersion
        request.client = client
        request.mcpClient = mcpClient
        request.secrets = [AgentSecretRequest(name: finding.name, ref: finding.ref, delivery: finding.delivery)]
        request.program = finding.program
        request.wait = 0
        return request
    }

    /// The command-line tool's notice: straight to the app, from the tool's own working folder.
    static func send(_ finding: ArgumentWatch.Finding, client: String) {
        let notice = request(finding, client: client)
        dispatch { _ = AppConnection.send(notice) }
    }

    /// Runs `work` (a notice on its way) on its own thread, counted for `wait`.
    static func dispatch(_ work: @escaping @Sendable () -> Void) {
        group.enter()
        Thread.detachNewThread {
            work()
            group.leave()
        }
    }

    static func wait() {
        _ = group.wait(timeout: .now() + 2)
    }
}
