import AppKit
import Combine
import PasswordPieBridge
import PasswordPieCore
import SafariServices

/// How a fill reaches the browser.
enum BrowserFillPlan: Equatable {
    /// No extension path: type the keystrokes, as before.
    case keystrokes
    /// The browser is on the account's site: fill this tab.
    case thisTab(website: String)
    /// Open the account's website in a new tab of that browser and fill it when it loads.
    case newTab(website: String, url: URL)
}

/// Return and ⇧Return fill this tab when it is the account's site, otherwise a new tab; ⌥Return always opens a new tab.
/// `pageURL` is the browser's current tab, or nil when it is not known.
func browserFillPlan(entry: VaultEntry, mode: FillMode, preferredWebsite: String?, pageURL: String?) -> BrowserFillPlan {
    guard mode != .open else { return .keystrokes }
    if mode != .openAndFill, let pageURL {
        if let preferredWebsite, BrowserSite.allowsFill(entryWebsite: preferredWebsite, pageURL: pageURL) {
            return .thisTab(website: preferredWebsite)
        }
        if let website = SiteSuggestions.matchingWebsite(of: entry, pageURL: pageURL) {
            return .thisTab(website: website)
        }
    }
    // A new tab opens a website of the account, never its reset link.
    let websites = entryWebsites(entry).filter { webURL($0) != nil }
    guard let website = [preferredWebsite, entry.url].compactMap({ $0 }).first(where: { webURL($0) != nil }) ?? websites.first,
          let url = webURL(website) else { return .keystrokes }
    return .newTab(website: website, url: url)
}

/// The page the browser is on. The extension's report is current while it can see the tab, but a tab it has no access to
/// (Safari asks per site) sends nothing, and its last report goes stale. The address read from the window then wins.
func resolvedPageURL(extensionURL: String?, windowURL: String?) -> String? {
    guard let extensionURL else { return windowURL }
    guard let windowURL, let reported = BrowserSite(url: extensionURL), let shown = BrowserSite(url: windowURL) else { return extensionURL }
    return reported.key == shown.key ? extensionURL : windowURL
}

/// The line above the search field when the front browser's extension is missing.
enum ExtensionBanner: Equatable {
    case addChrome
    case enableSafari
    /// Over a browser built on Chromium the person said no to: opens the question again. `name` is the browser's.
    case allowBrowser(name: String)

    var title: String {
        switch self {
        case .addChrome: "Add Chrome Extension…"
        case .enableSafari: "Enable Safari Extension…"
        case .allowBrowser(let name): "Allow “\(name)” to Fill Passwords…"
        }
    }

    var browserBundleID: String {
        switch self {
        case .addChrome, .allowBrowser: BrowserBridge.chromeBundleID
        case .enableSafari: BrowserBridge.safariBundleID
        }
    }
}

/// Which banner the panel shows for the app that was in front, if any. `chromeInFront` is whether an extension speaks
/// for the Chrome profile in front: one connected in another profile does not count. Other browsers built on Chromium
/// get Chrome's line, except one the person did not allow: `deniedName` is its name, and its line asks again.
func extensionBanner(frontBundleID: String?, chromeInFront: Bool, safariEnabled: Bool, chromeSupported: Bool, deniedName: String? = nil) -> ExtensionBanner? {
    switch BrowserBridge.browser(forBundleID: frontBundleID) {
    case .chrome:
        guard chromeSupported else { return nil }
        if let deniedName { return .allowBrowser(name: deniedName) }
        return chromeInFront ? nil : .addChrome
    case .safari: return safariEnabled ? nil : .enableSafari
    case nil: return nil
    }
}

/// What the bridge needs to know of the app that was in front when the panel opened.
struct FrontApp: Equatable {
    let bundleID: String?
    let bundleURL: URL?
    /// False when it was not really in front: PasswordPie's own window was (Preferences), and this is
    /// the app the panel will go back to. Its browser then has no profile in front, and the one used last stands for it.
    let inFront: Bool

    init(bundleID: String?, bundleURL: URL?, inFront: Bool = true) {
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.inFront = inFront
    }

    init?(_ app: NSRunningApplication?, inFront: Bool = true) {
        guard let app else { return nil }
        self.init(bundleID: app.bundleIdentifier, bundleURL: app.bundleURL, inFront: inFront)
    }
}

/// Where a fill through Chrome's extension goes.
enum ChromeFillRoute: Equatable {
    /// No extension speaks for the profile that would get it: type the keystrokes.
    case keystrokes
    /// The profile in front, by its connection. No other profile may take it.
    case link(Int)
    /// Not known which profile: any connection may take it, except one that says its profile is not in front.
    case anyProfile
}

/// `chromeInFront` is whether Chrome was the app in front; `front` the connection of its profile in front, if any;
/// `connected` whether any profile is connected. Chrome opens a new tab in the profile used last, and from another app
/// that is not known before the tab reports.
func chromeFillRoute(chromeInFront: Bool, front: FrontLink?, connected: Bool) -> ChromeFillRoute {
    guard chromeInFront else { return connected ? .anyProfile : .keystrokes }
    guard let front else { return .keystrokes }
    return front.certain ? .link(front.peer.link) : .anyProfile
}

