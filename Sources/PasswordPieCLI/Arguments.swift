import Foundation
import PasswordPieAgent

/// What the command line asked for. See `usageText` and docs/AGENTS.md, "The command-line tool".
enum Command: Equatable {
    case run(RunOptions)
    case read(ReadOptions)
    case login(LoginOptions)
    case list(query: String?, json: Bool, wait: Int?)
    case status(json: Bool)
    /// `passwordpie mcp`: the MCP server on standard input and output.
    case mcp
    case help
    case version
}

struct RunOptions: Equatable {
    /// In the order given: `--env`, `--file`, `--stdin`, then the `--env-file` lines.
    var secrets: [AgentSecretRequest] = []
    /// `.env.pp` lines without a reference, set as they are.
    var literals: [(name: String, value: String)] = []
    var reason: String?
    var wait: Int?
    var masking = true
    var command: [String] = []

    static func == (lhs: RunOptions, rhs: RunOptions) -> Bool {
        lhs.secrets == rhs.secrets && lhs.literals.map(\.name) == rhs.literals.map(\.name)
            && lhs.literals.map(\.value) == rhs.literals.map(\.value) && lhs.reason == rhs.reason && lhs.wait == rhs.wait
            && lhs.masking == rhs.masking && lhs.command == rhs.command
    }
}

struct ReadOptions: Equatable {
    var ref: String
    var reason: String?
    var wait: Int?
    var newline = true
}

struct LoginOptions: Equatable {
    var ref: String?
    var url: String?
    var submit = false
    var browser: AgentBrowserName?
    var reason: String?
    var wait: Int?
    var json = false
}

struct UsageError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

