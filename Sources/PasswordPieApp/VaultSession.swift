import AppKit
import ApplicationServices
import LocalAuthentication
import PasswordPieCore
import Security
import SwiftUI
import UniformTypeIdentifiers

enum FillMode {
    case fill
    case openAndFill
    case open
    case oneTimePassword
}

/// What a details field or shortcut copies.
enum CopyTarget {
    case username
    case password
    case url
    case notes
    case oneTimePassword
    case custom(String)
}

private enum TouchIDGate {
    case accepted
    case cancelled
    case failed(String)
}

@MainActor
final class VaultSession: ObservableObject {
    @Published var locked = true
    @Published var creating = false
    @Published var passwordDraft = ""
    @Published var confirmDraft = ""
    @Published var searchAll: Bool {
        didSet { UserDefaults.standard.set(searchAll, forKey: "searchAllFields") }
    }
    @Published var entries: [VaultEntry] = []
    @Published var message = ""
    @Published var editing: VaultEntry?
    @Published var editingIsNew = false
    @Published var touchIDAvailable = false
    @Published var touchIDEnabled = false
    @Published var touchIDHardware = false
    @Published var touchIDBusy = false
    @Published var touchIDStatus = ""
    @Published var touchIDStatusIsError = false
    @Published var recordingHotKey = false
    @Published var hotKeyActive = true
    @Published var autoLock: AutoLockSettings {
        didSet {
            autoLock.save()
            onAutoLockChange?(autoLock)
        }
    }
    @Published var clipboardTimeout: Int {
        didSet {
            UserDefaults.standard.set(clipboardTimeout, forKey: "clipboardTimeout")
            clipboard.timeout = TimeInterval(clipboardTimeout)
        }
    }
    @Published var hotKey: HotKeyConfig {
        didSet {
            hotKey.save()
            AppDelegate.shared?.reregisterHotkey()
        }
    }
    @Published var databaseURL: URL {
        didSet {
            guard !applyingRoster else { return }
            adopt(roster.selecting(databaseURL.path))
        }
    }
    /// Every database the user has opened. The current file is first.
    @Published private(set) var databasePaths: [String] = []
    /// Shown on the lock screen only for a KeePass 1 database.
    @Published private(set) var keyFileName = ""

    // Wired by the app delegate.
    var hidePanel: (() -> Void)?
    var onWrongPassword: (() -> Void)?
    var onAutoLockChange: ((AutoLockSettings) -> Void)?
    /// Called for every vault action and unlock, so the idle timer restarts.
    var onActivity: (() -> Void)?

    private(set) var vaultName = "PasswordPie"
    private var masterPassword = ""
    private var rootName = "PasswordPie"
    private var kdf = KDFParameters.default
    /// The opened database, including its decrypted XML. Cleared on lock so secrets do not outlive the session.
    private var opened: Vault?
    private var keyFileData: Data?
    private var roster = DatabaseRoster(current: "")
    private var applyingRoster = false
    private let clipboard: ClipboardGuard
    private let secretStore = TouchIDSecretStore()

    var databaseMenuTitles: [String] { DatabaseRoster.menuTitles(for: databasePaths) }

    /// File types the open panel may select. `.opvault` is a package once 1Password has registered it.
    nonisolated static func databaseContentTypes() -> [UTType] {
        var types: [UTType] = [.data, .json, .commaSeparatedText, .folder]
        let opvault = UTType(filenameExtension: "opvault", conformingTo: .package)
            ?? UTType(importedAs: "com.agilebits.opvault", conformingTo: .package)
        types.append(opvault)
        return types
    }

