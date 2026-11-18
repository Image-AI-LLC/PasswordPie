import CryptoKit
import Darwin
import Foundation

// The program rule of a standing permission (docs/AGENTS.md, "Standing permissions"): a grant names what the command
// runs, not "whatever the agent runs next". The program is the resolved first word; for a launcher (a shell, an
// interpreter, `env`, `xcrun`, `npx`, `uv`, `make`, a package manager's `run`), it is the launcher plus what it runs.
// A file inside the project, and any script a launcher runs, is bound by its content (SHA-256), so an edit asks again.
// Inline code and launchers this file does not know how to read never get a standing permission: they ask every time.

/// What a standing permission binds a command to. Two commands are the same program when `key` is equal.
public struct AgentProgramBinding: Codable, Equatable, Sendable {
    /// The resolved path of the first word (symbolic links followed), or a bare name a launcher looks up itself.
    public var program: String
    /// For a launcher, what it runs: a script's resolved path, a tool ("notarytool"), a module ("-m twine"), a package
    /// script ("run deploy"), make's targets. Each launcher in the chain adds one.
    public var targets: [String]
    /// SHA-256 (hex) of each file whose content is bound, by resolved path.
    public var contents: [String: String]
    /// How the owner sees it: "Scripts/release-direct.sh", "xcrun notarytool", "npm run deploy".
    public var display: String

    public init(program: String, targets: [String] = [], contents: [String: String] = [:], display: String) {
        self.program = program
        self.targets = targets
        self.contents = contents
        self.display = display
    }

    /// What has to be equal for a grant to cover a command. The display text is not part of it.
    public var key: String {
        ([program] + targets + contents.keys.sorted().map { "\($0)#\(contents[$0] ?? "")" }).joined(separator: "\u{1F}")
    }
}

public enum AgentProgramVerdict: Equatable, Sendable {
    /// The command can be covered by a standing permission bound to this.
    case bound(AgentProgramBinding)
    /// It asks every time. The reason is shown on the window's lasting-choice button.
    case asksEveryTime(String)
}

public enum AgentProgramRule {
    /// Shells: `sh script` is bound to the script; `sh -c` is inline code.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "tcsh", "csh", "yash"]
    /// Interpreters read here: the first argument must be the script (or `-m module` for Python).
    static let interpreters: Set<String> = ["python", "ruby", "perl", "node", "php", "lua", "osascript", "rscript", "tclsh"]
    /// Launchers and programs that run other code in ways this file does not read: they ask every time rather than guess.
    static let unknownLaunchers: Set<String> = [
        "xargs", "sudo", "doas", "nohup", "nice", "time", "timeout", "gtimeout", "caffeinate", "script", "arch", "exec",
        "command", "builtin", "open", "watch", "entr", "parallel", "find", "busybox", "java", "javaw", "jshell", "dotnet",
        "go", "cargo", "swift", "swiftc", "deno", "pwsh", "nu", "elvish", "xonsh", "awk", "gawk", "mawk", "nawk",
        "expect", "wish", "tmux", "screen", "ssh", "launchctl", "su", "login", "pnpx",
        "gradle", "mvn", "rake", "bundle", "poetry", "pipenv", "hatch", "pdm", "rye", "pixi", "conda", "mamba", "tox",
        "nox", "just", "task", "direnv", "mise", "asdf", "devbox", "nix", "nix-shell", "docker", "podman", "kubectl",
    ]
    /// Variables that make a program load other code. A command started with one set never gets a standing permission:
    /// a granted script would run whatever the variable points at, with the secret in its environment.
    public static let codeLoadingVariables: Set<String> = [
        "BASH_ENV", "ENV", "ZDOTDIR", "SHELLOPTS", "BASHOPTS", "PS4", "PROMPT_COMMAND",
        "NODE_OPTIONS", "NODE_PATH", "BUN_OPTIONS",
        "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "PYTHONEXECUTABLE",
        "PERL5OPT", "PERL5LIB", "PERLLIB", "PERL5DB", "RUBYOPT", "RUBYLIB",
        "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS",
        "DEVELOPER_DIR", "MAKEFLAGS", "MAKEFILES", "GNUMAKEFLAGS", "NPM_CONFIG_SCRIPT_SHELL", "npm_config_script_shell",
    ]

