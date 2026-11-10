import AppKit
import PasswordPieCore
import Security

/// One database's remembered key file in the login keychain. `TouchIDSecretStore` is the real one.
protocol KeyFileKeychain {
    func save(secret: Data, account: String) -> OSStatus
    func load(account: String) -> (status: OSStatus, secret: Data?)
    func delete(account: String) -> OSStatus
}

extension TouchIDSecretStore: KeyFileKeychain {}

/// A master password change as typed: the current one, then the new one twice.
struct MasterPasswordChange: Equatable {
    var current: String
    var new: String
    var repeated: String
}

/// The dialogs behind the key file actions, so tests can answer them.
@MainActor
protocol KeyFilePrompting: AnyObject {
    /// A warning with buttons. Returns the index of the button chosen; the last button is Cancel.
    func choose(title: String, text: String, buttons: [String]) -> Int
    func saveLocation(suggestedName: String, directory: URL?) -> URL?
    func existingKeyFile(message: String) -> URL?
    func masterPasswordChange() -> MasterPasswordChange?
}

/// How a key file action ended. Tests read it; the app shows `keyFileStatus`.
enum KeyFileOutcome: Equatable {
    case changed
    case cancelled
    case failed(String)
}

extension VaultSession {
    static let keyFileService = "com.oldcai.passwordpie.keyfile"

    static let keyFileWarning = "Without this key file, the database cannot be opened, and PasswordPie cannot recover it. "
        + "Keep a backup somewhere else: not in the database's folder, and not in the same cloud storage."

    /// The text under the database name after a wrong password.
    var wrongPasswordMessage: String {
        lastUnlockHadKeyFile ? "Incorrect password or key file. Please try again." : "Incorrect password. Please try again."
    }

    /// Key changes need the current database open and writable as KeePass.
    var canChangeKeys: Bool {
        !locked && VaultFormat.writesKDBX(databaseURL) && openedFiles.contains { $0.url.path == databaseURL.path }
    }

    // MARK: Remembering

    func rememberedKeyFile(for path: String) -> RememberedKeyFile? {
        let loaded = keyFileMemory.load(account: path)
        guard loaded.status == errSecSuccess, let secret = loaded.secret else { return nil }
        return RememberedKeyFile(stored: secret)
    }

    /// Fills the lock screen's key file for `databaseURL`: what was chosen for it, or what this Mac remembers.
    func syncKeyFileDraft() {
        let path = databaseURL.path
        if keyFileOwner != path {
            keyFileData = nil
            keyFileName = ""
            keyFileRemembered = false
            keyFileOwner = path
        }
        guard keyFileData == nil, Self.takesKeyFile(databaseURL), let remembered = rememberedKeyFile(for: path) else { return }
        keyFileData = remembered.data
        keyFileName = remembered.name
        keyFileRemembered = true
    }

    /// After a database opens (or is created) with a key file, this Mac keeps it, so the next unlock needs only the
    /// password or Touch ID. A failure is reported and changes nothing else.
    @discardableResult
    func rememberKeyFile(_ data: Data, name: String? = nil) -> Bool {
        let path = databaseURL.path
        let label = name ?? (keyFileName.isEmpty || keyFileOwner != path ? "Key file" : keyFileName)
        if keyFileRemembered, keyFileOwner == path, keyFileData == data, keyFileName == label { return true }
        let status = keyFileMemory.save(secret: RememberedKeyFile(name: label, data: data).encoded, account: path)
        keyFileData = data
        keyFileName = label
        keyFileOwner = path
        guard status == errSecSuccess else {
            keyFileRemembered = false
            keyFileStatus = "Couldn't keep the key file on this Mac (\(status)). Choose it again at the next unlock."
            keyFileStatusIsError = true
            return false
        }
        keyFileRemembered = true
        return true
    }

    /// Forget Key File: this Mac stops keeping it. The database still needs it, so the next unlock asks for the file.
    /// An open database keeps working until it locks.
    @discardableResult
    func forgetKeyFile() -> Bool {
        let path = databaseURL.path
        let status = keyFileMemory.delete(account: path)
        guard status == errSecSuccess else {
            keyFileStatus = "Couldn't forget the key file (\(status))."
            keyFileStatusIsError = true
            return false
        }
        dropKeyFileFromTouchIDSecret(account: path)
        keyFileData = nil
        keyFileName = ""
        keyFileRemembered = false
        keyFileOwner = path
        if !locked {
            keyFileStatus = databaseUsesKeyFile
                ? "This Mac no longer keeps the key file. The next unlock asks for it."
                : ""
            keyFileStatusIsError = false
        }
        return true
    }

