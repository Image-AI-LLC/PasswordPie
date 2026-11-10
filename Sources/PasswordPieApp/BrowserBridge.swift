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

/// Which banner the panel shows for the app that was in front, if any.
func extensionBanner(frontBundleID: String?, chromeConnected: Bool, safariEnabled: Bool, chromeSupported: Bool) -> ExtensionBanner? {
    switch BrowserBridge.browser(forBundleID: frontBundleID) {
    case .chrome: chromeSupported && !chromeConnected ? .addChrome : nil
    case .safari: safariEnabled ? nil : .enableSafari
    case nil: nil
    }
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

    @Published private(set) var chromeConnected = false
    @Published private(set) var safariEnabled = false

    private unowned let session: VaultSession
    private var state = BridgeState()
    /// The site icons asked for in `tab` answers, waiting for the extension's `icon` request.
    private var iconLedger = SiteIconLedger()
    /// Where icons from the extension go.
    var icons: () -> SiteIconStore = { SiteIconStore.shared }
    private var server: BrowserBridgeServer?
    /// From the Accessibility fallback, for the panel's site list only. Replaced every time the panel opens.
    private var readURLs: [BridgeBrowser: String] = [:]
    private var readGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    /// The app that was in front when the panel opened.
    var targetApp: () -> NSRunningApplication? = { nil }
    /// Hides the panel; true gives focus back to the app that was in front.
    var hidePanel: (Bool) -> Void = { _ in }
    /// The extension's toolbar button was clicked: open the panel as the shortcut does.
    var onShowPanel: (() -> Void)?
    /// The tab a browser is on changed, so the site list may change.
    var onPageChanged: (() -> Void)?
    /// The person scanned a two-step QR code in the extension's popup: the checked code, the page's origin, the browser.
    var onScan: ((ScannedOTP, String?, BridgeBrowser) -> Void)?
    var now: () -> Date = Date.init

    init(session: VaultSession) {
        self.session = session
    }

    func start() {
        let server = BrowserBridgeServer(
            handler: { [weak self] frame, browser in self?.answer(frame, from: browser) },
            changed: { [weak self] counts in self?.connectionsChanged(counts) }
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

    /// The extension can fill in `browser`: Chrome's host is connected now; Safari's extension is on and has reported a tab.
    func canFill(in browser: BridgeBrowser) -> Bool {
        switch browser {
        case .chrome: Self.chromeSupported && chromeConnected
        case .safari: safariEnabled && state.heardFrom(.safari, now: now())
        }
    }

    /// The page `browser` is on: what its extension reported, checked against what Accessibility read when the panel opened.
    func pageURL(for browser: BridgeBrowser) -> String? {
        let reported = canFill(in: browser) ? state.currentURL(for: browser, now: now()) : nil
        return resolvedPageURL(extensionURL: reported, windowURL: readURLs[browser])
    }

    func banner(for app: NSRunningApplication?) -> ExtensionBanner? {
        extensionBanner(
            frontBundleID: app?.bundleIdentifier,
            chromeConnected: chromeConnected,
            safariEnabled: safariEnabled,
            chromeSupported: Self.chromeSupported
        )
    }

    private func connectionsChanged(_ counts: [BridgeBrowser: Int]) {
        let connected = (counts[.chrome] ?? 0) > 0
        guard connected != chromeConnected else { return }
        chromeConnected = connected
        if connected {
            // Ask for the tab now, so the site list does not wait for the next tab change.
            poke(.chrome)
        } else {
            state.forget(.chrome)
        }
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

    func answer(_ frame: Data, from browser: BridgeBrowser) -> Data? {
        var response: BridgeResponse
        if let request = try? JSONDecoder().decode(BridgeRequest.self, from: frame) {
            if request.type == "icon" { return try? JSONEncoder().encode(answerIcon(frame, from: browser)) }
            let before = state.currentURL(for: browser, now: now())
            let now = now()
            var scanned: (ScannedOTP, String?, BridgeBrowser)?
            response = state.handle(
                request,
                from: browser,
                locked: session.locked,
                now: now,
                codeAllowed: { token in browserCodeAllowed(entitlement: token, now: now) },
                premium: PremiumChannel.passRelay(from: browser),
                scan: { scanned = ($0, $1, $2) }
            ) { [session] id in session.entry(id) }
            if let scanned {
                // After the answer is on its way, as for `show`. The answer says the same whatever happens next.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onScan?(scanned.0, scanned.1, scanned.2) }
                }
            }
            if state.currentURL(for: browser, now: now) != before { onPageChanged?() }
            if response.type == "tab", wantsIcon(request, from: browser) { response.wantIcon = true }
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
    func expectScannedCode(entryID: UUID, browser: BridgeBrowser, origin: String) {
        guard let entry = session.entry(entryID), let page = BrowserSite(url: origin),
              entryWebsites(entry).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }),
              state.expectCode(afterScanOf: entryID, browser: browser, pageURL: origin, now: now()) else { return }
        poke(browser)
    }

    /// Asks the extension to report its tab now. Carries nothing.
    func poke(_ browser: BridgeBrowser) {
        switch browser {
        case .chrome:
            guard let data = try? JSONEncoder().encode(BridgeResponse.poke) else { return }
            server?.push(data, to: .chrome)
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
        readURLs = [:]
        readGeneration &+= 1
        refreshSafariState()
        guard let app, let browser = Self.browser(forBundleID: app.bundleIdentifier) else { return }
        // Poke whenever the extension could answer, not only when it reported lately: a tab left open for hours sends nothing.
        switch browser {
        case .chrome: if chromeConnected { poke(.chrome) }
        case .safari: if safariEnabled { poke(.safari) }
        }
        // Also read the window: it shows the list without the extension, and catches a report that went stale.
        let generation = readGeneration
        let pid = app.processIdentifier
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

    func install(_ banner: ExtensionBanner) {
        switch banner {
        case .addChrome:
            open(Self.chromeInstallURL, inBrowser: Self.chromeBundleID)
        case .enableSafari:
            SFSafariApplication.showPreferencesForExtension(withIdentifier: BridgeConstants.safariExtensionIdentifier) { _ in }
        }
    }

    private func open(_ url: URL, inBrowser bundleID: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Fill

    /// Fills through the extension when the target browser has one. False means the caller types the keystrokes instead.
    func fill(_ entry: VaultEntry, _ mode: FillMode, website: String?) -> Bool {
        guard mode != .open else { return false }
        let front = targetApp()
        var browser = Self.browser(forBundleID: front?.bundleIdentifier)
        var browserApp = front?.bundleURL
        // From another app, Open and Fill goes to the default browser.
        if browser == nil, mode != .fill, let url = webURL(website ?? entry.url),
           let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let found = Self.browser(forBundleID: Bundle(url: app)?.bundleIdentifier) {
            browser = found
            browserApp = app
        }
        guard let browser, let browserApp, canFill(in: browser) else { return false }
        let page = front?.bundleURL == browserApp ? pageURL(for: browser) : nil
        switch browserFillPlan(entry: entry, mode: mode, preferredWebsite: website, pageURL: page) {
        case .keystrokes:
            return false
        case .thisTab(let site):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now()) else { return false }
            state.pending.set(pending)
            hidePanel(true)
            poke(browser)
            return true
        case .newTab(let site, let url):
            guard let pending = PendingFill(entryID: entry.id, browser: browser, website: site, created: now()) else { return false }
            state.pending.set(pending)
            hidePanel(false)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browserApp, configuration: configuration)
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
