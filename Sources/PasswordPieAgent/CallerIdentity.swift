import Darwin
import Foundation
import Security

// Who is asking. The socket peer is always PasswordPie's own command-line tool, which any program can start, so the app
// looks further itself, from the kernel: the tool's working folder (the project), and its parents up to launchd, each with
// its executable, start time and code signature. Nothing in a request is taken for any of this. See docs/AGENTS.md,
// "Who is asking".

/// One process of the chain, as the activity log keeps it.
public struct AgentProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Microseconds since 1970. With the pid, it names this process and not a later one that got the same pid.
    public var startTime: UInt64
    public var path: String
    /// What the agent is called: a known agent's name, the script an interpreter runs, or the executable's name.
    public var name: String
    /// Signing team and identifier, when the code signature is valid. A platform binary has an identifier and no team.
    public var team: String?
    public var identifier: String?
    /// The organisation named in the signing certificate ("Anthropic PBC"), or "Apple" for a platform binary.
    public var signer: String?

    public init(pid: Int32, startTime: UInt64, path: String, name: String, team: String? = nil, identifier: String? = nil, signer: String? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.path = path
        self.name = name
        self.team = team
        self.identifier = identifier
        self.signer = signer
    }

    public var isSigned: Bool { identifier != nil && (team != nil || signer == "Apple") }

    /// "signed by Anthropic PBC", or "not signed: /opt/homebrew/bin/node" when the app cannot tell one program from another.
    public var signatureText: String {
        if isSigned, let signer { return "signed by \(signer)" }
        if isSigned, let team { return "signed by team \(team)" }
        return "not signed: \(path)"
    }

    /// What a standing permission binds to: the signing team and identifier, or the executable path when unsigned.
    public var identity: String {
        if isSigned, let identifier { return "\(team ?? "apple"):\(identifier)" }
        return "path:\(path)"
    }
}

public struct AgentCaller: Equatable, Sendable {
    /// The `passwordpie` process on the other end of the socket.
    public var cli: AgentProcess
    /// Its parents, nearest first, up to launchd.
    public var chain: [AgentProcess]
    /// The agent: the nearest known agent host in the chain, else the first that is not a shell or terminal.
    public var agent: AgentProcess?
    /// What one prompt at a time, the rate limit and session-long permissions count by: the agent process (pid and start
    /// time), or when no known agent host is in the chain, the tool's POSIX session.
    public var sessionKey: String
    /// The tool's working folder, read from the kernel.
    public var cwd: String
    /// The nearest folder above `cwd` (or `cwd` itself) holding `.git`, else `cwd`.
    public var project: String

    public init(cli: AgentProcess, chain: [AgentProcess], agent: AgentProcess?, sessionKey: String, cwd: String, project: String) {
        self.cli = cli
        self.chain = chain
        self.agent = agent
        self.sessionKey = sessionKey
        self.cwd = cwd
        self.project = project
    }

    public var agentName: String { agent?.name ?? "A program" }
    public var signatureText: String { agent?.signatureText ?? "not signed" }
}

/// Agent programs the app knows by name, and what is not an agent (shells, terminals, multiplexers).
public enum AgentHosts {
    /// Signing identifier → name.
    public static let byIdentifier: [String: String] = [
        "com.anthropic.claude-code": "Claude Code",
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "dev.zed.Zed": "Zed",
        "com.google.antigravity": "Antigravity",
    ]

