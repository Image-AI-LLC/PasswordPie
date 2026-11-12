import Foundation

// Matching and protocol rules for the browser extension. The design is in docs/BROWSER_EXTENSION.md.
// Nothing here logs or stores a URL or a credential.

/// The browsers the extension runs in. Which one is talking comes from the peer's code signature, never from a message.
public enum BridgeBrowser: String, Sendable, CaseIterable {
    case chrome
    case safari
}

/// One end of the bridge: the browser, and which of its connections. Chrome keeps one connection open for each profile
/// that has the extension, numbered by the app's server as they arrive. Safari opens a connection per message, so its
/// link is always 0.
public struct BridgePeer: Hashable, Sendable {
    public let browser: BridgeBrowser
    public let link: Int

    public init(_ browser: BridgeBrowser, link: Int = 0) {
        self.browser = browser
        self.link = link
    }
}

/// The connection that stands for the browser's window in front.
public struct FrontLink: Equatable, Sendable {
    public let peer: BridgePeer
    /// True when its extension said it has the focus. False for an extension that says nothing about focus (the one in
    /// the store before 0.4.0): it is connected, so it may be in front, as it always counted.
    public let certain: Bool

    public init(peer: BridgePeer, certain: Bool) {
        self.peer = peer
        self.certain = certain
    }
}

/// What each connection last said, and which one is the profile in front. Chrome's extensions are per profile, and a
/// profile's extension is told when its windows gain or lose the focus; a profile without the extension says nothing.
/// So the profile in front is the one that says it has the focus, and when none does, the window in front belongs to
/// a profile nobody speaks for. See docs/BROWSER_EXTENSION.md, "Chrome profiles". Memory only.
public struct BridgeLinks: Sendable {
    private struct Link: Sendable {
        /// Nil until the extension says: one that never does counts as before.
        var focused: Bool?
        /// Orders the links that say they have the focus: the latest wins.
        var saidOrder = 0
        var url: String?
        var urlAt: Date?
        var reportedAt: Date?
    }

    private var links: [BridgePeer: Link] = [:]
    private var order = 0
    /// While PasswordPie's panel is open it has the keyboard, so the browser tells its extension the window lost the
    /// focus. The profile that had it when the panel opened stays the one in front until the panel closes.
    private var holding = false
    private var held: [BridgeBrowser: BridgePeer] = [:]

    public init() {}

    public mutating func opened(_ peer: BridgePeer) {
        if links[peer] == nil { links[peer] = Link() }
    }

    public mutating func closed(_ peer: BridgePeer) {
        links[peer] = nil
        if held[peer.browser] == peer { held[peer.browser] = nil }
    }

    /// The extension went away: forget every connection of `browser`.
    public mutating func forget(_ browser: BridgeBrowser) {
        for peer in links.keys where peer.browser == browser { links[peer] = nil }
        held[browser] = nil
    }

    /// The profile's windows gained or lost the focus.
    public mutating func said(_ peer: BridgePeer, focused: Bool) {
        opened(peer)
        order += 1
        links[peer]?.focused = focused
        links[peer]?.saidOrder = order
        // A click on the browser and the shortcut right after: the word that it has the focus can arrive when the panel
        // is already opening. Losing it never changes what the panel holds: the panel itself takes it.
        if holding, focused { held[peer.browser] = peer }
    }

    /// A `tab` report: the active tab's page (nil when it is not a web page), and the focus if the extension says it.
    public mutating func reported(_ peer: BridgePeer, url: String?, focused: Bool?, now: Date) {
        opened(peer)
        if let focused { said(peer, focused: focused) }
        links[peer]?.url = url
        links[peer]?.urlAt = url == nil ? nil : now
        links[peer]?.reportedAt = now
    }

    /// The panel is opening: keep the profile that has the focus now.
    public mutating func hold() {
        holding = true
        for browser in BridgeBrowser.allCases {
            if let peer = focusedLink(browser) { held[browser] = peer }
        }
    }

    /// The panel closed.
    public mutating func release() {
        holding = false
        held = [:]
    }

