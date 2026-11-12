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
    let websites = entryWebsites(entry).filter { webURL($0) != nil }
    guard mode != .open, !websites.isEmpty else { return .keystrokes }
    if mode != .openAndFill, let pageURL {
        if let preferredWebsite, BrowserSite.allowsFill(entryWebsite: preferredWebsite, pageURL: pageURL) {
            return .thisTab(website: preferredWebsite)
        }
        if let website = SiteSuggestions.matchingWebsite(of: entry, pageURL: pageURL) {
            return .thisTab(website: website)
        }
    }
    let website = [preferredWebsite, entry.url].compactMap { $0 }.first { webURL($0) != nil } ?? websites[0]
    guard let url = webURL(website) else { return .keystrokes }
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

    var title: String {
        switch self {
        case .addChrome: "Add Chrome Extension…"
        case .enableSafari: "Enable Safari Extension…"
        }
    }

    var browserBundleID: String {
        switch self {
        case .addChrome: BrowserBridge.chromeBundleID
        case .enableSafari: BrowserBridge.safariBundleID
        }
    }
}

/// Which banner the panel shows for the app that was in front, if any. `chromeInFront` is whether an extension speaks
/// for the Chrome profile in front: one connected in another profile does not count.
func extensionBanner(frontBundleID: String?, chromeInFront: Bool, safariEnabled: Bool, chromeSupported: Bool) -> ExtensionBanner? {
    switch BrowserBridge.browser(forBundleID: frontBundleID) {
    case .chrome: chromeSupported && !chromeInFront ? .addChrome : nil
    case .safari: safariEnabled ? nil : .enableSafari
    case nil: nil
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

    nonisolated static func browser(forBundleID id: String?) -> BridgeBrowser? {
        switch id {
        case chromeBundleID: .chrome
        case safariBundleID: .safari
        default: nil
        }
    }

    /// How many Chrome profiles have the extension connected now.
    @Published private(set) var chromeProfiles = 0
    /// An extension speaks for the Chrome profile in front. False when every connected profile says the focus is
    /// elsewhere: the window in front belongs to a profile without the extension.
    @Published private(set) var chromeInFront = false
    @Published private(set) var safariEnabled = false
    var chromeConnected: Bool { chromeProfiles > 0 }

    private unowned let session: VaultSession
    private var state = BridgeState()
    /// The site icons asked for in `tab` answers, waiting for the extension's `icon` request.
    private var iconLedger = SiteIconLedger()
    /// Where icons from the extension go.
    var icons: () -> SiteIconStore = { SiteIconStore.shared }
    private var server: BrowserBridgeServer?
    private var chromeLinks: Set<BridgePeer> = []
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
    var now: () -> Date = Date.init

    init(session: VaultSession) {
        self.session = session
        pushToChrome = { [weak self] data, link in self?.server?.push(data, to: .chrome, link: link) }
    }

    func start() {
        let server = BrowserBridgeServer(
            handler: { [weak self] frame, peer in self?.answer(frame, from: peer.browser, link: peer.link) },
            changed: { [weak self] peers in self?.connectionsChanged(peers) }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("PasswordPie: browser bridge unavailable (%@)", String(describing: error))
        }
        #if PP_DIRECT
        ChromeHostManifest.install()
        #endif
        refreshSafariState()
        session.$locked
            .filter { $0 }
            .sink { [weak self] _ in
                self?.state.pending.clear()
                self?.iconLedger.clear()
            }
            .store(in: &cancellables)
    }

    // MARK: State

    /// The connection that stands for Chrome's window. `inFront` is whether Chrome was the app in front: then only a
    /// profile that says it has the focus (or an extension that says nothing) counts. When PasswordPie's own window was
    /// in front, no profile has the focus, and the one used last stands for Chrome, as any connection did before.
    private func chromeLink(inFront: Bool) -> FrontLink? {
        inFront ? state.front(.chrome) : state.recent(.chrome)
    }

    /// The extension can fill `browser`'s window: a connected extension speaks for Chrome's profile (see `chromeLink`);
    /// Safari's extension is on and has reported a tab.
    func canFill(in browser: BridgeBrowser, inFront: Bool = true) -> Bool {
        switch browser {
        case .chrome: Self.chromeSupported && chromeLink(inFront: inFront) != nil
        case .safari: safariEnabled && state.heardFrom(.safari, now: now())
        }
    }

    /// The page `browser` is on: what its extension reported, checked against what Accessibility read when the panel opened.
    /// `inFront` is whether the browser really is the app in front for this panel or fill (see `chromeLink`).
    func pageURL(for browser: BridgeBrowser, inFront: Bool = true) -> String? {
        let usedLast = browser == .chrome && !inFront
        let reported = canFill(in: browser, inFront: inFront) ? state.currentURL(for: browser, now: now(), usedLast: usedLast) : nil
        return resolvedPageURL(extensionURL: reported, windowURL: readURLs[browser])
    }

    func banner(for app: NSRunningApplication?, inFront: Bool = true) -> ExtensionBanner? {
        banner(frontBundleID: app?.bundleIdentifier, inFront: inFront)
    }

    func banner(frontBundleID: String?, inFront: Bool = true) -> ExtensionBanner? {
        extensionBanner(
            frontBundleID: frontBundleID,
            chromeInFront: chromeLink(inFront: inFront) != nil,
            safariEnabled: safariEnabled,
            chromeSupported: Self.chromeSupported
        )
    }

    /// The server's open connections changed. Each Chrome connection is one profile's extension.
    func connectionsChanged(_ peers: Set<BridgePeer>) {
        let chrome = peers.filter { $0.browser == .chrome }
        guard chrome != chromeLinks else { return }
        let page = state.currentURL(for: .chrome, now: now())
        let added = chrome.subtracting(chromeLinks)
        for peer in chromeLinks.subtracting(chrome) { state.closed(peer) }
        for peer in added { state.opened(peer) }
        chromeLinks = chrome
        if chromeProfiles != chrome.count { chromeProfiles = chrome.count }
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
            response = state.handle(
                request,
                from: browser,
                link: link,
                locked: session.locked,
                now: now,
                codeAllowed: { browserCodeAllowed() },
                scan: { scanned = ($0, $1, $2) }
            ) { [session] id in session.entry(id) }
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
              entryWebsites(entry).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
              state.expectCode(afterScanOf: entryID, browser: browser, link: link, pageURL: origin, now: now()) else { return }
        poke(browser, link: link)
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
            if let link = chromeLink(inFront: front?.inFront ?? false) { poke(.chrome, link: link.certain ? link.peer.link : nil) }
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

    /// Opens where the extension is added or turned on. `front` is the app the panel was over: when that is Chrome, the
    /// store page opens in it, and Chrome puts it in the profile whose window was used last, the one in front.
    func install(_ banner: ExtensionBanner, in front: FrontApp? = nil) {
        switch banner {
        case .addChrome:
            let chrome = front?.bundleID == Self.chromeBundleID ? front?.bundleURL : nil
            openInBrowser(Self.chromeInstallURL, chrome ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID))
        case .enableSafari:
            SFSafariApplication.showPreferencesForExtension(withIdentifier: BridgeConstants.safariExtensionIdentifier) { _ in }
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
        // From another app, Open and Fill goes to the default browser.
        if browser == nil, mode != .fill, let url = webURL(website ?? entry.url),
           let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let found = Self.browser(forBundleID: Bundle(url: app)?.bundleIdentifier) {
            browser = found
            browserApp = app
        }
        guard let browser, let browserApp else { return false }
        // The panel was over this browser, and it really was the app in front then.
        let overBrowser = front?.bundleURL == browserApp
        let inFront = overBrowser && front?.inFront == true
        // The connection the fill is for: in Chrome, the profile in front. Never a tab of another profile.
        let link: Int?
        switch browser {
        case .chrome:
            guard Self.chromeSupported else { return false }
            switch chromeFillRoute(chromeInFront: inFront, front: state.front(.chrome), connected: chromeConnected) {
            case .keystrokes: return false
            case .link(let id): link = id
            case .anyProfile: link = nil
            }
        case .safari:
            guard canFill(in: .safari) else { return false }
            link = nil
        }
        let page = overBrowser ? pageURL(for: browser, inFront: inFront) : nil
        switch browserFillPlan(entry: entry, mode: mode, preferredWebsite: website, pageURL: page) {
        case .keystrokes:
            return false
        case .thisTab(let site):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now(), link: link) else { return false }
            state.pending.set(pending)
            hidePanel(true)
            poke(browser, link: link)
            return true
        case .newTab(let site, let url):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now(), link: link) else { return false }
            state.pending.set(pending)
            hidePanel(false)
            openInBrowser(url, browserApp)
            return true
        }
    }
}

