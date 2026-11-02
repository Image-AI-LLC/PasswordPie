import AppKit
import PasswordPieCore

/// Live Chrome logins. Direct channel only: the App Store build has the same methods as no-ops, and no reader code.
#if PP_DIRECT
/// Where a Chrome read comes from. Tests substitute a store that never touches the keychain or the real Chrome folder.
struct ChromeSnapshotSource: Sendable {
    var signature: @Sendable () -> ChromeStoreSignature
    var load: @Sendable (_ cachedKey: Data?) throws -> (key: Data, result: ChromeLoginsResult)

    static let live = ChromeSnapshotSource(
        signature: { ChromeLogins.storeSignature() },
        load: { cached in
            let key: Data
            if let cached {
                key = cached
            } else {
                let secret = ChromeSafeStorage.keychainPassword()
                guard let password = secret.password else { throw ChromeLoginsError.keychain(secret.status) }
                key = try ChromeSafeStorage.deriveKey(password: password)
            }
            return (key, try ChromeLogins.load(key: key))
        }
    )
}
#endif
extension VaultSession {
    var chromeSyncAvailable: Bool {
        #if PP_DIRECT
        return true
        #else
        return false
        #endif
    }

    func clearChrome() {
        chromeGeneration += 1
        chromeKey = nil
        liveEntries = []
        chromeLastUsed = [:]
        chromeBusy = false
        chromeStatus = ""
        chromeStatusIsError = false
        chromeNeedsSettings = false
        #if PP_DIRECT
        chromeStoreSignature = nil
        chromeRecheckAfterRead = false
        #endif
    }

    #if PP_DIRECT
    private static let chromeSyncKey = "chromeSyncEnabled"

    /// Turning it on is the user's authorization: macOS then asks to let PasswordPie read "Chrome Safe Storage".
    func setChromeSync(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.chromeSyncKey)
        chromeSyncEnabled = enabled
        if enabled {
            refreshChrome()
        } else {
            clearChrome()
        }
    }

    func startChromeSyncIfEnabled() {
        chromeSyncEnabled = UserDefaults.standard.bool(forKey: Self.chromeSyncKey)
    }

    /// The panel is on screen. Compare the login files and, when they changed, read them without blocking the menu.
    func noteChromePanelShown() {
        guard chromeSyncEnabled, !locked else { return }
        if chromeBusy {
            chromeRecheckAfterRead = true
            return
        }
        let source = chromeSource
        Task { @MainActor [weak self] in
            let current = await Task.detached(priority: .utility) { source.signature() }.value
            guard let self else { return }
            self.refreshChromeIfStoreChanged(current)
        }
    }

    /// Reads only when `current` is not the signature of the last successful read.
    func refreshChromeIfStoreChanged(_ current: ChromeStoreSignature) {
        guard chromeSyncEnabled, !locked else { return }
        if chromeBusy {
            chromeRecheckAfterRead = true
            return
        }
        guard current != chromeStoreSignature else { return }
        refreshChrome()
    }

    /// Reads Chrome again. Uses the key from this session when there is one, so the keychain prompt shows once per unlock at most.
    /// The menu keeps its current passwords until this finishes. A failed read leaves them in place.
    func refreshChrome() {
        guard !locked, chromeSyncEnabled else { return }
        if chromeBusy {
            chromeRecheckAfterRead = true
            return
        }
        chromeBusy = true
        chromeGeneration += 1
        let generation = chromeGeneration
        let cached = chromeKey
        let source = chromeSource
        Task { @MainActor [weak self] in
            let outcome: Result<(key: Data, result: ChromeLoginsResult, signature: ChromeStoreSignature), Error> =
                await Task.detached(priority: .userInitiated) {
                    let signature = source.signature()
                    do {
                        let loaded = try source.load(cached)
                        return .success((loaded.key, loaded.result, signature))
                    } catch {
                        return .failure(error)
                    }
                }.value
            guard let self else { return }
            // A lock or a newer refresh while this ran makes the result stale. Drop it.
            guard generation == self.chromeGeneration, !self.locked else { return }
            self.chromeBusy = false
            switch outcome {
            case .success(let loaded):
                self.applyChromeSuccess(loaded)
            case .failure(let error):
                self.applyChromeFailure(error)
            }
            guard self.chromeRecheckAfterRead, !self.locked else { return }
            self.chromeRecheckAfterRead = false
            self.noteChromePanelShown()
        }
    }

    private func applyChromeSuccess(_ loaded: (key: Data, result: ChromeLoginsResult, signature: ChromeStoreSignature)) {
        chromeKey = loaded.key
        chromeStoreSignature = loaded.signature
        chromeNeedsSettings = false
        chromeStatusIsError = false
        chromeStatus = chromeSummary(loaded.result)
        let lastUsedChanged = loaded.result.lastUsed != chromeLastUsed
        if lastUsedChanged {
            chromeLastUsed = loaded.result.lastUsed
        }
        // Same logins: leave `liveEntries` alone so the open menu is not rebuilt.
        // A new last-used time still has to reach search, which reads it when the catalog is rebuilt.
        if loaded.result.entries != liveEntries {
            liveEntries = loaded.result.entries
        } else if lastUsedChanged {
            catalogChanged()
        }
    }

    private func applyChromeFailure(_ error: Error) {
        let chrome = error as? ChromeLoginsError
        // Nothing was shown yet, so this failure is the whole result.
        guard !liveEntries.isEmpty else {
            chromeKey = nil
            chromeLastUsed = [:]
            chromeStatus = chromeErrorText(error)
            chromeStatusIsError = true
            chromeNeedsSettings = chrome == .accessDenied
            return
        }
        // A torn read while Chrome is writing must not wipe the passwords already on screen.
        switch chrome {
        case .keychain, .wrongKey:
            chromeKey = nil
        case .database, nil:
            return
        case .accessDenied, .noChrome:
            break
        }
        chromeStatus = chromeErrorText(error)
        chromeStatusIsError = true
        chromeNeedsSettings = chrome == .accessDenied
    }

    private func chromeSummary(_ result: ChromeLoginsResult) -> String {
        let passwords = result.entries.count == 1 ? "1 password" : "\(result.entries.count) passwords"
        let profiles = result.profileCount == 1 ? "1 profile" : "\(result.profileCount) profiles"
        var text = "\(passwords) from \(profiles)."
        if result.skipped > 0 { text += " \(result.skipped) couldn't be read." }
        if !result.failedProfiles.isEmpty {
            text += result.failedProfiles.count == 1 ? " 1 profile couldn't be read." : " \(result.failedProfiles.count) profiles couldn't be read."
        }
        return text
    }

    private func chromeErrorText(_ error: Error) -> String {
        if let chrome = error as? ChromeLoginsError {
            if case .keychain = chrome {
                return "macOS didn't let PasswordPie read Chrome Safe Storage. Turn this off and on again, then choose Always Allow."
            }
            return chrome.description
        }
        return error.localizedDescription
    }

    /// macOS 27 has no prompt for this. The switch is under Files & Folders, one row per app.
    func openChromeFileAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Chrome owns these logins, so changes happen there.
    func editInChrome() {
        guard let page = URL(string: "chrome://password-manager/passwords"),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
    #else
    func setChromeSync(_ enabled: Bool) {}
    func startChromeSyncIfEnabled() {}
    func noteChromePanelShown() {}
    func refreshChrome() {}
    func editInChrome() {}
    #endif
}