    private func focusedLink(_ browser: BridgeBrowser) -> BridgePeer? {
        links.filter { $0.key.browser == browser && $0.value.focused == true }
            .max { $0.value.saidOrder < $1.value.saidOrder }?.key
    }

    /// The connection of the profile in front, or nil when there is none: nothing connected, or every profile with the
    /// extension says the focus is elsewhere.
    public func front(_ browser: BridgeBrowser) -> FrontLink? {
        if holding, let peer = held[browser], links[peer] != nil { return FrontLink(peer: peer, certain: true) }
        if let peer = focusedLink(browser) { return FrontLink(peer: peer, certain: true) }
        // Extensions that say nothing about focus: the last to report, as before. One that only connected still counts.
        let silent = links.filter { $0.key.browser == browser && $0.value.focused == nil }
        let latest = silent.max { lhs, rhs in
            let left = lhs.value.reportedAt ?? .distantPast
            let right = rhs.value.reportedAt ?? .distantPast
            return left == right ? lhs.key.link < rhs.key.link : left < right
        }
        return latest.map { FrontLink(peer: $0.key, certain: false) }
    }

    /// What `peer` last said about the focus, nil if nothing.
    public func focused(_ peer: BridgePeer) -> Bool? {
        links[peer]?.focused
    }

    /// The web page `peer` last reported as its active tab, if it is less than `maxAge` old.
    public func url(of peer: BridgePeer, now: Date, maxAge: TimeInterval) -> String? {
        guard let link = links[peer], let url = link.url, let at = link.urlAt, now.timeIntervalSince(at) <= maxAge else { return nil }
        return url
    }

    /// True when a connection of `browser` sent a tab report in the last `within` seconds.
    public func heardFrom(_ browser: BridgeBrowser, now: Date, within: TimeInterval) -> Bool {
        links.contains { peer, link in
            guard peer.browser == browser, let last = link.reportedAt else { return false }
            return now.timeIntervalSince(last) <= within
        }
    }

    /// How many connections `browser` has: for Chrome, the open profiles with the extension.
    public func count(_ browser: BridgeBrowser) -> Int {
        links.keys.filter { $0.browser == browser }.count
    }
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
    /// The connection it is for: the Chrome profile that was in front at the pick. Nil when that is not known (a new tab
    /// in a browser that was not in front, or an extension that says nothing about focus): then any connection of the
    /// browser may take it, except one that says its profile is not in front.
    public let link: Int?

    public init?(entryID: UUID, browser: BridgeBrowser, website: String, created: Date, link: Int? = nil) {
        guard let site = BrowserSite(url: website) else { return nil }
        self.entryID = entryID
        self.browser = browser
        self.website = website
        self.site = site
        self.created = created
        self.link = link
    }
}

/// The two-step code of an account that just filled, waiting for the page to show its code field. Holds no code: it is
/// computed only when the extension asks, and only for Premium.
public struct PendingCode: Equatable, Sendable {
    public let entryID: UUID
    public let browser: BridgeBrowser
    /// The connection that took the fill, or scanned the code: the code goes to that Chrome profile only.
    public var link = 0
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
    mutating func takeAnnouncement(browser: BridgeBrowser, link: Int = 0, page: BrowserSite, now: Date) -> PendingCode? {
        guard let code, code.announce else { return nil }
        let age = now.timeIntervalSince(code.created)
        guard age <= Self.codeLifetime, age >= -1 else {
            self.code = nil
            return nil
        }
        guard code.browser == browser, code.link == link, code.site.allowsFill(on: page) else { return nil }
        self.code?.announce = false
        return code
    }

    /// The pending code, if `browser` asks from a page of its site. Taking it deletes it. An expired one is deleted unused.
    mutating func takeCode(browser: BridgeBrowser, link: Int = 0, pageURL: String, now: Date) -> PendingCode? {
        guard let code else { return nil }
        let age = now.timeIntervalSince(code.created)
        guard age <= Self.codeLifetime, age >= -1 else {
            self.code = nil
            return nil
        }
        guard code.browser == browser, code.link == link, let page = BrowserSite(url: pageURL), code.site.allowsFill(on: page) else { return nil }
        self.code = nil
        return code
    }

