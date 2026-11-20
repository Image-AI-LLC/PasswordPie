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
        /// `saidOrder` of the last time it said it has the focus; 0 if it never did. The profile used last.
        var hadFocusOrder = 0
        var url: String?
        var urlAt: Date?
        var reportedAt: Date?
        /// When it last asked for the panel (`show`): a sign of life that is not a tab report.
        var notedAt: Date?
        /// The bundle ID of the browser it is in: Chrome, or another browser built on Chromium. Nil when not said.
        var app: String?

        /// The latest sign of life, for choosing among extensions that say nothing about focus.
        var lastSign: Date { max(reportedAt ?? .distantPast, notedAt ?? .distantPast) }
    }

    private var links: [BridgePeer: Link] = [:]
    private var order = 0
    /// While PasswordPie's panel is open it has the keyboard, so the browser tells its extension the window lost the
    /// focus. The profile that had it when the panel opened stays the one in front until the panel closes.
    private var holding = false
    /// Per browser app: Chrome and ego lite each have a profile in front of their own.
    private var held: [Scope: BridgePeer] = [:]
    /// The connections that had said nothing about focus when the panel opened. The first thing such a one says may
    /// be that it lost the focus to the panel (the app was just started by the toolbar button), so until the panel
    /// closes it still counts as one that says nothing.
    private var heldSilent: Set<BridgePeer> = []

    /// A browser and, for the browsers built on Chromium, which app: what "the profile in front" is counted within.
    private struct Scope: Hashable, Sendable {
        let browser: BridgeBrowser
        let app: String?
    }

    public init() {}

    /// `app` is the bundle ID of the browser the connection is in, when known (the app learns which browser started
    /// Chrome's host).
    public mutating func opened(_ peer: BridgePeer, app: String? = nil) {
        if links[peer] == nil { links[peer] = Link() }
        if let app { links[peer]?.app = app }
    }

    public mutating func closed(_ peer: BridgePeer) {
        links[peer] = nil
        heldSilent.remove(peer)
        held = held.filter { $0.value != peer }
    }

    /// The extension went away: forget every connection of `browser`.
    public mutating func forget(_ browser: BridgeBrowser) {
        links = links.filter { $0.key.browser != browser }
        heldSilent = heldSilent.filter { $0.browser != browser }
        held = held.filter { $0.key.browser != browser }
    }

    /// The bundle ID of the browser `peer` is in, if it was said.
    public func app(of peer: BridgePeer) -> String? {
        links[peer]?.app
    }

    private func scope(of peer: BridgePeer) -> Scope {
        Scope(browser: peer.browser, app: links[peer]?.app)
    }

    /// `peer` is a connection of `browser`, and of the browser app `app` when one is named.
    private func belongs(_ peer: BridgePeer, _ link: Link, to browser: BridgeBrowser, app: String?) -> Bool {
        peer.browser == browser && (app == nil || link.app == app)
    }

    /// The profile's windows gained or lost the focus.
    public mutating func said(_ peer: BridgePeer, focused: Bool) {
        opened(peer)
        order += 1
        links[peer]?.focused = focused
        links[peer]?.saidOrder = order
        if focused { links[peer]?.hadFocusOrder = order }
        // A click on the browser and the shortcut right after: the word that it has the focus can arrive when the panel
        // is already opening. Losing it never changes what the panel holds: the panel itself takes it.
        if holding, focused { held[scope(of: peer)] = peer }
    }

    /// A `tab` report: the active tab's page (nil when it is not a web page), and the focus if the extension says it.
    public mutating func reported(_ peer: BridgePeer, url: String?, focused: Bool?, now: Date) {
        opened(peer)
        if let focused { said(peer, focused: focused) }
        links[peer]?.url = url
        links[peer]?.urlAt = url == nil ? nil : now
        links[peer]?.reportedAt = now
    }

    /// The connection asked for the panel (the toolbar button or its shortcut): the person is in that profile.
    /// It only orders the connections that say nothing about focus; it is not a tab report.
    public mutating func noted(_ peer: BridgePeer, now: Date) {
        opened(peer)
        links[peer]?.notedAt = now
    }

    /// The panel is opening: keep the profile that has the focus now.
    public mutating func hold() {
        if !holding { heldSilent = Set(links.filter { $0.value.focused == nil }.keys) }
        holding = true
        for scope in Set(links.keys.map(scope(of:))) {
            if let peer = focusedLink(scope.browser, app: scope.app, exact: true) { held[scope] = peer }
        }
    }

    /// The panel closed.
    public mutating func release() {
        holding = false
        held = [:]
        heldSilent = []
    }

    /// `exact` matches a nil `app` only to connections that did not say theirs; otherwise nil matches any.
    private func focusedLink(_ browser: BridgeBrowser, app: String?, exact: Bool = false) -> BridgePeer? {
        links.filter { peer, link in
            let mine = exact ? peer.browser == browser && link.app == app : belongs(peer, link, to: browser, app: app)
            return mine && link.focused == true
        }
        .max { $0.value.saidOrder < $1.value.saidOrder }?.key
    }

    /// The connection of the profile in front, or nil when there is none: nothing connected, or every profile with the
    /// extension says the focus is elsewhere. `app` is the browser app in front, for the browsers built on Chromium:
    /// only its connections count. Nil counts every connection of `browser`.
    public func front(_ browser: BridgeBrowser, app: String? = nil) -> FrontLink? {
        let kept = held.filter { scope, peer in
            scope.browser == browser && (app == nil || scope.app == app) && links[peer] != nil
        }
        if holding, let peer = kept.values.max(by: { (links[$0]?.saidOrder ?? 0) < (links[$1]?.saidOrder ?? 0) }) {
            return FrontLink(peer: peer, certain: true)
        }
        if let peer = focusedLink(browser, app: app) { return FrontLink(peer: peer, certain: true) }
        // Extensions that say nothing about focus: the last to report, as before. One that only connected still counts.
        let silent = links.filter { peer, link in
            belongs(peer, link, to: browser, app: app) && (link.focused == nil || (holding && heldSilent.contains(peer)))
        }
        return Self.latest(silent).map { FrontLink(peer: $0, certain: false) }
    }

    private static func latest(_ links: [BridgePeer: Link]) -> BridgePeer? {
        links.max { lhs, rhs in
            lhs.value.lastSign == rhs.value.lastSign ? lhs.key.link < rhs.key.link : lhs.value.lastSign < rhs.value.lastSign
        }?.key
    }

    /// The connection that stands for `browser` when it is not the app in front (PasswordPie's own window is, or
    /// another app): the one in front if there is one, else the profile that had the focus last, else any connection.
    /// A guess, as "connected" always was: nil only when nothing is connected.
    public func recent(_ browser: BridgeBrowser, app: String? = nil) -> FrontLink? {
        if let front = front(browser, app: app) { return front }
        let mine = links.filter { belongs($0.key, $0.value, to: browser, app: app) }
        let usedLast = mine.filter { $0.value.hadFocusOrder > 0 }.max { $0.value.hadFocusOrder < $1.value.hadFocusOrder }?.key
        return (usedLast ?? Self.latest(mine)).map { FrontLink(peer: $0, certain: false) }
    }

    /// What `peer` last said about the focus, nil if nothing.
    public func focused(_ peer: BridgePeer) -> Bool? {
        links[peer]?.focused
    }

    /// When `peer` last sent a tab report.
    public func reportedAt(_ peer: BridgePeer) -> Date? {
        links[peer]?.reportedAt
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

    /// How many connections `browser` has: for Chrome, the open profiles with the extension; with `app`, those of that
    /// browser app only.
    public func count(_ browser: BridgeBrowser, app: String? = nil) -> Int {
        links.filter { belongs($0.key, $0.value, to: browser, app: app) }.count
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

/// The addresses whose sites the entry may fill: its websites, then its reset link. The page where a password is changed
/// asks for the same account, often on another domain. An `http` reset link is left out on a site the entry has an
/// `https` website for, so it never undoes "No downgrade". See "The reset link's site is the account's site too" in
/// docs/UX.md.
public func entryFillSites(_ entry: VaultEntry) -> [String] {
    let websites = entryWebsites(entry)
    let link = PasswordRotation.resetLink(of: entry)
    guard !link.isEmpty, let site = BrowserSite(url: link) else { return websites }
    if site.scheme == "http", !site.isLoopback,
       websites.contains(where: { website in BrowserSite(url: website).map { $0.scheme == "https" && $0.key == site.key } == true }) {
        return websites
    }
    return websites + [link]
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
    /// Reset Password only: the account's new password, not used yet, for the page's new and confirm boxes. `website` is
    /// then the reset address. Nil for every ordinary fill.
    public let newPassword: String?
    /// The browser app it is for, among the browsers built on Chromium, when no connection is named: only that app's
    /// connections may take it. Nil lets any connection of `browser` take it.
    public let app: String?
    #if PP_DIRECT
    /// An agent's approved login (`passwordpie login`, docs/AGENTS.md "Website login"). The tab that takes it is told to
    /// report how it went, and to send the form when the agent asked. Nil for every fill the owner picked.
    public var agent: AgentFillTicket?
    #endif

    public init?(entryID: UUID, browser: BridgeBrowser, website: String, created: Date, link: Int? = nil, newPassword: String? = nil, app: String? = nil) {
        guard let site = BrowserSite(url: website) else { return nil }
        self.entryID = entryID
        self.browser = browser
        self.website = website
        self.site = site
        self.created = created
        self.link = link
        self.newPassword = newPassword
        self.app = app
    }
}

/// A new password went to a change-password page, and the page may report that its form was sent. Holds no password:
/// only which account to ask the person about.
public struct PendingChange: Equatable, Sendable {
    public let entryID: UUID
    public let browser: BridgeBrowser
    /// The connection that took the fill: only that Chrome profile's report counts.
    public let link: Int
    /// The site of the reset address. The report must come from a page of it.
    public let site: BrowserSite
    /// When the fill was taken.
    public let created: Date
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
    #if PP_DIRECT
    /// The agent login whose fill this code follows: whether it went in is part of the agent's answer.
    var agentToken: UUID?
    #endif
}

#if PP_DIRECT
/// An agent's login, approved by the owner. Holds no credential: the account is the pending fill's.
public struct AgentFillTicket: Equatable, Sendable {
    public let token: UUID
    /// Press the form's own button once the password is in.
    public let submit: Bool

    public init(token: UUID, submit: Bool) {
        self.token = token
        self.submit = submit
    }
}

/// A tab took an agent's fill; its `login-result` is expected from that connection and site.
public struct PendingAgentResult: Equatable, Sendable {
    public let token: UUID
    public let browser: BridgeBrowser
    public let link: Int
    public let site: BrowserSite
    public let created: Date
}

/// What the extension says of an agent's fill (`login-result`).
public enum AgentFillResult: String, Sendable, CaseIterable {
    /// The password went in; the form was not sent.
    case filled
    /// The password went in and the form's button was pressed.
    case submitted
    /// No password field appeared while the fill lasted.
    case noFields = "no-fields"
}
#endif

/// What happened to an agent's fill, for the app to answer the agent. Carries no credential. Only the direct app makes
/// agent fills, so the App Store app never sees one.
public enum AgentFillEvent: Equatable, Sendable {
    /// A tab of the fill's site took it.
    case taken(UUID)
    /// The fill's connection reported a tab in front on another site (nil: not a website): the agent's tab is not in front.
    case otherSite(UUID, site: String?)
    case result(UUID, String)
    /// The code request after the fill: the code went in, or not for want of Premium.
    case code(UUID, filled: Bool)
}

/// At most one pending fill. It is used once, by the first matching tab report, and dropped after 30 seconds.
/// After it fills an account with a two-step code, at most one pending code, used once and dropped after 30 seconds.
/// After it fills a new password into a change-password page, at most one pending change, used once and dropped after
/// 10 minutes.
public struct PendingFillStore: Sendable {
    public static let lifetime: TimeInterval = 30
    /// From the moment the fill was taken: enough to press Sign In and reach the code page.
    public static let codeLifetime: TimeInterval = 30
    /// From the moment the fill was taken: enough to read the site's rules, fix what it refused and press its button.
    public static let changeLifetime: TimeInterval = 600
    public private(set) var pending: PendingFill?
    public private(set) var code: PendingCode?
    public private(set) var change: PendingChange?
    #if PP_DIRECT
    public private(set) var agentResult: PendingAgentResult?
    /// From the moment a tab took an agent's fill: the fill's own 30 s for the fields to appear, and a little more.
    public static let agentResultLifetime: TimeInterval = 35
    #endif

    public init() {}

    /// A new pick replaces the old one, and the code of the one before. A change still waiting for its page stays:
    /// filling another account meanwhile does not answer it.
    public mutating func set(_ fill: PendingFill) {
        pending = fill
        code = nil
    }

    public mutating func clear() {
        pending = nil
        code = nil
        change = nil
        #if PP_DIRECT
        agentResult = nil
        #endif
    }

    #if PP_DIRECT
    /// Drops the pending fill if it is the agent login `token`: it was withdrawn, or its tab is not in front.
    public mutating func withdrawAgentFill(_ token: UUID) {
        if pending?.agent?.token == token { pending = nil }
        if code?.agentToken == token { code = nil }
        if agentResult?.token == token { agentResult = nil }
    }

    mutating func expectAgentResult(_ result: PendingAgentResult) {
        agentResult = result
    }

    /// The agent login waiting for its result, if `browser`'s connection `link` reports from a page of its site in time.
    /// Taking it deletes it.
    mutating func takeAgentResult(browser: BridgeBrowser, link: Int, page: BrowserSite, loginId: String?, now: Date) -> PendingAgentResult? {
        guard let waiting = agentResult, loginId == waiting.token.uuidString else { return nil }
        let age = now.timeIntervalSince(waiting.created)
        guard age <= Self.agentResultLifetime, age >= -1 else {
            agentResult = nil
            return nil
        }
        guard waiting.browser == browser, waiting.link == link, waiting.site.allowsFill(on: page) else { return nil }
        agentResult = nil
        return waiting
    }

    /// The pending fill is an agent's, alive, for `browser`, and this report is from the connection it is for: the one
    /// named, or with none named any that does not say its profile is elsewhere. Its token, else nil.
    func agentFillWatching(browser: BridgeBrowser, link: Int, focused: Bool?, now: Date) -> PendingFill? {
        guard let fill = pending, fill.agent != nil, fill.browser == browser else { return nil }
        let age = now.timeIntervalSince(fill.created)
        guard age <= Self.lifetime, age >= -1 else { return nil }
        if let wanted = fill.link { return wanted == link ? fill : nil }
        return focused == false ? nil : fill
    }
    #endif

    /// A new password was just handed to a page; `change` is what its report will be matched against. A newer one
    /// replaces the one before.
    mutating func expectChange(_ change: PendingChange) {
        self.change = change
    }

    /// The pending change, if `browser` reports from a page of its site in time. Taking it deletes it. An expired one is
    /// deleted unused.
    mutating func takeChange(browser: BridgeBrowser, link: Int = 0, pageURL: String, now: Date) -> PendingChange? {
        guard let change else { return nil }
        let age = now.timeIntervalSince(change.created)
        guard age <= Self.changeLifetime, age >= -1 else {
            self.change = nil
            return nil
        }
        guard change.browser == browser, change.link == link, let page = BrowserSite(url: pageURL), change.site.allowsFill(on: page) else { return nil }
        self.change = nil
        return change
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
    /// `app` is the browser app the reporting connection is in: a fill for one app goes to no other.
    public mutating func take(browser: BridgeBrowser, link: Int = 0, focused: Bool? = nil, app: String? = nil, pageURL: String, now: Date) -> PendingFill? {
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
        } else if let wanted = fill.app, wanted != app {
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
    #if PP_DIRECT
    /// `login-result` only: `filled`, `submitted` or `no-fields`.
    public var result: String?
    /// `login-result` only: the `loginId` of the fill it is about.
    public var loginId: String?
    #endif
}

public struct BridgeFill: Codable, Equatable, Sendable {
    public var origin: String
    public var username: String
    public var password: String
    /// Whole seconds left of the pending fill's 30, so the extension drops its copy when the app would have.
    public var expiresIn: Int
    /// True when the account has a two-step code: the extension watches for a code field and asks with `code`.
    public var otp: Bool?
    /// Reset Password only: the account's new password, for the page's new and confirm boxes. `password` is still the
    /// saved one, for the box that asks for the current password. Left out of every other fill. The extension never
    /// submits the form.
    public var newPassword: String?
    #if PP_DIRECT
    /// An agent's login only: press the form's own button once the password is in.
    public var submit: Bool?
    /// An agent's login only: say how it went with a `login-result` request.
    public var report: Bool?
    /// An agent's login only: which one, echoed in its `login-result`, so word about an older fill is never taken for a
    /// newer one on the same site. A random id: it says nothing about the account.
    public var loginId: String?
    #endif
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

    /// The answer to `show`, the toolbar button: the app heard it. Carries nothing but the request's id.
    public static func show(id: Int?) -> BridgeResponse {
        BridgeResponse(type: "show", id: id)
    }

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

    /// The connection of `browser`'s profile in front, if one speaks for it. `app`: of that browser app only.
    public func front(_ browser: BridgeBrowser, app: String? = nil) -> FrontLink? {
        links.front(browser, app: app)
    }

    /// How many connections `browser` has open: for Chrome, the profiles with the extension. `app`: of that browser app only.
    public func linkCount(_ browser: BridgeBrowser, app: String? = nil) -> Int {
        links.count(browser, app: app)
    }

    /// The connection that stands for `browser` when it is not the app in front: see `BridgeLinks.recent`.
    public func recent(_ browser: BridgeBrowser, app: String? = nil) -> FrontLink? {
        links.recent(browser, app: app)
    }

    /// The web page the profile in front of `browser` reported as its active tab, if it is less than `maxAge` old.
    /// Another profile's tab is never it. `usedLast` is for when the browser is not the app in front: then the page
    /// is that of the profile used last.
    public func currentURL(for browser: BridgeBrowser, app: String? = nil, now: Date, maxAge: TimeInterval = 3600, usedLast: Bool = false) -> String? {
        guard let front = usedLast ? links.recent(browser, app: app) : links.front(browser, app: app) else { return nil }
        return links.url(of: front.peer, now: now, maxAge: maxAge)
    }

    /// A connection opened (Chrome: a profile's extension connected). `app` is the browser app it is in, when known.
    public mutating func opened(_ peer: BridgePeer, app: String? = nil) {
        links.opened(peer, app: app)
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

    /// The page `peer` last reported, and whether it was a web page at all, if it reported since `since`.
    public func report(of peer: BridgePeer, since: Date) -> (url: String?, at: Date)? {
        guard let at = links.reportedAt(peer), at >= since else { return nil }
        return (links.url(of: peer, now: at, maxAge: 0), at)
    }

    #if PP_DIRECT
    /// The agent's fill is for this connection and its tab in front is elsewhere: drop the fill and say so.
    private mutating func agentTabElsewhere(browser: BridgeBrowser, link: Int, focused: Bool?, site: String?, now: Date, agent: ((AgentFillEvent) -> Void)?) {
        guard let fill = pending.agentFillWatching(browser: browser, link: link, focused: focused, now: now), let token = fill.agent?.token else { return }
        pending.withdrawAgentFill(token)
        agent?(.otherSite(token, site: site))
    }
    #endif

    /// Answers one request. `entry` looks up an account by id in the unlocked vault. `codeAllowed` is the Premium check
    /// for a two-step code: whether this Mac has Premium (docs/ACCOUNTS.md, "Who decides"). The extension carries no proof
    /// of its own, so a `code` request says nothing about Premium. `scan` takes a checked QR code with the origin of the page
    /// it was on (nil for none) and the browser; the answer never says what the app did with it. `changed` takes the
    /// account whose change-password page says its form was sent; the answer is the same whether or not one matched.
    public mutating func handle(
        _ request: BridgeRequest,
        from browser: BridgeBrowser,
        link: Int = 0,
        locked: Bool,
        now: Date,
        codeAllowed: () -> Bool = { false },
        scan: ((ScannedOTP, String?, BridgeBrowser) -> Void)? = nil,
        changed: ((UUID) -> Void)? = nil,
        agent: ((AgentFillEvent) -> Void)? = nil,
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
                #if PP_DIRECT
                if !locked { agentTabElsewhere(browser: browser, link: link, focused: links.focused(peer), site: nil, now: now, agent: agent) }
                #endif
                return BridgeResponse(type: "tab", id: request.id)
            }
            links.reported(peer, url: url, focused: request.focused, now: now)
            #if PP_DIRECT
            // An agent's fill is answered only on its own site: a report of another site from its connection says the
            // agent's tab is not in front, and the fill is dropped rather than wait for a tab to be switched.
            if !locked, let fill = pending.agentFillWatching(browser: browser, link: link, focused: links.focused(peer), now: now),
               !fill.site.allowsFill(on: page) {
                agentTabElsewhere(browser: browser, link: link, focused: links.focused(peer), site: page.key, now: now, agent: agent)
            }
            #endif
            guard !locked,
                  let fill = pending.take(browser: browser, link: link, focused: links.focused(peer), app: links.app(of: peer), pageURL: url, now: now),
                  let account = entry(fill.entryID),
                  entryFillSites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }) else {
                var answer = BridgeResponse(type: "tab", id: request.id)
                if !locked, let code = pending.takeAnnouncement(browser: browser, link: link, page: page, now: now) {
                    let left = PendingFillStore.codeLifetime - now.timeIntervalSince(code.created)
                    answer.expectCode = BridgeExpectCode(origin: page.origin, expiresIn: max(1, Int(left.rounded(.up))))
                }
                return answer
            }
            let left = PendingFillStore.lifetime - now.timeIntervalSince(fill.created)
            let hasCode = OneTimeCodes.hasCode(account)
            var code = hasCode ? PendingCode(entryID: account.id, browser: browser, link: link, site: page, created: now) : nil
            #if PP_DIRECT
            code?.agentToken = fill.agent?.token
            #endif
            pending.expectCode(code)
            // A new password that became the saved one since the pick is no longer new: the fill is an ordinary one.
            let newPassword = fill.newPassword.flatMap { $0.isEmpty || $0 == account.password ? nil : $0 }
            if newPassword != nil {
                pending.expectChange(PendingChange(entryID: account.id, browser: browser, link: link, site: fill.site, created: now))
            }
            var credentials = BridgeFill(
                origin: page.origin,
                username: account.username,
                password: account.password,
                expiresIn: max(1, Int(left.rounded(.up))),
                otp: hasCode ? true : nil,
                newPassword: newPassword
            )
            #if PP_DIRECT
            if let ticket = fill.agent {
                credentials.submit = ticket.submit ? true : nil
                credentials.report = true
                credentials.loginId = ticket.token.uuidString
                pending.expectAgentResult(PendingAgentResult(token: ticket.token, browser: browser, link: link, site: page, created: now))
                agent?(.taken(ticket.token))
            }
            #endif
            return BridgeResponse(type: "tab", id: request.id, fill: credentials)
        case "changed":
            // The page that got a new password says its form was sent. Said the same way whatever is waiting, and whether
            // the vault is locked: the extension learns nothing about the account. The app only asks the person.
            let url = request.url ?? ""
            if !locked, let page = BrowserSite(url: url),
               let change = pending.takeChange(browser: browser, link: link, pageURL: url, now: now),
               let account = entry(change.entryID),
               entryFillSites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }) {
                changed?(account.id)
            }
            return BridgeResponse(type: "changed", id: request.id, version: BridgeResponse.protocolVersion)
        case "code":
            let url = request.url ?? ""
            guard !locked, let page = BrowserSite(url: url),
                  let wanted = pending.takeCode(browser: browser, link: link, pageURL: url, now: now),
                  let account = entry(wanted.entryID),
                  entryFillSites(account).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
                  OneTimeCodes.hasCode(account) else {
                return BridgeResponse(type: "code", id: request.id)
            }
            guard codeAllowed(),
                  case .available(let settings) = OneTimeCodes.access(for: account, hasPremium: true) else {
                #if PP_DIRECT
                if let token = wanted.agentToken { agent?(.code(token, filled: false)) }
                #endif
                return BridgeResponse(type: "code", id: request.id, premium: false)
            }
            let period = max(settings.period, 1)
            let elapsed = Int(now.timeIntervalSince1970.rounded(.down)) % period
            let code = BridgeCode(origin: page.origin, code: OneTimeCodes.code(settings: settings, at: now), expiresIn: period - elapsed)
            #if PP_DIRECT
            if let token = wanted.agentToken { agent?(.code(token, filled: true)) }
            #endif
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
        #if PP_DIRECT
        case "login-result":
            // How an agent's fill went. Counted once, from the connection that took it, from a page of its site, while it
            // lasts; the answer is the same whatever was waiting, locked or not, and carries nothing.
            if !locked, let result = request.result.flatMap(AgentFillResult.init(rawValue:)),
               let page = BrowserSite(url: request.url ?? ""),
               let waiting = pending.takeAgentResult(browser: browser, link: link, page: page, loginId: request.loginId, now: now) {
                agent?(.result(waiting.token, result.rawValue))
            }
            return BridgeResponse(type: "login-result", id: request.id)
        #endif
        case "show":
            // The toolbar button. The app opens its panel; the answer only acknowledges it.
            links.noted(peer, now: now)
            return BridgeResponse(type: "show", id: request.id)
        default:
            return .error("bad-request", id: request.id)
        }
    }
}

