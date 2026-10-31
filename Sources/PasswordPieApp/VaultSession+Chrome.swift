import AppKit
import PasswordPieCore

/// Live Chrome logins. Direct channel only: the App Store build has the same methods as no-ops, and no reader code.
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
        chromeBusy = false
        chromeStatus = ""
        chromeStatusIsError = false
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
        if chromeSyncEnabled { refreshChrome() }
    }

    /// Reads Chrome again. Uses the key from this session when there is one, so the keychain prompt shows once per unlock at most.
    func refreshChrome() {
        guard !locked, !chromeBusy else { return }
        chromeBusy = true
        chromeStatus = "Reading Chrome…"
        chromeStatusIsError = false
        chromeGeneration += 1
        let generation = chromeGeneration
        let cached = chromeKey
        Task {
            let outcome: Result<(key: Data, result: ChromeLoginsResult), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let key: Data
                    if let cached {
                        key = cached
                    } else {
                        let secret = ChromeSafeStorage.keychainPassword()
                        guard let password = secret.password else { throw ChromeLoginsError.keychain(secret.status) }
                        key = try ChromeSafeStorage.deriveKey(password: password)
                    }
                    return .success((key, try ChromeLogins.load(key: key)))
                } catch {
                    return .failure(error)
                }
            }.value
            // A lock or a newer refresh while this ran makes the result stale. Drop it.
            guard generation == chromeGeneration, !locked else { return }
            chromeBusy = false
            switch outcome {
            case .success(let loaded):
                chromeKey = loaded.key
                liveEntries = loaded.result.entries
                chromeStatus = chromeSummary(loaded.result)
                chromeStatusIsError = false
            case .failure(let error):
                liveEntries = []
                chromeKey = nil
                chromeStatus = chromeErrorText(error)
                chromeStatusIsError = true
            }
        }
    }

    private func chromeSummary(_ result: ChromeLoginsResult) -> String {
        let passwords = result.entries.count == 1 ? "1 password" : "\(result.entries.count) passwords"
        let profiles = result.profileCount == 1 ? "1 profile" : "\(result.profileCount) profiles"
        var text = "\(passwords) from \(profiles)."
        if result.skipped > 0 { text += " \(result.skipped) couldn't be read." }
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

    /// Chrome owns these logins, so changes happen there.
    func editInChrome() {
        guard let page = URL(string: "chrome://password-manager/passwords"),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
    #else
    func setChromeSync(_ enabled: Bool) {}
    func startChromeSyncIfEnabled() {}
    func refreshChrome() {}
    func editInChrome() {}
    #endif
}