    /// True for a variable that makes programs load other code.
    public static func isCodeLoading(_ name: String) -> Bool {
        codeLoadingVariables.contains(name) || name.hasPrefix("DYLD_") || name.hasPrefix("LD_")
    }

    /// The binding for a `use` request, or why it asks every time. `program` is the tool's resolved first word, `argv`
    /// the command as typed, `cwd` the tool's working folder read from the kernel, `project` its project, and
    /// `environment` the names of the variables set in the tool's environment.
    public static func bind(program: String?, argv: [String], cwd: String, project: String, environment: [String] = []) -> AgentProgramVerdict {
        if let variable = environment.first(where: isCodeLoading) {
            return .asksEveryTime("Started with \(variable) set, which makes programs load other code.")
        }
        guard let program, program.hasPrefix("/"), let first = argv.first, !first.isEmpty else {
            return .asksEveryTime("There is no command to bind it to.")
        }
        // The tool found `program` from the first word; it must be that word's program, read again here.
        let typedName = (first as NSString).lastPathComponent
        if first.contains("/") {
            guard realPath(absolute(first, cwd: cwd)) == realPath(program) else { return .asksEveryTime("The command's program could not be checked.") }
        } else {
            guard (program as NSString).lastPathComponent == first else { return .asksEveryTime("The command's program could not be checked.") }
        }
        guard let resolved = realPath(program), isRegularFile(resolved) else { return .asksEveryTime("The command's program could not be read.") }
        let context = Context(cwd: realPath(cwd) ?? cwd, project: realPath(project) ?? project)
        return context.bind(path: resolved, typedName: typedName, arguments: Array(argv.dropFirst()), depth: 0)
    }

    /// "python3.12" → "python", "Rscript" → "rscript", "-zsh" → "zsh".
    static func family(_ name: String) -> String {
        var lower = name.lowercased()
        while lower.hasPrefix("-") { lower.removeFirst() }
        for base in ["python", "ruby", "perl", "node", "php", "lua", "pypy"] where lower.hasPrefix(base) {
            let rest = lower.dropFirst(base.count)
            if rest.allSatisfy({ $0.isNumber || $0 == "." }) { return base == "pypy" ? "python" : base }
        }
        return lower
    }

