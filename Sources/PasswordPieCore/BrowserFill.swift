import Foundation

// Matching and protocol rules for the browser extension. The design is in docs/BROWSER_EXTENSION.md.
// Nothing here logs or stores a URL or a credential.

/// The browsers the extension runs in. Which one is talking comes from the peer's code signature, never from a message.
public enum BridgeBrowser: String, Sendable, CaseIterable {
    case chrome
    case safari
}

/// A web address reduced to what fill decisions need: its scheme, its origin and its site.
public struct BrowserSite: Equatable, Sendable {
    public let scheme: String
    public let host: String
    /// Nil for the scheme's default port.
    public let port: Int?
    /// The registrable domain (eTLD+1), or the exact `host:port` for a host without one, such as `localhost:8000`.
    public let key: String

    /// Accepts full http(s) URLs and bare hosts such as `github.com` or `localhost:3000`, which get https.
    /// Any other scheme, such as `chrome://`, `about:` or `file://`, gives nil.
    public init?(url raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            // `about:blank` and `javascript:…` are schemes; `localhost:8000` is a host and a port.
            if let colon = trimmed.firstIndex(of: ":") {
                let after = trimmed[trimmed.index(after: colon)...].prefix { $0 != "/" }
                guard !after.isEmpty, after.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            }
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }
        self.scheme = scheme
        self.host = host
        self.port = port
        if let domain = PublicSuffix.registrableDomain(ofHost: host) {
            key = domain
        } else {
            key = port.map { "\(host):\($0)" } ?? host
        }
    }

    /// `scheme://host[:port]`, as `location.origin` gives it in the page.
    public var origin: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(shownHost)" + (port.map { ":\($0)" } ?? "")
    }

    var isLoopback: Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
    }

    /// The same site, and no step down from an https account to a plain http page (except on this Mac's own loopback).
    public static func allowsFill(entryWebsite: String, pageURL: String) -> Bool {
        guard let entry = BrowserSite(url: entryWebsite), let page = BrowserSite(url: pageURL) else { return false }
        return entry.allowsFill(on: page)
    }

    public func allowsFill(on page: BrowserSite) -> Bool {
        guard key == page.key else { return false }
        if scheme == "https", page.scheme == "http", !page.isLoopback { return false }
        return true
    }
}

/// Every website of an entry: the main one first, then the numbered `URL (2)` fields.
public func entryWebsites(_ entry: VaultEntry) -> [String] {
    ([entry.url] + EntryMerge.otherWebsites(entry).map(\.value)).filter { !$0.isEmpty }
}

/// One account the user picked to fill, waiting for the extension to ask for it.
public struct PendingFill: Equatable, Sendable {
    public let entryID: UUID
    public let browser: BridgeBrowser
    /// The entry website that will be filled. Its site is what the tab must be on.
    public let website: String
    public let site: BrowserSite
    public let created: Date

    public init?(entryID: UUID, browser: BridgeBrowser, website: String, created: Date) {
        guard let site = BrowserSite(url: website) else { return nil }
        self.entryID = entryID
        self.browser = browser
        self.website = website
        self.site = site
        self.created = created
    }
}

/// At most one pending fill. It is used once, by the first matching tab report, and dropped after 30 seconds.
public struct PendingFillStore: Sendable {
    public static let lifetime: TimeInterval = 30
    public private(set) var pending: PendingFill?

    public init() {}

    /// A new pick replaces the old one.
    public mutating func set(_ fill: PendingFill) {
        pending = fill
    }

    public mutating func clear() {
        pending = nil
    }

    /// The pending fill, if `browser` reports a page it may fill. Taking it deletes it. An expired one is deleted unused.
    public mutating func take(browser: BridgeBrowser, pageURL: String, now: Date) -> PendingFill? {
        guard let fill = pending else { return nil }
        let age = now.timeIntervalSince(fill.created)
        guard age <= Self.lifetime, age >= -1 else {
            pending = nil
            return nil
        }
        guard fill.browser == browser, let page = BrowserSite(url: pageURL), fill.site.allowsFill(on: page) else { return nil }
        pending = nil
        return fill
    }
}

/// A message from the extension. Unknown fields are ignored.
public struct BridgeRequest: Decodable, Sendable {
    public var type: String
    public var id: Int?
    public var url: String?
    public var reason: String?
    public var version: Int?
}

public struct BridgeFill: Codable, Equatable, Sendable {
    public var origin: String
    public var username: String
    public var password: String
}

/// A message to the extension. Fields that are nil are left out.
public struct BridgeResponse: Encodable, Equatable, Sendable {
    public static let protocolVersion = 1

