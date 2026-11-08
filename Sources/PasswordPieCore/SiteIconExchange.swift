import Foundation
import ImageIO
import UniformTypeIdentifiers

// Site icons without the network: bundled for the top sites, otherwise handed over by the browser extension when the app
// asks for one. The protocol is `wantIcon` and `icon` in docs/BROWSER_EXTENSION.md; what the user sees is in docs/UX.md.

/// Which hosts have icons, and which icon bytes the app takes from the extension.
public enum SiteIconRules {
    /// The largest icon the extension may send, in bytes of PNG and in pixels a side.
    public static let maxBytes = 65_536
    public static let maxPixels = 128

    /// A public DNS name. Local and private names keep the letter tile: they have no bundled icon, and a name that is not
    /// a DNS name never becomes a file name.
    public static func isPublicSite(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isDNSLabel) else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        // IANA special-use names (registry of 2026-05-22) and the private suffixes used on local networks.
        // One `arpa` entry covers every special-use name under it, including reverse DNS.
        let reserved = [
            "alt", "arpa", "example", "example.com", "example.net", "example.org",
            "invalid", "local", "localhost", "localdomain", "onion", "test",
            "corp", "home", "internal", "intranet", "lan",
        ]
        return !reserved.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isDNSLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    /// Where an icon for `host` is looked for, most specific first: the host itself, then its registrable domain, so
    /// `gist.github.com` falls back to `github.com`. Empty for a host that is not a public site.
    public static func lookupHosts(forHost raw: String?) -> [String] {
        guard let raw else { return [] }
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard isPublicSite(host) else { return [] }
        var hosts = [host]
        if let site = PublicSuffix.registrableDomain(ofHost: host), site != host, isPublicSite(site) { hosts.append(site) }
        return hosts
    }

    /// A PNG of at most `maxBytes` and `maxPixels` a side that decodes. Anything else, including another image format, is
    /// refused: the app stores these bytes and draws them.
    public static func isAcceptableIcon(_ data: Data) -> Bool {
        guard (1...maxBytes).contains(data.count),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...maxPixels).contains(width), (1...maxPixels).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == width, image.height == height else { return false }
        // ImageIO returns a partial image for a truncated file; decoding the pixels proves the data is all there.
        guard let provider = image.dataProvider, provider.data != nil else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
}

/// An `icon` request from the extension. Unknown fields are ignored.
public struct BridgeIconRequest: Decodable, Sendable {
    public var id: Int?
    /// `scheme://host[:port]` of the tab the icon belongs to.
    public var origin: String?
    /// Base64 of the PNG.
    public var png: String?
}

/// An icon the app may keep: the PNG, and the hosts to store it under.
public struct SiteIconDelivery: Equatable, Sendable {
    public let png: Data
    /// The tab's host (one `www` removed), then its registrable domain when that differs. The app keeps the icon under the
    /// host, and under the registrable domain unless that has an icon already, so every account on the site finds it.
    public let hosts: [String]

    public init(png: Data, hosts: [String]) {
        self.png = png
        self.hosts = hosts
    }
}

/// The icons the app asked for and has not had yet. Memory only, like the rest of the bridge state.
public struct SiteIconLedger: Sendable {
    /// How long after asking an `icon` request is taken.
    public static let answerWindow: TimeInterval = 60
    /// A site that was asked about is not asked about again for this long, whatever came of it.
    public static let askAgainAfter: TimeInterval = 600

    public enum Rejection: Error, Equatable {
        /// The app did not ask this browser for an icon of this origin, or asked too long ago.
        case notAsked
        /// Not base64, not a PNG, or too large.
        case notAnIcon
    }

    private var asked: [BridgeBrowser: [String: Date]] = [:]
    private var lastAsked: [String: Date] = [:]

    public init() {}

    /// For a `tab` report: true when the tab's site has an account whose icon is missing. The extension then sends the
    /// tab's icon. `hasIcon` says whether a host already resolves to an icon (bundled or cached).
    public mutating func shouldAsk(
        browser: BridgeBrowser,
        pageURL: String,
        entries: [VaultEntry],
        hasIcon: (String) -> Bool,
        now: Date
    ) -> Bool {
        guard let page = BrowserSite(url: pageURL), SiteIconRules.isPublicSite(page.host) else { return false }
        if let last = lastAsked[page.key], now.timeIntervalSince(last) < Self.askAgainAfter, now >= last { return false }
        let missing = SiteSuggestions.entries(entries, pageURL: pageURL).contains { entry in
            guard let website = SiteSuggestions.matchingWebsite(of: entry, pageURL: pageURL),
                  let host = websiteHost(forWebsite: website) else { return false }
            return !SiteIconRules.lookupHosts(forHost: host).isEmpty && !hasIcon(host)
        }
        guard missing else { return false }
        prune(now: now)
        lastAsked[page.key] = now
        asked[browser, default: [:]][page.origin] = now
        return true
    }

    /// For an `icon` request: the icon, if the app asked `browser` for this exact origin within the answer window and it is
    /// an acceptable PNG. An ask is used by the first answer, accepted or not.
    public mutating func accept(browser: BridgeBrowser, origin: String, png: String, now: Date) -> Result<SiteIconDelivery, Rejection> {
        guard let at = asked[browser]?.removeValue(forKey: origin),
              now.timeIntervalSince(at) <= Self.answerWindow, now >= at.addingTimeInterval(-1),
              let page = BrowserSite(url: origin), page.origin == origin else { return .failure(.notAsked) }
        guard png.count <= (SiteIconRules.maxBytes + 2) / 3 * 4 + 4,
              let data = Data(base64Encoded: png),
              SiteIconRules.isAcceptableIcon(data) else { return .failure(.notAnIcon) }
        let host = websiteHost(forWebsite: page.origin) ?? page.host
        let hosts = SiteIconRules.lookupHosts(forHost: host)
        guard !hosts.isEmpty else { return .failure(.notAsked) }
        return .success(SiteIconDelivery(png: data, hosts: hosts))
    }

    /// Locking forgets every ask.
    public mutating func clear() {
        asked = [:]
        lastAsked = [:]
    }

    private mutating func prune(now: Date) {
        for browser in asked.keys {
            asked[browser] = asked[browser]?.filter { now.timeIntervalSince($0.value) <= Self.answerWindow }
        }
        lastAsked = lastAsked.filter { now.timeIntervalSince($0.value) < Self.askAgainAfter }
    }
}

extension BridgeResponse {
    /// The answer to an `icon` request the app kept.
    public static func iconStored(id: Int?) -> BridgeResponse {
        BridgeResponse(type: "icon", id: id)
    }
}