    /// Executable (or script) name → name. For agents that run unsigned, or on an interpreter.
    public static let byName: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "cursor-agent": "Cursor Agent",
        "cursor": "Cursor",
        "gemini": "Gemini CLI",
        "agy": "Antigravity",
        "antigravity": "Antigravity",
        "aider": "Aider",
        "goose": "Goose",
        "opencode": "opencode",
        "amp": "Amp",
        "droid": "Droid",
        "copilot": "GitHub Copilot CLI",
        "qwen": "Qwen Code",
        "crush": "Crush",
        "openhands": "OpenHands",
    ]

    /// Programs that run the next program's code: an agent on one of them is named by its script.
    public static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

    /// Not agents: they only pass a command on.
    public static let passThrough: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh",
        "login", "sudo", "env", "nohup", "time", "timeout", "caffeinate", "tmux", "screen", "script", "sshd",
        "make", "xargs", "npx", "npm", "pnpm", "yarn", "uv", "uvx", "direnv", "mise", "asdf",
    ]

    /// Terminal apps, by signing identifier. Reaching one without passing an agent means the owner typed the command.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]

    /// The known agent's name for a process, if any.
    public static func knownName(identifier: String?, path: String, arguments: [String]) -> String? {
        if let identifier, let name = byIdentifier[identifier] { return name }
        let executable = (path as NSString).lastPathComponent.lowercased()
        if let name = byName[executable] { return name }
        if let first = arguments.first, let name = byName[(first as NSString).lastPathComponent.lowercased()] { return name }
        if interpreters.contains(executable) || interpreters.contains(where: { executable.hasPrefix($0) }) {
            for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
                var script = (argument as NSString).lastPathComponent.lowercased()
                for suffix in [".js", ".mjs", ".cjs", ".py", ".ts"] where script.hasSuffix(suffix) { script = String(script.dropLast(suffix.count)) }
                // The npm packages' entry points are named for the tool: @openai/codex/bin/codex.js, gemini-cli/bundle/gemini.js.
                return byName[script]
            }
        }
        return nil
    }

    public static func isPassThrough(_ process: AgentProcess) -> Bool {
        if let identifier = process.identifier, terminals.contains(identifier) { return true }
        let name = (process.path as NSString).lastPathComponent.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return passThrough.contains(name) || process.pid <= 1
    }
}

/// Reads the facts the walk needs about one process, from the kernel. A protocol so tests can stand in a table.
public protocol ProcessFacts: Sendable {
    func info(_ pid: Int32) -> ProcessRecord?
    func workingDirectory(_ pid: Int32) -> String?
    func arguments(_ pid: Int32) -> [String]
    func sessionID(_ pid: Int32) -> Int32?
    func signature(_ pid: Int32) -> (team: String?, identifier: String?, signer: String?)
}

public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var startTime: UInt64
    public var path: String

    public init(pid: Int32, parent: Int32, startTime: UInt64, path: String) {
        self.pid = pid
        self.parent = parent
        self.startTime = startTime
        self.path = path
    }
}

public enum CallerInspector {
    /// The caller behind the `passwordpie` process `pid`. Nil when the process is gone.
    public static func identify(pid: Int32, facts: ProcessFacts = LiveProcessFacts.shared) -> AgentCaller? {
        guard let cliRecord = facts.info(pid) else { return nil }
        let cli = process(cliRecord, facts: facts, arguments: [])
        var chain: [AgentProcess] = []
        var agent: AgentProcess?
        var firstOther: AgentProcess?
        var child = cliRecord
        var seen: Set<Int32> = [pid]
        while child.pid > 1, chain.count < 64 {
            let parentPID = child.parent
            guard parentPID > 0, !seen.contains(parentPID), let parent = facts.info(parentPID) else { break }
            // A parent starts before its child. One that did not is a later process that got the exited parent's pid.
            guard parent.startTime <= child.startTime else { break }
            seen.insert(parentPID)
            let arguments = facts.arguments(parentPID)
            var entry = process(parent, facts: facts, arguments: arguments)
            if agent == nil, let known = AgentHosts.knownName(identifier: entry.identifier, path: entry.path, arguments: arguments) {
                entry.name = known
                agent = entry
            } else if firstOther == nil, !AgentHosts.isPassThrough(entry) {
                firstOther = entry
            }
            chain.append(entry)
            child = parent
        }
        let cwd = facts.workingDirectory(pid) ?? "/"
        let sessionKey: String
        if let agent {
            sessionKey = "agent:\(agent.pid):\(agent.startTime)"
        } else {
            let sid = facts.sessionID(pid) ?? pid
            let leaderStart = facts.info(sid)?.startTime ?? 0
            sessionKey = "session:\(sid):\(leaderStart)"
        }
        return AgentCaller(cli: cli, chain: chain, agent: agent ?? firstOther, sessionKey: sessionKey, cwd: cwd, project: project(for: cwd))
    }