/// A browser's line in Preferences, "Browser extensions".
struct ExtensionStatus: Equatable {
    let text: String
    let on: Bool

    /// `profiles` is how many Chrome profiles have the extension connected now.
    static func chrome(profiles: Int) -> ExtensionStatus {
        switch profiles {
        case ..<1: ExtensionStatus(text: "Not connected", on: false)
        case 1: ExtensionStatus(text: "Connected", on: true)
        default: ExtensionStatus(text: "Connected in \(profiles) profiles", on: true)
        }
    }

    static func safari(enabled: Bool) -> ExtensionStatus {
        ExtensionStatus(text: enabled ? "On" : "Off", on: enabled)
    }
}

/// A browser built on Chromium other than Google Chrome, in Preferences > Browsers: one the person answered about, or
/// one connected now (Chrome Beta is never asked about, and shows only while connected).
struct ChromiumBrowserRow: Equatable, Identifiable {
    let bundleID: String
    let teamID: String
    let name: String
    let status: ExtensionStatus
    /// The person's answer; nil for Google's browsers, which have no button.
    let approval: BrowserApproval?

    var id: String { bundleID + "|" + teamID }

    /// The button that changes the answer.
    var button: String? {
        switch approval {
        case .allowed?: BrowserApprovalPrompt.denyTitle
        case .denied?: BrowserApprovalPrompt.allowTitle
        case nil: nil
        }
    }

    /// What the button sets.
    var toggled: BrowserApproval? {
        switch approval {
        case .allowed?: .denied
        case .denied?: .allowed
        case nil: nil
        }
    }
}

