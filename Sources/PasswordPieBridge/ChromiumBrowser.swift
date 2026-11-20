import Darwin
import Foundation
import Security

// Which browser started the Chrome host. Every browser built on Chromium runs the same extension and starts the same host,
// so the host and the app do not keep a list of browsers: they check what the browser is. See docs/BROWSER_EXTENSION.md,
// "Other Chromium browsers". The person decides, once per browser, whether it may connect (the app's part).

/// A running browser built on Chromium, as its code signature says.
public struct ChromiumBrowserIdentity: Hashable, Sendable {
    /// The bundle ID from its Info.plist, which the signature covers (`com.citrolabs.ego.lite`): what the app in front
    /// is known by.
    public let bundleID: String
    public let teamID: String
    /// The app bundle.
    public let bundleURL: URL
    /// The browser's name from its bundle ("ego lite").
    public let name: String
    /// Who signed it, from the certificate ("CITRO LABS PTE. LIMITED"). Nil when the certificate says no organization.
    public let signer: String?

    public init(bundleID: String, teamID: String, bundleURL: URL, name: String, signer: String?) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.bundleURL = bundleURL
        self.name = name
        self.signer = signer
    }

    /// Google's signing team: Chrome, Chrome Beta, Dev and Canary. The person is never asked about these.
    public static let googleTeamID = "EQHXZ8M8AV"

    public var isGoogle: Bool { teamID == Self.googleTeamID }
}

public enum ChromiumBrowserCheck {
    /// `BrowserCrApplication` is the application class of every Chromium build for the Mac. Electron apps, which are
    /// also Chromium inside, use their own and are no browser.
    public static let principalClass = "BrowserCrApplication"

    /// True when `info` (an Info.plist) is that of a browser built on Chromium.
    public static func isChromium(info: [String: Any]?) -> Bool {
        info?["NSPrincipalClass"] as? String == principalClass
    }

    /// The process `pid` when it is a browser built on Chromium, validly signed by a certificate Apple issued to a
    /// developer team; otherwise nil. Only for a pid that cannot be reused meanwhile, such as this process's parent.
    public static func identity(ofProcess pid: pid_t) -> ChromiumBrowserIdentity? {
        guard let signature = PeerIdentity.verifiedSignature(ofProcess: pid),
              let bundle = Bundle(url: signature.bundleURL), isChromium(info: bundle.infoDictionary) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? signature.bundleURL.deletingPathExtension().lastPathComponent
        return ChromiumBrowserIdentity(
            bundleID: bundle.bundleIdentifier ?? signature.identifier,
            teamID: signature.teamID,
            bundleURL: signature.bundleURL,
            name: name,
            signer: signature.organization
        )
    }

    /// The pid of the process at the other end of a connected Unix socket, as the kernel recorded it at connect time.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The parent of `pid`. A process whose parent has exited belongs to launchd (1), which is no browser.
    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 1 ? parent : nil
    }

    /// "Developer ID Application: CITRO LABS PTE. LIMITED (JGQLC6YQYJ)" gives "CITRO LABS PTE. LIMITED". A certificate
    /// that is not a developer's (Apple's App Store signing) gives nil.
    public static func organization(fromCertificateSummary summary: String) -> String? {
        let prefixes = ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: "]
        guard let prefix = prefixes.first(where: { summary.hasPrefix($0) }) else { return nil }
        var name = String(summary.dropFirst(prefix.count))
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
