import Foundation

/// `passwordpie://activate?token=<JWT>`: how passwordpie.com hands Premium to the App Store app, which has no account and
/// no network code of its own. See "Who has Premium: the App Store channel" in docs/CHANNELS.md.
public enum ActivationLink {
    public static let scheme = "passwordpie"
    public static let host = "activate"

    /// Whether the URL is meant as an activation at all, good or bad.
    public static func matches(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host
    }

    /// The token the link carries. Nil for anything else. Whether it is any good is `EntitlementToken`'s to say.
    public static func token(in url: URL) -> String? {
        guard matches(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == "token" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