enum Arguments {
    /// `readFile` reads `--env-file`; tests pass their own.
    static func parse(_ arguments: [String], readFile: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }) throws -> Command {
        guard let verb = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())
        switch verb {
        case "run": return .run(try parseRun(&rest, readFile: readFile))
        case "read": return .read(try parseRead(&rest))
        case "login": return .login(try parseLogin(&rest))
        case "list", "ls":
            var json = false
            var wait: Int?
            var query: [String] = []
            while let next = rest.first {
                rest.removeFirst()
                switch next {
                case "--json": json = true
                case "--wait": wait = try waitValue(take(&rest, after: next))
                default:
                    if next.hasPrefix("--wait=") { wait = try waitValue(String(next.dropFirst(7))); continue }
                    guard !next.hasPrefix("-") else { throw UsageError("Unknown option \(next) for list.") }
                    query.append(next)
                }
            }
            return .list(query: query.isEmpty ? nil : query.joined(separator: " "), json: json, wait: wait)
        case "status":
            for next in rest where next != "--json" { throw UsageError("Unknown option \(next) for status.") }
            return .status(json: rest.contains("--json"))
        case "mcp":
            guard rest.isEmpty else { throw UsageError("mcp takes no options; agents start it from their MCP configuration.") }
            return .mcp
        case "help", "-h", "--help": return .help
        case "version", "--version", "-V": return .version
        default: throw UsageError("Unknown command \(verb).")
        }
    }

    private static func parseRun(_ rest: inout [String], readFile: (String) throws -> String) throws -> RunOptions {
        var options = RunOptions()
        var stdinSet = false
        var names: Set<String> = []
        func add(_ secret: AgentSecretRequest) throws {
            if let name = secret.name {
                guard AgentEnvFile.isVariableName(name) else { throw UsageError("\"\(name)\" is not a variable name.") }
                guard names.insert(name).inserted else { throw UsageError("\(name) is given twice.") }
            }
            guard (try? AgentReference(secret.ref)) != nil else { throw UsageError("\(secret.ref) is not a reference (pp://folder/item[/field]).") }
            options.secrets.append(secret)
        }
        while let next = rest.first {
            if next == "--" {
                rest.removeFirst()
                break
            }
            guard next.hasPrefix("-") else { break }
            rest.removeFirst()
            let (flag, inline) = split(next)
            func value() throws -> String { try inline ?? take(&rest, after: flag) }
            switch flag {
            case "--env", "--file":
                let pair = try value()
                guard let equals = pair.firstIndex(of: "=") else { throw UsageError("\(flag) takes NAME=pp://….") }
                try add(AgentSecretRequest(
                    name: String(pair[..<equals]),
                    ref: String(pair[pair.index(after: equals)...]),
                    delivery: flag == "--env" ? .env : .file
                ))
            case "--stdin":
                guard !stdinSet else { throw UsageError("--stdin is given twice.") }
                stdinSet = true
                try add(AgentSecretRequest(name: nil, ref: try value(), delivery: .stdin))
            case "--env-file":
                let path = try value()
                let text: String
                do {
                    text = try readFile(path)
                } catch {
                    throw UsageError("Could not read \(path).")
                }
                let lines: [AgentEnvFile.Line]
                do {
                    lines = try AgentEnvFile.parse(text)
                } catch let problem as AgentEnvFile.Problem {
                    throw UsageError("\(path), \(problem.description).")
                }
                for line in lines {
                    switch line {
                    case .secret(let name, let ref, let delivery):
                        try add(AgentSecretRequest(name: name, ref: ref, delivery: delivery))
                    case .literal(let name, let value):
                        guard names.insert(name).inserted else { throw UsageError("\(name) is given twice.") }
                        options.literals.append((name, value))
                    }
                }
            case "--reason": options.reason = try value()
            case "--wait": options.wait = try waitValue(try value())
            case "--no-masking": options.masking = false
            default: throw UsageError("Unknown option \(flag) for run.")
            }
        }
        options.command = rest
        guard !options.command.isEmpty else { throw UsageError("run needs a command after --.") }
        guard !options.secrets.isEmpty else { throw UsageError("run needs at least one --env, --file, --stdin or --env-file reference.") }
        return options
    }

    private static func parseRead(_ rest: inout [String]) throws -> ReadOptions {
        var ref: String?
        var options = ReadOptions(ref: "")
        while let next = rest.first {
            rest.removeFirst()
            let (flag, inline) = split(next)
            switch flag {
            case "--reason": options.reason = try inline ?? take(&rest, after: flag)
            case "--wait": options.wait = try waitValue(try inline ?? take(&rest, after: flag))
            case "-n", "--no-newline": options.newline = false
            default:
                guard !next.hasPrefix("-"), ref == nil else { throw UsageError("Unknown option \(next) for read.") }
                ref = next
            }
        }
        guard let ref else { throw UsageError("read needs a reference: passwordpie read pp://folder/item[/field].") }
        guard (try? AgentReference(ref)) != nil else { throw UsageError("\(ref) is not a reference (pp://folder/item[/field]).") }
        options.ref = ref
        return options
    }

    private static func parseLogin(_ rest: inout [String]) throws -> LoginOptions {
        var options = LoginOptions()
        while let next = rest.first {
            rest.removeFirst()
            let (flag, inline) = split(next)
            switch flag {
            case "--url": options.url = try inline ?? take(&rest, after: flag)
            case "--submit": options.submit = true
            case "--browser":
                let name = try inline ?? take(&rest, after: flag)
                guard let browser = AgentBrowserName(rawValue: name) else { throw UsageError("--browser takes chrome or safari.") }
                options.browser = browser
            case "--reason": options.reason = try inline ?? take(&rest, after: flag)
            case "--wait": options.wait = try waitValue(try inline ?? take(&rest, after: flag))
            case "--json": options.json = true
            default:
                guard !next.hasPrefix("-"), options.ref == nil else { throw UsageError("Unknown option \(next) for login.") }
                options.ref = next
            }
        }
        if let ref = options.ref, (try? AgentReference(ref)) == nil { throw UsageError("\(ref) is not a reference (pp://folder/item).") }
        guard options.ref != nil || options.url != nil else {
            throw UsageError("login needs a reference, or --url to be offered the shared items for that site: passwordpie login pp://folder/item [--url URL].")
        }
        return options
    }

    private static func split(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    private static func take(_ rest: inout [String], after flag: String) throws -> String {
        guard !rest.isEmpty else { throw UsageError("\(flag) needs a value.") }
        return rest.removeFirst()
    }

    private static func waitValue(_ text: String) throws -> Int {
        guard let seconds = Int(text), seconds >= 0, seconds <= AgentConstants.maxWaitSeconds else {
            throw UsageError("--wait takes seconds, 0 to \(AgentConstants.maxWaitSeconds).")
        }
        return seconds
    }

    static let usageText = """
    passwordpie: use secrets from PasswordPie without seeing them.

      passwordpie run [--env NAME=REF]... [--file NAME=REF]... [--stdin REF] [--env-file PATH]
                      [--reason TEXT] [--wait SECONDS] [--no-masking] -- COMMAND [ARG]...
      passwordpie read REF [--reason TEXT] [--wait SECONDS] [-n]
      passwordpie login [REF] [--url URL] [--submit] [--browser chrome|safari] [--reason TEXT] [--wait SECONDS] [--json]
      passwordpie list [QUERY] [--json]
      passwordpie status [--json]
      passwordpie mcp

    REF is pp://<folder>/<item>[/<field>] or pp://id/<UUID>[/<field>]; the field is password (the default), username,
    url, notes, a custom field's name, or attachment/<name>. `passwordpie list` shows what is shared with agents.

    run starts COMMAND with the values in its environment (--env), in short-lived files whose paths are in the
    environment (--file), or on its standard input (--stdin), and replaces every value in its output with
    [concealed by PasswordPie]. Each use asks the owner, who approves with Touch ID.

    Your shell expands $NAME before passwordpie runs, so `passwordpie run --env T=… -- curl -H "Authorization: $T"`
    sends an empty header. Put such commands in a script, or in sh -c '…' (which asks every time).

    read prints the value itself: it enters your conversation. Prefer run. Never ask the owner to paste a secret
    into the conversation.

    While a command runs, PasswordPie watches the command lines of the processes under it and warns when a value it
    handed out appears on one, where any process can read it.

    login fills REF's username and password into the sign-in form of the tab in front of the owner's browser, through
    PasswordPie's extension, after the owner approves; --submit also presses the form's button. Open the sign-in page
    first. Without REF, --url offers the owner the shared items for that site. You get the outcome and the item's
    title, username and websites, never the password.

    mcp is an MCP server on standard input and output, for agents that use MCP tools: passwordpie_status,
    passwordpie_list, passwordpie_run, passwordpie_read and passwordpie_login. Add it to the agent's MCP configuration (Preferences >
    Agents shows the lines for Claude Code, Codex and Cursor).

    Exit codes: the command's own, or 64 usage, 65 not-available, 66 ambiguous, 67 denied, 68 timeout, 69 locked,
    70 app-unavailable, 71 access-off, 72 too-many-requests, 73 premium-required; for login, 74 no-matching-tab,
    75 site-mismatch, 76 timed-out, 77 no-fields. See docs/AGENTS.md.
    """
}
