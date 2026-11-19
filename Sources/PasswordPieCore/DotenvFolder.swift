import Foundation

/// What a folder of dotenv files holds, as items for the database: `<service>/<identity>.env` is folder `<service>`, item
/// `<identity>`, one field per variable, comment lines as notes, key files beside it as attachments. Everything else is
/// listed as left alone. See docs/UX.md, "A folder of .env files becomes items".
public struct DotenvPlan: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        /// The variable's name in the file.
        public var name: String
        /// The field it becomes. The same, unless the name is one an item keeps for itself (`PASSWORD`, `URL`…).
        public var key: String
        public var value: String
    }

    public struct KeyFile: Equatable, Sendable {
        /// Where it is inside the folder, with `/` between the parts.
        public var path: String
        /// The attachment's name: the file's own.
        public var name: String
        public var data: Data
    }

    public struct Item: Equatable, Sendable, Identifiable {
        /// The folders the file is in, below the chosen folder.
        public var folder: [String]
        public var title: String
        /// The `.env` file it was read from. Nil for an item that holds only key files.
        public var file: String?
        public var fields: [Field]
        /// The file's comment lines.
        public var notes: String
        public var keyFiles: [KeyFile]

        public var id: String { (folder + [title]).joined(separator: "\u{1F}") }
    }

    public enum Reason: String, Sendable, CaseIterable {
        /// A name that starts with `.`: `.git`, `.backup`, a hidden file.
        case hidden
        /// A name that starts with `_`: `_local`, `_archive`.
        case underscore
        case template
        case oldCopy
        case link
        case tooLarge
        /// Named like a dotenv file, and not UTF-8 text.
        case notText
        /// Another file in the folder is already this item.
        case duplicate
        case dependencies
        case other
    }

    public struct Skipped: Equatable, Sendable {
        public var path: String
        public var reason: Reason
        public var isFolder: Bool
        /// The variables being imported whose value this file, or a file in this folder, holds in plain text.
        public var holds: [String] = []
    }

    /// Something in a file the person should look at. Names and line numbers, never a value.
    public enum Remark: Equatable, Sendable {
        case unreadable(file: String, lines: [Int])
        case repeated(file: String, names: [String])
        case shellSensitive(file: String, names: [String])
        case renamed(file: String, name: String, key: String)
    }

    /// The chosen folder's own name.
    public var folderName: String
    public var items: [Item] = []
    public var skipped: [Skipped] = []
    public var remarks: [Remark] = []

    /// The field a variable is kept in. An item's own fields and PasswordPie's bookkeeping are matched without regard to
    /// case everywhere in the app, so a variable named like one would be taken for it: it gets " (variable)" after it.
    public static func fieldKey(forVariable name: String) -> String {
        let lowered = name.lowercased()
        let own: Set<String> = ["title", "username", "password", "url", "notes", "otp"]
        if own.contains(lowered) || lowered.hasPrefix("timeotp") || EntryMerge.isReservedKey(name) {
            return name + " (variable)"
        }
        return name
    }
}

public struct DotenvFolderError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum DotenvFolder {
    /// A folder with more entries than this is not a folder of dotenv files: someone chose their home folder.
    public static let maximumFiles = 50_000
    /// A dotenv file or a key file larger than this is left alone.
    public static let maximumFileBytes = 1 << 20
    /// A file left alone is looked into for imported values only up to this size.
    static let maximumScannedBytes = 4 << 20
    /// The shortest value looked for in the files left alone. A shorter one is in too many files by chance.
    static let minimumScannedValue = 8
    static let keyFilesTitle = "Key files"

