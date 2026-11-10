import AppKit
import ApplicationServices
import LocalAuthentication
import PasswordPieCore
import Security
import SwiftUI
import UniformTypeIdentifiers

enum FillMode {
    /// ⇧Return: fill the app that was in front.
    case fill
    /// ⌥Return: open the website, then fill it.
    case openAndFill
    /// Return on a login: fill the browser tab when it is already on the account's site, otherwise open the website and fill.
    /// Without the browser extension it is Open and Fill.
    case fillOrOpen
    case open
}

/// One step of typing an account into another app.
enum FillKeystroke: Equatable {
    case text(String)
    case tab
}

/// What Fill and Open and Fill type: the username and the password, on every channel, and never a one-time code.
func fillKeystrokes(for entry: VaultEntry) -> [FillKeystroke] {
    // Password items have no username field to leave; Logins keep the Tab even without a saved username.
    let username: [FillKeystroke] = entry.category == .password ? [] : [.text(entry.username), .tab]
    return username + [.text(entry.password)]
}

/// How a copy shortcut ended, so its caller knows whether to close the menu.
enum CopyOutcome: Equatable {
    case copied
    case nothingToCopy
    /// The item has a one-time code and this user does not have Premium. The plans are opening; the clipboard was not touched.
    case premiumRequired
}

/// What a details field or shortcut copies.
enum CopyTarget: Equatable {
    case username
    case password
    case url
    case notes
    case oneTimePassword
    case custom(String)
}

enum SplitPlacement {
    static func index(slot: Int?, entries: [VaultEntry], id: UUID) -> Int? {
        if let slot, entries.indices.contains(slot), entries[slot].id == id { return slot }
        return entries.firstIndex { $0.id == id }
    }
}

private enum TouchIDGate {
    case accepted
    case cancelled
    case failed(String)
}

struct OpenedFile {
    var url: URL
    var vault: Vault
    var password: String
    var keyFile: Data?
    /// Set when an import was written to a sibling but its keychain secret did not move.
    var pendingSaveURL: URL?
    /// What the file holds. A failed write comes back to this, so a later write cannot carry it to disk.
    var committedEntries: [VaultEntry]
    /// Goes up on every write. A background write that finds it moved was overtaken.
    var revision: Int

    init(url: URL, vault: Vault, password: String, keyFile: Data?, pendingSaveURL: URL? = nil, revision: Int = 0) {
        self.url = url
        self.vault = vault
        self.password = password
        self.keyFile = keyFile
        self.pendingSaveURL = pendingSaveURL
        self.committedEntries = vault.entries
        self.revision = revision
    }
}

/// A decrypted database and the key file that opened it.
private struct DecryptedVault {
    let vault: Vault
    let keyFile: Data?
}

private struct SiblingJob: Sendable {
    let path: String
    let password: String
    let keyFile: Data?
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
    @Published var entries: [VaultEntry] = [] {
        didSet { catalogChanged() }
    }
    @Published var message = ""
    @Published var importStatus = ""
    @Published var importStatusIsError = false
    /// Chrome logins read live. These are never saved as they are. A newer password reaches the saved entry through `reconcileChromeUpdates`.
    @Published var liveEntries: [VaultEntry] = [] {
        didSet { catalogChanged() }
    }
    /// One row per account: the database's entries, plus Chrome logins with no entry yet.
    /// Search and menus read this. Saving must not: use `storedEntry`, because Chrome's values here are for display.
    /// Kept up to date when either list changes, so lookups do not merge the lists again.
    @Published private(set) var allEntries: [VaultEntry] = []
    /// The menu shown with an empty search, built off the main thread. Nil until the first build for this catalog finishes.
    @Published private(set) var topLevelRows: [MenuRow]?
    /// Search text for `allEntries`, built off the main thread a piece at a time. A search uses what is indexed so far.
    @Published private(set) var searchIndex = SearchIndex()
    /// True while entries are still being added to `searchIndex`.
    @Published private(set) var indexing = false
    /// Bumped on every catalog change; background work from an older catalog does not publish.
    var menuGeneration: UInt = 0
    var menuWork: [Task<Void, Never>] = []
    @Published var chromeStatus = ""
    @Published var chromeStatusIsError = false
    /// True when macOS blocked the Chrome folder. The preferences button opens Files & Folders.
    @Published var chromeNeedsSettings = false
    @Published var chromeBusy = false
    @Published var chromeSyncEnabled = false
    /// Held in memory while unlocked so a refresh does not ask the keychain again.
    var chromeKey: Data?
    var chromeGeneration = 0
    /// Chrome's own last-used times for the live logins. Replaced on every refresh, cleared on lock.
    var chromeLastUsed: [UUID: Date] = [:]
    /// Rows with anything from Chrome in them, as listed.
    @Published private(set) var chromeBadgeIDs: Set<UUID> = []
    /// Set while more updates are waiting than may be written without asking.
    @Published var chromeBatch: ChromeBatch?
    /// Set when Apply or dismiss could not be written.
    @Published var chromeBatchError = ""
    /// Entries whose newest update could not be written. They keep the saved password.
    @Published var chromeUpdateFailures: Set<UUID> = []
    #if PP_DIRECT
    /// Every row from the last read, including a login's second store.
    var chromeRows: [ChromeRow] = []
    /// Other open databases are still decrypting. "Exactly one saved entry" can't be answered until they have arrived.
    var chromeAwaitingSiblings = false
    /// Replaced in tests, so a fixture's dates can be in this clock's past.
    var chromeClock: () -> Date = Date.init
    /// Events already waiting for a decision. Not persisted: a restart works it out again.
    var chromeHeldEvents: Set<String> = []
    var chromeWriteInFlight = false
    var chromeReconcileAgain = false
    /// Login-file signature from the last successful read. Nil until then, and again after lock, so the next open reads.
    var chromeStoreSignature: ChromeStoreSignature?
    /// The panel opened again while a read was running. Check the files once more when that read finishes.
    var chromeRecheckAfterRead = false
    var chromeSource: ChromeSnapshotSource = {
        #if DEBUG
        // A fixture run must never reach the real Chrome folder, not even to compare file sizes.
        if let fixture = ChromeFixture.source() { return fixture }
        #endif
        return .live
    }()
    #endif
    private let usage: UsageStore
    @Published var editing: VaultEntry?
    /// The item as the editor opened it. Nil for something new.
    private var editingOriginal: VaultEntry?
    @Published var editingIsNew = false
    @Published var touchIDAvailable = false
    @Published var touchIDEnabled = false
    @Published var touchIDHardware = false
    @Published var touchIDBusy = false
    /// True while a database decrypts off the main thread. The lock screen hides its form and turns the logo.
    @Published private(set) var unlocking = false
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
    /// Menu id → file path. Set before `entries` so a refresh can label rows from other files.
    private(set) var entrySources: [UUID: String] = [:]
    /// The key file the lock screen holds for `databaseURL`: chosen there, or remembered in this Mac's keychain.
    /// Shown for KeePass databases (`.kdbx`, `.kdb`).
    @Published var keyFileName = ""
    /// The lock screen's key file came from this Mac's keychain.
    @Published var keyFileRemembered = false
    /// The unlocked database is locked with a key file. Preferences offers Remove Key File and Forget Key File from this.
    @Published var databaseUsesKeyFile = false
    /// The outcome of the last key file or master password change, shown in Preferences.
    @Published var keyFileStatus = ""
    @Published var keyFileStatusIsError = false
    /// The last unlock that failed had a key file, so the error names both keys.
    var lastUnlockHadKeyFile = false

