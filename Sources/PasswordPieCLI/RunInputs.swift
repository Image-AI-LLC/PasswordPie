import Foundation
import PasswordPieAgent

/// What a run sets for its command, gathered from the flags and from `.env.pp` files. Shared by `passwordpie run` and the
/// MCP server's `passwordpie_run`, so both follow one rule (docs/AGENTS.md, ".env.pp"):
///
/// - A name set by `--env` or `--file` is set once; a second flag for it is a mistake.
/// - `--env-file` may be given more than once. A later file's line replaces an earlier file's line of the same name,
///   so a second file kept on one Mac can add or change what the committed one says. A name twice in one file is a
///   mistake.
/// - A flag wins over a file, wherever it stands.
struct RunInputs {
    struct Problem: Error, Equatable {
        var message: String
    }

    /// `--env`, `--file` and `--stdin`, in the order given.
    private var flags: [AgentSecretRequest] = []
    private var flagNames: Set<String> = []
    private var stdinSet = false
    /// The files' lines by name, each holding the line of the last file that names it, in the order the names first appear.
    private var fileOrder: [String] = []
    private var fileLines: [String: AgentEnvFile.Line] = [:]

    mutating func add(_ secret: AgentSecretRequest) throws {
        if let name = secret.name {
            guard AgentEnvFile.isVariableName(name) else { throw Problem(message: "\"\(name)\" is not a variable name.") }
            guard flagNames.insert(name).inserted else { throw Problem(message: "\(name) is given twice.") }
        } else {
            guard !stdinSet else { throw Problem(message: "--stdin is given twice.") }
            stdinSet = true
        }
        guard (try? AgentReference(secret.ref)) != nil else {
            throw Problem(message: "\(secret.ref) is not a reference (pp://folder/item[/field]).")
        }
        flags.append(secret)
    }

    /// The lines of one `.env.pp`, as `path` names it in messages.
    mutating func add(envFile text: String, path: String) throws {
        let lines: [AgentEnvFile.Line]
        do {
            lines = try AgentEnvFile.parse(text)
        } catch let problem as AgentEnvFile.Problem {
            throw Problem(message: "\(path), \(problem.description).")
        }
        var inThisFile: Set<String> = []
        for line in lines {
            let name: String
            switch line {
            case .secret(let variable, _, _), .literal(let variable, _): name = variable
            }
            guard inThisFile.insert(name).inserted else { throw Problem(message: "\(path): \(name) is given twice.") }
            if fileLines[name] == nil { fileOrder.append(name) }
            fileLines[name] = line
        }
    }

    /// The flags' secrets, then the files' that no flag names.
    var secrets: [AgentSecretRequest] {
        flags + fileOrder.compactMap { name in
            guard !flagNames.contains(name), case .secret(_, let ref, let delivery)? = fileLines[name] else { return nil }
            return AgentSecretRequest(name: name, ref: ref, delivery: delivery)
        }
    }

    /// The files' plain lines that no flag names: set as they are.
    var literals: [(name: String, value: String)] {
        fileOrder.compactMap { name in
            guard !flagNames.contains(name), case .literal(_, let value)? = fileLines[name] else { return nil }
            return (name, value)
        }
    }
}
