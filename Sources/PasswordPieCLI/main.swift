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
    request.environment = options.literals.map(\.name)
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

func loginCommand(_ options: LoginOptions) -> Never {
    var request = AgentRequest(type: .login, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.secrets = options.ref.map { [AgentSecretRequest(name: nil, ref: $0, delivery: .fill)] }
    request.url = options.url
    request.submit = options.submit
    request.browser = options.browser?.rawValue
    request.reason = options.reason
    request.wait = options.wait
    guard let login = ask(request).login else { refuse(.appUnavailable, detail: "PasswordPie gave no answer about the login.") }
    if options.json {
        FileHandle.standardOutput.write(AgentCoding.encode(login) + Data("\n".utf8))
        if !login.outcome.succeeded { printError(login.line) }
    } else if login.outcome.succeeded {
        print(login.line)
    } else {
        printError(login.line)
    }
    exit(login.outcome.exitCode)
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

/// `passwordpie write-env`: shows, or with `--write` writes, the project's `.env.pp`. It asks the app only for what is
/// shared (`list`: names, never a value) and reads the project's files for the names it reads.
func writeEnvCommand(_ options: WriteEnvOptions) -> Never {
    let folder = URL(fileURLWithPath: options.folder ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        refuse(.usage, detail: "\(options.folder ?? folder.path) is not a folder.")
    }
    let scan: RepositoryScan
    do {
        scan = try RepositoryScan.scan(folder)
    } catch let problem as UsageError {
        refuse(.usage, detail: problem.message)
    } catch {
        refuse(.usage, detail: "Could not read \(folder.path).")
    }
    var request = AgentRequest(type: .list, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.wait = options.wait
    let items = ask(request).items ?? []
    let plan = EnvFilePlan.make(scan: scan, items: items, identities: options.identities, also: options.also)
    for line in WriteEnv.notes(plan, scan: scan) { printError(line) }
    guard !plan.files.isEmpty else {
        printError(items.isEmpty
            ? "PasswordPie: nothing is shared with agents, so there is nothing to refer to. Ask the owner to choose Share with Agents on the items or their folder in PasswordPie."
            : "PasswordPie: no item shared with agents has a field named like a variable this project reads. `passwordpie list` shows what is shared.")
        exit(AgentErrorCode.notAvailable.exitCode)
    }
    var kept: [String] = []
    for file in plan.files {
        let url = folder.appendingPathComponent(file.name)
        let exists = FileManager.default.fileExists(atPath: url.path)
        print("\(file.name)\(file.identity.map { ", from the items named \($0)" } ?? ""):")
        print(file.text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { "  " + $0 }.joined(separator: "\n"))
        guard options.write else { continue }
        if exists, !options.force, !WriteEnv.confirmReplacing(file.name) {
            kept.append(file.name)
            continue
        }
        do {
            try Data(file.text.utf8).write(to: url, options: .atomic)
            printError("PasswordPie: wrote \(file.name).")
        } catch {
            refuse(.usage, detail: "Could not write \(url.path).")
        }
    }
    if !options.write {
        printError("PasswordPie: nothing was written. Run it again with --write to write \(plan.files.map(\.name).joined(separator: " and ")).")
    }
    if !kept.isEmpty {
        refuse(.usage, detail: "\(kept.joined(separator: " and ")) \(kept.count == 1 ? "is" : "are") already there and \(kept.count == 1 ? "was" : "were") not replaced. Add --force to replace \(kept.count == 1 ? "it" : "them").")
    }
    exit(0)
}

/// `passwordpie check-import`: asks the app to compare a folder of dotenv files with the vault. The app reads the
/// folder and compares; the tool gets a word per name and prints it. No value passes through the tool.
func checkImportCommand(_ options: CheckImportOptions) -> Never {
    // The app reads the folder itself, so it needs the whole path: links resolved, as the app would see it.
    let folder = URL(fileURLWithPath: options.folder).standardizedFileURL.resolvingSymlinksInPath().path
    var request = AgentRequest(type: .check, id: 1)
    request.version = AgentConstants.protocolVersion
    request.client = "cli"
    request.folder = folder
    request.inside = options.inside
    request.reason = options.reason
    request.wait = options.wait
    let lines = ask(request).checks ?? []
    let failed = lines.contains { $0.status != .same }
    if options.json {
        FileHandle.standardOutput.write(AgentCoding.encode(lines) + Data("\n".utf8))
    } else {
        print(CheckImport.report(lines), terminator: "")
    }
    if failed { printError(CheckImport.failureLine(lines)) }
    exit(failed ? AgentConstants.checkFailedExitCode : 0)
}

enum CheckImport {
    static func word(_ status: AgentCheckStatus) -> String {
        switch status {
        case .same: return "same"
        case .differs: return "differs"
        case .missing: return "missing"
        case .ambiguous: return "ambiguous"
        case .notChecked: return "not checked"
        }
    }

    /// The names under their file, each with its word, then the counts. Names and words only.
    static func report(_ lines: [AgentCheckLine]) -> String {
        var text = ""
        var file: String?
        let width = min(lines.map(\.name.count).max() ?? 0, 48)
        for line in lines {
            if line.file != file {
                file = line.file
                text += line.file + "\n"
            }
            text += "  " + line.name.padding(toLength: max(width, line.name.count), withPad: " ", startingAt: 0) + "  " + word(line.status) + "\n"
        }
        return text + summary(lines) + "\n"
    }

    /// "12 same, 1 differs, 2 missing."
    static func summary(_ lines: [AgentCheckLine]) -> String {
        let order: [AgentCheckStatus] = [.same, .differs, .missing, .ambiguous, .notChecked]
        let parts = order.compactMap { status -> String? in
            let count = lines.filter { $0.status == status }.count
            return count == 0 ? nil : "\(count) \(word(status))"
        }
        return parts.joined(separator: ", ") + "."
    }

    /// One line for the agent to relay when the folder and the vault are not the same.
    static func failureLine(_ lines: [AgentCheckLine]) -> String {
        var line = "PasswordPie: the folder and PasswordPie do not hold the same. Do not delete the files yet."
        if lines.contains(where: { $0.status == .missing }) {
            line += " Missing means not imported, or not shared with agents: ask the owner to import the folder and to share the items or their folder (Preferences > Agents)."
        }
        if lines.contains(where: { $0.status == .differs }) {
            line += " Where a name differs, the file or the item was changed after the import: importing the folder again updates the item."
        }
        if lines.contains(where: { $0.status == .ambiguous }) {
            line += " Ambiguous means more than one shared item has that folder and name."
        }
        return line + " " + AgentConstants.pasteWarning
    }
}

enum WriteEnv {
    /// What the person should know beside the files: names only.
    static func notes(_ plan: EnvFilePlan, scan: RepositoryScan) -> [String] {
        var lines: [String] = []
        if !plan.notShared.isEmpty {
            lines.append("PasswordPie: read by the code and set in \(dotenvNames(scan)), but in no item shared with agents: \(plan.notShared.joined(separator: ", ")). If one is not a secret (a path, a region), set it in a second file kept on this Mac: --env-file .env.pp --env-file .env.local.")
        }
        if !plan.notRead.isEmpty {
            let why = scan.loaders.first.map { " The project loads the file as a whole (\($0)), so a library may read one without the code naming it." } ?? ""
            lines.append("PasswordPie: set in \(dotenvNames(scan)) but not found in the code, so left out: \(plan.notRead.joined(separator: ", ")).\(why) Add one with --also NAME.")
        }
        for name in plan.ambiguous.keys.sorted() {
            lines.append("PasswordPie: \(name) is in more than one shared item (\((plan.ambiguous[name] ?? []).joined(separator: ", "))), so it was left out. Say whose with --identity NAME.")
        }
        return lines
    }

    private static func dotenvNames(_ scan: RepositoryScan) -> String {
        let names = scan.dotenvs.map(\.name)
        return names.isEmpty ? "the project's .env" : names.joined(separator: " and ")
    }

    /// Asks at a terminal. Anywhere else nobody can answer, so the file is kept.
    static func confirmReplacing(_ name: String) -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else { return false }
        FileHandle.standardError.write(Data("\(name) is already there. Replace it? [y/N] ".utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }
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
case .login(let options):
    loginCommand(options)
case .run(let options):
    runCommand(options)
case .writeEnv(let options):
    writeEnvCommand(options)
case .checkImport(let options):
    checkImportCommand(options)
case .mcp:
    MCPServer().serve()
}
