import Foundation
import PasswordPieAgent

/// Which environment variables a project reads, found by reading its files: `process.env.X`, `os.environ["X"]`,
/// `os.getenv("X")`, `$X` in shell scripts and the like, and the names in the dotenv files at its top. Names only: no
/// value is kept, and none is ever printed. For `passwordpie write-env` (docs/AGENTS.md, "Writing a project's .env.pp").
struct RepositoryScan: Equatable {
    /// A dotenv file at the top of the project: `.env`, `.env.work`, or a link to one kept elsewhere.
    struct Dotenv: Equatable {
        /// Its name in the project: `.env`.
        var name: String
        /// Whose it is, from the name of the file it is or links to: `work` for a link to `…/work.env`.
        var identity: String?
        /// The names it sets, in its order.
        var names: [String]
        /// The names it sets to the path of a file, with that path: a key file handed over by its place on disk.
        var paths: [String: String]
    }

    /// The names the code reads, each with the first file it was found in.
    var names: [String: String] = [:]
    var dotenvs: [Dotenv] = []
    /// Where the code loads a dotenv file as a whole (`load_dotenv()`, `dotenv.config()`, `source .env`): a library may
    /// then read names the code never spells out.
    var loaders: [String] = []

    static let maximumFiles = 20_000
    static let maximumFileBytes = 1 << 20
    /// Folders that hold other people's code or what a build made.
    static let skippedFolders: Set<String> = [
        "node_modules", "vendor", "Pods", "DerivedData", "venv", "env", "site-packages", "__pycache__", "dist", "build",
        "target", "coverage", "out",
    ]