    /// The pending fill, if `browser` reports a page it may fill. Taking it deletes it. An expired one is deleted unused.
    /// `link` is the connection reporting and `focused` what it says of its profile's windows: a fill for one connection
    /// goes to that one, and a fill for none never goes to a profile that says it is not in front.
    public mutating func take(browser: BridgeBrowser, link: Int = 0, focused: Bool? = nil, pageURL: String, now: Date) -> PendingFill? {
        guard let fill = pending else { return nil }
        let age = now.timeIntervalSince(fill.created)
        guard age <= Self.lifetime, age >= -1 else {
            pending = nil
            return nil
        }
        if let wanted = fill.link {
            guard wanted == link else { return nil }
        } else if focused == false {
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
    /// `tab` and `focus`: whether a window of the extension's profile has the focus. Missing from an extension that
    /// does not say (before 0.4.0, and Safari's).
    public var focused: Bool?
    /// `scan` only: the text of the QR code the user scanned on the page. Never logged or kept by the bridge.
    public var otpauth: String?
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
    /// `code` answers: false when this Mac has no Premium, so no code goes to the browser.
    public var premium: Bool?
    /// The error code of an `error`.
    public var code: String?
    /// `tab` answers: send this tab's icon with an `icon` request (docs/BROWSER_EXTENSION.md, "icon").
    public var wantIcon: Bool?
    /// `tab` answers: a code was added from a scan for this site; watch for its field (docs/BROWSER_EXTENSION.md, "`scan`").
    public var expectCode: BridgeExpectCode?

    public static let poke = BridgeResponse(type: "poke")

    public static func error(_ code: String, id: Int?) -> BridgeResponse {
        BridgeResponse(type: "error", id: id, code: code)
    }

    enum CodingKeys: String, CodingKey {
        case type, id, version, locked, fill, otp, premium, code, wantIcon, expectCode
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
        try container.encodeIfPresent(expectCode, forKey: .expectCode)
    }
}

/// The app's side of the protocol: the pending fill, and what each connection last reported. Memory only.
public struct BridgeState: Sendable {
    public var pending = PendingFillStore()
    public private(set) var links = BridgeLinks()

    /// The longest QR code text a `scan` may carry. A real `otpauth://` link is a few hundred bytes.
    public static let maxScanLength = 4096

    public init() {}

    /// True when `browser` sent a tab report, of any page, in the last `within` seconds: its extension works.
    public func heardFrom(_ browser: BridgeBrowser, now: Date, within: TimeInterval = 3600) -> Bool {
        links.heardFrom(browser, now: now, within: within)
    }

    /// The connection of `browser`'s profile in front, if one speaks for it.
    public func front(_ browser: BridgeBrowser) -> FrontLink? {
        links.front(browser)
    }

    /// How many connections `browser` has open: for Chrome, the profiles with the extension.
    public func linkCount(_ browser: BridgeBrowser) -> Int {
        links.count(browser)
    }

    /// The web page the profile in front of `browser` reported as its active tab, if it is less than `maxAge` old.
    /// Another profile's tab is never it.
    public func currentURL(for browser: BridgeBrowser, now: Date, maxAge: TimeInterval = 3600) -> String? {
        guard let front = links.front(browser) else { return nil }
        return links.url(of: front.peer, now: now, maxAge: maxAge)
    }

    /// A connection opened (Chrome: a profile's extension connected).
    public mutating func opened(_ peer: BridgePeer) {
        links.opened(peer)
    }

    /// A connection closed: forget what it said.
    public mutating func closed(_ peer: BridgePeer) {
        links.closed(peer)
    }

    /// PasswordPie's panel is opening over the browser, and will take the keyboard from it.
    public mutating func panelOpened() {
        links.hold()
    }

    public mutating func panelClosed() {
        links.release()
    }

    /// The person added a scanned code to `entryID` in the app. The extension that scanned it may fill that code into
    /// the page, as after a fill: the next `tab` report of the site says to watch for the field, and the `code` request
    /// that follows is answered as usual (Premium included). False when `pageURL` is not a web page.
    @discardableResult
    public mutating func expectCode(afterScanOf entryID: UUID, browser: BridgeBrowser, link: Int = 0, pageURL: String, now: Date) -> Bool {
        guard let site = BrowserSite(url: pageURL) else { return false }
        pending.expectCode(PendingCode(entryID: entryID, browser: browser, link: link, site: site, created: now, announce: true))
        return true
    }

    /// The browser's extension went away: forget what it said.
    public mutating func forget(_ browser: BridgeBrowser) {
        links.forget(browser)
    }

    /// Answers one request. `entry` looks up an account by id in the unlocked vault. `codeAllowed` is the Premium check
    /// for a two-step code: whether this Mac has Premium (docs/ACCOUNTS.md, "Who decides"). The extension carries no proof
    /// of its own, so a `code` request says nothing about Premium. `scan` takes a checked QR code with the origin of the page
    /// it was on (nil for none) and the browser; the answer never says what the app did with it.
    public mutating func handle(
        _ request: BridgeRequest,
        from browser: BridgeBrowser,
        link: Int = 0,
        locked: Bool,
        now: Date,
        codeAllowed: () -> Bool = { false },
        scan: ((ScannedOTP, String?, BridgeBrowser) -> Void)? = nil,
        entry: (UUID) -> VaultEntry?
    ) -> BridgeResponse {
        if locked { pending.clear() }
        let peer = BridgePeer(browser, link: link)
        switch request.type {
        case "hello":
            links.opened(peer)
            return BridgeResponse(type: "hello", id: request.id, version: BridgeResponse.protocolVersion, locked: locked)
        case "focus":
            // The profile's windows gained or lost the focus. Says nothing back, locked or not.
            guard let focused = request.focused else { return .error("bad-request", id: request.id) }
            links.said(peer, focused: focused)
            return BridgeResponse(type: "focus", id: request.id)
        case "tab":
            let url = request.url ?? ""
            guard let page = BrowserSite(url: url) else {
                links.reported(peer, url: nil, focused: request.focused, now: now)
                return BridgeResponse(type: "tab", id: request.id)
            }
            links.reported(peer, url: url, focused: request.focused, now: now)
            guard !locked,
                  let fill = pending.take(browser: browser, link: link, focused: links.focused(peer), pageURL: url, now: now),
                  let account = entry(fill.entryID),
                  entryWebsites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }) else {
                var answer = BridgeResponse(type: "tab", id: request.id)
                if !locked, let code = pending.takeAnnouncement(browser: browser, link: link, page: page, now: now) {
                    let left = PendingFillStore.codeLifetime - now.timeIntervalSince(code.created)
                    answer.expectCode = BridgeExpectCode(origin: page.origin, expiresIn: max(1, Int(left.rounded(.up))))
                }
                return answer
            }
            let left = PendingFillStore.lifetime - now.timeIntervalSince(fill.created)
            let hasCode = OneTimeCodes.hasCode(account)
            pending.expectCode(hasCode ? PendingCode(entryID: account.id, browser: browser, link: link, site: page, created: now) : nil)
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
                  let wanted = pending.takeCode(browser: browser, link: link, pageURL: url, now: now),
                  let account = entry(wanted.entryID),
                  entryWebsites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
                  OneTimeCodes.hasCode(account) else {
                return BridgeResponse(type: "code", id: request.id)
            }
            guard codeAllowed(),
                  case .available(let settings) = OneTimeCodes.access(for: account, hasPremium: true) else {
                return BridgeResponse(type: "code", id: request.id, premium: false)
            }
            let period = max(settings.period, 1)
            let elapsed = Int(now.timeIntervalSince1970.rounded(.down)) % period
            let code = BridgeCode(origin: page.origin, code: OneTimeCodes.code(settings: settings, at: now), expiresIn: period - elapsed)
            return BridgeResponse(type: "code", id: request.id, otp: code)
        case "upgrade":
            // "Upgrade" in the page's note about Premium. The app opens its Premium window; the answer only acknowledges
            // it, the same whatever this Mac has.
            return BridgeResponse(type: "upgrade", id: request.id)
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
