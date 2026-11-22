import AppKit
import PasswordPieCore
import Security
import UniformTypeIdentifiers

/// The app a copy or the menu is over, or one picked by hand, as something an account can be linked to.
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

    /// Reads a `.app` bundle chosen on disk (for manual linking or Preferences exclusion). Returns nil for browsers,
    /// PasswordPie itself, or bundles with no identifier.
    static func linkable(bundleURL: URL) -> LinkedApp? {
        guard let bundle = Bundle(url: bundleURL), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary
        let browser = isBrowser(bundleID: bundleID, info: info)
        guard isLinkable(bundleID: bundleID, ownBundleID: Bundle.main.bundleIdentifier, isBrowser: browser) else { return nil }
        let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkedApp(bundleID: bundleID, teamID: signedTeam(url: bundleURL), name: cleanName.isEmpty ? bundleID : cleanName)
    }

    /// Regular desktop apps currently running that can be linked (excluding browsers, PasswordPie, and `excluding`).
    static func runningLinkableApps(excluding excludedBundleIDs: Set<String> = []) -> [LinkedApp] {
        var seen: Set<String> = Set(excludedBundleIDs.map { $0.lowercased() })
        var result: [LinkedApp] = []
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let linked = linkable(running, inFront: true) else { continue }
            let key = linked.bundleID.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(linked)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Opens a modal chooser defaulted to `/Applications` for picking a `.app` bundle.
    static func chooseAppPanel(prompt: String = "Choose") -> LinkedApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return linkable(bundleURL: url)
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
        return signingTeam(of: staticCode)
    }

    /// Same validity check as `signedTeam(pid:)`, for an app bundle chosen on disk.
    nonisolated static func signedTeam(url: URL) -> String? {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { return nil }
        return signingTeam(of: staticCode)
    }

    private nonisolated static func signingTeam(of staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The app's icon for a link in the details, picker, preferences and bubble. An app not on this Mac gets the plain one.
    static func icon(for app: LinkedApp) -> NSImage {
        icon(forBundleID: app.bundleID)
    }

    static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
