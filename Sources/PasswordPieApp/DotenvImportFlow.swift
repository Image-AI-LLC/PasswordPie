import AppKit
import Combine
import PasswordPieCore

/// Preferences > Import > A Folder of .env Files: the folder, what was found in it, and what importing did (docs/UX.md,
/// "A folder of .env files becomes items"). The folder is only ever read. What it held stays in memory until it is
/// imported, another folder or source is chosen, Preferences closes, or the database locks. Nothing here that reaches
/// the screen, a message or the debug status file holds a value: names and counts only.
@MainActor
final class DotenvImportFlow: ObservableObject {
    /// One item of the folder, as the page lists it.
    struct Row: Identifiable, Equatable {
        let id: String
        /// "stripe › work", with the folder it is put inside in front.
        let place: String
        let fieldNames: [String]
        let fileNames: [String]
        let status: DotenvImport.Status
    }

    struct Outcome: Equatable {
        var summary: DotenvImport.Summary
        var folderName: String
    }

    enum Stage: Equatable {
        case waiting
        /// The folder is being read, off the main thread.
        case reading(folderName: String)
        /// Read, and not in the database yet.
        case found
        case done(Outcome)
    }

    @Published private(set) var stage: Stage = .waiting
    @Published private(set) var error = ""
    @Published private(set) var rows: [Row] = []
    /// The items left out: unticked rows.
    @Published private(set) var excluded: Set<String> = []
    /// "Put them inside": the folder everything lands in. Empty for the top of the database.
    @Published var parentDraft = "" {
        didSet { if parentDraft != oldValue { refreshRows() } }
    }

    /// Shows the open panel for a folder. Replaced in tests.
    var pickFolder: () -> URL? = {
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.message = "Choose the folder that holds your .env files. It is only read."
        chooser.prompt = "Choose"
        return chooser.runModal() == .OK ? chooser.url : nil
    }

    private let session: VaultSession
    private(set) var plan: DotenvPlan?
    private var generation = 0
    private var readTask: Task<Void, Never>?
    private var lockWatch: AnyCancellable?

    init(session: VaultSession) {
        self.session = session
        lockWatch = session.$locked.dropFirst().sink { [weak self] locked in
            if locked { self?.forget() }
        }
    }

    var parent: [String] { DotenvImport.parentPath(parentDraft) }

    // MARK: The folder

    func chooseFolder() {
        guard let url = pickFolder() else { return }
        take(url)
    }

