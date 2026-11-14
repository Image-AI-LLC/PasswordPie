import Foundation
import Security

/// What the updater trusts: code requirements for the app that asks, the downloaded disk image and the app inside it.
/// See docs/CHANNELS.md, "Updates".
public struct ReleasePolicy: Sendable {
    /// The installed app must satisfy this, or the updater does nothing: a build made with `make install` is left alone.
    public var installed: String
    public var image: String
    public var app: String
    public var bundleIdentifier: String

    public init(installed: String, image: String, app: String, bundleIdentifier: String) {
        self.installed = installed
        self.image = image
        self.app = app
        self.bundleIdentifier = bundleIdentifier
    }

    public static let teamID = "2S468LUF8V"
    public static let appIdentifier = "com.passwordpie"
    /// Apple's Developer ID Application certificate chain, for our team.
    static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\""

    public static let release = ReleasePolicy(
        installed: "\(developerID) and identifier \"\(appIdentifier)\"",
        image: "\(developerID) and notarized",
        app: "\(developerID) and identifier \"\(appIdentifier)\" and notarized",
        bundleIdentifier: appIdentifier
    )
}

public enum CodeSignature {
    /// True when the code at `url` (an app bundle or a disk image) has a valid signature that satisfies `requirement`.
    /// Everything on disk is read and hashed: resources, every architecture, and with `nested` the code inside a bundle.
    public static func satisfies(_ url: URL, requirement: String, nested: Bool) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if nested { flags |= kSecCSCheckNestedCode }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), parsed) == errSecSuccess
    }
}

/// The two values the updater reads from an app's `Info.plist`. The signature seals that file, so they are read after it is checked.
public struct BundleInfo: Equatable, Sendable {
    public let identifier: String
    public let version: AppVersion

    public init?(app: URL) {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = object["CFBundleIdentifier"] as? String,
              let short = object["CFBundleShortVersionString"] as? String,
              let version = AppVersion(short) else { return nil }
        self.identifier = identifier
        self.version = version
    }
}

extension ReleasePolicy {
    /// The app at `url` is ours, intact, and a higher version than `installed`. Returns its version.
    public func verifyApp(_ url: URL, newerThan installed: AppVersion) throws -> AppVersion {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink == false, values?.isDirectory == true else {
            throw UpdateError("The download does not contain PasswordPie.")
        }
        guard CodeSignature.satisfies(url, requirement: app, nested: true) else {
            throw UpdateError("The download is not signed by PasswordPie's developer.")
        }
        guard let info = BundleInfo(app: url), info.identifier == bundleIdentifier else {
            throw UpdateError("The download does not contain PasswordPie.")
        }
        guard info.version > installed else {
            throw UpdateError("The download is not newer than this PasswordPie.")
        }
        return info.version
    }
}