/// The accounts for the page the browser is on, for the top of the panel.
public enum SiteSuggestions {
    /// Entries with a website or a reset link on the page's site that may fill it. Favorites first, then the most recently
    /// used, then title.
    public static func entries(_ entries: [VaultEntry], pageURL: String, lastUsed: [UUID: Date] = [:]) -> [VaultEntry] {
        guard let page = BrowserSite(url: pageURL) else { return [] }
        let needle = page.key
        let found = entries.filter { entry in
            guard !entry.trashed else { return false }
            return entryFillSites(entry).contains { website in
                // A cheap substring test first: thousands of entries, one parse each only when it could match.
                // An IPv6 key (`::1:3000`) never appears in the text as written (`[::1]:3000`), so those skip the shortcut.
                guard !website.allSatisfy(\.isASCII) || page.host.contains(":") || website.lowercased().contains(needle) else { return false }
                return BrowserSite(url: website)?.allowsFill(on: page) == true
            }
        }
        return ordered(found, lastUsed: lastUsed)
    }

    /// Favorites first, then the most recently used, then title.
    public static func ordered(_ entries: [VaultEntry], lastUsed: [UUID: Date]) -> [VaultEntry] {
        entries.map { (entry: $0, title: $0.title, used: lastUsed[$0.id]) }.sorted { lhs, rhs in
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

    /// The entry's address that may fill `pageURL`: the main website when it can, otherwise the first other website that
    /// can, otherwise its reset link.
    public static func matchingWebsite(of entry: VaultEntry, pageURL: String) -> String? {
        guard let page = BrowserSite(url: pageURL) else { return nil }
        return entryFillSites(entry).first { BrowserSite(url: $0)?.allowsFill(on: page) == true }
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