    /// A folder dropped on the page or chosen in the panel. Reads it; nothing is in the database yet.
    func take(_ url: URL) {
        guard !session.locked else {
            fail("Unlock PasswordPie first.")
            return
        }
        forget()
        generation += 1
        let ticket = generation
        stage = .reading(folderName: url.lastPathComponent)
        readTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<DotenvPlan, Error> in
                // In the App Store sandbox a dropped or chosen folder is security-scoped for as long as it is read.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try DotenvFolder.read(url) }
            }.value
            // The page moved on, or the database locked, while the folder was being read.
            guard let self, self.generation == ticket else { return }
            self.finishRead(result)
        }
    }

    private func finishRead(_ result: Result<DotenvPlan, Error>) {
        switch result {
        case .success(let plan) where plan.items.isEmpty:
            stage = .waiting
            error = "No .env files or key files in “\(plan.folderName)”. Choose the folder that holds them."
        case .success(let plan):
            self.plan = plan
            stage = .found
            refreshRows()
        case .failure(let failure):
            stage = .waiting
            error = (failure as? DotenvFolderError)?.description ?? "Couldn’t read that folder."
        }
    }

    /// Returns once a folder handed over has been read. For tests and debug hooks.
    func settled() async {
        await readTask?.value
    }

    // MARK: What was found

    private func refreshRows() {
        guard let plan, stage == .found else { return }
        let parent = parent
        let statuses = session.dotenvStatuses(of: plan.items, inside: parent)
        rows = plan.items.enumerated().map { offset, item in
            Row(
                id: item.id,
                place: (parent + item.folder + [item.title]).joined(separator: " › "),
                fieldNames: item.fields.map(\.key),
                fileNames: item.keyFiles.map(\.name),
                status: statuses?[offset] ?? .new
            )
        }
    }

    func isIncluded(_ id: String) -> Bool { !excluded.contains(id) }

    func toggle(_ id: String) {
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
    }

    /// The ticked rows that importing would add or change.
    var pendingCount: Int {
        rows.filter { isIncluded($0.id) && $0.status != .upToDate }.count
    }

    var importTitle: String { "Import \(Self.counted(pendingCount, "Item"))" }

    /// Why there is nothing to press Import for, when there is not.
    var nothingToImport: String? {
        guard pendingCount == 0 else { return nil }
        return rows.contains { isIncluded($0.id) } ? "Already up to date. Nothing to import." : "Tick at least one item to import."
    }

    // MARK: Importing

    func commit() {
        guard stage == .found, let plan else { return }
        guard !session.locked else {
            fail("Unlock PasswordPie first.")
            return
        }
        let chosen = plan.items.filter { isIncluded($0.id) }
        guard let summary = session.importDotenv(chosen, inside: parent) else {
            error = "Couldn’t save the imported items. Nothing was changed."
            return
        }
        let name = plan.folderName
        forgetPlan()
        stage = .done(Outcome(summary: summary, folderName: name))
    }

    func startOver() {
        forget()
    }

    func forget() {
        // A read still running finishes into nothing.
        forgetPlan()
        error = ""
        stage = .waiting
    }

    private func forgetPlan() {
        generation += 1
        plan = nil
        rows = []
        excluded = []
    }

    private func fail(_ text: String) {
        forget()
        error = text
    }

    // MARK: Words

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// "3 fields, 1 key file".
    static func contents(_ row: Row) -> String {
        var parts: [String] = []
        if !row.fieldNames.isEmpty || row.fileNames.isEmpty { parts.append(counted(row.fieldNames.count, "field")) }
        if !row.fileNames.isEmpty { parts.append(counted(row.fileNames.count, "key file")) }
        return parts.joined(separator: ", ")
    }

    /// "New", "Up to date", or what would change: "1 field changes, 2 new fields".
    static func statusText(_ status: DotenvImport.Status) -> String {
        switch status {
        case .new: return "New"
        case .upToDate: return "Up to date"
        case .changes(let changes):
            var parts: [String] = []
            func add(_ count: Int, one: String, many: String) {
                if count > 0 { parts.append(count == 1 ? "1 \(one)" : "\(count) \(many)") }
            }
            add(changes.changedFields.count, one: "field changes", many: "fields change")
            add(changes.newFields.count, one: "new field", many: "new fields")
            add(changes.changedFiles.count, one: "key file changes", many: "key files change")
            add(changes.newFiles.count, one: "new key file", many: "new key files")
            if changes.notes { parts.append("notes change") }
            return parts.joined(separator: ", ")
        }
    }

    /// The files left alone, counted by kind: "4 other files", "1 template", "1 old copy"…
    static func leftAlone(_ skipped: [DotenvPlan.Skipped]) -> [String] {
        func count(_ reasons: [DotenvPlan.Reason], folders: Bool = false) -> Int {
            skipped.filter { reasons.contains($0.reason) && $0.isFolder == folders }.count
        }
        var lines: [String] = []
        func add(_ count: Int, _ one: String, _ many: String) {
            if count > 0 { lines.append(count == 1 ? "1 \(one)" : "\(count) \(many)") }
        }
        add(count([.other]), "other file", "other files")
        add(count([.template]), "template", "templates")
        add(count([.oldCopy]), "old copy", "old copies")
        add(count([.hidden, .underscore, .dependencies, .other], folders: true), "folder not opened", "folders not opened")
        add(count([.hidden, .underscore]), "file whose name starts with . or _", "files whose names start with . or _")
        add(count([.link]), "link, not followed", "links, not followed")
        add(count([.tooLarge]), "file too large for a key file (over 1 MB)", "files too large for a key file (over 1 MB)")
        add(count([.notText]), ".env file that is not text", ".env files that are not text")
        add(count([.duplicate]), "file that would be an item another file already is", "files that would be items other files already are")
        return lines
    }

    static func reasonText(_ skipped: DotenvPlan.Skipped) -> String {
        switch skipped.reason {
        case .hidden, .underscore: return skipped.isFolder ? "folder not opened: its name starts with . or _" : "name starts with . or _"
        case .dependencies: return "folder not opened: dependencies"
        case .template: return "template"
        case .oldCopy: return "old copy"
        case .link: return "link"
        case .tooLarge: return "too large"
        case .notText: return "not text"
        case .duplicate: return "already an item"
        case .other: return skipped.isFolder ? "folder not opened: the database cannot keep its name" : "not a .env or key file"
        }
    }

    /// One line per thing to look at, naming files, lines and variables. Never a value.
    static func remarkText(_ remark: DotenvPlan.Remark) -> String {
        switch remark {
        case .unreadable(let file, let lines):
            let numbers = lines.prefix(8).map(String.init).joined(separator: ", ") + (lines.count > 8 ? "…" : "")
            return "\(file): \(lines.count == 1 ? "line \(numbers) is" : "lines \(numbers) are") not NAME=value, and \(lines.count == 1 ? "was" : "were") not read."
        case .repeated(let file, let names):
            return "\(file): \(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") set more than once. The last value is used."
        case .shellSensitive(let file, let names):
            return "\(file): \(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") a $, a backtick, a backslash or a space in the value. A shell that runs source on the file reads \(names.count == 1 ? "it" : "them") differently."
        case .renamed(let file, let name, let key):
            return "\(file): \(name) is kept as the field “\(key)”, apart from the item’s own \(name.lowercased())."
        }
    }

    static func summaryText(_ outcome: Outcome) -> String {
        let summary = outcome.summary
        var parts: [String] = []
        if summary.added > 0 { parts.append("\(summary.added) added") }
        if summary.updated > 0 { parts.append("\(summary.updated) updated") }
        if parts.isEmpty { return "Already up to date. Nothing was changed." }
        return parts.joined(separator: ", ") + "."
    }

    static func folderText(_ outcome: Outcome) -> String {
        "The files in “\(outcome.folderName)” are as they were. They still hold every value in plain text."
    }

    #if DEBUG
    /// The page's words, for the debug status file. Names and counts only.
    var debugSummary: [String: Any] {
        [
            "stage": String(describing: stage).split(separator: "(").first.map(String.init) ?? "",
            "error": error,
            "rows": rows.map { "\(isIncluded($0.id) ? "☑" : "☐") \($0.place): \(Self.contents($0)), \(Self.statusText($0.status))" },
            "leftAlone": Self.leftAlone(plan?.skipped ?? []),
            "holds": (plan?.skipped ?? []).filter { !$0.holds.isEmpty }.map(\.path),
            "remarks": (plan?.remarks ?? []).map(Self.remarkText),
            "import": stage == .found ? (nothingToImport ?? importTitle) : "",
        ]
    }
    #endif
}
