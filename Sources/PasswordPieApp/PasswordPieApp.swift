import AppKit
import Carbon.HIToolbox
import Combine
import PasswordPieCore
import SwiftUI

/// NSApplicationMain alone never installs a delegate when there is no nib, so the entry point does it explicitly.
@main
enum PasswordPieMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        migrateFromLegacyNamespace()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// The direct build v0.1.0 had the old ID (`AppNamespace.legacyID`). Before anything reads a preference, bring over what it kept,
    /// once (`LegacyMigration`). Direct channel only: no App Store build ever had the old ID, and the sandbox hides other
    /// apps' preferences anyway.
    @MainActor
    private static func migrateFromLegacyNamespace() {
        #if PP_DIRECT
        LegacyMigration.runOnce(
            legacyPreferences: LegacyMigration.preferences(domain: AppNamespace.legacyID),
            services: LegacyMigration.Services(
                touchID: TouchIDSecretStore().service,
                keyFile: VaultSession.keyFileService,
                premium: PremiumChannel.keychainService,
                premiumAccounts: [PremiumSecret.activation.rawValue]
            )
        )
        #endif
    }
}

/// A borderless panel that can take key status: Large Type closes on any key press or when it loses focus.
/// It takes the keys without activating the app, because a pinned window can open it while another app is in front.
final class LargeTypeWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var statusItem: NSStatusItem!
    private var session: VaultSession!
    private var pendingOpenURLs: [URL] = []
    private(set) var panelController: PanelController!
    private(set) var bridge: BrowserBridge!
    private var autoLock: AutoLockMonitor!
    private var hotKey: EventHotKeyRef?
    private var pinnedHotKeys: [EventHotKeyRef] = []
    private var hotKeyHandlerInstalled = false
    private let hotKeySignature: OSType = 0x50506965
    private(set) var largeTypeWindow: NSWindow?
    private struct PinnedAccount {
        let panel: PinnedEntryPanel
        var model: DetailsModel
        var snapshot: VaultEntry
        var contentHeight: CGFloat
    }
    private var pinnedAccounts: [UUID: PinnedAccount] = [:]
    /// Back to front. `NSApp.orderedWindows` is empty while another app is in front, which is when the shortcuts run.
    private var pinnedOrder: [UUID] = []
    private var editorWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private let preferencesNavigator = PreferencesNavigator()
    private var aboutWindow: NSWindow?
    private var chromeReviewWindow: NSWindow?
    private var paywallWindow: NSWindow?
    private var scanWindow: NSWindow?
    /// True while the scan window closes because the vault locked: the scan keeps waiting for the unlock.
    private var closingScanForLock = false
    private(set) var otpScan: OTPScanModel!
    private var cancellables = Set<AnyCancellable>()
    #if DEBUG
    private var reporter: StatusReporter?
    private var hotKeyStatus = ""
    #endif

    /// The browser extensions fill through the bridge; Fill falls back to keystrokes when it cannot.
    private func startBrowserBridge() {
        bridge = BrowserBridge(session: session)
        bridge.fillTarget = { [weak self] in
            guard let target = self?.panelController.fillTarget else { return nil }
            return FrontApp(target.app, inFront: target.inFront)
        }
        bridge.hidePanel = { [weak self] refocus in self?.panelController.hide(refocusPrevious: refocus) }
        session.browserFill = { [weak self] entry, mode, website in
            self?.bridge.fill(entry, mode, website: website) ?? false
        }
        bridge.onShowPanel = { [weak self] in self?.showFromExtension() }
        bridge.onUpgrade = { [weak self] in self?.showPaywall() }
        otpScan = OTPScanModel(session: session)
        otpScan.present = { [weak self] in self?.presentScan() }
        otpScan.codeAdded = { [weak self] id, browser, origin in self?.bridge.expectScannedCode(entryID: id, browser: browser, origin: origin) }
        bridge.onScan = { [weak self] scanned, origin, browser in self?.otpScan.receive(scanned, origin: origin, browser: browser) }
        panelController.bridge = bridge
        bridge.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        session = VaultSession()
        session.restore()
        autoLock = AutoLockMonitor(settings: session.autoLock) { [weak self] in
            guard let self, !self.session.locked || self.session.unlocking else { return }
            self.session.lock()
        }
        autoLock.start()
        session.onActivity = { [weak self] in self?.autoLock.registerActivity() }
        session.onAutoLockChange = { [weak self] settings in self?.autoLock.update(settings) }
        buildMainMenu()
        wirePremium()
        panelController = PanelController(session: session)
        session.hidePanel = { [weak self] in self?.panelController.hide() }
        startBrowserBridge()
        buildStatusItem()
        registerHotkey()
        session.$editing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in self?.editingChanged(entry) }
            .store(in: &cancellables)
        // Large Type shows a secret on screen at screen-saver level; it must not outlive the unlocked vault.
        session.$locked
            .filter { $0 }
            .sink { [weak self] _ in
                self?.closeScanForLock()
                self?.largeTypeWindow?.close()
                self?.largeTypeWindow = nil
                let pinned = Array(self?.pinnedAccounts.values.map(\.panel) ?? [])
                pinned.forEach { $0.close() }
            }
            .store(in: &cancellables)
        // A scan that arrived while locked shows once the vault is open.
        session.$locked
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.otpScan.isWaiting else { return }
                self.otpScan.prepare()
                self.showScanWindow()
            }
            .store(in: &cancellables)
        session.$allEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.refreshPinnedEntry(entries)
            }
            .store(in: &cancellables)
        applyDebugHooks()
    }

    // MARK: Apple Passwords hand-off

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        VaultSession.isCredentialExchange(userActivityType)
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard VaultSession.isCredentialExchange(userActivity.activityType),
              let token = VaultSession.credentialExchangeToken(from: userActivity.userInfo) else { return false }
        session.importFromCredentialExchange(token: token)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.flushClipboard()
    }

    // MARK: Panel

    func toggleFromHotkey() {
        autoLock.registerActivity()
        panelController.toggle(.hotkey)
    }

    /// The extension's toolbar button: opens the panel like the shortcut, but a second click brings it forward instead of closing it.
    func showFromExtension() {
        autoLock.registerActivity()
        if panelController.isVisible, !panelController.lockingOut {
            panelController.bringForward()
        } else {
            panelController.show(.hotkey)
        }
    }

    func hidePanel() { panelController.hide() }

    /// Runs `body` (typically a modal file chooser) without the panel hiding when it loses key status.
    func keepOpen<T>(_ body: () -> T) -> T { panelController.keepOpen(body) }

    /// Shows a file panel once this app is active. See `FilePanelTiming`.
    func presentFilePanel(_ show: @escaping () -> Void) {
        panelController.presentFilePanel(show)
    }

    func passwordTyped() { panelController.passwordTyped() }

    private func showUnderStatusItem() {
        guard let button = statusItem.button, let window = button.window else {
            panelController.toggle(.hotkey)
            return
        }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        panelController.toggle(.statusItem(rect))
    }

    // MARK: Windows

    func showLargeType(_ text: String) {
        largeTypeWindow?.close()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let maxWidth = max(visible.width - 48, 200)
        let maxHeight = max(visible.height - 48, 120)
        let size = LargeTypeMetrics.fit(text: text, maxWidth: maxWidth, maxHeight: maxHeight).size
        let window = LargeTypeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        // NSPanel hides while the app is inactive by default, and a pinned window can open this with another app in front.
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: LargeTypeView(text: text, maxWidth: maxWidth, maxHeight: maxHeight))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        window.makeKeyAndOrderFront(nil)
        largeTypeWindow = window
    }

    /// Shows `entry` in its own window. Pinning it again brings that window forward and leaves it in place.
    func showPinnedEntry(_ entry: VaultEntry) {
        switch pinnedWindowPlacement(openIDs: Array(pinnedAccounts.keys), id: entry.id) {
        case .orderFront:
            updatePinned(entry)
            raisePinned(entry.id)
        case .openNew(let index):
            let model = pinnedModel(for: entry, previous: nil)
            let panel = PinnedEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160))
            panel.applyWarmTitlebar()
            panel.delegate = self
            panel.title = model.title
            panel.contentView = FirstMouseHostingView(rootView: pinnedRoot(model))
            // A panel that cannot be key does not rise by itself. The window on top is the one the shortcuts copy.
            let id = entry.id
            panel.onMouseDown = { [weak self] in
                self?.raisePinned(id)
                self?.panelController.pinnedWindowClicked()
            }
            pinnedAccounts[entry.id] = PinnedAccount(panel: panel, model: model, snapshot: entry, contentHeight: 0)
            placePinned(panel, index: index)
            raisePinned(entry.id)
            syncPinnedHotKeys()
        }
    }

    private func raisePinned(_ id: UUID) {
        pinnedOrder = pinnedOrderRaising(id, in: pinnedOrder)
        pinnedAccounts[id]?.panel.orderFrontRegardless()
    }

    private func updatePinned(_ entry: VaultEntry) {
        guard var account = pinnedAccounts[entry.id] else { return }
        let model = pinnedModel(for: entry, previous: account.model)
        account.model = model
        account.snapshot = entry
        account.panel.title = model.title
        if let host = account.panel.contentView as? FirstMouseHostingView<DetailsView> {
            host.rootView = pinnedRoot(model)
        }
        pinnedAccounts[entry.id] = account
    }

    private func pinnedModel(for entry: VaultEntry, previous: DetailsModel?) -> DetailsModel {
        let model = DetailsModel(entry: entry, session: session, presentation: .pinned, done: {})
        if let previous {
            model.previousOpen = previous.previousOpen
            model.focusedRow = model.rowOrder.contains(previous.focusedRow) ? previous.focusedRow : model.focusedRow
            model.revealed = previous.revealed
        }
        return model
    }

    private func pinnedRoot(_ model: DetailsModel) -> DetailsView {
        DetailsView(model: model) { [weak self] height in
            self?.resizePinned(id: model.entryID, height: height)
        }
    }

    private func refreshPinnedEntry(_ entries: [VaultEntry]) {
        for id in Array(pinnedAccounts.keys) {
            guard let snapshot = pinnedAccounts[id]?.snapshot else { continue }
            guard let entry = activePinnedEntry(entries, id: id) else {
                pinnedAccounts[id]?.panel.close()
                continue
            }
            guard entry != snapshot else { continue }
            showPinnedEntry(entry)
        }
    }

    /// Keeps the title bar where the user put it while the content grows or shrinks.
    private func resizePinned(id: UUID, height: CGFloat) {
        guard var account = pinnedAccounts[id], height != account.contentHeight else { return }
        account.contentHeight = height
        let panel = account.panel
        let oldMaxY = panel.frame.maxY
        panel.setContentSize(NSSize(width: 400, height: height))
        var frame = panel.frame
        frame.origin.y += oldMaxY - frame.maxY
        panel.setFrame(frame, display: true)
        pinnedAccounts[id] = account
    }

    private func placePinned(_ panel: NSPanel, index: Int) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = pinnedWindowOrigin(
            visibleMaxX: visible.maxX,
            visibleMaxY: visible.maxY,
            size: panel.frame.size,
            index: index
        )
        panel.setFrameOrigin(origin)
    }

    /// The item editor is a detached window; the panel hides while it is open.
    private func editingChanged(_ entry: VaultEntry?) {
        guard let entry else {
            editorWindow?.close()
            editorWindow = nil
            return
        }
        if editorWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.applyWarmTitlebar()
            window.contentView = NSHostingView(rootView: EditorView(session: session))
            window.delegate = self
            window.center()
            editorWindow = window
        }
        // A Chrome login being saved is new to the database but already has a name.
        editorWindow?.title = session.editingIsNew && entry.title.isEmpty ? "New Item" : "Edit \(entry.title)"
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens Preferences; with `section`, scrolled to it.
    func showPreferences(at section: PreferencesSection? = nil) {
        preferencesNavigator.target = section
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.styleMask.insert(.resizable)
            window.title = "PasswordPie Preferences"
            window.applyWarmTitlebar()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(session: session, navigator: preferencesNavigator, bridge: bridge))
            window.setContentSize(NSSize(width: 560, height: 800))
            window.contentMinSize = NSSize(width: 560, height: 480)
            if let screen = NSScreen.main {
                let height = min(800, screen.visibleFrame.height - 60)
                window.setContentSize(NSSize(width: 560, height: height))
            }
            window.delegate = self
            window.center()
            preferencesWindow = window
        }
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    /// Starts finding out who has Premium. A locked code opens the Premium window, and Premium arriving closes it.
    private func wirePremium() {
        let premium = session.premium
        premium.presentPaywall = { [weak self] in self?.showPaywall() }
        premium.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // After the published value lands: `hasPremium` reads the store, not the sink's argument.
                DispatchQueue.main.async {
                    guard premium.hasPremium, premium.activity.message == nil else { return }
                    self?.paywallWindow?.close()
                }
            }
            .store(in: &cancellables)
        session.premium.start()
        let waiting = pendingOpenURLs
        pendingOpenURLs = []
        openActivationLinks(waiting)
    }

    /// passwordpie.com opening `passwordpie://activate?…`, in both channels. Can arrive before launch has finished and
    /// `session` exists. Any other `passwordpie://` URL, such as the old `auth` callback, does nothing.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard session != nil else {
            pendingOpenURLs += urls
            return
        }
        openActivationLinks(urls)
    }

    private func openActivationLinks(_ urls: [URL]) {
        var handled = false
        for url in urls where session.premium.activate(url) { handled = true }
        guard handled else { return }
        // On the next turn of the run loop, so a link that launched the app finds launch finished.
        DispatchQueue.main.async { [weak self] in self?.showPaywall() }
    }

    func showPaywall() {
        if paywallWindow == nil {
            let host = NSHostingController(rootView: PaywallView(store: session.premium))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "PasswordPie Premium"
            window.applyWarmTitlebar()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            paywallWindow = window
        }
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        paywallWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Two-step QR codes from the extension

    /// A scan arrived. Locked: the panel opens on the unlock screen and the window follows the unlock.
    private func presentScan() {
        autoLock.registerActivity()
        if session.locked {
            scanWindow?.close()
            if panelController.isVisible { panelController.bringForward() } else { panelController.show(.hotkey) }
        } else {
            showScanWindow()
        }
    }

    /// The Add Two-Step Code window. It floats, so the code stays in view while it is typed into the browser.
    func showScanWindow() {
        if scanWindow == nil {
            let host = NSHostingController(rootView: OTPScanConfirmView(model: otpScan, session: session, premium: session.premium) { [weak self] in
                self?.scanWindow?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "Add Two-Step Code"
            window.applyWarmTitlebar()
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
            window.center()
            scanWindow = window
        }
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        scanWindow?.makeKeyAndOrderFront(nil)
    }

    /// Locking hides other items' names. A scan still waiting comes back after the unlock; a finished one is done.
    private func closeScanForLock() {
        if case .added = otpScan?.phase { otpScan.cancel() }
        guard let window = scanWindow else { return }
        closingScanForLock = true
        window.close()
        closingScanForLock = false
    }

    /// The accounts in a held batch, read-only, with one button that applies them.
    func showChromeBatchReview() {
        if chromeReviewWindow == nil {
            let host = NSHostingController(rootView: ChromeBatchReviewView(session: session) { [weak self] in
                self?.chromeReviewWindow?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "Passwords Changed in Chrome"
            window.applyWarmTitlebar()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            chromeReviewWindow = window
        }
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        chromeReviewWindow?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = AboutCopy.menuTitle
            window.applyWarmTitlebar()
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AboutView())
            host.sizingOptions = [.intrinsicContentSize]
            window.contentView = host
            window.layoutIfNeeded()
            let fitted = host.fittingSize
            if fitted.height > 80 {
                window.setContentSize(NSSize(width: 440, height: fitted.height))
            }
            window.delegate = self
            window.center()
            aboutWindow = window
        }
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === paywallWindow { paywallWindow = nil }
        if window === chromeReviewWindow { chromeReviewWindow = nil }
        if window === scanWindow {
            scanWindow = nil
            // The close button is Cancel. Locking only hides the window.
            if !closingScanForLock { otpScan.cancel() }
        }
        if window === editorWindow {
            editorWindow = nil
            if session.editing != nil { session.cancelEditing() }
        } else if window === preferencesWindow {
            preferencesWindow = nil
        } else if window === aboutWindow {
            aboutWindow = nil
        } else if let id = pinnedAccounts.first(where: { $0.value.panel === window })?.key {
            pinnedAccounts[id] = nil
            pinnedOrder.removeAll { $0 == id }
            syncPinnedHotKeys()
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image()
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    /// Left and right mouse-down toggle the panel; Option-click opens the settings menu instead.
    @objc private func statusClicked() {
        reregisterHotkey()
        if NSEvent.modifierFlags.contains(.option) {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        showUnderStatusItem()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show PasswordPie", action: #selector(showCenteredAction), keyEquivalent: "")
        menu.addItem(withTitle: "Preferences…", action: #selector(showPreferencesAction), keyEquivalent: ",")
        menu.addItem(withTitle: browserExtensionsMenuTitle, action: #selector(showBrowserExtensionsAction), keyEquivalent: "")
        menu.addItem(withTitle: session.locked ? "Locked" : "Lock Now", action: #selector(lockNow), keyEquivalent: "")
        let hotkey = NSMenuItem(
            title: hotKey == nil ? "\(session.hotKey.display) is not registered" : "Shortcut \(session.hotKey.display)",
            action: nil,
            keyEquivalent: ""
        )
        hotkey.isEnabled = false
        menu.addItem(hotkey)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func showCenteredAction() { panelController.show(.hotkey) }
    @objc private func lockNow() { session.lock() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showPreferencesAction() { showPreferences() }
    @objc private func showBrowserExtensionsAction() { showPreferences(at: .browserExtensions) }
    @objc private func showAboutAction() { showAbout() }

    /// Without a main menu a menu-bar-only app has no Edit commands, so ⌘V and friends do nothing in text fields.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: AboutCopy.menuTitle, action: #selector(showAboutAction), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferencesAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PasswordPie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: Global shortcut

    func unregisterHotkey() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = nil
        syncPinnedHotKeys()
    }

    /// Registers the configured shortcut again, replacing any earlier registration.
    func reregisterHotkey() {
        unregisterHotkey()
        registerHotkey()
    }

    #if DEBUG
    static func suppressesPreviewHotkey(_ environment: [String: String]) -> Bool {
        environment["PASSWORDPIE_PREFERENCES"] != nil
            || environment["PASSWORDPIE_ABOUT"] != nil
            || environment["PASSWORDPIE_PAYWALL"] != nil
            || environment["PASSWORDPIE_DISABLE_HOTKEY"] != nil
    }
    #endif

    private func registerHotkey() {
        #if DEBUG
        // Preview bundles have separate defaults, but Carbon shortcuts are system-wide.
        // Apply this at the shared registration boundary, including recorder completion.
        if Self.suppressesPreviewHotkey(ProcessInfo.processInfo.environment) {
            hotKeyStatus = "disabled in preview"
            return
        }
        #endif
        if hotKey != nil || session.recordingHotKey { return }
        installHotKeyHandlerIfNeeded()
        let config = session.hotKey
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: menuHotKeyID)
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
        }
        session.hotKeyActive = status == noErr
        #if DEBUG
        hotKeyStatus = "\(config.display) status \(status)"
        #endif
        syncPinnedHotKeys()
    }

    private func installHotKeyHandlerIfNeeded() {
        guard !hotKeyHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.signature == 0x50506965 {
                let id = hotKeyID.id
                DispatchQueue.main.async { AppDelegate.shared?.hotKeyPressed(id: id) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        hotKeyHandlerInstalled = installed == noErr
    }

    private func hotKeyPressed(id: UInt32) {
        if id == menuHotKeyID {
            toggleFromHotkey()
        } else if let shortcut = pinnedCopyShortcut(id: id) {
            copyFromPinnedHotKey(shortcut)
        }
    }

    /// The copy shortcuts belong to the system only while an account is pinned. Recording a new menu shortcut
    /// releases them so the recorder can see those keys.
    private func syncPinnedHotKeys() {
        pinnedHotKeys.forEach { UnregisterEventHotKey($0) }
        pinnedHotKeys = []
        #if DEBUG
        guard !Self.suppressesPreviewHotkey(ProcessInfo.processInfo.environment) else { return }
        #endif
        guard !pinnedAccounts.isEmpty, !session.recordingHotKey else { return }
        installHotKeyHandlerIfNeeded()
        for hotKey in pinnedCopyHotKeys(excluding: session.hotKey) {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKey.id)
            let status = RegisterEventHotKey(hotKey.config.keyCode, hotKey.config.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { pinnedHotKeys.append(ref) }
        }
    }

    /// While the menu is open it owns these keys, as it does when no account is pinned.
    private func copyFromPinnedHotKey(_ shortcut: QuickAccessShortcut) {
        if panelController.isVisible {
            _ = panelController.headerShortcut(shortcut)
            return
        }
        guard let id = pinnedOrder.last else { return }
        session.runCopyShortcut(shortcut, of: id)
    }

    // MARK: Debug hooks

    /// Screenshot and test hooks, compiled out of release builds.
    private func applyDebugHooks() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        reporter = StatusReporter { [weak self] in self?.statusSnapshot() ?? [:] }
        reporter?.start()
        if env["PASSWORDPIE_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if env["PASSWORDPIE_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["PASSWORDPIE_ABOUT"] != nil {
            showAbout()
            return
        }
        runPremiumScript(env["PASSWORDPIE_PREMIUM_SCRIPT"])
        if env["PASSWORDPIE_PAYWALL"] != nil {
            showPaywall()
            return
        }
        if env["PASSWORDPIE_PREFERENCES"] != nil {
            showPreferences()
            if let rawHeight = env["PASSWORDPIE_PREFERENCES_HEIGHT"], let height = Double(rawHeight), height.isFinite {
                preferencesWindow?.setContentSize(NSSize(width: 560, height: max(480, min(800, height))))
            }
            return
        }
        guard env["PASSWORDPIE_SHOW"] != nil else { return }
        if env["PASSWORDPIE_ANCHOR"] == "status" { showUnderStatusItem() } else { panelController.show(.hotkey) }
        applyUnlockedDebugHooks(env)
        #endif
    }

    #if DEBUG
    /// Screenshot hook: steps such as `buy-lifetime,restore,refresh` (App Store), 2.5 s apart, so the Premium flows can be
    /// recorded without synthetic clicks.
    private func runPremiumScript(_ script: String?) {
        guard let script else { return }
        let premium = session.premium
        Task { @MainActor in
            for step in script.split(separator: ",").map(String.init) {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                switch step {
                #if !PP_DIRECT
                case "buy-lifetime": await premium.purchase(.lifetime)
                case "buy-yearly": await premium.purchase(.yearly)
                case "restore": await premium.restore()
                #endif
                case "refresh": await premium.refresh(force: true)
                default: break
                }
            }
        }
    }

    /// Unlocking with `PASSWORDPIE_PASSWORD` finishes on a background task, so these wait for it instead of finding the panel still locked.
    private func applyUnlockedDebugHooks(_ env: [String: String]) {
        if session.locked {
            guard env["PASSWORDPIE_PASSWORD"] != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.applyUnlockedDebugHooks(env) }
            return
        }
        session.noteChromePanelShown()
        if let text = env["PASSWORDPIE_QUERY"] {
            panelController.header.searchField.stringValue = text
            panelController.headerSearchChanged(text)
        }
        if let hover = env["PASSWORDPIE_HOVER"] {
            // Each path component is hovered 1.2 s after the previous one, long enough for any hover delay.
            for (step, title) in hover.split(separator: "/").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + 1.2 * Double(step)) { [weak self] in
                    self?.panelController.menu.debugHover(title)
                }
            }
        }
        if let title = env["PASSWORDPIE_PIN"], let id = session.allEntries.first(where: { $0.title == title })?.id {
            session.pinEntry(id)
        }
        // `new` opens a new item's editor; anything else, the editor of the item with that title.
        if let title = env["PASSWORDPIE_EDIT"] {
            if title == "new" {
                session.newEntry()
            } else if let id = session.allEntries.first(where: { $0.title == title })?.id {
                session.edit(id)
            }
        }
        if env["PASSWORDPIE_REVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showChromeBatchReview() }
        }
        if let state = env["PASSWORDPIE_DETAILS"] {
            // After the hover above has opened the details.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.panelController.menu.debugDetails { model in
                    guard state.contains("previous") else { return }
                    model.previousOpen = true
                    if state.contains("focus"), let first = model.previous.first { model.focusedRow = .previous(first.id) }
                }
            }
        }
        if let path = env["PASSWORDPIE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panelController.menu.debugOpen(path: path.split(separator: "/").map(String.init))
            }
        }
        // An `otpauth://` link arrives as if the browser extension scanned it on `PASSWORDPIE_SCAN_ORIGIN`; with
        // `PASSWORDPIE_SCAN_ADD`, Add is pressed a second later, so the Added state can be captured.
        if let link = env["PASSWORDPIE_SCAN"], case .scanned(let scanned) = OTPInputScanner.scan(text: link) {
            otpScan.receive(scanned, origin: env["PASSWORDPIE_SCAN_ORIGIN"], browser: nil)
            if env["PASSWORDPIE_SCAN_ADD"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.otpScan.add() }
            }
        }
    }

    private func statusSnapshot() -> [String: Any] {
        guard let panelController else { return [:] }
        let panel = panelController.panel
        let menu = panelController.menu
        let key = NSApp.keyWindow
        var keyKind = "none"
        if panel.isKeyWindow { keyKind = "panel" } else if let key {
            keyKind = menu.auxiliaryWindows.contains { $0 === key } ? "menu-child" : String(describing: type(of: key))
        }
        let responder = panel.firstResponder
        var responderName = responder.map { String(describing: type(of: $0)) } ?? "nil"
        var searchText = panelController.header.searchField.stringValue
        var passwordLength = -1
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
            responderName = String(describing: type(of: field)) + "(field editor)"
            if field is NSSecureTextField { passwordLength = field.stringValue.count } else { searchText = field.stringValue }
        }
        return [
            "visible": panel.isVisible,
            "locked": session.locked,
            "keyWindow": keyKind,
            "panelIsKey": panel.isKeyWindow,
            "firstResponder": responderName,
            "searchText": searchText,
            "passwordLength": passwordLength,
            "menuDepth": menu.levels.count,
            "selectedRow": menu.selectedTitle ?? NSNull(),
            "selectedEntry": menu.currentEntryID?.uuidString ?? NSNull(),
            "popoverOpen": menu.popoverIsOpen,
            "detailsFocus": menu.focusedFieldLabel ?? NSNull(),
            "panelWindow": panel.isVisible ? panel.windowNumber : NSNull(),
            "popoverWindow": menu.popoverWindowNumber ?? NSNull(),
            "reviewWindow": chromeReviewWindow?.windowNumber ?? NSNull(),
            "preferencesWindow": preferencesWindow?.isVisible == true ? preferencesWindow?.windowNumber ?? NSNull() : NSNull(),
            "editorWindow": editorWindow?.isVisible == true ? editorWindow?.windowNumber ?? NSNull() : NSNull(),
            "scanWindow": scanWindow?.isVisible == true ? scanWindow?.windowNumber ?? NSNull() : NSNull(),
            "scanPhase": otpScan.map { String(describing: $0.phase) } ?? NSNull(),
            "chromeSync": session.chromeSyncEnabled,
            "chromeStatus": session.chromeStatus,
            "chromeBadges": session.chromeBadgeIDs.count,
            "chromeBatch": session.chromeBatch?.summary ?? NSNull(),
            "chromeFailures": session.chromeUpdateFailures.count,
            "rootRows": menu.root.rows.map(\.title),
            "appActive": NSApp.isActive,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "panelFrame": NSStringFromRect(panel.frame),
            "systemIdleSeconds": SystemIdle.seconds(),
            "hotkey": hotKeyStatus,
            "chromeConnected": bridge?.chromeConnected ?? false,
            "chromeProfiles": bridge?.chromeProfiles ?? 0,
            "chromeInFront": bridge?.chromeInFront ?? false,
            "pageURL": BrowserBridge.browser(forBundleID: panelController.targetApp?.bundleIdentifier).flatMap { bridge?.pageURL(for: $0, inFront: panelController.targetInFront) } ?? NSNull(),
            "safariEnabled": bridge?.safariEnabled ?? false,
            "canFill": BridgeBrowser.allCases.filter { bridge?.canFill(in: $0) == true }.map(\.rawValue),
            "extensionBanner": panelController.shownBanner?.title ?? NSNull(),
            "hasPremium": session.premium.hasPremium,
            "premiumMessage": session.premium.activity.message ?? NSNull(),
            "paywallWindow": paywallWindow?.isVisible == true ? paywallWindow?.windowNumber ?? NSNull() : NSNull()
        ]
    }
    #endif
}