    var hasMasterPassword: Bool { !masterPassword.isEmpty }
    var showsKeyFile: Bool { !creating && databaseURL.pathExtension.lowercased() == "kdb" }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasswordPie", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let initialPath: String
        if let override = ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] {
            initialPath = override
        } else if let saved = UserDefaults.standard.string(forKey: "databasePath") {
            initialPath = saved
        } else {
            initialPath = support.appendingPathComponent("PasswordPie.kdbx").path
        }
        databaseURL = URL(fileURLWithPath: initialPath)
        searchAll = UserDefaults.standard.bool(forKey: "searchAllFields")
        autoLock = AutoLockSettings.load()
        let timeout = UserDefaults.standard.object(forKey: "clipboardTimeout") as? Int ?? Int(ClipboardGuard.defaultTimeout)
        clipboardTimeout = timeout
        clipboard = ClipboardGuard(pasteboard: SystemPasteboard(), timeout: TimeInterval(timeout)) { delay, action in
            TimerCancellable(delay: delay, action: action)
        }
        hotKey = HotKeyConfig.load()
        let remembered = UserDefaults.standard.stringArray(forKey: "databasePaths") ?? []
        roster = DatabaseRoster(current: initialPath, remembered: remembered)
        databasePaths = roster.paths
    }

    func restore() {
        creating = !FileManager.default.fileExists(atPath: databaseURL.path)
        refreshTouchID()
        applyDebugOverrides()
    }

    /// Test hooks. Compiled out of release builds so no secret is ever read from the environment there.
    private func applyDebugOverrides() {
        #if DEBUG
        if let password = ProcessInfo.processInfo.environment["PASSWORDPIE_PASSWORD"] {
            passwordDraft = password
            unlock()
        }
        #endif
    }

    // MARK: Unlock and lock

    func unlock() {
        let password = passwordDraft
        let keyOnly = showsKeyFile && keyFileData != nil
        guard !password.isEmpty || keyOnly else {
            message = "Enter the master password."
            return
        }
        if creating {
            guard password == confirmDraft else {
                message = "The two passwords do not match."
                return
            }
            masterPassword = password
            entries = []
            kdf = .default
            creating = false
            passwordDraft = ""
            confirmDraft = ""
            message = ""
            save()
            didUnlock(withMasterPassword: true)
            return
        }
        do {
            let vault = try VaultFormat.load(url: databaseURL, password: password, keyFile: keyFileForUnlock)
            apply(vault, password: password)
            message = ""
            didUnlock(withMasterPassword: true)
        } catch {
            if isWrongPassword(error) {
                onWrongPassword?()
                if onWrongPassword == nil { message = "Incorrect password. Please try again." }
            } else {
                message = openErrorText(error)
            }
        }
    }

    private func didUnlock(withMasterPassword: Bool) {
        locked = false
        let declined = UserDefaults.standard.bool(forKey: touchIDDeclinedKey)
        // touchIDHardware stays true when a sensor exists but no fingerprint is enrolled.
        // Store only when biometrics can actually gate the next read.
        if withMasterPassword, UnlockMemory.shouldStore(
            hardware: biometryCanGate(),
            declined: declined,
            alreadyEnabled: touchIDEnabled
        ) {
            rememberUnlockSecret()
        }
        onActivity?()
    }

    /// The file keeps its own password. After this unlock, the login keychain holds it
    /// so the next lock can open with Touch ID. A key file is stored with the password.
    private func rememberUnlockSecret() {
        let secret = StoredUnlock(password: masterPassword, keyFile: showsKeyFile ? keyFileData : nil).encoded
        guard !secret.isEmpty else { return }
        let status = secretStore.save(secret: secret, account: databaseURL.path)
        switch TouchIDEnrollment.refreshAfterMasterUnlock(saveStatus: status) {
        case .refreshed:
            UserDefaults.standard.set(true, forKey: touchIDEnabledKey)
            UserDefaults.standard.removeObject(forKey: touchIDDeclinedKey)
            UserDefaults.standard.removeObject(forKey: touchIDStaleKey)
            stampTouchIDUnlock()
            touchIDEnabled = true
            touchIDAvailable = touchIDHardware
            touchIDStatus = ""
            touchIDStatusIsError = false
        case .stale(let failed):
            touchIDAvailable = false
            UserDefaults.standard.set(true, forKey: touchIDStaleKey)
            touchIDStatus = "Touch ID couldn't be refreshed (\(failed))."
            touchIDStatusIsError = true
        }
    }

    func unlockWithTouchID() {
        // Re-check the 7-day window: this process may have been locked for longer than that.
        refreshTouchID()
        guard touchIDAvailable, !touchIDBusy else { return }
        let account = databaseURL.path
        touchIDBusy = true
        Task { @MainActor in
            defer { self.touchIDBusy = false }
            guard let stored = await self.authenticateTouchID(reason: "Unlock PasswordPie", account: account) else { return }
            guard self.databaseURL.path == account else {
                self.message = "The open database changed. Try Touch ID again."
                return
            }
            if let keyFile = stored.keyFile {
                self.keyFileData = keyFile
                if self.keyFileName.isEmpty { self.keyFileName = "Saved key file" }
            }
            do {
                let vault = try VaultFormat.load(url: self.databaseURL, password: stored.password, keyFile: self.keyFileForUnlock)
                self.apply(vault, password: stored.password)
                self.didUnlock(withMasterPassword: false)
            } catch {
                if self.isWrongPassword(error) {
                    self.message = "The saved Touch ID password doesn't match this database. Unlock with the master password."
                } else {
                    self.message = self.openErrorText(error)
                }
            }
        }
    }

    func enableTouchID() {
        guard !masterPassword.isEmpty else {
            touchIDStatus = "Unlock PasswordPie before turning on Touch ID."
            touchIDStatusIsError = true
            return
        }
        guard !touchIDBusy else { return }
        let password = masterPassword
        let keyFile = showsKeyFile ? keyFileData : nil
        let account = databaseURL.path
        touchIDBusy = true
        touchIDStatus = ""
        touchIDStatusIsError = false
        Task { @MainActor in
            defer { self.touchIDBusy = false }
            switch await self.promptForTouchID(reason: "Turn on Touch ID for PasswordPie") {
            case .accepted:
                break
            case .cancelled:
                return
            case .failed(let text):
                self.touchIDStatus = text
                self.touchIDStatusIsError = true
                return
            }
            switch TouchIDEnrollment.commit(
                capturedAccount: account,
                currentAccount: self.databaseURL.path,
                capturedSecret: Data(password.utf8),
                currentSecret: Data(self.masterPassword.utf8)
            ) {
            case .rejectChangedPassword:
                self.touchIDStatus = "The master password changed. Turn on Touch ID again."
                self.touchIDStatusIsError = true
                return
            case .write(let target, let showOnCurrentDatabase):
                let stored = StoredUnlock(password: password, keyFile: keyFile)
                let status = self.secretStore.save(secret: stored.encoded, account: target)
                guard status == errSecSuccess else {
                    self.touchIDStatus = "Couldn't save the Touch ID unlock (\(status))."
                    self.touchIDStatusIsError = true
                    return
                }
                UserDefaults.standard.set(true, forKey: self.touchIDEnabledKey(for: target))
                UserDefaults.standard.set(Date(), forKey: self.touchIDStampKey(for: target))
                UserDefaults.standard.removeObject(forKey: self.touchIDStaleKey(for: target))
                UserDefaults.standard.removeObject(forKey: self.touchIDDeclinedKey(for: target))
                guard showOnCurrentDatabase else {
                    self.touchIDStatus = "Touch ID was turned on for the previous database."
                    self.touchIDStatusIsError = false
                    return
                }
                self.touchIDEnabled = true
                self.touchIDAvailable = self.touchIDHardware
                self.touchIDStatus = ""
                self.touchIDStatusIsError = false
            }
        }
    }

    func disableTouchID(quiet: Bool = false, declined: Bool = false) {
        let status = secretStore.delete(account: databaseURL.path)
        guard !TouchIDEnrollment.keepsPersistedFlag(deleteStatus: status) else {
            touchIDAvailable = false
            touchIDStatus = "Touch ID stays on. The saved password is still in the login keychain (\(status))."
            touchIDStatusIsError = true
            return
        }
        UserDefaults.standard.removeObject(forKey: touchIDEnabledKey)
        UserDefaults.standard.removeObject(forKey: touchIDStampKey)
        UserDefaults.standard.removeObject(forKey: touchIDStaleKey)
        if declined { UserDefaults.standard.set(true, forKey: touchIDDeclinedKey) }
        touchIDEnabled = false
        touchIDAvailable = false
        if !quiet || touchIDStatusIsError {
            touchIDStatus = ""
            touchIDStatusIsError = false
        }
    }

    func lock() {
        opened = nil
        entries = []
        masterPassword = ""
        passwordDraft = ""
        confirmDraft = ""
        editing = nil
        locked = true
        creating = !FileManager.default.fileExists(atPath: databaseURL.path)
        message = ""
        refreshTouchID()
    }

    // MARK: Touch ID window

    private var touchIDStampKey: String { touchIDStampKey(for: databaseURL.path) }
    private var touchIDEnabledKey: String { touchIDEnabledKey(for: databaseURL.path) }
    private var touchIDStaleKey: String { touchIDStaleKey(for: databaseURL.path) }
    private var touchIDDeclinedKey: String { touchIDDeclinedKey(for: databaseURL.path) }
    private func touchIDStampKey(for account: String) -> String { "touchIDUnlockedAt.\(account)" }
    private func touchIDEnabledKey(for account: String) -> String { "touchIDEnabled.\(account)" }
    private func touchIDStaleKey(for account: String) -> String { "touchIDStale.\(account)" }
    private func touchIDDeclinedKey(for account: String) -> String { "touchIDDeclined.\(account)" }

    private func stampTouchIDUnlock() {
        UserDefaults.standard.set(Date(), forKey: touchIDStampKey)
    }

    /// The secret is only usable for a week after the last master-password unlock; later it is deleted.
    private func refreshTouchID() {
        let context = LAContext()
        var bioError: NSError?
        // biometryType stays set when fingers are not enrolled, so the button can explain that.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &bioError)
        switch context.biometryType {
        case .touchID, .faceID, .opticID:
            touchIDHardware = true
        default:
            touchIDHardware = false
        }
        touchIDEnabled = UserDefaults.standard.bool(forKey: touchIDEnabledKey)
        guard touchIDEnabled else {
            touchIDAvailable = false
            touchIDStatus = ""
            touchIDStatusIsError = false
            return
        }
        if UserDefaults.standard.bool(forKey: touchIDStaleKey) {
            touchIDAvailable = false
            touchIDStatus = "Touch ID couldn't be refreshed. Unlock with the master password again."
            touchIDStatusIsError = true
            return
        }
        // A secret saved before the 7-day window existed has no timestamp; its window starts now.
        if UserDefaults.standard.object(forKey: touchIDStampKey) == nil { stampTouchIDUnlock() }
        let stamp = UserDefaults.standard.object(forKey: touchIDStampKey) as? Date
        guard TouchIDWindow.isValid(unlockedAt: stamp, now: Date()) else {
            disableTouchID(quiet: true)
            return
        }
        switch TouchIDEnrollment.offer(hardware: touchIDHardware, probe: secretStore.probe(account: databaseURL.path)) {
        case .available:
            touchIDAvailable = true
            if touchIDStatusIsError {
                touchIDStatus = ""
                touchIDStatusIsError = false
            }
        case .noHardware:
            touchIDAvailable = false
        case .missingSecret:
            touchIDAvailable = false
            disableTouchID(quiet: true)
        case .unreadable:
            touchIDAvailable = false
            touchIDStatus = "Touch ID is on, but this version of PasswordPie can't read the saved password. Unlock with the master password."
            touchIDStatusIsError = true
        }
    }

    /// Touch ID first. The keychain item itself is not biometric; this prompt is the gate.
    private func promptForTouchID(reason: String) async -> TouchIDGate {
        NSApp.activate()
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return accepted ? .accepted : .cancelled
        } catch let error as LAError {
            if let text = TouchIDPromptMessage.message(for: error.code) {
                return .failed(text)
            }
            return .cancelled
        } catch {
            return .failed("Touch ID is not available.")
        }
    }

    private func authenticateTouchID(reason: String, account: String) async -> StoredUnlock? {
        switch await promptForTouchID(reason: reason) {
        case .accepted:
            break
        case .cancelled:
            return nil
        case .failed(let text):
            message = text
            return nil
        }
        guard databaseURL.path == account else {
            message = "The open database changed. Try Touch ID again."
            return nil
        }
        let loaded = secretStore.load(account: account)
        guard loaded.status == errSecSuccess, let secret = loaded.secret, let stored = StoredUnlock(stored: secret) else {
            message = "Touch ID is on, but this version of PasswordPie can't read the saved password. Unlock with the master password."
            return nil
        }
        return stored
    }

    // MARK: Database files

    func chooseDatabase() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = Self.databaseContentTypes()
        chooser.canChooseFiles = true
        chooser.canChooseDirectories = true
        chooser.treatsFilePackagesAsDirectories = false
        chooser.allowsOtherFileTypes = true
        chooser.message = "Choose a KeePass, Bitwarden, Proton Pass, PUX, OPVault, or CSV database"
        let accepted = AppDelegate.shared?.keepOpen { chooser.runModal() == .OK } ?? false
        if accepted, let url = chooser.url {
            databaseURL = databaseURL(resolving: url)
            clearKeyFile()
            lock()
            offerRememberedUnlock()
        }
    }

    /// Switches to a database already in the list. Its own password stays in the keychain.
    func selectDatabase(_ path: String) {
        let url = databaseURL(resolving: URL(fileURLWithPath: path))
        guard url.path != databaseURL.path else { return }
        databaseURL = url
        clearKeyFile()
        lock()
        offerRememberedUnlock()
    }

    /// Drops a database from the list. The file on disk is left in place.
    func forgetDatabase(_ path: String) {
        let resolved = databaseURL(resolving: URL(fileURLWithPath: path)).path
        let next = roster.removing(resolved)
        guard next != roster else { return }
        let status = secretStore.delete(account: resolved)
        guard !TouchIDEnrollment.keepsPersistedFlag(deleteStatus: status) else {
            reportKeychainCleanupFailure(status, path: resolved)
            return
        }
        guard next.current != databaseURL.path else {
            adopt(next)
            return
        }
        applyingRoster = true
        adopt(next)
        databaseURL = URL(fileURLWithPath: next.current)
        applyingRoster = false
        clearKeyFile()
        lock()
        offerRememberedUnlock()
    }

    private func adopt(_ next: DatabaseRoster) {
        let evicted = roster.paths.filter { !next.paths.contains($0) }
        var blocked: [String] = []
        for path in evicted {
            let status = secretStore.delete(account: path)
            if TouchIDEnrollment.keepsPersistedFlag(deleteStatus: status) {
                blocked.append(path)
                reportKeychainCleanupFailure(status, path: path)
            } else {
                clearTouchIDDefaults(for: path)
            }
        }
        let applied = next.keeping(blocked)
        roster = applied
        databasePaths = applied.paths
        guard ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil else { return }
        UserDefaults.standard.set(applied.current, forKey: "databasePath")
        UserDefaults.standard.set(applied.paths, forKey: "databasePaths")
    }

    private func clearTouchIDDefaults(for account: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: touchIDStampKey(for: account))
        defaults.removeObject(forKey: touchIDEnabledKey(for: account))
        defaults.removeObject(forKey: touchIDStaleKey(for: account))
        defaults.removeObject(forKey: touchIDDeclinedKey(for: account))
    }

    private func reportKeychainCleanupFailure(_ status: OSStatus, path: String) {
        let text = "Couldn't remove the saved password (\(status)). The database stays in the list."
        message = text
        guard path == databaseURL.path else { return }
        touchIDStatus = text
        touchIDStatusIsError = true
    }

    /// True only when this Mac can run a biometric prompt. A sensor with no enrolled finger is false.
    private func biometryCanGate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func offerRememberedUnlock() {
        guard touchIDAvailable, !creating else { return }
        unlockWithTouchID()
    }

    func chooseKeyFile() {
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = true
        chooser.canChooseDirectories = false
        chooser.allowsOtherFileTypes = true
        chooser.message = "Choose the KeePass 1 key file"
        let accepted = AppDelegate.shared?.keepOpen { chooser.runModal() == .OK } ?? false
        guard accepted, let url = chooser.url else { return }
        do {
            keyFileData = try Data(contentsOf: url)
            keyFileName = url.lastPathComponent
            message = ""
        } catch {
            keyFileData = nil
            keyFileName = ""
            message = "The key file could not be read."
        }
    }

    func newDatabase() {
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = "PasswordPie.kdbx"
        chooser.message = "Choose where to create the new KeePass database"
        let accepted = AppDelegate.shared?.keepOpen { chooser.runModal() == .OK } ?? false
        if accepted, let url = chooser.url {
            databaseURL = url
            clearKeyFile()
            lock()
        }
    }

    // MARK: Entries

    func entry(_ id: UUID) -> VaultEntry? {
        entries.first { $0.id == id && !$0.trashed }
    }

    func newEntry() {
        onActivity?()
        editing = VaultEntry()
        editingIsNew = true
    }

    func edit(_ id: UUID) {
        guard let entry = entry(id) else { return }
        onActivity?()
        editing = entry
        editingIsNew = false
    }

    func saveEditing(_ entry: VaultEntry) {
        var entry = entry
        if entry.title.isEmpty { entry.title = "Untitled" }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        editing = nil
        save()
    }

    func cancelEditing() {
        editing = nil
    }

    func deleteEditing() {
        guard let id = editing?.id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].trashed = true
        editing = nil
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].favorite.toggle()
        save()
    }

    /// A generated password saved as a new Password item, only when the user asks for it.
    func saveGenerated(_ password: String) {
        var entry = VaultEntry()
        entry.title = "Generated Password"
        entry.password = password
        entries.append(entry)
        save()
    }

    // MARK: Actions

    func value(of target: CopyTarget, in entry: VaultEntry) -> String {
        switch target {
        case .username: return entry.username
        case .password: return entry.password
        case .url: return entry.url
        case .notes: return entry.notes
        case .oneTimePassword: return TOTP.parse(entry: entry).map { TOTP.code(settings: $0) } ?? ""
        case .custom(let key): return entry.value(for: key)
        }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        onActivity?()
        clipboard.copy(text)
    }

    func copy(_ target: CopyTarget, of id: UUID) {
        guard let entry = entry(id) else { return }
        copy(value(of: target, in: entry))
    }

    func openURL(of id: UUID) {
        guard let raw = entry(id)?.url, let url = webURL(raw) else { return }
        onActivity?()
        NSWorkspace.shared.open(url)
    }

    /// Fills the previous app. The panel hides first so keystrokes reach the app that was frontmost.
    func fill(_ id: UUID, _ mode: FillMode) {
        guard let entry = entry(id) else { return }
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }
        onActivity?()
        let username = entry.username
        let password = entry.password
        // Password items have no username field to leave; Logins keep the Tab even without a saved username.
        let hasUsernameField = entry.category != .password
        let code = TOTP.parse(entry: entry).map { TOTP.code(settings: $0) } ?? ""
        let delay: Double
        if mode == .openAndFill || mode == .open, let url = webURL(entry.url) {
            NSWorkspace.shared.open(url)
            delay = 2.5
        } else {
            delay = 0.25
        }
        hidePanel?()
        guard mode != .open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch mode {
            case .oneTimePassword:
                typeText(code)
            default:
                if hasUsernameField {
                    typeText(username)
                    typeTab()
                }
                typeText(password)
            }
        }
    }

    func showLargeType(_ text: String) {
        guard !text.isEmpty else { return }
        AppDelegate.shared?.showLargeType(text)
    }

    // MARK: Private

    /// Quitting inside the clipboard timeout must not leave a copied secret behind.
    func flushClipboard() {
        clipboard.flush()
    }

    private func apply(_ vault: Vault, password: String) {
        opened = vault
        vaultName = vault.name
        rootName = vault.rootName
        kdf = vault.kdf
        entries = vault.entries
        masterPassword = password
        passwordDraft = ""
    }

    private func save() {
        onActivity?()
        var vault = opened ?? Vault(name: vaultName, rootName: rootName, entries: entries, kdf: kdf)
        vault.name = vaultName
        vault.rootName = rootName
        vault.entries = entries
        vault.kdf = kdf
        // An imported CSV, PUX, OPVault, Bitwarden, Proton Pass, or KeePass 1 file stays untouched.
        // The first change is written as a sibling .kdbx, and later saves use that file.
        // A key-file-only database can open with an empty password. The new .kdbx cannot.
        let writesKDBX = VaultFormat.writesKDBX(databaseURL)
        if VaultFormat.blocksImportSave(writesKDBX: writesKDBX, password: masterPassword) {
            message = "Set a master password before saving this database."
            NSSound.beep()
            return
        }
        let destination = writesKDBX ? databaseURL : VaultFormat.importedKDBXURL(beside: databaseURL)
        do {
            let data = try KDBX.save(vault: &vault, password: masterPassword)
            try data.write(to: destination, options: .atomic)
            if destination != databaseURL { databaseURL = destination }
            opened = vault
            entries = vault.entries
            kdf = vault.kdf
            rootName = vault.rootName
            vaultName = vault.name
        } catch {
            NSSound.beep()
        }
    }

    private var keyFileForUnlock: Data? {
        databaseURL.pathExtension.lowercased() == "kdb" ? keyFileData : nil
    }

    private func clearKeyFile() {
        keyFileData = nil
        keyFileName = ""
    }

    /// A file picked inside a .opvault bundle opens the bundle, which is the database.
    private func databaseURL(resolving url: URL) -> URL {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.lastPathComponent.lowercased().hasSuffix(".opvault") { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return url
    }

    private func isWrongPassword(_ error: Error) -> Bool {
        if let open = error as? VaultOpenError, case .wrongPassword = open { return true }
        if let kdbx = error as? KDBXError, kdbx == .wrongPassword { return true }
        return false
    }

    private func openErrorText(_ error: Error) -> String {
        if let open = error as? VaultOpenError { return open.description }
        if let kdbx = error as? KDBXError { return kdbx.description }
        return error.localizedDescription
    }
}

