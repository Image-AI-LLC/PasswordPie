import AppKit
import AuthenticationServices
import PasswordPieCore

/// Apple Passwords hands its items over through Credential Exchange (macOS 26+): the user picks PasswordPie in
/// Passwords > File > Export All Items to App, the system wakes this app with a one-time token, and the data
/// comes straight from the system. No file is written, so no plain-text copy is left on disk.
extension VaultSession {
    static var credentialExchangeAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// True for the activity type Passwords sends. Must also be listed under NSUserActivityTypes in Info.plist.
    static func isCredentialExchange(_ activityType: String) -> Bool {
        if #available(macOS 26.0, *) { return activityType == ASCredentialExchangeActivity }
        return false
    }

    static func credentialExchangeToken(from userInfo: [AnyHashable: Any]?) -> UUID? {
        guard #available(macOS 26.0, *) else { return nil }
        return userInfo?[ASCredentialImportToken] as? UUID
    }

    /// The token is single use and short lived, and the data is decrypted only on request, so a locked database
    /// asks the user to export again instead of keeping passwords in memory.
    func importFromCredentialExchange(token: UUID) {
        guard #available(macOS 26.0, *) else { return }
        AppDelegate.shared?.showPreferences()
        guard !locked else {
            setImportStatus("Unlock the database first, then choose Export All Items to App in Passwords again.", isError: true)
            return
        }
        setImportStatus("Reading Apple Passwords…", isError: false)
        Task { @MainActor in
            do {
                let data = try await ASCredentialImportManager().importCredentials(token: token)
                finishCredentialExchange(Self.exchangedItems(from: data))
            } catch {
                setImportStatus("Couldn't read the passwords from Apple Passwords. Try Export All Items to App again. (\(error.localizedDescription))", isError: true)
            }
        }
    }

    @available(macOS 26.0, *)
    private func finishCredentialExchange(_ items: [ExchangedItem]) {
        let imported = BrowserImport.entries(fromExchange: items, source: .applePasswords)
        guard !imported.isEmpty else {
            setImportStatus("Apple Passwords sent no passwords. Nothing was changed.", isError: true)
            return
        }
        guard let summary = mergeImported(imported, source: .applePasswords) else {
            setImportStatus("Couldn't save the imported passwords. Nothing was changed.", isError: true)
            return
        }
        setImportStatus(importSummaryText(summary, source: .applePasswords), isError: false)
    }

    /// Logins only: a password, optionally with a one-time code and a note. Cards, passkeys and the rest are left out.
    @available(macOS 26.0, *)
    static func exchangedItems(from data: ASExportedCredentialData) -> [ExchangedItem] {
        data.accounts.flatMap(\.items).map { item in
            var result = ExchangedItem(
                title: item.title,
                urls: item.scope?.urls.map(\.absoluteString) ?? []
            )
            for credential in item.credentials {
                switch credential {
                case .basicAuthentication(let login):
                    result.username = login.userName?.value
                    result.password = login.password?.value
                case .generatedPassword(let generated):
                    if result.password?.isEmpty ?? true { result.password = generated.password }
                case .totp(let code):
                    result.totp = ExchangedItem.TOTPSecret(
                        secret: code.secret,
                        period: Int(code.period),
                        digits: Int(code.digits),
                        algorithm: code.algorithm.rawValue
                    )
                case .note(let note):
                    result.note = note.content.value
                default:
                    break
                }
            }
            return result
        }
    }

    func openPasswordsApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