    static func absolute(_ path: String, cwd: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    /// The path with every symbolic link followed, or nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// SHA-256 of a file's bytes, read in pieces. Nil when it cannot be read.
    public static func sha256(ofFile path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Context {
        var cwd: String
        var project: String

        func inProject(_ path: String) -> Bool { path.hasPrefix(project == "/" ? "/" : project + "/") }

        /// "Scripts/a.sh" inside the project, "~/bin/x" in the home folder, else the path.
        func shown(_ path: String) -> String {
            if inProject(path) { return String(path.dropFirst(project.count + 1)) }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }

        /// A file the command runs, resolved against the working folder, with its content bound.
        func script(_ word: String) -> (path: String, hash: String)? {
            guard let path = realPath(absolute(word, cwd: cwd)), isRegularFile(path), let hash = sha256(ofFile: path) else { return nil }
            return (path, hash)
        }

        /// The program at `path` (resolved) run with `arguments`. `typedName` is the first word as typed, so a link named
        /// `deploy` to `/bin/sh` is read as `sh`.
        func bind(path: String, typedName: String, arguments: [String], depth: Int) -> AgentProgramVerdict {
            guard depth < 4 else { return .asksEveryTime("The command starts too many launchers to follow.") }
            let names = [family((path as NSString).lastPathComponent), family(typedName)]
            func any(_ set: Set<String>) -> String? { names.first(where: set.contains) }
            var binding = AgentProgramBinding(program: path, display: shown(path))
            if inProject(path) {
                guard let hash = sha256(ofFile: path) else { return .asksEveryTime("The command's program could not be read.") }
                binding.contents[path] = hash
            }
            if let shell = any(shells) { return self.shell(shell, binding, arguments) }
            if let interpreter = any(interpreters) { return self.interpreter(interpreter, binding, arguments) }
            if names.contains("env") { return env(binding, arguments, depth: depth) }
            if names.contains("xcrun") { return xcrun(binding, arguments, depth: depth) }
            if names.contains("make") || names.contains("gmake") { return make(binding, arguments) }
            if let manager = names.first(where: { ["npm", "pnpm", "yarn", "bun"].contains($0) }) { return packageScript(manager, binding, arguments) }
            if names.contains("npx") || names.contains("bunx") || names.contains("uvx") { return npx(binding, arguments) }
            if names.contains("uv") { return uv(binding, arguments, depth: depth) }
            if let unknown = any(unknownLaunchers) {
                return .asksEveryTime("\(unknown) runs other programs in ways PasswordPie does not read.")
            }
            return .bound(binding)
        }

        private static let inline = "Inline code asks every time."

        /// Adds what a launcher runs to `binding`.
        private func adding(_ binding: AgentProgramBinding, target: String, display: String, file: (path: String, hash: String)? = nil) -> AgentProgramBinding {
            var next = binding
            next.targets.append(target)
            if let file { next.contents[file.path] = file.hash }
            next.display = display
            return next
        }

        private func shell(_ name: String, _ binding: AgentProgramBinding, _ arguments: [String]) -> AgentProgramVerdict {
            let harmlessLong: Set<String> = ["--login", "--norc", "--noprofile", "--posix", "--no-config", "--private", "--noediting"]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { index += 1; break }
                if argument == "-" { return .asksEveryTime(Self.inline) }
                guard argument.count > 1, argument.hasPrefix("-") || argument.hasPrefix("+") else { break }
                if argument.hasPrefix("--") {
                    if argument == "--command" || argument.hasPrefix("--command=") || argument.hasPrefix("--init-command") { return .asksEveryTime(Self.inline) }
                    guard harmlessLong.contains(argument) else { return .asksEveryTime("\(name) \(argument) is not read by PasswordPie.") }
                    index += 1
                    continue
                }
                let letters = argument.dropFirst()
                if letters.contains("c") || letters.contains("C") || letters.contains("s") { return .asksEveryTime(Self.inline) }
                if letters.contains("i") { return .asksEveryTime("An interactive shell asks every time.") }
                // `-o pipefail`: the option's name is the next word.
                if letters.contains("o") || letters.contains("O") { index += 1 }
                index += 1
            }
            guard index < arguments.count else { return .asksEveryTime(Self.inline) }
            guard let file = script(arguments[index]) else { return .asksEveryTime("The script \(arguments[index]) could not be read.") }
            return .bound(adding(binding, target: file.path, display: "\(name) \(shown(file.path))", file: file))
        }

        private func interpreter(_ name: String, _ binding: AgentProgramBinding, _ arguments: [String]) -> AgentProgramVerdict {
            let inlineFlags: [String: Set<String>] = [
                "python": ["-c"], "ruby": ["-e"], "perl": ["-e", "-E"], "node": ["-e", "--eval", "-p", "--print"], "php": ["-r"],
                "lua": ["-e"], "osascript": ["-e"], "rscript": ["-e"], "tclsh": [],
            ]
            // Flags that change nothing about which code runs.
            let harmless: [String: Set<String>] = [
                "python": ["-u", "-B", "-I", "-E", "-s", "-S", "-O", "-OO", "-q"], "node": ["--no-warnings", "--enable-source-maps"],
                "ruby": ["-w", "-W"], "perl": ["-w", "-W", "-T"],
            ]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("-") else { break }
                if argument == "-" || (inlineFlags[name] ?? []).contains(where: { argument == $0 || (argument.hasPrefix($0) && $0.count == 2 && !argument.hasPrefix("--")) }) {
                    return .asksEveryTime(Self.inline)
                }
                if name == "python", argument == "-m", index + 1 < arguments.count {
                    let module = arguments[index + 1]
                    // `python -m x` finds ./x.py (or a folder ./x) in the working folder first: then that is what runs.
                    let top = module.split(separator: ".").first.map(String.init) ?? module
                    var isFolder: ObjCBool = false
                    if FileManager.default.fileExists(atPath: absolute(top, cwd: cwd), isDirectory: &isFolder), isFolder.boolValue {
                        return .asksEveryTime("The module \(module) is a folder in the working folder.")
                    }
                    let shownName = (binding.program as NSString).lastPathComponent
                    if let file = script(top + ".py") {
                        return .bound(adding(binding, target: "-m \(module)", display: "\(shownName) -m \(module)", file: file))
                    }
                    return .bound(adding(binding, target: "-m \(module)", display: "\(shownName) -m \(module)"))
                }
                guard (harmless[name] ?? []).contains(argument) else { return .asksEveryTime("\(name) \(argument) is not read by PasswordPie.") }
                index += 1
            }
            guard index < arguments.count else { return .asksEveryTime(Self.inline) }
            guard let file = script(arguments[index]) else { return .asksEveryTime("The script \(arguments[index]) could not be read.") }
            return .bound(adding(binding, target: file.path, display: "\((binding.program as NSString).lastPathComponent) \(shown(file.path))", file: file))
        }

        /// The rest of the command, from its first word: a path is resolved here; a bare name is looked up by the
        /// launcher, so it is kept as typed (and read for being a launcher itself).
        private func next(_ binding: AgentProgramBinding, launcher: String, rest: [String], depth: Int) -> AgentProgramVerdict {
            guard let word = rest.first, !word.isEmpty else { return .asksEveryTime("There is no command to bind it to.") }
            let inner: AgentProgramVerdict
            if word.contains("/") {
                guard let path = realPath(absolute(word, cwd: cwd)), isRegularFile(path) else { return .asksEveryTime("\(word) could not be read.") }
                inner = bind(path: path, typedName: (word as NSString).lastPathComponent, arguments: Array(rest.dropFirst()), depth: depth + 1)
            } else {
                inner = bind(path: word, typedName: word, arguments: Array(rest.dropFirst()), depth: depth + 1)
            }
            guard case .bound(let found) = inner else { return inner }
            var combined = binding
            combined.targets.append(found.program)
            combined.targets += found.targets
            combined.contents.merge(found.contents) { $1 }
            combined.display = "\(launcher) \(found.display)"
            return .bound(combined)
        }

        private func env(_ binding: AgentProgramBinding, _ arguments: [String], depth: Int) -> AgentProgramVerdict {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-i" || argument == "-" || argument == "--ignore-environment" || argument == "-v" { index += 1; continue }
                if argument == "-u" { index += 2; continue }
                if argument.hasPrefix("--unset=") { index += 1; continue }
                if argument.hasPrefix("-") { return .asksEveryTime("env \(argument) is not read by PasswordPie.") }
                if let equals = argument.firstIndex(of: "="), equals != argument.startIndex {
                    let name = String(argument[..<equals])
                    if name == "PATH" || isCodeLoading(name) {
                        return .asksEveryTime("env sets \(name), which changes what runs.")
                    }
                    index += 1
                    continue
                }
                break
            }
            return next(binding, launcher: "env", rest: Array(arguments.dropFirst(index)), depth: depth)
        }