/// The rows, by name. `connected` counts the open profiles per bundle ID; `seen` are the signatures of the browsers that
/// connected since launch.
func chromiumBrowserRows(approvals: BrowserApprovals, connected: [String: Int], seen: [String: ChromiumBrowserIdentity]) -> [ChromiumBrowserRow] {
    func status(_ bundleID: String, _ approval: BrowserApproval?) -> ExtensionStatus {
        let profiles = connected[bundleID] ?? 0
        if profiles > 0, approval != .denied { return .chrome(profiles: profiles) }
        return approval == .denied ? ExtensionStatus(text: "Not allowed", on: false) : ExtensionStatus(text: "Allowed", on: false)
    }
    var rows: [ChromiumBrowserRow] = approvals.records
        .filter { $0.bundleID != BrowserBridge.chromeBundleID }
        .map { ChromiumBrowserRow(bundleID: $0.bundleID, teamID: $0.teamID, name: $0.name, status: status($0.bundleID, $0.approval), approval: $0.approval) }
    for (bundleID, identity) in seen where bundleID != BrowserBridge.chromeBundleID && (connected[bundleID] ?? 0) > 0 {
        guard !rows.contains(where: { $0.bundleID == bundleID && $0.teamID == identity.teamID }) else { continue }
        let approval = approvals.approval(bundleID: bundleID, teamID: identity.teamID)
        rows.append(ChromiumBrowserRow(
            bundleID: bundleID,
            teamID: identity.teamID,
            name: identity.name,
            status: status(bundleID, approval),
            approval: identity.isGoogle ? nil : approval
        ))
    }
    return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Safari's button in Preferences. Both open Safari's Extensions settings with PasswordPie selected.
func safariExtensionButtonTitle(enabled: Bool) -> String {
    enabled ? "Open Safari Settings…" : ExtensionBanner.enableSafari.title
}

/// The app's side of the browser extensions: the socket server, which browsers are connected, the tab each one is on,
/// and the one pending fill. URLs and credentials stay in memory. See docs/BROWSER_EXTENSION.md.
@MainActor
final class BrowserBridge: ObservableObject {
    nonisolated static let chromeBundleID = "com.google.Chrome"
    nonisolated static let safariBundleID = "com.apple.Safari"
    /// Where "Add Chrome Extension…" leads: the extension's Chrome Web Store listing.
    static let chromeInstallURL = URL(string: "https://chromewebstore.google.com/detail/\(BridgeConstants.chromeExtensionID)")!

    #if PP_DIRECT
    nonisolated static let chromeSupported = true
    #else
    /// The App Store version has no Chrome host in v1.
    nonisolated static let chromeSupported = false
    #endif

    /// Which extension speaks for the app: Safari's, or Chrome's in Google Chrome and in every other browser built on
    /// Chromium (`ChromiumBrowsers`). Nil for any other app.
    nonisolated static func browser(forBundleID id: String?) -> BridgeBrowser? {
        guard let id else { return nil }
        if id == safariBundleID { return .safari }
        return ChromiumBrowsers.isChromium(bundleID: id) ? .chrome : nil
    }

    /// How many Google Chrome profiles have the extension connected now.
    @Published private(set) var chromeProfiles = 0
    /// How many profiles have the extension connected now, per browser built on Chromium (bundle ID), Chrome included.
    @Published private(set) var chromiumProfiles: [String: Int] = [:]
    /// The browsers built on Chromium seen connecting since launch, by bundle ID, with their signatures.
    @Published private(set) var chromiumBrowsers: [String: ChromiumBrowserIdentity] = [:]
    /// The person's answers about the browsers built on Chromium other than Google's (docs/UX.md, "Other browsers built
    /// on Chrome"). Kept in the preferences for good.
    @Published private(set) var approvals: BrowserApprovals
    /// Asks the person whether a browser may connect, and calls back with the answer. Replaced in tests.
    var askToAllow: (ChromiumBrowserIdentity, @escaping @MainActor (Bool) -> Void) -> Void = { identity, answer in
        BrowserApprovalPrompt.ask(identity, answer: answer)
    }
    /// The signature of the running browser the panel was over: what the question names. Replaced in tests.
    var identityOfRunning: (FrontApp) -> ChromiumBrowserIdentity? = { front in
        guard let bundleID = front.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        return ChromiumBrowserCheck.identity(ofProcess: app.processIdentifier)
    }
    /// Connections waiting for the person's answer about their browser, by `bundleID|teamID`.
    private var waitingApprovals: [String: [@MainActor (Bool) -> Void]] = [:]
    private let defaults: UserDefaults
    static let approvalsKey = "chromiumBrowserApprovals"
    /// An extension speaks for the Chrome profile in front. False when every connected profile says the focus is
    /// elsewhere: the window in front belongs to a profile without the extension.
    @Published private(set) var chromeInFront = false
    @Published private(set) var safariEnabled = false
    /// Any browser built on Chromium has the extension connected, in any profile.
    var chromeConnected: Bool { !chromiumProfiles.isEmpty }

    unowned let session: VaultSession
    /// Internal, not private, for the agent login (`BrowserBridge+AgentLogin.swift`).
    var state = BridgeState()
    /// The site icons asked for in `tab` answers, waiting for the extension's `icon` request.
    private var iconLedger = SiteIconLedger()
    /// Where icons from the extension go.
    var icons: () -> SiteIconStore = { SiteIconStore.shared }
    private var server: BrowserBridgeServer?
    private var chromeLinks: Set<BridgePeer> = []
    /// The browser app of each Chrome connection.
    private var chromeApps: [BridgePeer: String] = [:]
    /// The connection the latest scan came from, per browser: its code is expected in that Chrome profile.
    private var scanLinks: [BridgeBrowser: Int] = [:]
    /// Sends a frame to one Chrome connection, or to all when the link is nil.
    var pushToChrome: (Data, Int?) -> Void = { _, _ in }
    /// Opens a page in the browser at the given bundle, or in the default browser when there is none.
    var openInBrowser: (URL, URL?) -> Void = { url, app in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    /// The browser that opens `url` when no browser was in front. Replaced in tests.
    var defaultBrowser: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    /// From the Accessibility fallback, for the panel's site list only. Replaced every time the panel opens.
    private var readURLs: [BridgeBrowser: String] = [:]
    private var readGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    /// The app a fill is for: the one the panel opened over, or with the panel closed the one in front now
    /// (`PanelController.fillTarget`).
    var fillTarget: () -> FrontApp? = { nil }
    /// Hides the panel; true gives focus back to the app that was in front.
    var hidePanel: (Bool) -> Void = { _ in }
    /// The extension's toolbar button was clicked: open the panel as the shortcut does.
    var onShowPanel: (() -> Void)?
    /// "Upgrade" was clicked in the page's note about Premium: open the Premium window.
    var onUpgrade: (() -> Void)?
    /// The tab a browser is on changed, so the site list may change.
    var onPageChanged: (() -> Void)?
    /// The person scanned a two-step QR code from the extension's right-click menu: the checked code, the page's origin, the browser.
    var onScan: ((ScannedOTP, String?, BridgeBrowser) -> Void)?
    /// A change-password page that got an account's new password says its form was sent: the account, and the page's
    /// host for the question. Only the person can say whether the site took it.
    var onPasswordChanged: ((UUID, String) -> Void)?
    var now: () -> Date = Date.init
    /// Whether a two-step code may go to the browser: this Mac's own Premium (`browserCodeAllowed`). Tests stand in an answer.
    var codeAllowed: () -> Bool = { browserCodeAllowed() }
    #if PP_DIRECT
    /// The agent login waiting for its tab (docs/AGENTS.md, "Website login"). At most one, as there is one pending fill.
    var agentLogin: AgentLoginWait?
    /// How long an agent's fill waits for a tab of its site, and then for the tab to say how it went. Tests shorten them.
    var agentFillLifetime: TimeInterval = PendingFillStore.lifetime
    var agentResultLifetime: TimeInterval = PendingFillStore.agentResultLifetime
    var agentCodeLifetime: TimeInterval = PendingFillStore.codeLifetime
    /// How long to wait for the tab report a poke asks for, before the prompt.
    var agentPokeWait: TimeInterval = 1.5
    #endif

    init(session: VaultSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        approvals = BrowserApprovals.decode(defaults.data(forKey: Self.approvalsKey))
        pushToChrome = { [weak self] data, link in self?.server?.push(data, to: .chrome, link: link) }
    }

    func start() {
        let server = BrowserBridgeServer(
            handler: { [weak self] frame, peer in self?.answer(frame, from: peer.browser, link: peer.link) },
            changed: { [weak self] peers, apps in self?.connectionsChanged(peers, apps: apps) },
            approve: { [weak self] identity, answer in
                guard let self else { return answer(false) }
                self.approve(identity, answer: answer)
            },
            refused: { [weak self] frame, identity in self?.refusedFrame(frame, from: identity) ?? .close }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("PasswordPie: browser bridge unavailable (%@)", String(describing: error))
        }
        #if PP_DIRECT
        // Asks Launch Services and reads each browser's Info.plist: not on the main thread.
        DispatchQueue.global(qos: .utility).async { ChromeHostManifest.install() }
        // A browser opened later, perhaps installed after PasswordPie started, gets its manifest then. Its profiles folder
        // may only appear a moment after it starts, so look again shortly after.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleURL.map(ChromiumBrowsers.isChromium(bundleURL:)) == true }
            .sink { app in
                let pid = app.processIdentifier
                let bundleURL = app.bundleURL
                for delay in [0.0, 3.0] {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                        let home = FileManager.default.homeDirectoryForCurrentUser
                        let folders = ChromiumBrowsers.folders(home: home, installed: [], running: [(pid, bundleURL)])
                        ChromeHostManifest.install(folders: folders)
                    }
                }
            }
            .store(in: &cancellables)
        #endif
        refreshSafariState()
        session.$locked
            .filter { $0 }
            .sink { [weak self] _ in
                self?.state.pending.clear()
                self?.iconLedger.clear()
                #if PP_DIRECT
                self?.agentLogin?.finish(.locked)
                #endif
            }
            .store(in: &cancellables)
    }

    // MARK: State

    /// The connection that stands for the window of the browser `app` (a bundle ID; nil for any browser built on
    /// Chromium). `inFront` is whether that browser was the app in front: then only a profile that says it has the focus
    /// (or an extension that says nothing) counts. When PasswordPie's own window was in front, no profile has the focus,
    /// and the one used last stands for the browser, as any connection did before.
    private func chromeLink(app: String?, inFront: Bool) -> FrontLink? {
        inFront ? state.front(.chrome, app: app) : state.recent(.chrome, app: app)
    }

    /// The extension can fill `browser`'s window: a connected extension speaks for the profile of the browser app `app`
    /// (see `chromeLink`); Safari's extension is on and has reported a tab.
    func canFill(in browser: BridgeBrowser, app: String? = nil, inFront: Bool = true) -> Bool {
        switch browser {
        case .chrome: Self.chromeSupported && chromeLink(app: app, inFront: inFront) != nil
        case .safari: safariEnabled && state.heardFrom(.safari, now: now())
        }
    }

    /// The page `browser` is on: what its extension reported, checked against what Accessibility read when the panel opened.
    /// `app` is the browser app among those built on Chromium; `inFront` whether it really is the app in front for this
    /// panel or fill (see `chromeLink`).
    func pageURL(for browser: BridgeBrowser, app: String? = nil, inFront: Bool = true) -> String? {
        let usedLast = browser == .chrome && !inFront
        let reported = canFill(in: browser, app: app, inFront: inFront)
            ? state.currentURL(for: browser, app: browser == .chrome ? app : nil, now: now(), usedLast: usedLast)
            : nil
        return resolvedPageURL(extensionURL: reported, windowURL: readURLs[browser])
    }

    func banner(for app: NSRunningApplication?, inFront: Bool = true) -> ExtensionBanner? {
        banner(frontBundleID: app?.bundleIdentifier, inFront: inFront)
    }

    func banner(frontBundleID: String?, inFront: Bool = true) -> ExtensionBanner? {
        extensionBanner(
            frontBundleID: frontBundleID,
            chromeInFront: chromeLink(app: frontBundleID, inFront: inFront) != nil,
            safariEnabled: safariEnabled,
            chromeSupported: Self.chromeSupported,
            deniedName: approvals.records.first { $0.bundleID == frontBundleID && $0.approval == .denied }?.name
        )
    }

    /// The server's open connections changed. Each Chrome connection is one profile's extension, in the browser `apps`
    /// names (Google Chrome when it names none).
    func connectionsChanged(_ peers: Set<BridgePeer>, apps: [BridgePeer: ChromiumBrowserIdentity] = [:]) {
        let chrome = peers.filter { $0.browser == .chrome }
        guard chrome != chromeLinks else { return }
        let page = state.currentURL(for: .chrome, now: now())
        let added = chrome.subtracting(chromeLinks)
        for peer in chromeLinks.subtracting(chrome) {
            state.closed(peer)
            chromeApps[peer] = nil
        }
        for peer in added {
            let app = apps[peer]?.bundleID ?? Self.chromeBundleID
            chromeApps[peer] = app
            state.opened(peer, app: app)
            if let identity = apps[peer], chromiumBrowsers[identity.bundleID] != identity { chromiumBrowsers[identity.bundleID] = identity }
        }
        chromeLinks = chrome
        var counts: [String: Int] = [:]
        for peer in chrome { counts[chromeApps[peer] ?? Self.chromeBundleID, default: 0] += 1 }
        if chromiumProfiles != counts { chromiumProfiles = counts }
        let googleChrome = counts[Self.chromeBundleID] ?? 0
        if chromeProfiles != googleChrome { chromeProfiles = googleChrome }
        frontChanged(pageBefore: page)
        // Ask for the tab now, so the site list does not wait for the next tab change.
        for peer in added.sorted(by: { $0.link < $1.link }) { poke(.chrome, link: peer.link) }
    }

    /// Which Chrome profile is in front may have changed: the banner and the site list follow it.
    private func frontChanged(pageBefore: String?) {
        let inFront = state.front(.chrome) != nil
        if inFront != chromeInFront { chromeInFront = inFront }
        if state.currentURL(for: .chrome, now: now()) != pageBefore { onPageChanged?() }
    }

    func refreshSafariState() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: BridgeConstants.safariExtensionIdentifier) { [weak self] state, _ in
            // An error says nothing about the extension; keep what was known rather than forget a working one.
            guard let state else { return }
            let enabled = state.isEnabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.safariEnabled != enabled else { return }
                    self.safariEnabled = enabled
                    if !enabled { self.state.forget(.safari) }
                }
            }
        }
    }

    // MARK: Messages

    /// Answers one frame. `link` is the connection it came on: for Chrome, one per profile.
    func answer(_ frame: Data, from browser: BridgeBrowser, link: Int = 0) -> Data? {
        var response: BridgeResponse
        if let request = try? JSONDecoder().decode(BridgeRequest.self, from: frame) {
            if request.type == "icon" { return try? JSONEncoder().encode(answerIcon(frame, from: browser)) }
            let before = state.currentURL(for: browser, now: now())
            let now = now()
            var scanned: (ScannedOTP, String?, BridgeBrowser)?
            var changedEntry: UUID?
            var agentEvents: [AgentFillEvent] = []
            response = state.handle(
                request,
                from: browser,
                link: link,
                locked: session.locked,
                now: now,
                codeAllowed: { [codeAllowed] in codeAllowed() },
                scan: { scanned = ($0, $1, $2) },
                changed: { changedEntry = $0 },
                agent: { agentEvents.append($0) }
            ) { [session] id in session.entry(id) }
            #if PP_DIRECT
            for event in agentEvents { agentFillEvent(event) }
            #endif
            if let changedEntry, let host = request.url.flatMap({ BrowserSite(url: $0) })?.host {
                // After the answer is on its way, as for `show`. The answer says the same whatever happens next.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onPasswordChanged?(changedEntry, host) }
                }
            }
            if let scanned {
                scanLinks[browser] = link
                // After the answer is on its way, as for `show`. The answer says the same whatever happens next.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onScan?(scanned.0, scanned.1, scanned.2) }
                }
            }
            if browser == .chrome {
                frontChanged(pageBefore: before)
            } else if state.currentURL(for: browser, now: now) != before {
                onPageChanged?()
            }
            if response.type == "tab", wantsIcon(request, from: browser) { response.wantIcon = true }
            if response.type == "upgrade" {
                // "Upgrade" in the page's note: the Premium window, where this channel sells or says where to buy.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onUpgrade?() }
                }
            }
            if response.type == "show" {
                // After the answer is on its way: the server is waiting on this call to reply.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onShowPanel?() }
                }
            }
        } else {
            response = .error("bad-request", id: nil)
        }
        return try? JSONEncoder().encode(response)
    }

    /// A `tab` answer asks for the tab's icon only when an unlocked account on its site has none yet.
    private func wantsIcon(_ request: BridgeRequest, from browser: BridgeBrowser) -> Bool {
        guard !session.locked, let url = request.url else { return false }
        let store = icons()
        return iconLedger.shouldAsk(browser: browser, pageURL: url, entries: session.allEntries, hasIcon: { store.hasIcon(forHost: $0) }, now: now())
    }

    /// The extension's `icon` request: kept only when it answers this browser's recent `wantIcon` for that exact origin.
    private func answerIcon(_ frame: Data, from browser: BridgeBrowser) -> BridgeResponse {
        guard let request = try? JSONDecoder().decode(BridgeIconRequest.self, from: frame) else { return .error("bad-request", id: nil) }
        guard !session.locked,
              case .success(let delivery) = iconLedger.accept(browser: browser, origin: request.origin ?? "", png: request.png ?? "", now: now()),
              icons().store(delivery) else {
            return .error("bad-icon", id: request.id)
        }
        return .iconStored(id: request.id)
    }

    /// A scanned code was saved in `entryID`. When that item may fill the page it was scanned on, the extension is told to
    /// watch that page for its code field, and the code is answered as after a fill (`browserCodeAllowed` still decides).
    /// Only the connection the scan came from is told: in Chrome, the profile that scanned.
    func expectScannedCode(entryID: UUID, browser: BridgeBrowser, origin: String) {
        let link = scanLinks[browser] ?? 0
        guard let entry = session.entry(entryID), let page = BrowserSite(url: origin),
              entryFillSites(entry).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
              state.expectCode(afterScanOf: entryID, browser: browser, link: link, pageURL: origin, now: now()) else { return }
        poke(browser, link: link)
    }

    // MARK: Other Chromium browsers

    /// Whether the browser may connect: Google's always; another as the person answered, or after asking them once.
    /// Connections of the same browser that arrive while the question is open wait for the same answer.
    func approve(_ identity: ChromiumBrowserIdentity, answer: @escaping @MainActor (Bool) -> Void) {
        // The bundle ID comes from an Info.plist the signature does not vouch for here, and connections are told apart by it
        // alone: another team's browser must never take Google Chrome's (or Beta's) place and share its profile scope.
        if identity.bundleID.hasPrefix("com.google."), !identity.isGoogle { return answer(false) }
        switch approvals.approval(bundleID: identity.bundleID, teamID: identity.teamID) {
        case .allowed?: answer(true)
        case .denied?: answer(false)
        case nil:
            let key = identity.bundleID + "|" + identity.teamID
            if waitingApprovals[key] != nil {
                waitingApprovals[key]?.append(answer)
                return
            }
            waitingApprovals[key] = [answer]
            askToAllow(identity) { [weak self] allowed in
                self?.setApproval(allowed ? .allowed : .denied, bundleID: identity.bundleID, teamID: identity.teamID, name: identity.name)
            }
        }
    }

    /// Opens the question again for a browser the person said no to: from the panel's line, or from that browser's
    /// toolbar button. Nothing happens for a browser with another answer, or while its question is open.
    func askAgain(_ identity: ChromiumBrowserIdentity) {
        guard approvals.approval(bundleID: identity.bundleID, teamID: identity.teamID) == .denied else { return }
        let key = identity.bundleID + "|" + identity.teamID
        guard waitingApprovals[key] == nil else { return }
        waitingApprovals[key] = []
        askToAllow(identity) { [weak self] allowed in
            self?.setApproval(allowed ? .allowed : .denied, bundleID: identity.bundleID, teamID: identity.teamID, name: identity.name)
        }
    }

    /// What to do with a frame from a browser the person said no to. Its connection is kept open but is not a connected
    /// profile: nothing it sends reaches the vault, and it is told nothing.
    enum RefusedFrame: Equatable {
        /// The person allows the browser now: serve this frame and the rest like any connection's.
        case admit
        /// Not served. `answer` goes back when there is one: only the toolbar button gets one.
        case hold(answer: Data?)
        /// No answer on record: end the connection, and the next one is asked about afresh.
        case close
    }

    /// How long after a Don't Allow the browser's own toolbar button can bring the question back.
    static let askAgainAfter: TimeInterval = 10

    func refusedFrame(_ frame: Data, from identity: ChromiumBrowserIdentity) -> RefusedFrame {
        switch approvals.approval(bundleID: identity.bundleID, teamID: identity.teamID) {
        case .allowed?: return .admit
        case nil: return .close
        case .denied?: break
        }
        // The toolbar button: say the app heard it, so the extension does not open the website as if PasswordPie were
        // missing, and ask the person again. The answer carries nothing but the request's own id.
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: frame), request.type == "show" else {
            return .hold(answer: nil)
        }
        let decided = approvals.records.first { $0.bundleID == identity.bundleID && $0.teamID == identity.teamID }?.decided
        if decided.map({ now().timeIntervalSince($0) >= Self.askAgainAfter }) ?? true { askAgain(identity) }
        return .hold(answer: try? JSONEncoder().encode(BridgeResponse.show(id: request.id)))
    }

    /// Keeps the person's answer for a browser, from the question or from Preferences. A browser no longer allowed is
    /// disconnected at once; one allowed now is let in as soon as its extension speaks, which the poke makes it do.
    func setApproval(_ approval: BrowserApproval, bundleID: String, teamID: String, name: String) {
        approvals.set(approval, bundleID: bundleID, teamID: teamID, name: name, now: now())
        defaults.set(approvals.encoded(), forKey: Self.approvalsKey)
        if approval == .denied { server?.disconnect(app: bundleID, teamID: teamID) }
        if approval == .allowed, let poke = try? JSONEncoder().encode(BridgeResponse.poke) {
            server?.pushToHeld(poke, app: bundleID, teamID: teamID)
        }
        let key = bundleID + "|" + teamID
        let waiting = waitingApprovals.removeValue(forKey: key) ?? []
        for answer in waiting { answer(approval == .allowed) }
    }

    /// Asks the extension to report its tab now. Carries nothing. For Chrome, `link` is the one connection to ask, or
    /// nil for all of them.
    func poke(_ browser: BridgeBrowser, link: Int? = nil) {
        switch browser {
        case .chrome:
            guard let data = try? JSONEncoder().encode(BridgeResponse.poke) else { return }
            pushToChrome(data, link)
        case .safari:
            SFSafariApplication.dispatchMessage(
                withName: "poke",
                toExtensionWithIdentifier: BridgeConstants.safariExtensionIdentifier,
                userInfo: nil
            )
        }
    }

    // MARK: Panel

    /// The panel is opening over `app`. Freshens what is known about its tab.
    func panelWillShow(over app: NSRunningApplication?) {
        panelWillShow(over: FrontApp(app), pid: app?.processIdentifier)
    }

    /// `pid` is the front app's process, for reading its window; nil reads nothing.
    func panelWillShow(over front: FrontApp?, pid: pid_t?) {
        readURLs = [:]
        readGeneration &+= 1
        refreshSafariState()
        // Before the panel takes the keyboard: from then on Chrome tells its extensions that their windows lost the
        // focus, and the profile that has it now must stay the one in front.
        let page = state.currentURL(for: .chrome, now: now())
        state.panelOpened()
        frontChanged(pageBefore: page)
        guard let browser = Self.browser(forBundleID: front?.bundleID) else { return }
        // Poke whenever the extension could answer, not only when it reported lately: a tab left open for hours sends nothing.
        switch browser {
        case .chrome:
            // Only the profile in front is asked. One that says nothing about focus cannot be told apart: ask them all.
            if let link = chromeLink(app: front?.bundleID, inFront: front?.inFront ?? false) { poke(.chrome, link: link.certain ? link.peer.link : nil) }
        case .safari: if safariEnabled { poke(.safari) }
        }
        guard let pid else { return }
        // Also read the window: it shows the list without the extension, and catches a report that went stale.
        let generation = readGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = BrowserURLReader.read(pid: pid, browser: browser)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let url, self.readGeneration == generation else { return }
                    self.readURLs[browser] = url
                    self.onPageChanged?()
                }
            }
        }
    }

    /// The panel closed: what each profile says about the focus counts again.
    func panelDidHide() {
        let page = state.currentURL(for: .chrome, now: now())
        state.panelClosed()
        frontChanged(pageBefore: page)
    }

    /// Opens where the extension is added or turned on. `front` is the app the panel was over: when that is Chrome or
    /// another browser built on Chromium, the store page opens in it, and it puts it in the profile whose window was used
    /// last, the one in front.
    func install(_ banner: ExtensionBanner, in front: FrontApp? = nil) {
        switch banner {
        case .addChrome:
            let chrome = Self.browser(forBundleID: front?.bundleID) == .chrome ? front?.bundleURL : nil
            openInBrowser(Self.chromeInstallURL, chrome ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID))
        case .enableSafari:
            SFSafariApplication.showPreferencesForExtension(withIdentifier: BridgeConstants.safariExtensionIdentifier) { _ in }
        case .allowBrowser:
            // The question names the browser by its own signature, read from the running app, not by the line's words.
            guard let front, let identity = identityOfRunning(front) else { return }
            askAgain(identity)
        }
    }

    // MARK: Fill

    /// Fills through the extension when the target browser has one. False means the caller types the keystrokes instead.
    func fill(_ entry: VaultEntry, _ mode: FillMode, website: String?) -> Bool {
        fill(entry, mode, website: website, front: fillTarget())
    }

    /// `front` is the app the fill is for (`PanelController.fillTarget`): the one the panel opened over, or with the
    /// panel closed the one in front now.
    func fill(_ entry: VaultEntry, _ mode: FillMode, website: String?, front: FrontApp?) -> Bool {
        guard mode != .open else { return false }
        var browser = Self.browser(forBundleID: front?.bundleID)
        var browserApp = front?.bundleURL
        var browserID = front?.bundleID
        // From another app, Open and Fill goes to the default browser.
        if browser == nil, mode != .fill, let url = webURL(website ?? entry.url),
           let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier,
           let found = Self.browser(forBundleID: id) {
            browser = found
            browserApp = app
            browserID = id
        }
        guard let browser, let browserApp else { return false }
        // The panel was over this browser, and it really was the app in front then.
        let overBrowser = front?.bundleURL == browserApp
        let inFront = overBrowser && front?.inFront == true
        // Among the browsers built on Chromium, only this one's connections count.
        let app = browser == .chrome ? browserID : nil
        // The connection the fill is for: in Chrome, the profile in front. Never a tab of another profile.
        let link: Int?
        switch browser {
        case .chrome:
            guard Self.chromeSupported else { return false }
            switch chromeFillRoute(chromeInFront: inFront, front: state.front(.chrome, app: app), connected: state.linkCount(.chrome, app: app) > 0) {
            case .keystrokes: return false
            case .link(let id): link = id
            case .anyProfile: link = nil
            }
        case .safari:
            guard canFill(in: .safari) else { return false }
            link = nil
        }
        let page = overBrowser ? pageURL(for: browser, app: app, inFront: inFront) : nil
        switch browserFillPlan(entry: entry, mode: mode, preferredWebsite: website, pageURL: page) {
        case .keystrokes:
            return false
        case .thisTab(let site):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now(), link: link, app: app) else { return false }
            state.pending.set(pending)
            hidePanel(true)
            poke(browser, link: link)
            return true
        case .newTab(let site, let url):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now(), link: link, app: app) else { return false }
            state.pending.set(pending)
            hidePanel(false)
            openInBrowser(url, browserApp)
            return true
        }
    }

    /// Reset Password: opens `address` in Chrome and fills it when it loads, the saved password where the page asks for
    /// the current one and `newPassword` in its new and confirm boxes. False means nothing was done and the caller only
    /// opens the page: the address is not on a site of the account, the browser it would open in is not Chrome, or no
    /// extension speaks for the profile that would get it. The new password is never typed by keystrokes.
    func openReset(_ entry: VaultEntry, address: String, newPassword: String) -> Bool {
        openReset(entry, address: address, newPassword: newPassword, front: fillTarget())
    }

    /// `front` is the app the panel opened over. From another app the page goes to the default browser, as it did
    /// before there was anything to fill.
    func openReset(_ entry: VaultEntry, address: String, newPassword: String, front: FrontApp?) -> Bool {
        guard Self.chromeSupported, !newPassword.isEmpty, let url = webURL(address),
              entryFillSites(entry).contains(where: { BrowserSite.allowsFill(entryWebsite: $0, pageURL: address) }) else { return false }
        var browser = Self.browser(forBundleID: front?.bundleID)
        var browserApp = front?.bundleURL
        var browserID = front?.bundleID
        if browser == nil, let app = defaultBrowser(url) {
            browserID = Bundle(url: app)?.bundleIdentifier
            browser = Self.browser(forBundleID: browserID)
            browserApp = app
        }
        // Safari's extension does not fill a change form (docs/UX.md, "When it does not apply").
        guard browser == .chrome, let browserApp else { return false }
        let inFront = front?.bundleURL == browserApp && front?.inFront == true
        let link: Int?
        switch chromeFillRoute(chromeInFront: inFront, front: state.front(.chrome, app: browserID), connected: state.linkCount(.chrome, app: browserID) > 0) {
        case .keystrokes: return false
        case .link(let id): link = id
        case .anyProfile: link = nil
        }
        guard let pending = PendingFill(entryID: entry.id, browser: .chrome, website: address, created: now(), link: link, newPassword: newPassword, app: browserID) else { return false }
        state.pending.set(pending)
        hidePanel(false)
        openInBrowser(url, browserApp)
        return true
    }
}