    /// Reads `folder` and its subfolders. Nothing in it is changed.
    public static func read(_ folder: URL) throws -> DotenvPlan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DotenvFolderError(description: "Choose a folder: the one that holds the .env files.")
        }
        var walk = Walk(root: folder.standardizedFileURL)
        try walk.visit(walk.root, components: [])
        var plan = DotenvPlan(folderName: folder.lastPathComponent)
        plan.items = walk.items
        plan.skipped = walk.skipped
        plan.remarks = walk.remarks
        try markCopies(in: &plan, root: walk.root, budget: maximumFiles - walk.seen)
        return plan
    }

    // MARK: Names

    /// The item a dotenv file is: `work.env` and `.env.work` are "work", `.env` is "env". Nil for any other name.
    static func identity(ofFileNamed name: String) -> String? {
        if name == ".env" { return "env" }
        if name.hasPrefix(".env."), name.count > 5 { return String(name.dropFirst(5)) }
        if name.hasSuffix(".env"), name.count > 4, !name.hasPrefix(".") { return String(name.dropLast(4)) }
        return nil
    }

    /// `.env.example`, `work.env.sample`, `example.env`: a file with the names and none of the values.
    static func isTemplate(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if [".example", ".sample", ".template", ".tmpl", ".dist"].contains(where: lowered.hasSuffix) { return true }
        guard let identity = identity(ofFileNamed: lowered) else { return false }
        return ["example", "sample", "template"].contains(identity)
    }

    /// `work.env.bak`, `work.env.bak2`, `work.env.old`, `work.env~`: a copy kept from before a change.
    static func isOldCopy(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasSuffix("~") { return true }
        return lowered.range(of: #"\.(bak[0-9]*|old|orig|backup|swp)$"#, options: .regularExpression) != nil
    }

    static let dependencyFolders: Set<String> = ["node_modules", "Pods", "DerivedData", "venv", "site-packages"]

    // MARK: Key files

    /// A file that is a secret as a whole: a PEM block, a key container, a JSON file with a private key or a client
    /// secret, or a file named for the one key it holds.
    static func isKeyFile(named name: String, data: Data) -> Bool {
        let file = name as NSString
        let ext = file.pathExtension.lowercased()
        if ["pem", "key", "p8", "p12", "pfx"].contains(ext) { return true }
        let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        if head.range(of: #"(?m)^-----BEGIN [A-Z0-9 ]+-----"#, options: .regularExpression) != nil { return true }
        if ext == "json", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let secret: Set<String> = ["private_key", "private_key_id", "client_secret", "refresh_token"]
            if object.keys.contains(where: secret.contains) { return true }
            // Google's OAuth client file keeps them one level down: {"installed": {"client_secret": …}}.
            return object.values.contains { ($0 as? [String: Any])?.keys.contains(where: secret.contains) == true }
        }
        let bare: Set<String> = ["api_key", "apikey", "api-key", "token", "access_token", "secret", "credentials"]
        let stem = file.deletingPathExtension.lowercased()
        // `api_key`, and `work-api_key` or `personal.token`: the word alone, or after the name of whose it is.
        let namesAKey = bare.contains { word in stem == word || ["-", "_", "."].contains { stem.hasSuffix($0 + word) } }
        if ext.isEmpty || ext == "txt", namesAKey, data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    /// True when `title` stands in `name` as a word of its own: "work" in `work.pem` and `google-work.json`, not in
    /// `network.pem`.
    static func names(_ name: String, title: String) -> Bool {
        let (name, title) = (name.lowercased(), title.lowercased())
        guard !title.isEmpty else { return false }
        var search = name.startIndex..<name.endIndex
        while let found = name.range(of: title, range: search) {
            let before = found.lowerBound == name.startIndex ? nil : name[name.index(before: found.lowerBound)]
            let after = found.upperBound == name.endIndex ? nil : name[found.upperBound]
            let free: (Character?) -> Bool = { $0.map { !$0.isLetter && !$0.isNumber } ?? true }
            if free(before), free(after) { return true }
            search = name.index(after: found.lowerBound)..<name.endIndex
        }
        return false
    }

    // MARK: Copies of the values in the files left alone

    /// Says which files left alone hold a value that is being imported: generated copies, backups, a script with a token
    /// pasted in. Those are the files to delete with the dotenv files once the values are in the database.
    private static func markCopies(in plan: inout DotenvPlan, root: URL, budget: Int) throws {
        var needles: [(name: String, bytes: Data)] = []
        var seen = Set<Data>()
        for item in plan.items {
            for field in item.fields where field.value.utf8.count >= minimumScannedValue {
                let bytes = Data(field.value.utf8)
                if seen.insert(bytes).inserted { needles.append((field.name, bytes)) }
            }
        }
        guard !needles.isEmpty else { return }
        var remaining = budget
        func held(in url: URL) -> [String] {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumScannedBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            return needles.filter { data.range(of: $0.bytes) != nil }.map(\.name)
        }
        for index in plan.skipped.indices {
            let skipped = plan.skipped[index]
            guard skipped.reason != .link, skipped.reason != .dependencies else { continue }
            let url = root.appendingPathComponent(skipped.path)
            guard skipped.isFolder else {
                plan.skipped[index].holds = held(in: url)
                continue
            }
            // A folder that was not opened for items (`.backup`, `_local`) is still looked into. Not `.git`: what it
            // holds is packed, and a value would not be found as it is.
            guard url.lastPathComponent != ".git" else { continue }
            var names: [String] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let file as URL in files {
                remaining -= 1
                guard remaining > 0 else { break }
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                for name in held(in: file) where !names.contains(name) { names.append(name) }
            }
            plan.skipped[index].holds = names
        }
    }
}

/// One pass over the folder: its dotenv files become items, its key files are attached, the rest is listed.
private struct Walk {
    let root: URL
    var items: [DotenvPlan.Item] = []
    var skipped: [DotenvPlan.Skipped] = []
    var remarks: [DotenvPlan.Remark] = []
    var seen = 0

    init(root: URL) {
        self.root = root
    }

    mutating func visit(_ directory: URL, components: [String]) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw DotenvFolderError(description: "Couldn’t read the folder “\(directory.lastPathComponent)”.")
        }
        var folders: [(URL, String)] = []
        var dotenvs: [(name: String, identity: String, data: Data)] = []
        var keyFiles: [DotenvPlan.KeyFile] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            if name == ".DS_Store" { continue }
            seen += 1
            guard seen <= DotenvFolder.maximumFiles else {
                throw DotenvFolderError(description: "This folder has more than \(DotenvFolder.maximumFiles) files in it. Choose the folder that holds the .env files.")
            }
            let path = (components + [name]).joined(separator: "/")
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true
            func skip(_ reason: DotenvPlan.Reason) {
                skipped.append(DotenvPlan.Skipped(path: path, reason: reason, isFolder: isFolder))
            }
            // A link is never followed: what it points at may be anywhere.
            if values?.isSymbolicLink == true {
                skipped.append(DotenvPlan.Skipped(path: path, reason: .link, isFolder: false))
                continue
            }
            if isFolder {
                if name.hasPrefix(".") { skip(.hidden) }
                else if name.hasPrefix("_") { skip(.underscore) }
                else if DotenvFolder.dependencyFolders.contains(name) { skip(.dependencies) }
                else { folders.append((child, name)) }
                continue
            }
            guard values?.isRegularFile == true else {
                skip(.other)
                continue
            }
            if DotenvFolder.isTemplate(name) { skip(.template); continue }
            if DotenvFolder.isOldCopy(name) { skip(.oldCopy); continue }
            if name.hasPrefix("_") { skip(.underscore); continue }
            let size = values?.fileSize ?? 0
            if let identity = DotenvFolder.identity(ofFileNamed: name) {
                guard size <= DotenvFolder.maximumFileBytes else { skip(.tooLarge); continue }
                guard let data = try? Data(contentsOf: child), String(data: data, encoding: .utf8) != nil else { skip(.notText); continue }
                if dotenvs.contains(where: { $0.identity == identity }) { skip(.duplicate); continue }
                dotenvs.append((name, identity, data))
                continue
            }
            if name.hasPrefix(".") { skip(.hidden); continue }
            // Only a file that could be a key file is read: an image or a snapshot of 40 MB is not.
            guard size <= DotenvFolder.maximumFileBytes else {
                let ext = (name as NSString).pathExtension.lowercased()
                skip(["pem", "key", "p8", "p12", "pfx"].contains(ext) ? .tooLarge : .other)
                continue
            }
            guard let data = try? Data(contentsOf: child), DotenvFolder.isKeyFile(named: name, data: data) else { skip(.other); continue }
            keyFiles.append(DotenvPlan.KeyFile(path: path, name: name, data: data))
        }

        var found: [DotenvPlan.Item] = []
        for dotenv in dotenvs {
            let path = (components + [dotenv.name]).joined(separator: "/")
            let parsed = DotenvFile.parse(String(decoding: dotenv.data, as: UTF8.self))
            var fields: [DotenvPlan.Field] = []
            for variable in parsed.variables {
                let key = DotenvPlan.fieldKey(forVariable: variable.name)
                if key != variable.name { remarks.append(.renamed(file: path, name: variable.name, key: key)) }
                fields.append(DotenvPlan.Field(name: variable.name, key: key, value: variable.value))
            }
            if !parsed.unreadable.isEmpty { remarks.append(.unreadable(file: path, lines: parsed.unreadable)) }
            if !parsed.repeated.isEmpty { remarks.append(.repeated(file: path, names: parsed.repeated)) }
            let sensitive = parsed.variables.filter(\.shellSensitive).map(\.name)
            if !sensitive.isEmpty { remarks.append(.shellSensitive(file: path, names: sensitive)) }
            found.append(DotenvPlan.Item(
                folder: components, title: dotenv.identity, file: path, fields: fields,
                notes: parsed.comments.joined(separator: "\n"), keyFiles: []
            ))
        }
        // A key file goes to the item its name names, else to the folder's only item, else to "Key files".
        for keyFile in keyFiles {
            let named = found.indices.filter { DotenvFolder.names(keyFile.name, title: found[$0].title) }
            let index: Int
            if named.count == 1 {
                index = named[0]
            } else if found.count == 1 {
                index = 0
            } else if let shared = found.firstIndex(where: { $0.title == DotenvFolder.keyFilesTitle }) {
                index = shared
            } else {
                found.append(DotenvPlan.Item(folder: components, title: DotenvFolder.keyFilesTitle, file: nil, fields: [], notes: "", keyFiles: []))
                index = found.count - 1
            }
            found[index].keyFiles.append(keyFile)
        }
        items.append(contentsOf: found)
        for (folder, name) in folders {
            try visit(folder, components: components + [name])
        }
    }
}