    // Wired by the app delegate.
    var hidePanel: (() -> Void)?
    /// Fills through the browser extension when the target browser has one; false means type the keystrokes.
    var browserFill: ((VaultEntry, FillMode, String?) -> Bool)?
    var onWrongPassword: (() -> Void)?
    var onAutoLockChange: ((AutoLockSettings) -> Void)?
    /// Called for every vault action and unlock, so the idle timer restarts.
    var onActivity: (() -> Void)?

    private(set) var vaultName = "PasswordPie"
    var masterPassword = ""
    var rootName = "PasswordPie"
    var kdf = KDFParameters.default
    /// Decrypted databases for this unlock. Cleared on lock so secrets do not outlive the session.
    var openedFiles: [OpenedFile] = []
    /// Bumped on lock and on each unlock. A sibling decrypt still running from the previous generation must not publish.
    private(set) var catalogGeneration: UInt = 0
    /// Bumped by lock(). A decrypt that started before a lock must not unlock the vault afterwards.
    private var unlockGeneration: UInt = 0
    /// Menu id → id stored in that file. They differ only when two files share a UUID.
    private(set) var listOrigins: [UUID: UUID] = [:]
    /// Menu id → index in that file. Two entries in one file can share a stored UUID.
    private(set) var listSlots: [UUID: Int] = [:]
    private(set) var listPaths: [UUID: String] = [:]
    /// The key file's contents for the lock screen. Belongs to `keyFileOwner`, cleared when another database is chosen.
    var keyFileData: Data?
    var keyFileOwner = ""
    /// Where remembered key files live: the login keychain, one item per database path. Tests pass their own.
    let keyFileMemory: KeyFileKeychain
    /// The dialogs the key file actions show. Tests replace them.
    lazy var keyFilePrompts: KeyFilePrompting = AppKitKeyFilePrompts()
    private var roster = DatabaseRoster(current: "")
    private var applyingRoster = false
    private let clipboard: ClipboardGuard
    /// Who has Premium. Changes without a relaunch, and it is never written to the database or to disk.
    let premium: PremiumStore
    let secretStore = TouchIDSecretStore()

    var databaseMenuTitles: [String] { DatabaseRoster.menuTitles(for: databasePaths) }

    /// File types the open panel may select. `.opvault` is a package, declared in Info.plist,
    /// so the panel can choose that directory without treating every folder as a database.
    nonisolated static func databaseContentTypes() -> [UTType] {
        var types: [UTType] = [.data, .json, .commaSeparatedText]
        let opvault = UTType(filenameExtension: "opvault", conformingTo: .package)
            ?? UTType(importedAs: "com.agilebits.opvault", conformingTo: .package)
        types.append(opvault)
        return types
    }

    var hasMasterPassword: Bool { !masterPassword.isEmpty }
    /// KeePass databases, old and new, can have a key file. Imports (CSV, 1Password, Bitwarden, Proton Pass) cannot.
    var showsKeyFile: Bool { Self.takesKeyFile(databaseURL) }

    nonisolated static func takesKeyFile(_ url: URL) -> Bool {
        ["kdbx", "kdb"].contains(url.pathExtension.lowercased())
    }

    /// Both come from the channel unless a test passes its own.
    init(premium: PremiumStore? = nil, pasteboard: PasteboardLike? = nil, keyFileMemory: KeyFileKeychain? = nil) {
        self.premium = premium ?? PremiumChannel.makeStore()
        self.keyFileMemory = keyFileMemory ?? TouchIDSecretStore(service: VaultSession.keyFileService)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasswordPie", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let usagePath = ProcessInfo.processInfo.environment["PASSWORDPIE_USAGE"]
        usage = UsageStore(url: usagePath.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("usage.json"))
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
        clipboard = ClipboardGuard(pasteboard: pasteboard ?? SystemPasteboard(), timeout: TimeInterval(timeout)) { delay, action in
            TimerCancellable(delay: delay, action: action)
        }
        hotKey = HotKeyConfig.load()
        let remembered = UserDefaults.standard.stringArray(forKey: "databasePaths") ?? []
        // A failed keychain delete may have saved more than 32 paths. Loading must not drop them.
        let cap = max(DatabaseRoster.limit, remembered.count + 1)
        roster = DatabaseRoster(current: initialPath, remembered: remembered, limit: cap)
        databasePaths = roster.paths
    }

