import AppKit
import Combine
import PasswordPieCore

/// What Apple Passwords sending its items came to (macOS 26+). Preferences > Import shows it.
enum ExchangeReport: Equatable {
    case reading
    case failed(String)
    case done(BrowserImportSummary)
}

/// Preferences > Import: a source, its file, and what importing it did (docs/UX.md, "Import with a guide").
/// What a file held stays in memory only until it is imported, another file or source is chosen, or the database locks.
@MainActor
final class ImportFlow: ObservableObject {
    struct Outcome: Equatable {
        enum File: Equatable {
            /// Nothing on disk to worry about: a protected file, or no file at all.
            case none
            /// A plain-text export, and the user has not said what to do with it yet.
            case ask
            case deleted
            case kept
            case deleteFailed
        }

        var summary: BrowserImportSummary
        var source: BrowserImportSource
        var fileName: String
        var file: File
    }

    enum Stage: Equatable {
        case waiting
        /// The file needs a password before it can be read.
        case protected(fileName: String)
        /// Read, and not in the database yet.
        case found(fileName: String, count: Int)
        case done(Outcome)
    }

    /// Nil: the grid of sources.
    @Published private(set) var tile: ImportTile?
    @Published private(set) var stage: Stage = .waiting
    @Published private(set) var error = ""
    /// Apple Passwords is sending its items.
    @Published private(set) var reading = false
    @Published var passwordDraft = ""

    /// Shows the open panel. Replaced in tests.
    var pickFile: (_ message: String) -> URL? = { message in
        let chooser = NSOpenPanel()
        // Files, and an .opvault package. A plain folder stays out (see `DatabaseChooser`).
        DatabaseChooser.configure(chooser)
        chooser.message = message
        return chooser.runModal() == .OK ? chooser.url : nil
    }

    private let session: VaultSession
    private var url: URL?
    private var pending: ImportedFile?
    private var lockWatch: AnyCancellable?

    init(session: VaultSession) {
        self.session = session
        lockWatch = session.$locked.dropFirst().sink { [weak self] locked in
            if locked { self?.forget() }
        }
    }

    // MARK: Choosing

    func choose(_ tile: ImportTile) {
        forget()
        self.tile = tile
    }

    func showSources() {
        forget()
        tile = nil
    }

    func chooseFile() {
        guard let tile, let source = tile.source else { return }
        let guide = ImportGuide.guide(for: tile, exchange: false, macOS: 15)
        guard let url = pickFile("Choose the \(source == .csv ? "exported" : source.label) file: \(guide.files)") else { return }
        take(url)
    }

    /// A file dropped on the page or chosen in the panel. Reads it; nothing is in the database yet.
    func take(_ url: URL) {
        guard tile?.source != nil else { return }
        guard !session.locked else {
            fail("Unlock PasswordPie first.")
            return
        }
        forget()
        self.url = url
        read(password: "")
    }

    /// The password typed for a protected file.
    func unlockFile() {
        guard case .protected = stage, !passwordDraft.isEmpty else { return }
        let password = passwordDraft
        passwordDraft = ""
        read(password: password)
    }

    private func read(password: String) {
        guard let url, let source = tile?.source else { return }
        error = ""
        do {
            let file = try BrowserImport.read(url, source: source, password: password)
            pending = file
            stage = .found(fileName: url.lastPathComponent, count: file.entries.count)
        } catch VaultOpenError.wrongPassword {
            pending = nil
            stage = .protected(fileName: url.lastPathComponent)
            if !password.isEmpty { error = "That password does not open this file." }
        } catch {
            pending = nil
            self.url = nil
            stage = .waiting
            self.error = session.openErrorText(error)
        }
    }

    // MARK: Importing

    func commit() {
        guard let file = pending, let url, let source = tile?.source else { return }
        guard !session.locked else {
            fail("Unlock PasswordPie first.")
            return
        }
        guard let summary = session.mergeImported(file.entries, source: source) else {
            error = "Couldn’t save the imported passwords. Nothing was changed."
            return
        }
        pending = nil
        error = ""
        stage = .done(Outcome(summary: summary, source: source, fileName: url.lastPathComponent, file: file.plainText ? .ask : .none))
    }

    /// Deletes the plain-text export outright. The Trash would keep the passwords readable.
    func deleteFile() {
        guard case .done(var outcome) = stage, outcome.file == .ask, let url else { return }
        do {
            try BrowserImport.deleteExport(at: url)
            outcome.file = .deleted
        } catch {
            outcome.file = .deleteFailed
        }
        self.url = nil
        stage = .done(outcome)
    }

    func keepFile() {
        guard case .done(var outcome) = stage, outcome.file == .ask else { return }
        outcome.file = .kept
        url = nil
        stage = .done(outcome)
    }

    /// Back to an empty drop zone on the same source.
    func startOver() {
        forget()
    }

    // MARK: Apple Passwords, without a file

    func receive(_ report: ExchangeReport) {
        if tile?.source != .applePasswords { tile = ImportTile.tile("apple-passwords") }
        forget()
        switch report {
        case .reading:
            reading = true
        case .failed(let text):
            error = text
        case .done(let summary):
            stage = .done(Outcome(summary: summary, source: .applePasswords, fileName: "", file: .none))
        }
    }

    // MARK: Words

    /// "214 passwords" from a browser, "214 items" from a password manager, which also holds notes and cards.
    static func counted(_ count: Int, from source: BrowserImportSource, capitalized: Bool = false) -> String {
        let noun = source.exportsWholeList ? "password" : "item"
        let word = count == 1 ? noun : noun + "s"
        return "\(count) \(capitalized ? word.capitalized : word)"
    }

    static func summaryText(_ outcome: Outcome) -> String {
        let summary = outcome.summary
        var parts: [String] = []
        if summary.added > 0 { parts.append("\(summary.added) added") }
        if summary.updated > 0 { parts.append("\(summary.updated) updated") }
        if summary.removed > 0 { parts.append("\(summary.removed) moved to the Recycle Bin") }
        if parts.isEmpty { return "\(outcome.source.label) is already up to date. Nothing was changed." }
        return parts.joined(separator: ", ") + ", in the “\(outcome.source.label)” group."
    }

    static func fileText(_ outcome: Outcome) -> String {
        switch outcome.file {
        case .none: return ""
        case .ask: return "“\(outcome.fileName)” still holds every password in plain text. They are in your database now, so the file is no longer needed."
        case .deleted: return "The export file was deleted."
        case .kept: return "The export file is still on disk, in plain text."
        case .deleteFailed: return "Couldn’t delete the export file. It still holds your passwords in plain text, so delete it yourself."
        }
    }

    // MARK: Private

    private func fail(_ text: String) {
        forget()
        error = text
    }

    private func forget() {
        pending = nil
        url = nil
        passwordDraft = ""
        error = ""
        reading = false
        stage = .waiting
    }
}