    /// Older builds stored a KeePass 1 key file inside the Touch ID secret. Forgetting the key file must take it from
    /// there too; if that secret cannot be rewritten, Touch ID is turned off.
    private func dropKeyFileFromTouchIDSecret(account: String) {
        let loaded = secretStore.load(account: account)
        guard let secret = loaded.secret, let stored = StoredUnlock(stored: secret), stored.keyFile != nil else { return }
        let rewritten = StoredUnlock(password: stored.password).encoded
        if rewritten.isEmpty || secretStore.save(secret: rewritten, account: account) != errSecSuccess {
            disableTouchID(quiet: true)
        }
    }

    // MARK: Lock screen, new database

    /// Runs a key file dialog sequence once the app is active, or at once in tests.
    func runKeyFileFlow(_ body: @escaping () -> Void) {
        if let delegate = AppDelegate.shared {
            delegate.presentFilePanel(body)
        } else {
            body()
        }
    }

    /// The file's contents, checked the way KDBX reads them. KeePass 1 has its own rules (no XML), so `kdbxRules` is
    /// false for a `.kdb` and only an empty file is refused.
    static func readKeyFile(at url: URL, kdbxRules: Bool = true) -> Result<Data, KeyFileError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.invalid("it could not be opened.")) }
        guard kdbxRules else { return data.isEmpty ? .failure(.empty) : .success(data) }
        do {
            _ = try KeyFile.key(from: data)
            return .success(data)
        } catch let error as KeyFileError {
            return .failure(error)
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
    }

    /// New Database: the key file row makes a new key file or uses one, before Create Database.
    func addKeyFileToNewDatabase() {
        runKeyFileFlow { [weak self] in
            guard let self else { return }
            let choice = self.keyFilePrompts.choose(
                title: "Add a key file to the new database?",
                text: Self.keyFileWarning,
                buttons: ["Create New Key File…", "Use Existing Key File…", "Cancel"]
            )
            let picked: Result<(Data, String), KeyFileError>?
            switch choice {
            case 0: picked = self.makeKeyFile()
            case 1: picked = self.pickExistingKeyFile()
            default: picked = nil
            }
            switch picked {
            case .success(let (data, name)):
                self.keyFileData = data
                self.keyFileName = name
                self.keyFileOwner = self.databaseURL.path
                self.keyFileRemembered = false
                self.message = ""
            case .failure(let error):
                self.message = error.description
            case nil:
                break
            }
        }
    }

    // MARK: Preferences actions

    /// Add Key File…: a new KeePass XML 2.0 key file, saved where the person chooses, read back, then the database is
    /// saved again with the master password and that file.
    func addKeyFile() {
        runKeyFileFlow { [weak self] in
            guard let self, self.keyChangeAllowed() else { return }
            guard self.confirmKeyChange(
                title: "Add a key file to \(self.databaseURL.lastPathComponent)?",
                detail: "PasswordPie makes a new key file for you to save, then saves the database again, locked with your master password and the key file.",
                action: "Continue"
            ) else { return }
            switch self.makeKeyFile() {
            case .success(let (data, name)):
                self.rekey(password: self.masterPassword, keyFile: data, keyFileName: name,
                           done: "The database now needs \(name) and the master password. Keep a backup of the key file somewhere else.")
            case .failure(let error):
                self.reportKeyFile(.failed(error.description))
            case nil:
                break
            }
        }
    }

    /// Use Existing Key File…: any file can be the key, such as one made by KeePassXC.
    func useExistingKeyFile() {
        runKeyFileFlow { [weak self] in
            guard let self, self.keyChangeAllowed() else { return }
            guard self.confirmKeyChange(
                title: "Use a key file for \(self.databaseURL.lastPathComponent)?",
                detail: "Choose a file that will never change. If one byte of it changes, the database cannot be opened.",
                action: "Choose File…"
            ) else { return }
            switch self.pickExistingKeyFile() {
            case .success(let (data, name)):
                self.rekey(password: self.masterPassword, keyFile: data, keyFileName: name,
                           done: "The database now needs \(name) and the master password. Keep a backup of the key file somewhere else.")
            case .failure(let error):
                self.reportKeyFile(.failed(error.description))
            case nil:
                break
            }
        }
    }

    /// Remove Key File…: back to the master password alone. This Mac forgets the key file too.
    func removeKeyFile() {
        runKeyFileFlow { [weak self] in
            guard let self, self.keyChangeAllowed() else { return }
            guard self.databaseUsesKeyFile else { return }
            let choice = self.keyFilePrompts.choose(
                title: "Remove the key file from \(self.databaseURL.lastPathComponent)?",
                text: "The database will open with the master password alone. Anyone with a copy of it and the password can read it.",
                buttons: ["Remove Key File", "Cancel"]
            )
            guard choice == 0 else { return }
            self.rekey(password: self.masterPassword, keyFile: nil, keyFileName: nil,
                       done: "The database opens with the master password alone.")
        }
    }

    /// Change Master Password…: the key file, if there is one, stays.
    func changeMasterPassword() {
        runKeyFileFlow { [weak self] in
            guard let self, self.keyChangeAllowed() else { return }
            guard let change = self.keyFilePrompts.masterPasswordChange() else { return }
            guard change.current == self.masterPassword else {
                self.reportKeyFile(.failed("The current master password is not correct. Nothing was changed."))
                return
            }
            guard !change.new.isEmpty else {
                self.reportKeyFile(.failed("Enter a new master password."))
                return
            }
            guard change.new == change.repeated else {
                self.reportKeyFile(.failed("The two new passwords do not match. Nothing was changed."))
                return
            }
            let keyFile = self.openedFiles.first { $0.url.path == self.databaseURL.path }?.keyFile
            self.rekey(password: change.new, keyFile: keyFile, keyFileName: keyFile == nil ? nil : self.keyFileName,
                       done: keyFile == nil ? "The master password was changed." : "The master password was changed. The key file stays the same.")
        }
    }

    // MARK: Rekey

    private func keyChangeAllowed() -> Bool {
        guard canChangeKeys else {
            reportKeyFile(.failed(locked
                ? "Unlock the database first."
                : "Only a KeePass .kdbx database can change its keys."))
            return false
        }
        return true
    }

    private func confirmKeyChange(title: String, detail: String, action: String) -> Bool {
        keyFilePrompts.choose(title: title, text: "\(Self.keyFileWarning)\n\n\(detail)", buttons: [action, "Cancel"]) == 0
    }

    private func reportKeyFile(_ outcome: KeyFileOutcome) {
        switch outcome {
        case .changed, .cancelled:
            break
        case .failed(let text):
            keyFileStatus = text
            keyFileStatusIsError = true
            NSSound.beep()
        }
    }

    /// Writes the current database with new keys. `VaultFile.rekey` opens the new file with them before it replaces
    /// anything, and refuses if the file changed on disk since this session read it.
    private func rekey(password: String, keyFile: Data?, keyFileName name: String?, done: String) {
        let path = databaseURL.path
        guard let index = openedFiles.firstIndex(where: { $0.url.path == path }) else { return }
        guard let baseline = openedFiles[index].vault.fileBaseline else {
            reportKeyFile(.failed("Save the database once before changing its keys."))
            return
        }
        onActivity?()
        keyFileStatus = ""
        keyFileStatusIsError = false
        var vault = openedFiles[index].vault
        vault.name = vaultName
        vault.rootName = rootName
        vault.kdf = kdf
        let result: VaultFile.Rekeyed
        do {
            result = try VaultFile.rekey(openedFiles[index].url, vault: &vault, password: password, keyFile: keyFile, baseline: baseline)
        } catch {
            let reason = (error as? VaultWriteError)?.description ?? openErrorText(error)
            reportKeyFile(.failed("Nothing was changed. \(reason)"))
            return
        }
        openedFiles[index].vault = vault
        openedFiles[index].committedEntries = vault.entries
        openedFiles[index].password = password
        openedFiles[index].keyFile = keyFile
        openedFiles[index].revision += 1
        masterPassword = password
        databaseUsesKeyFile = keyFile != nil
        var notes = [done]
        if let keyFile, !password.isEmpty {
            keyFileRemembered = false
            if !rememberKeyFile(keyFile, name: name) { notes.append(keyFileStatus) }
        } else if !forgetKeyFile() {
            notes.append(keyFileStatus)
        } else if let keyFile {
            // A database with no password: the key stays in memory for this session only.
            keyFileData = keyFile
            keyFileName = name ?? "Key file"
            keyFileOwner = path
        }
        refreshTouchIDSecret(password: password)
        if !result.snapshotRefreshed {
            let snapshot = VaultFile.snapshotURL(for: openedFiles[index].url).lastPathComponent
            notes.append("The copy beside it, \(snapshot), could not be updated and still opens with the old keys. Delete it.")
        }
        keyFileStatus = notes.joined(separator: " ")
        keyFileStatusIsError = false
        publishCatalog()
    }

    /// The Touch ID secret is the master password. It is rewritten after a key change, so Touch ID keeps working
    /// and no older secret (such as one that carried a key file) is left behind. A failed write turns Touch ID off.
    private func refreshTouchIDSecret(password: String) {
        guard touchIDEnabled else { return }
        let path = databaseURL.path
        let secret = StoredUnlock(password: password).encoded
        if secret.isEmpty || secretStore.save(secret: secret, account: path) != errSecSuccess {
            disableTouchID(quiet: true)
        }
    }

    // MARK: Making and picking

    /// A new key file, saved where the person chooses and read back. Nil when cancelled.
    private func makeKeyFile() -> Result<(Data, String), KeyFileError>? {
        let stem = databaseURL.deletingPathExtension().lastPathComponent
        var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        while true {
            guard let url = keyFilePrompts.saveLocation(suggestedName: "\(stem).keyx", directory: directory) else { return nil }
            if isDatabaseFile(url) {
                return .failure(.invalid("that is the database itself. Choose another name."))
            }
            if sharesDatabaseFolder(url) {
                switch askAboutDatabaseFolder() {
                case .chooseAgain:
                    directory = nil
                    continue
                case .cancel:
                    return nil
                case .proceed:
                    break
                }
            }
            do {
                let generated = try KeyFile.generate()
                try generated.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let readBack = try Data(contentsOf: url)
                guard readBack == generated, try KeyFile.key(from: readBack) == KeyFile.key(from: generated) else {
                    return .failure(.invalid("the saved copy did not match. The database was not changed."))
                }
                return .success((readBack, url.lastPathComponent))
            } catch let error as KeyFileError {
                return .failure(error)
            } catch {
                return .failure(.invalid("it could not be saved (\(error.localizedDescription)). The database was not changed."))
            }
        }
    }

    /// An existing file as the key. Nil when cancelled.
    private func pickExistingKeyFile() -> Result<(Data, String), KeyFileError>? {
        guard let url = keyFilePrompts.existingKeyFile(message: "Choose the file to use as the key file") else { return nil }
        if isDatabaseFile(url) {
            return .failure(.invalid("a database cannot be its own key file."))
        }
        if sharesDatabaseFolder(url), askAboutDatabaseFolder() != .proceed { return nil }
        return Self.readKeyFile(at: url).map { ($0, url.lastPathComponent) }
    }

    private enum FolderAnswer { case chooseAgain, proceed, cancel }

    private func askAboutDatabaseFolder() -> FolderAnswer {
        let choice = keyFilePrompts.choose(
            title: "Keep the key file in the database's folder?",
            text: "This folder is usually the one that syncs. Anyone who gets both files can open the database with the master password.",
            buttons: ["Choose Another Place", "Use This Folder Anyway", "Cancel"]
        )
        switch choice {
        case 0: return .chooseAgain
        case 1: return .proceed
        default: return .cancel
        }
    }

    private func isDatabaseFile(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let database = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        return target == database.path || target == VaultFile.snapshotURL(for: database).path
            || openedFiles.contains { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == target }
    }

    private func sharesDatabaseFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == databaseURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The real dialogs: `NSAlert`, `NSSavePanel` and `NSOpenPanel`.