    /// The nearest folder at or above `cwd` that holds `.git` (a folder, or a worktree's file), else `cwd`.
    public static func project(for cwd: String) -> String {
        var folder = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder.path }
            let up = folder.deletingLastPathComponent()
            if up.path == folder.path { return cwd }
            folder = up
        }
    }

    private static func process(_ record: ProcessRecord, facts: ProcessFacts, arguments: [String]) -> AgentProcess {
        let signature = facts.signature(record.pid)
        var name = (record.path as NSString).lastPathComponent
        if AgentHosts.interpreters.contains(name.lowercased()),
           let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            name = "\(name) \((script as NSString).lastPathComponent)"
        }
        return AgentProcess(
            pid: record.pid,
            startTime: record.startTime,
            path: record.path,
            name: name,
            team: signature.team,
            identifier: signature.identifier,
            signer: signature.signer
        )
    }
}

/// The kernel's answers, for processes of this user.
public final class LiveProcessFacts: ProcessFacts, @unchecked Sendable {
    public static let shared = LiveProcessFacts()

    private let lock = NSLock()
    /// Signatures by pid and start time: checking one costs milliseconds, and a request walks a dozen processes.
    private var signatures: [String: (String?, String?, String?)] = [:]

    /// From `sysctl` rather than `proc_pidinfo`, which refuses processes of other users (the root `login` between a
    /// terminal and its shell), so the walk would stop there.
    public func info(_ pid: Int32) -> ProcessRecord? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessRecord(
            pid: pid,
            parent: info.kp_eproc.e_ppid,
            startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
            path: path
        )
    }

    public func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// The process's arguments (`KERN_PROCARGS2`). Used only to name an agent that runs on an interpreter; never logged.
    public func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding NULs, then argv.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while index < size, arguments.count < Int(count), arguments.count < 8 {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    public func sessionID(_ pid: Int32) -> Int32? {
        let sid = getsid(pid)
        return sid > 0 ? sid : nil
    }

    public func signature(_ pid: Int32) -> (team: String?, identifier: String?, signer: String?) {
        guard let record = info(pid) else { return (nil, nil, nil) }
        let key = "\(pid):\(record.startTime)"
        lock.lock()
        if let cached = signatures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let read = CodeSignature.read(pid: pid)
        // Still the same process: otherwise the signature read may belong to a later one.
        guard info(pid)?.startTime == record.startTime else { return (nil, nil, nil) }
        lock.lock()
        if signatures.count > 512 { signatures.removeAll() }
        signatures[key] = read
        lock.unlock()
        return read
    }
}

public enum CodeSignature {
    /// Team, identifier and signer of a running process, when its signature is valid; nils otherwise.
    public static func read(pid: Int32) -> (team: String?, identifier: String?, signer: String?) {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        // Anchored to Apple: Developer ID, App Store or Apple's own. A self-signed certificate can name any team and
        // organisation, so it counts as not signed.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple or anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return (nil, nil, nil) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return (nil, nil, nil) }
        let identifier = details[kSecCodeInfoIdentifier as String] as? String
        let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        // Ad hoc signatures have no certificates: they say nothing about who made the program.
        guard let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            return (nil, nil, nil)
        }
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        return (team, identifier, signerName(summary, team: team))
    }

    /// "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)" → "Anthropic PBC"; Apple's own → "Apple".
    public static func signerName(_ summary: String, team: String?) -> String? {
        if team == nil, summary.contains("Software Signing") || summary.contains("Apple") { return "Apple" }
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") { name = String(name[..<open.lowerBound]) }
        return name.isEmpty ? team : name
    }
}
