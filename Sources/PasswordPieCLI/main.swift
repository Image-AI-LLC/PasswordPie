import Darwin
import Foundation
import PasswordPieAgent

// `passwordpie`: PasswordPie's command-line tool for agents. It holds no vault: it asks the app over agent.sock, the app
// asks the owner, and the tool hands the values to the command (or, for `read`, prints the one value). It never puts a
// value on a command line and never logs one. See docs/AGENTS.md.

func printError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func refuse(_ code: AgentErrorCode, ref: String? = nil, refs: [String] = [], detail: String? = nil) -> Never {
    printError(AgentRefusal.line(code, ref: ref, refs: refs, detail: detail))
    exit(code.exitCode)
}

/// The app's answer, or the tool exits with the refusal.
func ask(_ request: AgentRequest) -> AgentResponse {
    do {
        return try AppConnection.ask(request)
    } catch let refusal as Refusal {
        refuse(refusal.code, ref: refusal.ref, refs: refusal.refs, detail: refusal.detail)
    } catch {
        refuse(.appUnavailable)
    }
}

func runCommand(_ options: RunOptions) -> Never {
    let environment = ProcessInfo.processInfo.environment
    guard let program = ProgramPath.resolve(options.command[0], path: environment["PATH"]) else {
        refuse(.usage, detail: "Command not found: \(options.command[0]).")
    }
    var request = AgentRequest(type: .use, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.secrets = options.secrets
    request.program = program
    request.argv = options.command
    request.reason = options.reason
    request.masking = options.masking
    request.wait = options.wait
    let answer = ask(request)

    var childEnvironment = environment
    for literal in options.literals { childEnvironment[literal.name] = literal.value }
    let prepared: PreparedRun
    do {
        prepared = try PreparedRun.make(secrets: options.secrets, answer: answer, environment: childEnvironment, masking: options.masking)
    } catch let refusal as Refusal {
        refuse(refusal.code, ref: refusal.ref, refs: refusal.refs, detail: refusal.detail)
    } catch {
        refuse(.usage)
    }
    prepared.notes.forEach(printError)
    let code = ChildProcess.run(ChildProcess.Plan(
        path: program,
        argv: options.command,
        environment: prepared.environment,
        stdin: prepared.stdin,
        mask: options.masking ? prepared.values : nil,
        watched: prepared.watched,
        report: { finding in
            printError(finding.warning)
            ArgumentNotice.send(finding, client: "cli")
        }
    ))
    prepared.removeFiles()
    ArgumentNotice.wait()
    exit(code)
}

func readCommand(_ options: ReadOptions) -> Never {
    var request = AgentRequest(type: .read, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.secrets = [AgentSecretRequest(name: nil, ref: options.ref, delivery: .shown)]
    request.reason = options.reason
    request.wait = options.wait
    let answer = ask(request)
    guard let value = answer.secrets?.first, let bytes = value.bytes else { refuse(.denied) }
    var output = bytes
    // Text ends with a newline unless -n; an attachment's bytes are written as they are.
    if options.newline, !RunFolder.namesAttachment(options.ref) { output.append(0x0A) }
    FileHandle.standardOutput.write(output)
    exit(0)
}

func listCommand(query: String?, json: Bool, wait: Int?) -> Never {
    var request = AgentRequest(type: .list, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.query = query
    request.wait = wait
    let items = ask(request).items ?? []
    if json {
        FileHandle.standardOutput.write(AgentCoding.encode(items) + Data("\n".utf8))
        exit(0)
    }
    if items.isEmpty {
        print(query == nil
            ? "Nothing is shared with agents. Ask the owner to choose Share with Agents on an item or folder in PasswordPie."
            : "No shared item matches \"\(query ?? "")\".")
        exit(0)
    }
    for item in items {
        print(item.ref)
        print("  id           \(item.idRef)")
        print("  fields       \((["password", "username", "url", "notes"] + item.fields).joined(separator: ", "))")
        if !item.attachments.isEmpty { print("  attachments  \(item.attachments.joined(separator: ", "))") }
        print("  asks         \(item.covered ? "no: a standing permission covers this agent and project" : "each time")")
    }
    exit(0)
}

func statusCommand(json: Bool) -> Never {
    var request = AgentRequest(type: .status, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    switch AppConnection.send(request) {
    case .failure(let failure):
        let running = failure.code == .accessOff
        if json {
            let object: [String: Any] = ["running": running, "agentAccess": false]
            FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
            print()
        } else {
            print("PasswordPie: \(running ? "running" : "not running")")
            print("Agent access: \(running ? "off (PasswordPie > Preferences > Agents)" : "unknown")")
        }
        exit(failure.code.exitCode)
    case .success(let answer):
        if let code = answer.errorCode { refuse(code) }
        guard let status = answer.status else { refuse(.appUnavailable) }
        if json {
            FileHandle.standardOutput.write(AgentCoding.encode(status) + Data("\n".utf8))
            exit(0)
        }
        print("PasswordPie: running, \(status.locked ? "locked" : "unlocked")")
        print("Agent access: \(status.access ? "on" : "off")")
        print("Agent: \(status.agent)")
        print("Project: \(status.project)")
        print("Standing permissions: \(status.grants.isEmpty ? "none; every use asks" : status.grants.joined(separator: "; "))")
        exit(0)
    }
}

let command: Command
do {
    command = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let problem as UsageError {
    refuse(.usage, detail: problem.message)
} catch {
    refuse(.usage)
}

switch command {
case .help:
    print(Arguments.usageText)
case .version:
    print("passwordpie \(AppConnection.version)")
case .status(let json):
    statusCommand(json: json)
case .list(let query, let json, let wait):
    listCommand(query: query, json: json, wait: wait)
case .read(let options):
    readCommand(options)
case .run(let options):
    runCommand(options)
case .mcp:
    MCPServer().serve()
}
