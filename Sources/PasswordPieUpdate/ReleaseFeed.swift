import Foundation

/// The newest release on GitHub, as far as the updater needs it.
public struct Release: Equatable, Sendable {
    public let version: AppVersion
    /// `PasswordPie-<version>.dmg`.
    public let imageName: String
    public let imageURL: URL
    public let imageBytes: Int
}

/// Why a check or an install stopped. `message` is the one line Preferences shows.
public struct UpdateError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// GitHub's "latest release" answer for the PasswordPie repository. See docs/CHANNELS.md, "Updates".
public enum ReleaseFeed {
    public static let repository = "Image-AI-LLC/PasswordPie"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Opened in the browser when this copy cannot replace itself.
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    /// The app is a few megabytes. A far larger file is not it.
    public static let maxImageBytes = 512 * 1024 * 1024

    /// Only the tag and the asset list are read. The download address is built here from the tag, never taken from the answer.
    public static func parse(_ data: Data) throws -> Release {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw UpdateError("GitHub's answer was not a release.")
        }
        guard object["draft"] as? Bool != true, object["prerelease"] as? Bool != true else {
            throw UpdateError("The latest release is not final.")
        }
        guard let version = AppVersion(tag: tag) else {
            throw UpdateError("The latest release has no version PasswordPie can read.")
        }
        let name = "PasswordPie-\(version).dmg"
        let assets = object["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == name }) else {
            throw UpdateError("PasswordPie \(version) has no download yet.")
        }
        guard let bytes = asset["size"] as? Int, (1...maxImageBytes).contains(bytes) else {
            throw UpdateError("The download for PasswordPie \(version) has an unexpected size.")
        }
        guard let url = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)") else {
            throw UpdateError("The latest release has no version PasswordPie can read.")
        }
        return Release(version: version, imageName: name, imageURL: url, imageBytes: bytes)
    }
}