// MARK: Auto-lock settings storage

extension AutoLockSettings {
    private static let keys = ["autoLockMinutes", "lockOnIdle", "lockOnSleep", "lockOnScreenSaver", "lockOnUserSwitch"]

    static func load() -> AutoLockSettings {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        let minutes = defaults.object(forKey: keys[0]) as? Int ?? 5
        // Earlier builds stored 0 for "never lock when idle"; keep that choice instead of falling back to 5 minutes.
        let legacyNever = minutes <= 0 && defaults.object(forKey: keys[1]) == nil
        return AutoLockSettings(
            timeoutMinutes: minutes > 0 ? minutes : 5,
            lockOnIdle: legacyNever ? false : flag(keys[1]),
            lockOnSleep: flag(keys[2]),
            lockOnScreenSaver: flag(keys[3]),
            lockOnUserSwitch: flag(keys[4])
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(timeoutMinutes, forKey: Self.keys[0])
        defaults.set(lockOnIdle, forKey: Self.keys[1])
        defaults.set(lockOnSleep, forKey: Self.keys[2])
        defaults.set(lockOnScreenSaver, forKey: Self.keys[3])
        defaults.set(lockOnUserSwitch, forKey: Self.keys[4])
    }
}

// MARK: Clipboard adapters

/// NSPasteboard behind the core clipboard policy; copies are flagged concealed for clipboard managers.
final class SystemPasteboard: PasteboardLike {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    var changeCount: Int { NSPasteboard.general.changeCount }

    func write(_ string: String) -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(string, forType: .string)
        board.setString("", forType: Self.concealed)
        return board.changeCount
    }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}

final class TimerCancellable: Cancellable {
    private var timer: Timer?

    init(delay: TimeInterval, action: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: Helpers

/// Accepts "example.com" as well as full URLs, since KeePass entries often hold bare hosts.
func webURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil { return url }
    return URL(string: "https://" + trimmed)
}

func groupedCode(_ code: String) -> String {
    let half = (code.count + 1) / 2
    guard code.count > 3 else { return code }
    return String(code.prefix(half)) + " " + String(code.dropFirst(half))
}

func typeText(_ text: String) {
    let units = Array(text.utf16)
    guard !units.isEmpty,
          let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
    units.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func typeTab() {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}