@MainActor
final class AppKitKeyFilePrompts: KeyFilePrompting {
    /// Debug builds only: where the panels start, so a test run never browses the real Documents folder.
    private var debugDirectory: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PASSWORDPIE_KEYFILE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }

    func choose(title: String, text: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        if let cancel = alert.buttons.last, buttons.count > 1 { cancel.keyEquivalent = "\u{1b}" }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func saveLocation(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.message = "Save the key file somewhere other than the database's folder or cloud storage"
        panel.canCreateDirectories = true
        if let start = debugDirectory ?? directory { panel.directoryURL = start }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func existingKeyFile(message: String) -> URL? {
        #if DEBUG
        // A scripted run picks this file instead of driving the system panel.
        if let path = ProcessInfo.processInfo.environment["PASSWORDPIE_KEYFILE_PICK"] { return URL(fileURLWithPath: path) }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = message
        if let debugDirectory { panel.directoryURL = debugDirectory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func masterPasswordChange() -> MasterPasswordChange? {
        let alert = NSAlert()
        alert.messageText = "Change the master password"
        alert.informativeText = "If the database has a key file, it stays the same. Other copies of the database, such as backups, still open with the old password."
        alert.addButton(withTitle: "Change Password")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let current = NSSecureTextField(frame: NSRect(x: 0, y: 64, width: 260, height: 24))
        current.placeholderString = "Current master password"
        let new = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        new.placeholderString = "New master password"
        let repeated = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        repeated.placeholderString = "Repeat new password"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
        for field in [current, new, repeated] { stack.addSubview(field) }
        current.nextKeyView = new
        new.nextKeyView = repeated
        alert.accessoryView = stack
        alert.window.initialFirstResponder = current
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return MasterPasswordChange(current: current.stringValue, new: new.stringValue, repeated: repeated.stringValue)
    }
}