#if PP_DIRECT
/// Chrome finds native messaging hosts through a manifest in its profile folder. The app writes it at launch, pointing
/// at the host inside the running bundle, and only for the extension IDs that may use it.
enum ChromeHostManifest {
    static let fileName = BridgeConstants.nativeHostName + ".json"

    static func manifest(hostPath: String, extensionIDs: [String] = BridgeConstants.chromeExtensionIDs) -> Data {
        let object: [String: Any] = [
            "name": BridgeConstants.nativeHostName,
            "description": "PasswordPie",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Writes the manifest when Chrome is installed for this user and the app runs from its bundle (not a bare debug binary).
    static func install(bundle: Bundle = .main, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard !BridgeConstants.chromeExtensionIDs.isEmpty, bundle.bundleURL.pathExtension == "app",
              let host = bundle.url(forAuxiliaryExecutable: "PasswordPieBrowserHost") else { return }
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        guard FileManager.default.fileExists(atPath: chrome.path) else { return }
        let folder = chrome.appendingPathComponent("NativeMessagingHosts")
        let file = folder.appendingPathComponent(fileName)
        let data = manifest(hostPath: host.path)
        guard (try? Data(contentsOf: file)) != data else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("PasswordPie: could not write the Chrome host manifest (%@)", String(describing: error))
        }
    }
}
#endif
