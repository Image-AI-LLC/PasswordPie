import AppKit
import PasswordPieCore
import Security

/// The app a copy or the menu is over, as something an account can be linked to.
/// See "An account remembers its app" in docs/UX.md.
@MainActor
enum AppIdentity {
    /// Nil for what is never linked: an app that was not really in front (a PasswordPie window was), PasswordPie
    /// itself, an app with no identifier, and every web browser. In a browser the site says which account, not the app.
    static func linkable(_ app: NSRunningApplication?, inFront: Bool) -> LinkedApp? {
        guard inFront, let app, let bundleID = app.bundleIdentifier else { return nil }
        let browser = isBrowser(bundleID: bundleID, info: app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary })
        guard isLinkable(bundleID: bundleID, ownBundleID: Bundle.main.bundleIdentifier, isBrowser: browser) else { return nil }
        return LinkedApp(bundleID: bundleID, teamID: teamID(of: app), name: app.localizedName ?? bundleID)
    }

    nonisolated static func isLinkable(bundleID: String, ownBundleID: String?, isBrowser: Bool) -> Bool {
        if isBrowser { return false }
        if let ownBundleID, bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame { return false }
        return true
    }

    /// A browser is an app that says it opens web addresses, whether or not PasswordPie has an extension for it.
    nonisolated static func isBrowser(bundleID: String, info: [String: Any]?) -> Bool {
        if BrowserBridge.browser(forBundleID: bundleID) != nil { return true }
        guard let types = info?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { type in
            (type["CFBundleURLSchemes"] as? [String] ?? []).contains { $0.lowercased() == "https" || $0.lowercased() == "http" }
        }
    }

    private static var teams: [pid_t: (launched: Date?, team: String?)] = [:]

    /// Who signed the running app. Nil when it has no team (Apple's own apps, an unsigned build), when its signature does
    /// not hold, or when macOS does not let PasswordPie look. Asked once per launch of the app.
    static func teamID(of app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        if let known = teams[pid], known.launched == app.launchDate { return known.team }
        let team = signedTeam(pid: pid)
        if teams.count > 64 { teams.removeAll() }
        teams[pid] = (app.launchDate, team)
        return team
    }

    /// Only a signature that holds and leads back to Apple counts. An app signed by nobody (ad hoc) could write any
    /// team into its signature, so it has none here.
    nonisolated static func signedTeam(pid: pid_t) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The app's icon for a link in the details and on the bubble. An app that is not on this Mac gets the plain one.
    static func icon(for app: LinkedApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