    static func scan(_ folder: URL) throws -> RepositoryScan {
        var scan = RepositoryScan()
        var seen = 0
        let root = folder.standardizedFileURL
        func visit(_ directory: URL, _ components: [String]) throws {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                seen += 1
                guard seen <= maximumFiles else { throw UsageError("This folder has more than \(maximumFiles) files outside its dependencies. Run write-env in the project's own folder.") }
                let values = try? child.resourceValues(forKeys: Set(keys))
                let path = (components + [name]).joined(separator: "/")
                if components.isEmpty, let dotenv = Self.dotenv(named: name, at: child) {
                    scan.dotenvs.append(dotenv)
                    continue
                }
                // A link is not followed, except a dotenv file at the top, which is often one.
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    // Hidden folders are tools' own; `.github` holds the project's workflows.
                    if name.hasPrefix("."), name != ".github" { continue }
                    if skippedFolders.contains(name) { continue }
                    try visit(child, components + [name])
                    continue
                }
                // Dotenv files hold values, not code that reads them. `.envrc` is a script, and is read.
                let holdsValues = name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= maximumFileBytes, !holdsValues, !name.hasSuffix(".pp"),
                      let data = try? Data(contentsOf: child), let text = String(data: data, encoding: .utf8) else { continue }
                for found in Self.names(in: text, fileName: name) where scan.names[found] == nil { scan.names[found] = path }
                if let loader = Self.loader(in: text) { scan.loaders.append("\(loader) in \(path)") }
            }
        }
        try visit(root, [])
        return scan
    }

    // MARK: Dotenv files at the top

    /// `.env`, `.env.<name>` or `<name>.env`, not a template and not a `.env.pp`. Read through a link.
    static func dotenv(named name: String, at url: URL) -> Dotenv? {
        guard name == ".env" || name.hasPrefix(".env.") || (name.hasSuffix(".env") && !name.hasPrefix(".")) else { return nil }
        let lowered = name.lowercased()
        guard !lowered.hasSuffix(".pp"), !["example", "sample", "template", "dist", "tmpl", "bak"].contains(where: { lowered.hasSuffix("." + $0) }) else { return nil }
        let target = url.resolvingSymlinksInPath()
        // Only a regular file is read: a link to a device or a pipe would never end.
        guard let found = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), found.isRegularFile == true,
              let size = found.fileSize, size <= maximumFileBytes,
              let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) else {
            return Dotenv(name: name, identity: identity(ofFileNamed: target.lastPathComponent), names: [], paths: [:])
        }
        var names: [String] = []
        var paths: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("export ") { body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !body.hasPrefix("#"), let equals = body.firstIndex(of: "=") else { continue }
            let variable = body[..<equals].trimmingCharacters(in: .whitespaces)
            guard isVariableName(variable) else { continue }
            if !names.contains(variable) { names.append(variable) }
            // Only a value that is the path of a file is looked at, to find the key file it stands for.
            var value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("~/") { value = NSHomeDirectory() + value.dropFirst(1) }
            if value.hasPrefix("/"), !value.contains("\n") { paths[variable] = value }
        }
        return Dotenv(name: name, identity: identity(ofFileNamed: target.lastPathComponent), names: names, paths: paths)
    }

    /// `work.env` and `.env.work` are "work". A bare `.env` names nobody.
    static func identity(ofFileNamed name: String) -> String? {
        if name.hasPrefix(".env."), name.count > 5 { return String(name.dropFirst(5)) }
        if name.hasSuffix(".env"), name.count > 4, !name.hasPrefix(".") { return String(name.dropLast(4)) }
        return nil
    }

    static func isVariableName(_ name: String) -> Bool { AgentEnvFile.isVariableName(name) }

    // MARK: Names in code

    private static let name = "([A-Za-z_][A-Za-z0-9_]*)"
    private static let quoted = #"\s*["'`]"# + name + #"["'`]"#

    /// Ways code names a variable it reads, in any file: JavaScript and TypeScript, Python, Go, Ruby, Rust, PHP, Swift.
    private static let anywhere: [NSRegularExpression] = [
        #"process\.env\."# + name,
        #"process\.env\["# + quoted + #"\s*\]"#,
        #"import\.meta\.env\."# + name,
        #"(?:Deno|Bun)\.env\.get\("# + quoted,
        #"Bun\.env\."# + name,
        #"\benviron\["# + quoted + #"\s*\]"#,
        #"\benviron\.get\("# + quoted,
        #"\b[Gg]etenv\("# + quoted,
        #"\bLookupEnv\("# + quoted,
        #"\bENV\["# + quoted + #"\s*\]"#,
        #"\bENV\.fetch\("# + quoted,
        #"\$_ENV\["# + quoted + #"\s*\]"#,
        #"\benv::var(?:_os)?\("# + quoted,
        #"\benv!\("# + quoted,
        #"processInfo\.environment\["# + quoted + #"\s*\]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// `const { A, B: renamed, C = "x" } = process.env`.
    private static let destructured = try! NSRegularExpression(pattern: #"\{([^{}]*)\}\s*=\s*process\.env\b"#)
    /// `$NAME` and `${NAME…}`, where a shell or a file a shell expands reads variables that way.
    private static let dollar = try! NSRegularExpression(pattern: #"\$\{?"# + name)

    /// The names `text` reads. `fileName` decides whether `$NAME` counts: in a shell script, a Makefile, a Dockerfile, a
    /// YAML file or `package.json`, not in code where `${name}` is a string template.
    static func names(in text: String, fileName: String) -> Set<String> {
        var found = Set<String>()
        let whole = NSRange(text.startIndex..., in: text)
        func collect(_ expression: NSRegularExpression) {
            for match in expression.matches(in: text, range: whole) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        anywhere.forEach(collect)
        for match in destructured.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            for part in text[range].split(separator: ",") {
                let key = part.split(whereSeparator: { $0 == ":" || $0 == "=" }).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                if isVariableName(key) { found.insert(key) }
            }
        }
        if expandsDollar(fileName: fileName, text: text) { collect(dollar) }
        return found
    }

    static func expandsDollar(fileName: String, text: String) -> Bool {
        let lowered = fileName.lowercased()
        let ext = (lowered as NSString).pathExtension
        if ["sh", "bash", "zsh", "fish", "ksh", "command", "yml", "yaml", "mk", "envrc"].contains(ext) { return true }
        if ["makefile", "dockerfile", "justfile", "procfile", "package.json", ".envrc"].contains(lowered) || lowered.hasPrefix("dockerfile.") { return true }
        // A script with no extension says what runs it on its first line.
        if text.hasPrefix("#!"), let first = text.split(whereSeparator: \.isNewline).first {
            return ["sh", "bash", "zsh", "fish", "ksh", "dash"].contains { first.hasSuffix("/" + $0) || first.hasSuffix(" " + $0) || first.contains("/\($0) ") || first.contains(" \($0) ") }
        }
        return false
    }

    /// How `text` loads a dotenv file as a whole, when it does.
    static func loader(in text: String) -> String? {
        for (pattern, said) in [
            (#"\bload_dotenv\s*\("#, "load_dotenv()"), (#"\bdotenv_values\s*\("#, "dotenv_values()"),
            (#"\bdotenv\.config\s*\("#, "dotenv.config()"), (#"["']dotenv/config["']"#, "dotenv/config"),
            (#"(?m)^\s*(?:source|\.)\s+\S*\.env\b"#, "source .env"), (#"--env-file[= ]\S*\.env\b(?!\.pp)"#, "--env-file .env"),
        ] where text.range(of: pattern, options: .regularExpression) != nil {
            return said
        }
        return nil
    }
}