#if PP_DIRECT
/// Chrome finds native messaging hosts through a manifest in its profile folder. The app writes one for each name in
/// `BridgeConstants.nativeHostNames`, all pointing at the host inside the running bundle, and only for the extension IDs
/// that may use it. It does so at launch for every browser built on Chromium that has a profiles folder
/// (`ChromiumBrowsers.folders`), and again when such a browser starts.
enum ChromeHostManifest {
    static func fileName(_ name: String) -> String { name + ".json" }

    static func manifest(name: String, hostPath: String, extensionIDs: [String] = BridgeConstants.chromeExtensionIDs) -> Data {
        let object: [String: Any] = [
            "name": name,
            "description": "PasswordPie",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Writes the manifests into each browser's profiles folder that exists, when the app runs from its bundle (not a bare
    /// debug binary). `folders` nil means every browser built on Chromium on this Mac.
    static func install(bundle: Bundle = .main, home: URL = FileManager.default.homeDirectoryForCurrentUser, folders: [URL]? = nil) {
        guard !BridgeConstants.chromeExtensionIDs.isEmpty, bundle.bundleURL.pathExtension == "app",
              let host = bundle.url(forAuxiliaryExecutable: "PasswordPieBrowserHost") else { return }
        let browsers = folders ?? ChromiumBrowsers.folders(
            home: home,
            installed: ChromiumBrowsers.installedBrowsers(),
            running: ChromiumBrowsers.runningApps()
        )
        for browser in browsers where FileManager.default.fileExists(atPath: browser.path) {
            write(host: host, into: browser.appendingPathComponent("NativeMessagingHosts"))
        }
    }

    private static func write(host: URL, into folder: URL) {
        for name in BridgeConstants.nativeHostNames {
            let file = folder.appendingPathComponent(fileName(name))
            let data = manifest(name: name, hostPath: host.path)
            guard (try? Data(contentsOf: file)) != data else { continue }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                NSLog("PasswordPie: could not write the Chrome host manifest %@ (%@)", name, String(describing: error))
            }
        }
    }
}
#endif