        private func xcrun(_ binding: AgentProgramBinding, _ arguments: [String], depth: Int) -> AgentProgramVerdict {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if ["--sdk", "-sdk", "--toolchain", "-toolchain"].contains(argument) { index += 2; continue }
                if ["-l", "--log", "-v", "--verbose", "-n", "--no-cache", "-r", "--run"].contains(argument) { index += 1; continue }
                if argument.hasPrefix("-") { return .asksEveryTime("xcrun \(argument) is not read by PasswordPie.") }
                break
            }
            guard index < arguments.count else { return .asksEveryTime("There is no command to bind it to.") }
            let tool = arguments[index]
            guard !tool.contains("/") else { return next(binding, launcher: "xcrun", rest: Array(arguments.dropFirst(index)), depth: depth) }
            // A developer tool found by xcrun: bound by its name. One that launches code is read like any other.
            let family = AgentProgramRule.family(tool)
            if shells.contains(family) || interpreters.contains(family) || unknownLaunchers.contains(family) {
                return next(binding, launcher: "xcrun", rest: Array(arguments.dropFirst(index)), depth: depth)
            }
            return .bound(adding(binding, target: tool, display: "xcrun \(tool)"))
        }

        private func make(_ binding: AgentProgramBinding, _ arguments: [String]) -> AgentProgramVerdict {
            var makefile: String?
            var targets: [String] = []
            var index = 0
            let harmless: Set<String> = ["-s", "--silent", "-k", "--keep-going", "-B", "--always-make", "-n", "--dry-run", "--no-print-directory", "-w", "-q"]
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-f" || argument == "--file" || argument == "--makefile" {
                    guard index + 1 < arguments.count else { return .asksEveryTime("make -f names no file.") }
                    makefile = arguments[index + 1]
                    index += 2
                    continue
                }
                if argument == "-j" || argument == "--jobs" {
                    index += (index + 1 < arguments.count && Int(arguments[index + 1]) != nil) ? 2 : 1
                    continue
                }
                if argument.hasPrefix("-j"), Int(argument.dropFirst(2)) != nil { index += 1; continue }
                if harmless.contains(argument) { index += 1; continue }
                if argument.hasPrefix("-") { return .asksEveryTime("make \(argument) is not read by PasswordPie.") }
                if argument.contains("=") { return .asksEveryTime("make with a variable on the command line asks every time.") }
                targets.append(argument)
                index += 1
            }
            let candidates = makefile.map { [$0] } ?? ["GNUmakefile", "makefile", "Makefile"]
            guard let file = candidates.lazy.compactMap({ self.script($0) }).first else { return .asksEveryTime("There is no Makefile to bind it to.") }
            let shownTargets = targets.isEmpty ? "" : " " + targets.joined(separator: " ")
            var bound = adding(binding, target: file.path, display: "make\(shownTargets)", file: file)
            bound.targets.append("targets:" + targets.joined(separator: " "))
            return .bound(bound)
        }

        /// `npm run deploy`, `pnpm run deploy`, `yarn run deploy`, `bun run deploy`: bound to the package's `package.json`.
        /// `bun run file.ts` and `bun file.ts` are a script. Other forms ask.
        private func packageScript(_ manager: String, _ binding: AgentProgramBinding, _ arguments: [String]) -> AgentProgramVerdict {
            if manager == "bun", let first = arguments.first, !first.hasPrefix("-"), first != "run", let file = script(first) {
                return .bound(adding(binding, target: file.path, display: "bun \(shown(file.path))", file: file))
            }
            guard arguments.count >= 2, arguments[0] == "run" || (manager == "npm" && arguments[0] == "run-script") else {
                return .asksEveryTime("Only \(manager) run <script> can be bound to a program.")
            }
            let name = arguments[1]
            guard !name.hasPrefix("-") else { return .asksEveryTime("\(manager) run \(name) is not read by PasswordPie.") }
            if manager == "bun", name.contains("."), let file = script(name) {
                return .bound(adding(binding, target: file.path, display: "bun run \(shown(file.path))", file: file))
            }
            guard let package = script("package.json") else { return .asksEveryTime("There is no package.json in the working folder.") }
            return .bound(adding(binding, target: "run \(name)", display: "\(manager) run \(name)", file: package))
        }

        private func npx(_ binding: AgentProgramBinding, _ arguments: [String]) -> AgentProgramVerdict {
            let launcher = (binding.program as NSString).lastPathComponent
            var index = 0
            while index < arguments.count, ["-y", "--yes", "--no", "-q", "--quiet"].contains(arguments[index]) { index += 1 }
            guard index < arguments.count else { return .asksEveryTime("There is no command to bind it to.") }
            let package = arguments[index]
            if package.hasPrefix("-") {
                return ["-c", "--call"].contains(package) ? .asksEveryTime(Self.inline) : .asksEveryTime("\(launcher) \(package) is not read by PasswordPie.")
            }
            return .bound(adding(binding, target: package, display: "\(launcher) \(package)"))
        }

        private func uv(_ binding: AgentProgramBinding, _ arguments: [String], depth: Int) -> AgentProgramVerdict {
            guard arguments.first == "run", arguments.count >= 2, !arguments[1].hasPrefix("-") else {
                return .asksEveryTime("Only uv run <command> with no options can be bound to a program.")
            }
            let rest = Array(arguments.dropFirst())
            if rest[0].hasSuffix(".py"), let file = script(rest[0]) {
                return .bound(adding(binding, target: file.path, display: "uv run \(shown(file.path))", file: file))
            }
            return next(binding, launcher: "uv run", rest: rest, depth: depth)
        }
    }
}