    func restore() {
        creating = !FileManager.default.fileExists(atPath: databaseURL.path)
        syncKeyFileDraft()
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
        // A new database always gets a master password, with or without a key file.
        // No password: only a key file chosen on the lock screen for this attempt. A remembered one never opens a
        // database by itself, or a database whose password was removed elsewhere would open with nothing typed.
        let keyOnly = !creating && keyFileForUnlock != nil && !keyFileRemembered
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
            if let key = keyFileForUnlock, openedFiles.contains(where: { $0.url.path == databaseURL.path }) {
                rememberKeyFile(key)
                databaseUsesKeyFile = true
            }
            loadRememberedDatabases()
            didUnlock(withMasterPassword: true)
            return
        }
        guard !unlocking else { return }
        message = ""
        decrypt(password: password) { session, result in
            switch result {
            case .success(let opened):
                session.apply(opened.vault, password: password, keyFile: opened.keyFile)
                session.didUnlock(withMasterPassword: true)
            case .failure(let error):
                if session.isWrongPassword(error) {
                    session.lastUnlockHadKeyFile = session.keyFileForUnlock != nil
                    session.onWrongPassword?()
                    if session.onWrongPassword == nil { session.message = session.wrongPasswordMessage }
                } else {
                    session.message = session.openErrorText(error)
                }
            }
        }
    }

    /// The key derivation can take a second, so it runs off the main thread and the lock screen keeps animating.
    /// The result is dropped when the database changed or something else unlocked it in the meantime.
    private func decrypt(password: String, keyFile keyFileOverride: Data? = nil, then finish: @escaping @MainActor (VaultSession, Result<DecryptedVault, Error>) -> Void) {
        let url = databaseURL
        let keyFile = keyFileOverride ?? keyFileForUnlock
        unlocking = true
        let generation = unlockGeneration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Vault, Error> in
                Result { try VaultFile.openRecovering(url: url, password: password, keyFile: keyFile) }
            }.value
            guard let self else { return }
            self.unlocking = false
            // Before the checks below: the file may have been repaired even if this result is dropped.
            if case .success(let opened) = result {
                self.showRecoveryNotice(opened.recoveryNotice, path: url.path, detailed: self.unlockGeneration == generation)
            }
            guard self.unlockGeneration == generation else { return }
            guard self.locked else { return }
            guard self.databaseURL.path == url.path else {
                self.message = "The open database changed. Try again."
                return
            }
            // Keep the key file this decrypt used, even if the draft changed while it ran.
            finish(self, result.map { DecryptedVault(vault: $0, keyFile: keyFile) })
        }
    }

    /// Database path plus outcome of notices already shown this run. Not cleared by lock(), and holds no titles.
    /// Keyed on the path, not the text: a failure reason names a per-attempt file, so the text differs every time.
    private var shownRecoveryNotices = Set<String>()

    /// `message` only shows on the lock screen, which is gone by now.
    /// Not `detailed` (the vault locked meanwhile): only the first paragraph, which names no entries.
    private func showRecoveryNotice(_ notice: String?, path: String, detailed: Bool) {
        guard var notice else { return }
        if !detailed, let split = notice.range(of: "\n\n") { notice = String(notice[..<split.lowerBound]) }
        let failed = notice.contains("The file was not changed")
        guard shownRecoveryNotices.insert("\(path)|\(failed)").inserted else { return }
        let alert = NSAlert()
        alert.messageText = "Database repair"
        alert.informativeText = notice
        alert.addButton(withTitle: "OK")
        if let delegate = AppDelegate.shared {
            _ = delegate.keepOpen { alert.runModal() }
        } else {
            alert.runModal()
        }
    }

    private func didUnlock(withMasterPassword: Bool) {
        // The open panel starts its Chrome check inside the lock subscriber, so the switch has to be loaded first.
        startChromeSyncIfEnabled()
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
    /// so the next lock can open with Touch ID. A key file is not part of it: it has its own item
    /// (`keyFileMemory`), which outlives Touch ID's 7-day window and goes only with Forget Key File. A database with no
    /// password is the exception: its key file is never kept on its own (that would open it with no secret at all), so
    /// Touch ID holds it, as it always did for KeePass 1.
    private func rememberUnlockSecret() {
        let keyOnly = masterPassword.isEmpty ? openedFiles.first { $0.url.path == databaseURL.path }?.keyFile : nil
        let secret = StoredUnlock(password: masterPassword, keyFile: keyOnly).encoded
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
        guard touchIDAvailable, !touchIDBusy, !unlocking else { return }
        let account = databaseURL.path
        let generation = unlockGeneration
        touchIDBusy = true
        Task { @MainActor in
            defer { self.touchIDBusy = false }
            guard let stored = await self.authenticateTouchID(reason: "Unlock PasswordPie", account: account) else { return }
            // lock() ran while the prompt was up: it must not get a key file back.
            guard self.unlockGeneration == generation else { return }
            guard self.databaseURL.path == account else {
                self.message = "The open database changed. Try Touch ID again."
                return
            }
            // Older builds kept a KeePass 1 key file inside the Touch ID secret.
            let storedKeyFile = stored.keyFile.flatMap { self.showsKeyFile ? $0 : nil }
            guard !self.unlocking else { return }
            self.decrypt(password: stored.password, keyFile: storedKeyFile) { session, result in
                switch result {
                case .success(let opened):
                    // Only a decrypt that lock() did not cancel gets here, and only a success keeps the key file in the draft.
                    if let keyFile = storedKeyFile {
                        session.keyFileData = keyFile
                        session.keyFileOwner = account
                        if session.keyFileName.isEmpty { session.keyFileName = "Key file" }
                    }
                    session.apply(opened.vault, password: stored.password, keyFile: opened.keyFile)
                    session.didUnlock(withMasterPassword: false)
                case .failure(let error):
                    if session.isWrongPassword(error) {
                        session.message = storedKeyFile == nil && session.keyFileForUnlock == nil && session.showsKeyFile
                            ? "The saved Touch ID password doesn't open this database. If it needs a key file, choose it first."
                            : "The saved Touch ID password doesn't match this database. Unlock with the master password."
                    } else {
                        session.message = session.openErrorText(error)
                    }
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
                let stored = StoredUnlock(password: password)
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
        // A database with no password: its key file is the only secret, so the lock screen must not keep it.
        let keyOnlyDatabase = databaseUsesKeyFile && masterPassword.isEmpty
        unlockGeneration &+= 1
        catalogGeneration &+= 1
        openedFiles = []
        listOrigins = [:]
        listSlots = [:]
        listPaths = [:]
        entrySources = [:]
        entries = []
        masterPassword = ""
        passwordDraft = ""
        confirmDraft = ""
        editing = nil
        locked = true
        creating = !FileManager.default.fileExists(atPath: databaseURL.path)
        message = ""
        importStatus = ""
        importStatusIsError = false
        databaseUsesKeyFile = false
        keyFileStatus = ""
        keyFileStatusIsError = false
        if keyOnlyDatabase { clearKeyFile() }
        syncKeyFileDraft()
        clearChrome(locking: true)
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
        AppDelegate.shared?.presentFilePanel { [weak self] in
            guard let self else { return }
            let chooser = NSOpenPanel()
            DatabaseChooser.configure(chooser)
            guard chooser.runModal() == .OK, let url = chooser.url else { return }
            self.databaseURL = self.databaseURL(resolving: url)
            self.clearKeyFile()
            self.lock()
            self.offerRememberedUnlock()
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
            let kept = OpenedCatalog.afterRemoval(
                openedPaths: openedFiles.map(\.url.path),
                removedPath: resolved,
                secretDeleted: true
            )
            if kept.count != openedFiles.count {
                openedFiles = openedFiles.filter { kept.contains($0.url.path) }
                publishCatalog()
            }
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
                clearPendingImport(source: path)
            }
        }
        let applied = next.keeping(blocked)
        roster = applied
        databasePaths = applied.paths
        if ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil {
            UserDefaults.standard.set(applied.current, forKey: "databasePath")
            UserDefaults.standard.set(applied.paths, forKey: "databasePaths")
        }
    }

    /// A sibling joins the merged list only while its own 7-day window is open.
    private func rememberedUnlock(for path: String) -> StoredUnlock? {
        let defaults = UserDefaults.standard
        let stamp = defaults.object(forKey: touchIDStampKey(for: path)) as? Date
        switch RememberedFile.access(
            enabled: defaults.bool(forKey: touchIDEnabledKey(for: path)),
            stale: defaults.bool(forKey: touchIDStaleKey(for: path)),
            unlockedAt: stamp,
            now: Date()
        ) {
        case .skip:
            return nil
        case .expire:
            expireTouchID(for: path)
            return nil
        case .load(let stampNow):
            if stampNow { defaults.set(Date(), forKey: touchIDStampKey(for: path)) }
            let loaded = secretStore.load(account: path)
            guard loaded.status == errSecSuccess, let secret = loaded.secret, let stored = StoredUnlock(stored: secret) else {
                if loaded.status == errSecItemNotFound { expireTouchID(for: path) }
                return nil
            }
            return stored
        }
    }

    /// Deletes one file's saved secret after its window ends. Does not mark Touch ID declined.
    private func expireTouchID(for account: String) {
        let status = secretStore.delete(account: account)
        guard !TouchIDEnrollment.keepsPersistedFlag(deleteStatus: status) else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: touchIDEnabledKey(for: account))
        defaults.removeObject(forKey: touchIDStampKey(for: account))
        defaults.removeObject(forKey: touchIDStaleKey(for: account))
    }

    /// An import saved as a sibling `.kdbx` keeps its keychain secret. A failed copy leaves the old path listed.
    private func migrateUnlockSecret(from old: String, to new: String) -> Bool {
        guard old != new else { return true }
        // A KeePass 1 file's key file stays with the .kdbx written from it.
        let key = keyFileMemory.load(account: old)
        if let remembered = key.secret, !remembered.isEmpty {
            guard keyFileMemory.save(secret: remembered, account: new) == errSecSuccess else { return false }
        } else if key.status != errSecItemNotFound {
            return false
        }
        let loaded = secretStore.load(account: old)
        if let secret = loaded.secret, !secret.isEmpty {
            guard secretStore.save(secret: secret, account: new) == errSecSuccess else { return false }
        } else if loaded.status != errSecItemNotFound {
            return false
        }
        let defaults = UserDefaults.standard
        let keys = [
            (touchIDStampKey(for: old), touchIDStampKey(for: new)),
            (touchIDEnabledKey(for: old), touchIDEnabledKey(for: new)),
            (touchIDStaleKey(for: old), touchIDStaleKey(for: new)),
            (touchIDDeclinedKey(for: old), touchIDDeclinedKey(for: new))
        ]
        for (source, destination) in keys {
            if let value = defaults.object(forKey: source) {
                defaults.set(value, forKey: destination)
            }
        }
        return true
    }

    /// The sibling path has to outlive lock. The opened file is cleared, and a fresh name would skip the file already written.
    private func pendingImportKey(for path: String) -> String { "importPending.\(path)" }

    private func pendingImportPath(for path: String) -> String? {
        guard ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil else { return nil }
        let saved = UserDefaults.standard.string(forKey: pendingImportKey(for: path))
        return saved?.isEmpty == false ? saved : nil
    }

    private func rememberPendingImport(source: String, destination: String) {
        guard ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil else { return }
        UserDefaults.standard.set(destination, forKey: pendingImportKey(for: source))
    }

    private func clearPendingImport(source: String) {
        guard ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil else { return }
        UserDefaults.standard.removeObject(forKey: pendingImportKey(for: source))
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

    /// The lock screen's key file row. While creating a database it adds a new or existing key file to it.
    func chooseKeyFile() {
        if creating {
            addKeyFileToNewDatabase()
            return
        }
        runKeyFileFlow { [weak self] in
            guard let self, let url = self.keyFilePrompts.existingKeyFile(message: "Choose the database's key file") else { return }
            switch Self.readKeyFile(at: url, kdbxRules: self.databaseURL.pathExtension.lowercased() != "kdb") {
            case .success(let data):
                self.keyFileData = data
                self.keyFileName = url.lastPathComponent
                self.keyFileOwner = self.databaseURL.path
                self.keyFileRemembered = false
                self.message = ""
            case .failure(let error):
                self.message = error.description
            }
        }
    }

    func newDatabase() {
        AppDelegate.shared?.presentFilePanel { [weak self] in
            guard let self else { return }
            let chooser = NSSavePanel()
            chooser.nameFieldStringValue = "PasswordPie.kdbx"
            chooser.message = "Choose where to create the new KeePass database"
            guard chooser.runModal() == .OK, let url = chooser.url else { return }
            self.databaseURL = url
            self.clearKeyFile()
            self.lock()
        }
    }

    // MARK: Entries

    /// Shared by `allEntries` and the pinned windows, which build it from the values a publisher just emitted.
    static func visibleEntries(saved: [VaultEntry], live: [VaultEntry]) -> [VaultEntry] {
        #if PP_DIRECT
        return ChromeLogins.combined(saved: saved, live: live)
        #else
        return saved
        #endif
    }

    private func visibleCatalog() -> (entries: [VaultEntry], badges: Set<UUID>) {
        #if PP_DIRECT
        let view = ChromeLogins.view(saved: entries, live: liveEntries, rules: chromeJoinRules())
        return (view.entries, view.fromChrome)
        #else
        return (entries, [])
        #endif
    }

    /// A Chrome login with no database entry yet.
    func isLive(_ id: UUID) -> Bool {
        liveEntries.contains { $0.id == id } && storedEntry(id) == nil
    }

    /// The entry as shown. Change and save `storedEntry` instead.
    func entry(_ id: UUID) -> VaultEntry? {
        allEntries.first { $0.id == id && !$0.trashed }
    }

    func storedEntry(_ id: UUID) -> VaultEntry? {
        entries.first { $0.id == id && !$0.trashed }
    }

    /// A Chrome login as a database entry, in the group and with the tag a CSV import uses.
    /// It keeps the login's id, so it stays the same account for an open details view, a pinned window and ranking.
    private func chromeDraft(_ id: UUID) -> VaultEntry? {
        guard isLive(id), var draft = entry(id) else { return nil }
        draft.groupPath = [BrowserImportSource.chrome.label]
        draft.tags = BrowserImportSource.chrome.label
        return draft
    }

    /// Chrome's own last-used time still ranks the entry after Chrome sync is turned off.
    private func keepChromeLastUsed(_ id: UUID) {
        if let used = chromeLastUsed[id] { try? usage.record(id, at: used) }
    }

    func newEntry() {
        onActivity?()
        editing = VaultEntry()
        editingOriginal = nil
        editingIsNew = true
    }

    /// Editing a Chrome login opens a draft. Save puts it in the database and Chrome is left as it is.
    func edit(_ id: UUID) {
        if let draft = chromeDraft(id) {
            onActivity?()
            editing = draft
            editingOriginal = nil
            editingIsNew = true
            return
        }
        guard let entry = storedEntry(id) else { return }
        onActivity?()
        editing = entry
        editingOriginal = entry
        editingIsNew = false
    }

    func saveEditing(_ entry: VaultEntry) {
        var entry = entry
        carryPasswordBookkeeping(into: &entry)
        carryScannedCode(into: &entry)
        let isDraft = storedEntry(entry.id) == nil
        if storeEntry(entry) {
            editing = nil
            keepChromeLastUsed(entry.id)
        } else if !isDraft {
            #if !PP_DIRECT
            editing = nil
            #endif
            // Direct channel: `persist` undid the failed write, and the editor stays open with what was typed.
        }
    }

    /// Writes one item, new or changed, to its database file. Leaves the editor alone, so a scanned code can be added while
    /// another item is open in it. False when the file could not be written.
    @discardableResult
    func storeEntry(_ entry: VaultEntry) -> Bool {
        var entry = entry
        if entry.title.isEmpty { entry.title = "Untitled" }
        let path = listPaths[entry.id] ?? databaseURL.path
        // A new item, or a Chrome draft that may reuse the row of its trashed copy. A failed write has nothing else holding it,
        // so it comes back out of the database and the editor stays open with what the user typed.
        let isDraft = storedEntry(entry.id) == nil
        let before = openedFiles.first { $0.url.path == path }?.vault.entries ?? []
        if listPaths[entry.id] != nil {
            replaceStored(entry)
        } else {
            appendStored(entry, to: path)
        }
        if persist(path: path) { return true }
        if isDraft {
            if let index = openedFiles.firstIndex(where: { $0.url.path == path }) {
                openedFiles[index].vault.entries = before
            }
            publishCatalog()
        }
        return false
    }

    /// A scanned code may have been added to this item while the editor was open. Keep it unless the editor changed the field.
    private func carryScannedCode(into entry: inout VaultEntry) {
        guard let original = editingOriginal, original.id == entry.id, let stored = storedEntry(entry.id), stored.otp != original.otp else { return }
        let untouched = entry.otp == original.otp || entry.otp == editorOTPValue(original.otp, title: entry.title, username: entry.username)
        if untouched { entry.otp = stored.otp }
    }

    /// The editor holds a copy from when it opened. A Chrome update or a Restore may have landed since.
    private func carryPasswordBookkeeping(into entry: inout VaultEntry) {
        #if PP_DIRECT
        guard let stored = storedEntry(entry.id) else { return }
        if entry.password == editingOriginal?.password { entry.password = stored.password }
        entry.fields.removeAll { $0.key == PreviousPasswords.key }
        if let record = stored.fields.first(where: { $0.key == PreviousPasswords.key }) { entry.fields.append(record) }
        if entry.password != stored.password {
            PreviousPasswords.recordChange(from: stored.password, on: &entry, previousDate: chromePasswordDates()[entry.id], now: chromeClock())
        }
        #endif
    }

    func cancelEditing() {
        editing = nil
    }

    /// Restores the accounts from before this one was merged, and marks each so it stays separate.
    func splitEditing() {
        guard let current = editing else { return }
        let path = listPaths[current.id] ?? databaseURL.path
        let originalID = listOrigins[current.id] ?? current.id
        guard let fileIndex = openedFiles.firstIndex(where: { $0.url.path == path }) else { return }
        var entries = openedFiles[fileIndex].vault.entries
        let survivorSlot = listSlots[current.id]
        let source: VaultEntry
        if let survivorSlot, entries.indices.contains(survivorSlot), entries[survivorSlot].id == originalID {
            source = entries[survivorSlot]
        } else if let found = entries.first(where: { $0.id == originalID }) {
            source = found
        } else {
            return
        }
        guard var parts = EntryMerge.split(source) else { return }
        if !parts.isEmpty { parts[0].id = originalID }
        var used = Set<Int>()
        for (index, part) in parts.enumerated() {
            if index == 0, let slot = SplitPlacement.index(slot: survivorSlot, entries: entries, id: originalID) {
                entries[slot] = part
                used.insert(slot)
                continue
            }
            if let slot = entries.indices.first(where: { entries[$0].id == part.id && entries[$0].trashed && !used.contains($0) }) {
                entries[slot] = part
                used.insert(slot)
            } else {
                entries.append(part)
            }
        }
        openedFiles[fileIndex].vault.entries = entries
        editing = nil
        persist(path: path)
    }

    /// Writes the file when a merge folded accounts. A database with nothing to fold is left untouched.
    private func autoMergeFile(at path: String) {
        guard let index = openedFiles.firstIndex(where: { $0.url.path == path }) else { return }
        let merged = EntryMerge.merged(openedFiles[index].vault.entries)
        guard merged != openedFiles[index].vault.entries else { return }
        openedFiles[index].vault.entries = merged
        _ = persist(path: path)
    }

    func deleteEditing() {
        guard let id = editing?.id, var entry = storedEntry(id) else { return }
        entry.trashed = true
        replaceStored(entry)
        editing = nil
        persist(path: listPaths[id] ?? databaseURL.path)
    }

    func toggleFavorite(_ id: UUID) {
        guard var entry = storedEntry(id) else {
            favoriteChromeLogin(id)
            return
        }
        entry.favorite.toggle()
        replaceStored(entry)
        persist(path: listPaths[id] ?? databaseURL.path)
    }

    /// A favorite lives in the database, so starring a Chrome login saves it. A failed write leaves it as a Chrome login.
    private func favoriteChromeLogin(_ id: UUID) {
        guard var draft = chromeDraft(id) else { return }
        draft.favorite = true
        let path = listPaths[id] ?? databaseURL.path
        let before = openedFiles.first { $0.url.path == path }?.vault.entries ?? []
        if listPaths[id] != nil {
            replaceStored(draft)
        } else {
            appendStored(draft, to: path)
        }
        if persist(path: path) {
            keepChromeLastUsed(id)
        } else {
            if let index = openedFiles.firstIndex(where: { $0.url.path == path }) {
                openedFiles[index].vault.entries = before
            }
            publishCatalog()
        }
    }

    /// A generated password saved as a new Password item, only when the user asks for it.
    /// New items go into the file whose password unlocked this session.
    func saveGenerated(_ password: String) {
        var entry = VaultEntry()
        entry.title = "Generated Password"
        entry.password = password
        appendStored(entry, to: databaseURL.path)
        persist(path: databaseURL.path)
    }

    // MARK: Browser password import

    /// Imports a Chrome or Apple Passwords CSV into this database, then offers to delete the plain-text file.
    func importPasswords(from source: BrowserImportSource) {
        guard !locked else {
            setImportStatus("Unlock the database first.", isError: true)
            return
        }
        AppDelegate.shared?.presentFilePanel { [weak self] in
            guard let self else { return }
            let chooser = NSOpenPanel()
            chooser.canChooseFiles = true
            chooser.canChooseDirectories = false
            chooser.allowedContentTypes = [.commaSeparatedText]
            chooser.allowsOtherFileTypes = true
            chooser.message = "Choose the \(source.label) password export (.csv)"
            guard chooser.runModal() == .OK, let url = chooser.url else { return }
            self.importChosenPasswords(from: url, source: source)
        }
    }

    private func importChosenPasswords(from url: URL, source: BrowserImportSource) {

        let imported: [VaultEntry]
        do {
            imported = try BrowserImport.entries(fromCSV: Data(contentsOf: url), source: source)
        } catch {
            setImportStatus(openErrorText(error), isError: true)
            return
        }
        guard let summary = mergeImported(imported, source: source) else {
            setImportStatus("Couldn't save the imported passwords. Nothing was changed.", isError: true)
            return
        }
        var status = importSummaryText(summary, source: source)
        var failed = false
        if confirmDeleteExport(url) {
            do {
                try BrowserImport.deleteExport(at: url)
                status += " The export file was deleted."
            } catch {
                status += " Couldn't delete the export file. It still holds your passwords in plain text, so delete it yourself."
                failed = true
            }
        } else {
            status += " The export file is still on disk in plain text."
        }
        setImportStatus(status, isError: failed)
    }

    /// Merges an export into the file this session unlocked and saves it. The merged menu list is never saved as one database.
    /// Returns nil, with nothing changed, when the file cannot be saved.
    func mergeImported(_ imported: [VaultEntry], source: BrowserImportSource) -> BrowserImportSummary? {
        let path = databaseURL.path
        guard let fileIndex = openedFiles.firstIndex(where: { $0.url.path == path }) else { return nil }
        let backup = openedFiles[fileIndex].vault
        let merged = BrowserImport.merge(imported, into: backup.entries, source: source)
        openedFiles[fileIndex].vault.entries = merged.entries
        guard persist(path: path) else {
            if let index = openedFiles.firstIndex(where: { $0.url.path == path }) { openedFiles[index].vault = backup }
            publishCatalog()
            return nil
        }
        return merged.summary
    }

    func setImportStatus(_ text: String, isError: Bool) {
        importStatus = text
        importStatusIsError = isError
    }

    func importSummaryText(_ summary: BrowserImportSummary, source: BrowserImportSource) -> String {
        var parts: [String] = []
        if summary.added > 0 { parts.append("\(summary.added) added") }
        if summary.updated > 0 { parts.append("\(summary.updated) updated") }
        if summary.removed > 0 { parts.append("\(summary.removed) moved to the Recycle Bin") }
        if parts.isEmpty { return "\(source.label) is already up to date." }
        return "Imported from \(source.label): " + parts.joined(separator: ", ") + "."
    }

    private func confirmDeleteExport(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete the exported file?"
        alert.informativeText = "\(url.lastPathComponent) holds your passwords in plain text. They are now in your PasswordPie database, so the file is no longer needed. Deleting it is permanent."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Keep")
        return AppDelegate.shared?.keepOpen { alert.runModal() == .alertFirstButtonReturn } ?? false
    }

    // MARK: Actions

    func value(of target: CopyTarget, in entry: VaultEntry) -> String {
        switch target {
        case .username: return entry.username
        case .password: return entry.password
        case .url: return entry.url
        case .notes: return entry.notes
        case .oneTimePassword:
            guard case .available(let settings) = oneTimeCodeAccess(for: entry) else { return "" }
            return OneTimeCodes.code(settings: settings)
        case .custom(let key): return entry.value(for: key)
        }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        onActivity?()
        clipboard.copy(text)
    }

    /// Whether this user can get `entry`'s one-time code. The only way to the code settings in the app.
    func oneTimeCodeAccess(for entry: VaultEntry) -> OneTimeCodeAccess {
        OneTimeCodes.access(for: entry, hasPremium: premium.hasPremium)
    }

    /// Opens the plans, or if the store has not answered yet, waits for it and then runs `action` for someone who has Premium.
    func requestPremium(then action: @escaping () -> Void = {}) {
        premium.requestUnlock(then: action)
    }

    func copy(_ target: CopyTarget, of id: UUID) {
        guard let entry = entry(id) else { return }
        // A locked code is an empty string, and it must not count as using the account.
        if target == .oneTimePassword, oneTimeCodeAccess(for: entry) == .locked {
            requestPremium { [weak self] in self?.copy(target, of: id) }
            return
        }
        copy(value(of: target, in: entry))
        switch target {
        case .username, .password, .oneTimePassword: recordUse(id)
        case .url, .notes, .custom: break
        }
    }

    /// What ⌃⌘C, ⇧⌘C and ⌥⌘C do, in the menu and with a pinned window.
    @discardableResult
    func runCopyShortcut(_ shortcut: QuickAccessShortcut, of id: UUID) -> CopyOutcome {
        guard let entry = entry(id), let target = quickAccessCopyTarget(shortcut, of: entry) else { return .nothingToCopy }
        if target == .oneTimePassword, oneTimeCodeAccess(for: entry) == .locked {
            copy(target, of: id)
            return .premiumRequired
        }
        guard !value(of: target, in: entry).isEmpty else { return .nothingToCopy }
        copy(target, of: id)
        return .copied
    }

    /// `website` is one of the account's sites. Nil opens its main one.
    func openURL(of id: UUID, website: String? = nil) {
        guard let raw = website ?? entry(id)?.url, let url = webURL(raw) else { return }
        onActivity?()
        NSWorkspace.shared.open(url)
        recordUse(id)
    }

    /// When each account was last used, for search ranking: this app's own record, or Chrome's for a login with that id, whichever is later.
    var lastUsedMap: [UUID: Date] {
        usage.lastUsed.merging(chromeLastUsed) { max($0, $1) }
    }

    /// Copying a username, password or code, filling, and opening the website count as using an account. Looking at it does not.
    /// A failed write only loses one ranking hint, so it does not interrupt the action.
    private func recordUse(_ id: UUID) {
        try? usage.record(id)
    }

    /// Fills the previous app. The panel hides first so keystrokes reach the app that was frontmost.
    func fill(_ id: UUID, _ mode: FillMode, website: String? = nil) {
        guard let entry = entry(id) else { return }
        // The browser extension fills the page itself, without keystrokes or Accessibility.
        if mode != .open, browserFill?(entry, mode, website) == true {
            onActivity?()
            recordUse(id)
            return
        }
        let mode: FillMode = mode == .fillOrOpen ? .openAndFill : mode
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }
        onActivity?()
        recordUse(id)
        let keystrokes = fillKeystrokes(for: entry)
        let delay: Double
        if mode == .openAndFill || mode == .open, let url = webURL(website ?? entry.url) {
            NSWorkspace.shared.open(url)
            delay = 2.5
        } else {
            delay = 0.25
        }
        hidePanel?()
        guard mode != .open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for keystroke in keystrokes {
                switch keystroke {
                case .text(let text): typeText(text)
                case .tab: typeTab()
                }
            }
        }
    }

    func showLargeType(_ text: String) {
        guard !text.isEmpty else { return }
        AppDelegate.shared?.showLargeType(text)
    }

    /// Pins the account in a floating window, then puts the menu away so the user can fill another app.
    func pinEntry(_ id: UUID) {
        guard let entry = entry(id) else { return }
        onActivity?()
        AppDelegate.shared?.showPinnedEntry(entry)
        hidePanel?()
    }

    // MARK: Private

    /// Quitting inside the clipboard timeout must not leave a copied secret behind.
    func flushClipboard() {
        clipboard.flush()
    }

    private func apply(_ vault: Vault, password: String, keyFile: Data?) {
        vaultName = vault.name
        rootName = vault.rootName
        kdf = vault.kdf
        masterPassword = password
        passwordDraft = ""
        // Not for a key-file-only database: keeping its key would open it with nothing typed.
        if let keyFile, !password.isEmpty { rememberKeyFile(keyFile) }
        databaseUsesKeyFile = keyFile != nil
        let file = OpenedFile(url: databaseURL, vault: vault, password: password, keyFile: keyFile)
        if let index = openedFiles.firstIndex(where: { $0.url.path == databaseURL.path }) {
            openedFiles[index] = file
        } else {
            openedFiles.insert(file, at: 0)
        }
        autoMergeFile(at: databaseURL.path)
        loadRememberedDatabases()
    }

    /// Other files in the list open from their own keychain secrets. A file without one stays out of the list.
    /// The current file is published immediately. Siblings decrypt off the main actor, one at a time.
    private func loadRememberedDatabases() {
        catalogGeneration &+= 1
        let generation = catalogGeneration
        let currentPath = databaseURL.path
        openedFiles.removeAll { $0.url.path != currentPath }
        publishCatalog()
        guard ProcessInfo.processInfo.environment["PASSWORDPIE_DB"] == nil else { return }
        let jobs: [SiblingJob] = databasePaths.compactMap { path in
            guard path != currentPath, let stored = rememberedUnlock(for: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let key = Self.takesKeyFile(url) ? (stored.keyFile ?? rememberedKeyFile(for: path)?.data) : nil
            return SiblingJob(path: path, password: stored.password, keyFile: key)
        }
        #if PP_DIRECT
        chromeAwaitingSiblings = !jobs.isEmpty
        #endif
        guard !jobs.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if PP_DIRECT
            defer {
                if generation == self.catalogGeneration {
                    self.chromeAwaitingSiblings = false
                    self.reconcileChromeUpdates()
                }
            }
            #endif
            for job in jobs {
                if CatalogLoad.step(
                    generation: generation,
                    current: self.catalogGeneration,
                    pathStillListed: true
                ) == .stop { return }
                let loaded = await Task.detached { () -> Vault? in
                    try? VaultFile.openRecovering(
                        url: URL(fileURLWithPath: job.path),
                        password: job.password,
                        keyFile: job.keyFile
                    )
                }.value
                self.showRecoveryNotice(loaded?.recoveryNotice, path: job.path, detailed: !self.locked)
                switch CatalogLoad.step(
                    generation: generation,
                    current: self.catalogGeneration,
                    pathStillListed: self.databasePaths.contains(job.path) && job.path != self.databaseURL.path
                ) {
                case .stop:
                    return
                case .skipFile:
                    continue
                case .publish:
                    guard let loaded, !self.openedFiles.contains(where: { $0.url.path == job.path }) else { continue }
                    let url = URL(fileURLWithPath: job.path)
                    self.openedFiles.append(OpenedFile(
                        url: url, vault: loaded, password: job.password, keyFile: job.keyFile
                    ))
                    self.publishCatalog()
                    self.autoMergeFile(at: job.path)
                }
            }
        }
    }

    func publishCatalog() {
        let merged = EntryCatalog.merge(openedFiles.map { (path: $0.url.path, entries: $0.vault.entries) })
        listOrigins = Dictionary(uniqueKeysWithValues: merged.map { ($0.listID, $0.entry.id) })
        listSlots = EntryCatalog.indexes(in: merged)
        listPaths = Dictionary(uniqueKeysWithValues: merged.map { ($0.listID, $0.path) })
        entrySources = listPaths
        entries = merged.map { item in
            var copy = item.entry
            copy.id = item.listID
            return copy
        }
    }

    private func appendStored(_ entry: VaultEntry, to path: String) {
        if !openedFiles.contains(where: { $0.url.path == path }) {
            openedFiles.insert(
                OpenedFile(
                    url: URL(fileURLWithPath: path),
                    vault: Vault(name: vaultName, rootName: rootName, entries: [], kdf: kdf),
                    password: masterPassword,
                    keyFile: path == databaseURL.path ? keyFileForUnlock : nil
                ),
                at: 0
            )
        }
        guard let index = openedFiles.firstIndex(where: { $0.url.path == path }) else { return }
        openedFiles[index].vault.entries.append(entry)
    }

    private func replaceStored(_ entry: VaultEntry) {
        guard let path = listPaths[entry.id], let original = listOrigins[entry.id],
              let slot = listSlots[entry.id],
              let fileIndex = openedFiles.firstIndex(where: { $0.url.path == path }),
              openedFiles[fileIndex].vault.entries.indices.contains(slot),
              openedFiles[fileIndex].vault.entries[slot].id == original
        else { return }
        var stored = entry
        stored.id = original
        openedFiles[fileIndex].vault.entries[slot] = stored
    }

    @discardableResult
    private func save() -> Bool {
        persist(path: databaseURL.path)
    }

    /// Writes one file. The merged list is never saved into a single database. Returns whether the file was written.
    @discardableResult
    private func persist(path: String) -> Bool {
        let written = write(path: path)
        #if PP_DIRECT
        // Nothing unsaved stays in memory, so a background Chrome write cannot carry a change the person was told had failed.
        if !written, let index = openedFiles.firstIndex(where: { $0.url.path == path }), openedFiles[index].vault.entries != openedFiles[index].committedEntries {
            openedFiles[index].vault.entries = openedFiles[index].committedEntries
            publishCatalog()
        }
        #endif
        return written
    }

    private func write(path: String) -> Bool {
        onActivity?()
        let index = openedFiles.firstIndex { $0.url.path == path }
        var vault = index.map { openedFiles[$0].vault }
            ?? Vault(name: vaultName, rootName: rootName, entries: [], kdf: kdf)
        let password = index.map { openedFiles[$0].password } ?? masterPassword
        let fileURL = index.map { openedFiles[$0].url } ?? URL(fileURLWithPath: path)
        let isCurrent = path == databaseURL.path
        // A file keeps the key file it opened with. A new database takes the one chosen on the lock screen.
        let keyFile = index.map { openedFiles[$0].keyFile } ?? (isCurrent ? keyFileForUnlock : nil)
        if isCurrent {
            vault.name = vaultName
            vault.rootName = rootName
            vault.kdf = kdf
        }
        vault.entries = EntryMerge.merged(vault.entries)
        // An imported CSV, PUX, OPVault, Bitwarden, Proton Pass, or KeePass 1 file stays untouched.
        // The first change is written as a sibling .kdbx, and later saves use that file.
        // A key-file-only database can open with an empty password. The new .kdbx cannot.
        let writesKDBX = VaultFormat.writesKDBX(fileURL)
        if VaultFormat.blocksImportSave(writesKDBX: writesKDBX, password: password) {
            message = "Set a master password before saving this database."
            NSSound.beep()
            return false
        }
        let pending = index.flatMap { openedFiles[$0].pendingSaveURL?.path } ?? pendingImportPath(for: path)
        let destination = writesKDBX ? fileURL : ImportDestination.url(source: fileURL, pending: pending)
        do {
            let data = try KDBX.save(vault: &vault, password: password, keyFile: keyFile)
            try VaultFile.replace(destination, with: data, password: password, keyFile: keyFile, expecting: vault)
            vault.noteFileContents(data)
            // Move the secret before the opened file changes path. A failed move keeps the
            // source path, so the next save still finds this vault and rewrites the same sibling.
            let moved = destination.path == path || migrateUnlockSecret(from: path, to: destination.path)
            let decision = ImportRetarget.decide(source: path, destination: destination.path, secretMoved: moved)
            let stored = OpenedFile(
                url: URL(fileURLWithPath: decision.openedPath),
                vault: vault,
                password: password,
                keyFile: keyFile,
                pendingSaveURL: decision.pendingPath.map { URL(fileURLWithPath: $0) },
                revision: index.map { openedFiles[$0].revision + 1 } ?? 0
            )
            if let index {
                openedFiles[index] = stored
            } else {
                openedFiles.insert(stored, at: 0)
            }
            if decision.retargetRoster {
                // The sibling .kdbx is the file we will open next. Leaving the import in the
                // roster would show the same entries twice.
                clearPendingImport(source: path)
                applyingRoster = true
                if isCurrent { databaseURL = URL(fileURLWithPath: decision.openedPath) }
                adopt(roster.replacing(path, with: destination.path))
                applyingRoster = false
            } else if let pendingPath = decision.pendingPath {
                rememberPendingImport(source: path, destination: pendingPath)
                message = "Saved \(destination.lastPathComponent), but the saved password could not move to it."
            }
            if isCurrent {
                kdf = vault.kdf
                rootName = vault.rootName
                vaultName = vault.name
                masterPassword = password
            }
            publishCatalog()
            return true
        } catch {
            message = (error as? VaultWriteError)?.description
                ?? (error as? KDBXError)?.description
                ?? "The database could not be saved."
            NSSound.beep()
            return false
        }
    }

    var keyFileForUnlock: Data? {
        Self.takesKeyFile(databaseURL) && keyFileOwner == databaseURL.path ? keyFileData : nil
    }

    func clearKeyFile() {
        keyFileData = nil
        keyFileName = ""
        keyFileRemembered = false
        keyFileOwner = databaseURL.path
        keyFileStatus = ""
        keyFileStatusIsError = false
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

    func isWrongPassword(_ error: Error) -> Bool {
        if let open = error as? VaultOpenError, case .wrongPassword = open { return true }
        if let kdbx = error as? KDBXError, kdbx == .wrongPassword { return true }
        return false
    }

    func openErrorText(_ error: Error) -> String {
        if let open = error as? VaultOpenError { return open.description }
        if let kdbx = error as? KDBXError { return kdbx.description }
        if let keyFile = error as? KeyFileError { return keyFile.description }
        return error.localizedDescription
    }
}

/// Open-panel settings for choosing a database.
///
/// A plain folder is not a database. `UTType.folder` makes the first panel select
/// the folder it is showing, and the file list ignores clicks until the panel is
/// opened again. An OPVault is a package, so it stays selectable with directories off.
/// `canChooseDirectories` is set after the content types: on macOS 27 those types
/// can turn directory selection back on.
enum DatabaseChooser {
    static func configure(_ panel: NSOpenPanel) {
        panel.allowedContentTypes = VaultSession.databaseContentTypes()
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a KeePass, Bitwarden, Proton Pass, PUX, OPVault, or CSV database"
    }
}

// MARK: Menu catalog
/// Keeps the menu and the search index in step with the entries without blocking the main thread.
/// The panel opens at once: it shows what is ready, and the rest arrives as the background work finishes.
extension VaultSession {
    /// Up to this many entries are folded or laid out on the main thread, which takes a few milliseconds.
    static let inlineCatalogLimit = 300
    /// Entries folded per background step. Each step makes them searchable.
    static let indexChunkSize = 500

    /// Called whenever `entries` or `liveEntries` changes.
    func catalogChanged() {
        let catalog = visibleCatalog()
        let visible = catalog.entries
        MenuIcons.chromeAccounts = catalog.badges
        chromeBadgeIDs = catalog.badges
        allEntries = visible
        menuGeneration &+= 1
        menuWork.forEach { $0.cancel() }
        menuWork = []

        // Entries that did not change keep their prepared search text, so an edit or a favorite refolds one entry.
        let (kept, pending) = searchIndex.reusing(for: visible)
        let sources = entrySources
        if visible.count <= Self.inlineCatalogLimit {
            searchIndex = kept.adding(SearchIndex(pending))
            indexing = false
            topLevelRows = MenuBuilder.topLevel(entries: visible, sources: sources)
            return
        }

        var queue = pending
        if queue.count <= Self.inlineCatalogLimit {
            searchIndex = kept.adding(SearchIndex(queue))
            queue = []
        } else {
            searchIndex = kept
        }
        indexing = !queue.isEmpty
        // A brand-new catalog (just unlocked) shows "Loading…"; a change to the open one keeps the old rows until the new ones are ready.
        if kept.count == 0 { topLevelRows = nil }

        let generation = menuGeneration
        menuWork.append(Task { @MainActor [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                MenuBuilder.topLevel(entries: visible, sources: sources)
            }.value
            guard let self, self.menuGeneration == generation else { return }
            self.topLevelRows = rows
        })
        guard !queue.isEmpty else { return }
        menuWork.append(Task { @MainActor [weak self] in
            var remaining = queue[...]
            while !remaining.isEmpty {
                let chunk = Array(remaining.prefix(Self.indexChunkSize))
                remaining = remaining.dropFirst(chunk.count)
                let piece = await Task.detached(priority: .userInitiated) { SearchIndex(chunk) }.value
                guard let self, self.menuGeneration == generation else { return }
                self.searchIndex = self.searchIndex.adding(piece)
            }
            guard let self, self.menuGeneration == generation else { return }
            self.indexing = false
        })
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
/// The web address of an entry's website field. Only http and https open: an entry can come from an import or from Chrome,
/// and Fill types the password into the front app after the open, so another scheme (android://, ssh://, file://) must not launch a handler.
/// A bare host such as `github.com` or `localhost:3000` gets https.
func webURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let url = URL(string: candidate), url.host != nil,
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return url
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