    public var type: String
    public var id: Int?
    public var version: Int?
    public var locked: Bool?
    public var fill: BridgeFill?
    public var code: String?

    public static let poke = BridgeResponse(type: "poke")

    public static func error(_ code: String, id: Int?) -> BridgeResponse {
        BridgeResponse(type: "error", id: id, code: code)
    }

    enum CodingKeys: String, CodingKey {
        case type, id, version, locked, fill, code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(code, forKey: .code)
    }
}

/// The app's side of the protocol: the pending fill and the last URL each browser reported. Memory only.
public struct BridgeState: Sendable {
    public var pending = PendingFillStore()
    private var currentURLs: [BridgeBrowser: (url: String, at: Date)] = [:]

    public init() {}

    /// The last web page `browser` reported as its active tab, if it is less than `maxAge` old.
    public func currentURL(for browser: BridgeBrowser, now: Date, maxAge: TimeInterval = 3600) -> String? {
        guard let current = currentURLs[browser], now.timeIntervalSince(current.at) <= maxAge else { return nil }
        return current.url
    }

    public mutating func forgetURL(for browser: BridgeBrowser) {
        currentURLs[browser] = nil
    }

    /// Answers one request. `entry` looks up an account by id in the unlocked vault.
    public mutating func handle(
        _ request: BridgeRequest,
        from browser: BridgeBrowser,
        locked: Bool,
        now: Date,
        entry: (UUID) -> VaultEntry?
    ) -> BridgeResponse {
        if locked { pending.clear() }
        switch request.type {
        case "hello":
            return BridgeResponse(type: "hello", id: request.id, version: BridgeResponse.protocolVersion, locked: locked)
        case "tab":
            let url = request.url ?? ""
            guard let page = BrowserSite(url: url) else {
                currentURLs[browser] = nil
                return BridgeResponse(type: "tab", id: request.id)
            }
            currentURLs[browser] = (url, now)
            guard !locked,
                  let fill = pending.take(browser: browser, pageURL: url, now: now),
                  let account = entry(fill.entryID),
                  entryWebsites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }) else {
                return BridgeResponse(type: "tab", id: request.id)
            }
            let credentials = BridgeFill(origin: page.origin, username: account.username, password: account.password)
            return BridgeResponse(type: "tab", id: request.id, fill: credentials)
        default:
            return .error("bad-request", id: request.id)
        }
    }
}

/// The accounts for the page the browser is on, for the top of the panel.
public enum SiteSuggestions {
    /// Entries with a website on the page's site that may fill it. Favorites first, then the most recently used, then title.
    public static func entries(_ entries: [VaultEntry], pageURL: String, lastUsed: [UUID: Date] = [:]) -> [VaultEntry] {
        guard let page = BrowserSite(url: pageURL) else { return [] }
        let needle = page.key
        let found = entries.filter { entry in
            guard !entry.trashed else { return false }
            return entryWebsites(entry).contains { website in
                // A cheap substring test first: thousands of entries, one parse each only when it could match.
                guard !website.allSatisfy(\.isASCII) || website.lowercased().contains(needle) else { return false }
                return BrowserSite(url: website)?.allowsFill(on: page) == true
            }
        }
        return found.map { (entry: $0, title: $0.title, used: lastUsed[$0.id]) }.sorted { lhs, rhs in
            if lhs.entry.favorite != rhs.entry.favorite { return lhs.entry.favorite }
            if lhs.used != rhs.used {
                guard let left = lhs.used else { return false }
                guard let right = rhs.used else { return true }
                return left > right
            }
            let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }.map(\.entry)
    }

    /// The entry's website that may fill `pageURL`: the main one when it can, otherwise the first other website that can.
    public static func matchingWebsite(of entry: VaultEntry, pageURL: String) -> String? {
        guard let page = BrowserSite(url: pageURL) else { return nil }
        return entryWebsites(entry).first { BrowserSite(url: $0)?.allowsFill(on: page) == true }
    }
}

extension MenuBuilder {
    /// The group at the top of the panel for the site the browser is on: a header with the site, up to five accounts,
    /// "Show N more items" for the rest, and a separator. Empty when there are no accounts.
    public static func siteRows(site: String, entries: [VaultEntry], sources: [UUID: String] = [:]) -> [MenuRow] {
        guard !entries.isEmpty else { return [] }
        var rows = [MenuRow(kind: .header, title: site)]
        let all = entryRows(entries, sources: sources, alreadySorted: true)
        rows += all.prefix(groupLimit)
        if all.count > groupLimit {
            let rest = Array(all.dropFirst(groupLimit))
            rows.append(MenuRow(kind: .showMore, title: "Show \(rest.count) more items", children: rest))
        }
        rows.append(.separator)
        return rows
    }
}
