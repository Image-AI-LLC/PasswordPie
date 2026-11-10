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
    /// Lowercased, without a trailing dot.
    public let host: String
    /// The host as the page's `location.origin` shows it, trailing dot included.
    private let originHost: String
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
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
            candidate = trimmed
        } else {
            // `about:blank` and `javascript:…` are schemes; `localhost:8000` is a host and a port. Only the part before the
            // path counts, so `example.com/a:b` is a host.
            let authority = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            if let colon = authority.firstIndex(of: ":") {
                let port = authority[authority.index(after: colon)...]
                guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            }
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased() else { return nil }
        var host = rawHost
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }
        self.scheme = scheme
        self.host = host
        originHost = rawHost
        self.port = port
        if let domain = PublicSuffix.registrableDomain(ofHost: host) {
            key = domain
        } else {
            key = port.map { "\(host):\($0)" } ?? host
        }
    }

    /// `scheme://host[:port]`, as `location.origin` gives it in the page.
    public var origin: String {
        let shownHost = originHost.contains(":") ? "[\(originHost)]" : originHost
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

/// The two-step code of an account that just filled, waiting for the page to show its code field. Holds no code: it is
/// computed only when the extension asks, and only for Premium.
public struct PendingCode: Equatable, Sendable {
    public let entryID: UUID
    public let browser: BridgeBrowser
    /// The page that took the fill. A code goes only to a page of the same site.
    public let site: BrowserSite
    /// When the fill was taken, or when a scanned code was added.
    public let created: Date
    /// A code just added from a scan: the next `tab` report of its site says to watch for the code field, since no fill
    /// started that watch. Said once.
    var announce = false
}

/// At most one pending fill. It is used once, by the first matching tab report, and dropped after 30 seconds.
/// After it fills an account with a two-step code, at most one pending code, used once and dropped after 30 seconds.
public struct PendingFillStore: Sendable {
    public static let lifetime: TimeInterval = 30
    /// From the moment the fill was taken: enough to press Sign In and reach the code page.
    public static let codeLifetime: TimeInterval = 30
    public private(set) var pending: PendingFill?
    public private(set) var code: PendingCode?

    public init() {}

    /// A new pick replaces the old one, and the code of the one before.
    public mutating func set(_ fill: PendingFill) {
        pending = fill
        code = nil
    }

    public mutating func clear() {
        pending = nil
        code = nil
    }

    /// The pick filled; `code` is its account's code to wait for, or nil when it has none.
    mutating func expectCode(_ code: PendingCode?) {
        self.code = code
    }

    /// The pending code to announce in a `tab` answer, once, if `browser` reports a page of its site in time.
    mutating func takeAnnouncement(browser: BridgeBrowser, page: BrowserSite, now: Date) -> PendingCode? {
        guard let code, code.announce else { return nil }
        let age = now.timeIntervalSince(code.created)
        guard age <= Self.codeLifetime, age >= -1 else {
            self.code = nil
            return nil
        }
        guard code.browser == browser, code.site.allowsFill(on: page) else { return nil }
        self.code?.announce = false
        return code
    }

    /// The pending code, if `browser` asks from a page of its site. Taking it deletes it. An expired one is deleted unused.
    mutating func takeCode(browser: BridgeBrowser, pageURL: String, now: Date) -> PendingCode? {
        guard let code else { return nil }
        let age = now.timeIntervalSince(code.created)
        guard age <= Self.codeLifetime, age >= -1 else {
            self.code = nil
            return nil
        }
        guard code.browser == browser, let page = BrowserSite(url: pageURL), code.site.allowsFill(on: page) else { return nil }
        self.code = nil
        return code
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
    /// `code` only: the entitlement token from passwordpie.com, checked by the direct app. Never logged or stored.
    public var entitlement: String?
    /// `premium` only: the extension's pass from passwordpie.com, for the direct app to keep in the keychain. Never logged.
    public var pass: String?
    /// `premium` only: the extension takes back the pass it delivered, and why (`PassDropReason`).
    public var drop: String?
    /// `scan` only: the text of the QR code the user scanned on the page. Never logged or kept by the bridge.
    public var otpauth: String?

    /// What a `premium` request asks, or nil when it is malformed: exactly one of a non-empty `pass` or a known `drop`.
    public var passRelay: PassRelay? {
        switch (pass, drop) {
        case (let pass?, nil) where !pass.isEmpty: return .pass(pass)
        case (nil, let drop?): return PassDropReason(rawValue: drop).map { .drop($0) }
        default: return nil
        }
    }
}

public struct BridgeFill: Codable, Equatable, Sendable {
    public var origin: String
    public var username: String
    public var password: String
    /// Whole seconds left of the pending fill's 30, so the extension drops its copy when the app would have.
    public var expiresIn: Int
    /// True when the account has a two-step code: the extension watches for a code field and asks with `code`.
    public var otp: Bool?
}

/// The answer to `code`: the current two-step code for the page.
public struct BridgeCode: Codable, Equatable, Sendable {
    public var origin: String
    public var code: String
    /// Whole seconds left in the code's time step.
    public var expiresIn: Int
}

/// A `tab` answer's word that a code was just added for this site from a scan: watch the page for its code field.
/// Carries no code and no secret; the code still comes only from a `code` request.
public struct BridgeExpectCode: Codable, Equatable, Sendable {
    public var origin: String
    /// Whole seconds left of the pending code's 30.
    public var expiresIn: Int
}

/// A message to the extension. Fields that are nil are left out.
public struct BridgeResponse: Encodable, Equatable, Sendable {
    public static let protocolVersion = 1

    public var type: String
    public var id: Int?
    public var version: Int?
    public var locked: Bool?
    public var fill: BridgeFill?
    /// `code` answers: the two-step code.
    public var otp: BridgeCode?
    /// `code` answers: false when this user does not have Premium for codes in the browser.
    public var premium: Bool?
    /// The error code of an `error`.
    public var code: String?
    /// `tab` answers: send this tab's icon with an `icon` request (docs/BROWSER_EXTENSION.md, "icon").
    public var wantIcon: Bool?
    /// `premium` answers to a pass: whether the app kept it. Never the pass itself.
    public var accepted: Bool?
    /// `tab` answers: a code was added from a scan for this site; watch for its field (docs/BROWSER_EXTENSION.md, "`scan`").
    public var expectCode: BridgeExpectCode?

    public static let poke = BridgeResponse(type: "poke")

    public static func error(_ code: String, id: Int?) -> BridgeResponse {
        BridgeResponse(type: "error", id: id, code: code)
    }

    enum CodingKeys: String, CodingKey {
        case type, id, version, locked, fill, otp, premium, code, wantIcon, accepted, expectCode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(otp, forKey: .otp)
        try container.encodeIfPresent(premium, forKey: .premium)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(wantIcon, forKey: .wantIcon)
        try container.encodeIfPresent(accepted, forKey: .accepted)
        try container.encodeIfPresent(expectCode, forKey: .expectCode)
    }
}

/// The app's side of the protocol: the pending fill and the last URL each browser reported. Memory only.
public struct BridgeState: Sendable {
    public var pending = PendingFillStore()
    private var currentURLs: [BridgeBrowser: (url: String, at: Date)] = [:]
    private var lastReports: [BridgeBrowser: Date] = [:]

    /// The longest QR code text a `scan` may carry. A real `otpauth://` link is a few hundred bytes.
    public static let maxScanLength = 4096

    public init() {}

    /// True when `browser` sent a tab report, of any page, in the last `within` seconds: its extension works.
    public func heardFrom(_ browser: BridgeBrowser, now: Date, within: TimeInterval = 3600) -> Bool {
        guard let last = lastReports[browser] else { return false }
        return now.timeIntervalSince(last) <= within
    }

    /// The last web page `browser` reported as its active tab, if it is less than `maxAge` old.
    public func currentURL(for browser: BridgeBrowser, now: Date, maxAge: TimeInterval = 3600) -> String? {
        guard let current = currentURLs[browser], now.timeIntervalSince(current.at) <= maxAge else { return nil }
        return current.url
    }

    /// The person added a scanned code to `entryID` in the app. The extension that scanned it may fill that code into
    /// the page, as after a fill: the next `tab` report of the site says to watch for the field, and the `code` request
    /// that follows is answered as usual (Premium included). False when `pageURL` is not a web page.
    @discardableResult
    public mutating func expectCode(afterScanOf entryID: UUID, browser: BridgeBrowser, pageURL: String, now: Date) -> Bool {
        guard let site = BrowserSite(url: pageURL) else { return false }
        pending.expectCode(PendingCode(entryID: entryID, browser: browser, site: site, created: now, announce: true))
        return true
    }

    /// The browser's extension went away: forget what it said.
    public mutating func forget(_ browser: BridgeBrowser) {
        currentURLs[browser] = nil
        lastReports[browser] = nil
    }

    /// Answers one request. `entry` looks up an account by id in the unlocked vault. `codeAllowed` is the Premium check
    /// for a two-step code, given the `code` request's entitlement token (docs/ACCOUNTS.md, "Who decides"). `premium` takes
    /// a `premium` request and says whether a pass was kept; nil in a build that takes no pass (the App Store app), which
    /// then answers as an app that does not know the message. `scan` takes a checked QR code with the origin of the page
    /// it was on (nil for none) and the browser; the answer never says what the app did with it.
    public mutating func handle(
        _ request: BridgeRequest,
        from browser: BridgeBrowser,
        locked: Bool,
        now: Date,
        codeAllowed: (String?) -> Bool = { _ in false },
        premium: ((PassRelay) -> Bool)? = nil,
        scan: ((ScannedOTP, String?, BridgeBrowser) -> Void)? = nil,
        entry: (UUID) -> VaultEntry?
    ) -> BridgeResponse {
        if locked { pending.clear() }
        switch request.type {
        case "hello":
            return BridgeResponse(type: "hello", id: request.id, version: BridgeResponse.protocolVersion, locked: locked)
        case "tab":
            lastReports[browser] = now
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
                var answer = BridgeResponse(type: "tab", id: request.id)
                if !locked, let code = pending.takeAnnouncement(browser: browser, page: page, now: now) {
                    let left = PendingFillStore.codeLifetime - now.timeIntervalSince(code.created)
                    answer.expectCode = BridgeExpectCode(origin: page.origin, expiresIn: max(1, Int(left.rounded(.up))))
                }
                return answer
            }
            let left = PendingFillStore.lifetime - now.timeIntervalSince(fill.created)
            let hasCode = OneTimeCodes.hasCode(account)
            pending.expectCode(hasCode ? PendingCode(entryID: account.id, browser: browser, site: page, created: now) : nil)
            let credentials = BridgeFill(
                origin: page.origin,
                username: account.username,
                password: account.password,
                expiresIn: max(1, Int(left.rounded(.up))),
                otp: hasCode ? true : nil
            )
            return BridgeResponse(type: "tab", id: request.id, fill: credentials)
        case "code":
            let url = request.url ?? ""
            guard !locked, let page = BrowserSite(url: url),
                  let wanted = pending.takeCode(browser: browser, pageURL: url, now: now),
                  let account = entry(wanted.entryID),
                  entryWebsites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
                  OneTimeCodes.hasCode(account) else {
                return BridgeResponse(type: "code", id: request.id)
            }
            guard codeAllowed(request.entitlement),
                  case .available(let settings) = OneTimeCodes.access(for: account, hasPremium: true) else {
                return BridgeResponse(type: "code", id: request.id, premium: false)
            }
            let period = max(settings.period, 1)
            let elapsed = Int(now.timeIntervalSince1970.rounded(.down)) % period
            let code = BridgeCode(origin: page.origin, code: OneTimeCodes.code(settings: settings, at: now), expiresIn: period - elapsed)
            return BridgeResponse(type: "code", id: request.id, otp: code)
        case "premium":
            // Not tied to the database: a pass is taken while locked too. The answer never carries the pass.
            guard let premium, let relay = request.passRelay else { return .error("bad-request", id: request.id) }
            let kept = premium(relay)
            guard case .pass = relay else { return BridgeResponse(type: "premium", id: request.id) }
            return BridgeResponse(type: "premium", id: request.id, accepted: kept)
        case "scan":
            // Said the same way whatever the vault holds, and whether it is locked: the extension learns nothing about it.
            guard let scan, let raw = request.otpauth, !raw.isEmpty, raw.utf8.count <= Self.maxScanLength else {
                return .error("bad-request", id: request.id)
            }
            switch OTPAuthImport.parse(raw) {
            case .success(let scanned):
                scan(scanned, request.url.flatMap { BrowserSite(url: $0) }?.origin, browser)
                return BridgeResponse(type: "scan", id: request.id)
            case .failure:
                return .error("bad-otp", id: request.id)
            }
        case "show":
            // The toolbar button. The app opens its panel; the answer only acknowledges it.
            return BridgeResponse(type: "show", id: request.id)
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
                // An IPv6 key (`::1:3000`) never appears in the text as written (`[::1]:3000`), so those skip the shortcut.
                guard !website.allSatisfy(\.isASCII) || page.host.contains(":") || website.lowercased().contains(needle) else { return false }
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
