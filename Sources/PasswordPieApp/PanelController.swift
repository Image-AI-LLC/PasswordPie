import AppKit
import Combine
import PasswordPieCore
import SwiftUI

/// Borderless panels refuse key status by default, which would leave the fields unusable.
final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onDragEnded: (() -> Void)?
    private var originAtMouseDown: NSPoint?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// The search and master-password fields share this editor, and both keep the brand caret and selection.
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let text = editor as? NSTextView {
            text.insertionPointColor = MenuPalette.caret
            text.selectedTextAttributes = [.backgroundColor: MenuPalette.textSelection]
        }
        return editor
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { originAtMouseDown = frame.origin }
        super.sendEvent(event)
        if event.type == .leftMouseUp, let start = originAtMouseDown {
            originAtMouseDown = nil
            if start != frame.origin { onDragEnded?() }
        }
    }
}

/// The blurred background. It lays out the header (top) and the menu list (below it) itself, so the
/// window's animated resize never leaves them stale.
final class PanelContentView: NSVisualEffectView {
    weak var header: NSView?
    weak var list: NSView?
    /// "Add Chrome Extension…", above the header. Zero height when hidden.
    weak var banner: NSView?
    var bannerHeight: CGFloat = 0 {
        didSet { if oldValue != bannerHeight { needsLayout = true } }
    }
    /// "12 passwords changed in Chrome", under the search field. Zero height when hidden.
    weak var batchRow: NSView?
    var batchRowHeight: CGFloat = 0 {
        didSet { if oldValue != batchRowHeight { needsLayout = true } }
    }

    override func layout() {
        super.layout()
        banner?.frame = NSRect(x: 0, y: bounds.height - bannerHeight, width: bounds.width, height: bannerHeight)
        banner?.isHidden = bannerHeight == 0
        let top = bounds.height - bannerHeight
        header?.frame = NSRect(x: 0, y: top - HeaderView.height, width: bounds.width, height: HeaderView.height)
        let belowHeader = top - HeaderView.height
        batchRow?.frame = NSRect(x: 0, y: belowHeader - batchRowHeight, width: bounds.width, height: batchRowHeight)
        batchRow?.isHidden = batchRowHeight == 0
        list?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(belowHeader - batchRowHeight, 0))
    }
}

/// When each step of the lock scene starts, in seconds after the vault locks. See `docs/UX.md`, "Lock".
struct LockScene: Equatable {
    /// The menu folds into the locked card.
    var fold: TimeInterval = 0.2
    /// The card is up; the logo settles and the padlock clicks.
    var settle: TimeInterval = 0.22
    /// The card starts to lift and fade out.
    var fadeStart: TimeInterval = 0.9
    var fadeDuration: TimeInterval = 0.3
    /// How far the card rises as it fades.
    static let lift: CGFloat = 6
}

/// Where the panel opens from.
enum PanelAnchor {
    /// Hangs from the left edge of the status item, flush under the menu bar.
    case statusItem(NSRect)
    case hotkey
}

/// Owns the panel: placement, the header, the swap between lock screen and menu, hide rules, and the unlock animation.
@MainActor
final class PanelController: NSObject, MenuHost, HeaderDelegate {
    let session: VaultSession
    let panel: KeyPanel
    let menu: MenuController
    let header = HeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: HeaderView.height))
    let lockModel = LockModel()
    let banner = ExtensionBannerView(frame: NSRect(x: 0, y: 0, width: 300, height: ExtensionBannerView.height))
    let batchRow = ChromeBatchRowView(frame: NSRect(x: 0, y: 0, width: 300, height: ChromeBatchRowView.height))
    /// What the panel shows in the banner: an extension the front browser is missing. Nil hides it.
    private(set) var shownBanner: ExtensionBanner?
    /// The browser extensions. Set once by the app delegate.
    var bridge: BrowserBridge? {
        didSet { bindBridge() }
    }
    private let container = NSView()
    private let effect: PanelContentView = {
        let view = PanelContentView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.applyMenuBackdrop()
        return view
    }()
    let lockHost: NSHostingView<DoorsView>
    private var cancellables = Set<AnyCancellable>()
    private var attached = false
    private var keepOpenDepth = 0
    /// True after the first file panel has been scheduled. The first one has to wait a turn.
    private var hasPresentedFilePanel = false
    /// A second click before the deferred panel appears must not open another one.
    private var filePanelQueued = false
    private var animatingLock = false
    /// The menu's width when ⌘L locked it: the locked card keeps it.
    private var lockCardWidth = Metrics.width
    /// True while the lock scene plays, from the lock until the panel has faded out.
    private(set) var lockingOut = false
    /// Bumped when a lock scene ends early, so its remaining steps do nothing.
    private var sceneGeneration = 0
    /// Replaced by tests, so the scene takes milliseconds and plays no sound.
    var lockScene = LockScene()
    var playSound: (LockSound) -> Void = { LockSoundPlayer.shared.play($0) }
    private var previousApp: NSRunningApplication?
    private var topLeft = NSPoint.zero
    private var contentWidth = MenuGeometry.rootWidth
    private var contentHeight: CGFloat = 0
    private var touchIDOffered = false
    /// True while the system Touch ID sheet is up. That sheet is another process and must not close this panel.
    private var touchIDPromptOpen = false
    private let positionKey = "panelTopLeft"
    private var recall = QuickAccessRecall()
    /// Replaced by tests, so the 10 seconds of `recall` need no real wait.
    var now: () -> Date = Date.init
    /// Debug builds can keep the panel open when focus moves elsewhere, so screenshots are stable.
    private var autoHideEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PASSWORDPIE_STICKY"] == nil
        #else
        return true
        #endif
    }

    var rootWindow: NSWindow { panel }
    /// The app that was in front when the panel opened: where Fill goes.
    var targetApp: NSRunningApplication? { previousApp }
    var isVisible: Bool { panel.isVisible }

    var onPanelHidden: (() -> Void)?

    init(session: VaultSession) {
        self.session = session
        menu = MenuController(session: session)
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.lockCardHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        lockHost = NSHostingView(rootView: DoorsView(session: session, lock: lockModel))
        super.init()
        buildPanel()
        menu.host = self
        header.delegate = self
        bind()
    }

    // MARK: Construction

    private func buildPanel() {
        panel.level = menuWindowLevel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onEscape = { [weak self] in self?.closeAsDone() }
        panel.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        panel.onDragEnded = { [weak self] in self?.dragEnded() }
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)

        container.frame = NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.lockCardHeight)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        effect.layer?.cornerRadius = Self.menuRadius
        container.addSubview(effect)

        let scroll = menu.root.scroll
        scroll.autoresizingMask = []
        header.autoresizingMask = []
        effect.addSubview(scroll)
        effect.addSubview(header)
        effect.addSubview(banner)
        effect.addSubview(batchRow)
        effect.batchRow = batchRow
        effect.header = header
        effect.list = scroll
        effect.banner = banner
        banner.onClick = { [weak self] in self?.installBannerExtension() }
        batchRow.onReview = { [weak self] in
            self?.hide(refocusPrevious: false)
            AppDelegate.shared?.showChromeBatchReview()
        }
        batchRow.onDismiss = { [weak self] in self?.session.dismissChromeBatch() }
        session.$chromeBatch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batch in self?.chromeBatchChanged(batch) }
            .store(in: &cancellables)
        menu.siteSection = { [weak self] in self?.siteSectionRows() ?? [] }

        lockHost.frame = container.bounds
        lockHost.autoresizingMask = [.width, .height]
        lockHost.wantsLayer = true
        lockHost.layer?.cornerRadius = Self.lockRadius
        lockHost.layer?.masksToBounds = true
        container.addSubview(lockHost)
        lockHost.layoutSubtreeIfNeeded()
        applyLayout(locked: session.locked)
    }

    private func bind() {
        session.$locked
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] locked in self?.lockedChanged(to: locked) }
            .store(in: &cancellables)
        session.$searchAll
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menu.refresh() } }
            .store(in: &cancellables)
        // The session builds the menu and the search index in the background; each finished piece refreshes the list it feeds.
        session.$topLevelRows
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menu.catalogUpdated(topLevel: true) } }
            .store(in: &cancellables)
        session.$searchIndex
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menu.catalogUpdated(topLevel: false) } }
            .store(in: &cancellables)
        session.$indexing
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.menu.catalogUpdated(topLevel: false) } }
            .store(in: &cancellables)
        session.$creating
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyLayout(locked: self?.session.locked ?? true) } }
            .store(in: &cancellables)
        // The lock form is as tall as what it holds: a long error, the Touch ID row or the key-file row resize it.
        // Each stream skips its own current value, so adding one cannot shift what is skipped.
        Publishers.Merge4(session.$message.dropFirst().map { _ in () }, session.$touchIDAvailable.dropFirst().map { _ in () },
                          session.$keyFileName.dropFirst().map { _ in () }, session.$databaseURL.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.lockFormChanged() } }
            .store(in: &cancellables)
        session.$touchIDBusy
            .removeDuplicates()
            .sink { [weak self] busy in
                guard let self else { return }
                if busy {
                    self.touchIDPromptOpen = true
                    return
                }
                guard self.touchIDPromptOpen else { return }
                self.restoreLockPanelAfterTouchID()
            }
            .store(in: &cancellables)
        session.$unlocking
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] busy in
                guard let self, self.panel.isVisible else { return }
                // The form is dimmed and disabled while the database decrypts; no keystroke should land in it.
                if busy {
                    self.panel.makeFirstResponder(nil)
                } else {
                    // A failed unlock brings the form back. The success path is handled by the lock animation.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session.locked, !self.touchIDPromptOpen else { return }
                        self.focusInitialField()
                    }
                }
            }
            .store(in: &cancellables)
        session.onWrongPassword = { [weak self] in self?.wrongPassword() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    // MARK: Showing and hiding

    /// The shortcut during the lock scene keeps the lock screen up, ready for the password.
    func toggle(_ anchor: PanelAnchor) {
        if panel.isVisible, !lockingOut { hide() } else { show(anchor) }
    }

    /// The panel is open: make it key again, as the click that asked for it went to another app.
    func bringForward() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func show(_ anchor: PanelAnchor) {
        // The store does not always announce a refund, and a menu-bar app rarely comes forward. Opening the menu is the next chance to ask.
        Task { [session] in await session.premium.refresh() }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        // Before the menu is built: the site group at its top comes from what the bridge knows about the front tab.
        bridge?.panelWillShow(over: previousApp)
        updateBanner()
        // Within 10 seconds of closing, the search and the selected account come back. Otherwise: empty search,
        // initial menu, first row selected. Locking forgets it, so a locked panel never has one.
        let recalled = session.locked ? nil : recall.take(at: now())
        header.searchField.stringValue = recalled?.searchText ?? ""
        header.showsSeparator = true
        touchIDOffered = false
        // The shortcut during the lock scene grows the card into the lock form instead of jumping.
        let growing = lockingOut && panel.isVisible
        endLockScene()
        animatingLock = false
        lockModel.turned = false
        lockModel.open = false
        if !session.locked {
            if let recalled { menu.restore(recalled.place) } else { menu.reset() }
        }
        applyLayout(locked: session.locked, animated: growing)

        // A test process can have no screens. Still compare Chrome; there is nowhere to place the panel.
        guard let screen = screen(for: anchor) else {
            session.noteChromePanelShown()
            return
        }
        var origin: NSPoint
        switch anchor {
        case .statusItem(let rect):
            attached = true
            origin = NSPoint(x: rect.minX, y: screen.visibleFrame.maxY)
        case .hotkey:
            attached = false
            origin = savedTopLeft() ?? MenuGeometry.centeredTopLeft(screenFrame: screen.frame)
        }
        topLeft = origin
        effect.layer?.maskedCorners = menuMaskedCorners
        panel.isMovableByWindowBackground = !attached
        setFrame(animated: growing, screen: screen)

        // Activation is a request that macOS may decline while another app is frontmost; the panel is
        // non-activating, so it still becomes key and the first responder below receives the keys.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        focusInitialField()
        if recalled != nil {
            menu.reopenSubmenus()
            // Selected, so the first typed letter starts a new search.
            header.searchField.currentEditor()?.selectAll(nil)
        }
        panel.invalidateShadow()
        // Compare Chrome after the menu is up. A locked panel returns immediately, so the keychain prompt waits for unlock.
        session.noteChromePanelShown()
        if session.locked, session.touchIDAvailable, !session.creating, !touchIDOffered {
            touchIDOffered = true
            session.unlockWithTouchID()
        }
    }

    /// The search field when unlocked, the master-password field when locked.
    func focusInitialField() {
        // The lock scene shows the locked card, not the form; nothing may take the keys until it ends.
        guard !lockingOut else { return }
        if session.locked {
            // While the database decrypts the form is dimmed and disabled; the end of unlocking focuses it again on failure.
            guard !session.unlocking else {
                panel.makeFirstResponder(nil)
                return
            }
            lockHost.layoutSubtreeIfNeeded()
            if let field = lockModel.fields.primary {
                panel.makeFirstResponder(field)
            } else {
                // The hosting view creates its field lazily; try again on the next pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panel.isVisible, let field = self.lockModel.fields.primary else { return }
                    self.panel.makeFirstResponder(field)
                }
            }
        } else {
            panel.makeFirstResponder(header.searchField)
        }
    }

    func hide(refocusPrevious: Bool = true) {
        guard panel.isVisible else { return }
        // Before anything closes: the open levels and the field editor are what gets remembered.
        if !session.locked, !animatingLock {
            recall.remember(QuickAccessSnapshot(searchText: searchText, place: menu.place), at: now())
        }
        menu.closeAll()
        panel.orderOut(nil)
        endLockScene()
        header.searchField.stringValue = ""
        // A half-typed master password must not wait in the field for whoever opens the panel next.
        if session.locked {
            session.passwordDraft = ""
            session.confirmDraft = ""
        }
        if refocusPrevious, NSApp.isActive, let previous = previousApp, !previous.isTerminated {
            previous.activate()
        }
        onPanelHidden?()
    }

    /// Escape closes for good: the next showing starts empty, however soon it comes.
    private func closeAsDone() {
        hide()
        recall.forget()
    }

    /// Runs `body` (a modal file chooser, a menu) without the panel hiding when it loses key status.
    func keepOpen<T>(_ body: () -> T) -> T {
        keepOpenDepth += 1
        defer {
            keepOpenDepth -= 1
            if panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
                focusInitialField()
            }
        }
        return body()
    }

    /// Presents a file panel after the app is active.
    ///
    /// This panel is non-activating, so the app is often inactive when Open Database
    /// is clicked. The first open panel built then selects the current folder and
    /// ignores clicks. The modal session activates the app, which is why cancelling
    /// and opening again works. Activation is requested first, and the panel is
    /// created on the next turn.
    func presentFilePanel(_ show: @escaping () -> Void) {
        guard !filePanelQueued else { return }
        let deferral = FilePanelTiming.deferPresentation(
            appIsActive: NSApp.isActive,
            hasPresentedFilePanel: hasPresentedFilePanel
        )
        hasPresentedFilePanel = true
        if !deferral {
            keepOpen(show)
            return
        }
        filePanelQueued = true
        keepOpenDepth += 1
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.filePanelQueued = false
            self.keepOpen(show)
            self.keepOpenDepth -= 1
        }
    }

    /// Touch ID cancel returns focus to another app. Stay open until the password field is key again.
    private func restoreLockPanelAfterTouchID() {
        DispatchQueue.main.async { [weak self] in
            self?.focusLockPanelIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.focusLockPanelIfNeeded()
                self?.touchIDPromptOpen = false
            }
        }
    }

    private func focusLockPanelIfNeeded() {
        guard panel.isVisible, session.locked else { return }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        focusInitialField()
    }

    /// A pinned window never takes key, so a click on it does not reach `panelResignedKey`.
    func pinnedWindowClicked() {
        guard PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: keepOpenDepth,
            touchIDBusy: touchIDPromptOpen,
            recordingHotKey: session.recordingHotKey,
            autoHideEnabled: autoHideEnabled
        ) else { return }
        hide()
    }

    @objc private func panelResignedKey() {
        guard PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: keepOpenDepth,
            touchIDBusy: touchIDPromptOpen,
            recordingHotKey: session.recordingHotKey,
            autoHideEnabled: autoHideEnabled
        ) else { return }
        // Resign key closes the panel on the next pass, unless a child window, the popover or Large Type took key.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, self.keepOpenDepth == 0, NSApp.modalWindow == nil else { return }
            guard PanelPresence.hidesOnFocusLoss(
                keepOpenDepth: self.keepOpenDepth,
                touchIDBusy: self.touchIDPromptOpen,
                recordingHotKey: self.session.recordingHotKey,
                autoHideEnabled: self.autoHideEnabled
            ) else { return }
            if let key = NSApp.keyWindow, self.isAuxiliary(key) { return }
            self.hide(refocusPrevious: false)
        }
    }

    private func isAuxiliary(_ window: NSWindow) -> Bool {
        window === AppDelegate.shared?.largeTypeWindow || menu.auxiliaryWindows.contains { $0 === window }
    }

    @objc private func appActivated(_ note: Notification) {
        guard panel.isVisible, PanelPresence.hidesOnFocusLoss(
            keepOpenDepth: keepOpenDepth,
            touchIDBusy: touchIDPromptOpen,
            recordingHotKey: session.recordingHotKey,
            autoHideEnabled: autoHideEnabled
        ) else { return }
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        hide(refocusPrevious: false)
    }

    // MARK: Layout and placement

    private func screen(for anchor: PanelAnchor) -> NSScreen? {
        switch anchor {
        case .statusItem(let rect):
            return NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens.first
        case .hotkey:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    private var currentScreen: NSScreen? {
        panel.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func applyLayout(locked: Bool, animated: Bool = false) {
        lockHost.isHidden = !(locked || animatingLock)
        effect.isHidden = locked && !animatingLock
        if locked, !animatingLock, let screen = currentScreen { setFrame(animated: animated, screen: screen) }
    }

    /// What the lock screen shows right now; its height is the locked panel's.
    var lockPresentation: LockScreenPresentation {
        LockScreenPresentation(session: session, locking: lockModel.locking)
    }

    private func lockFormChanged() {
        guard session.locked, !lockingOut, !animatingLock, panel.isVisible, let screen = currentScreen else { return }
        setFrame(animated: true, screen: screen)
    }

    private var panelSize: NSSize {
        if lockingOut {
            return NSSize(width: lockCardWidth, height: Metrics.lockCardHeight)
        }
        if session.locked || animatingLock {
            return NSSize(width: Metrics.width, height: LockScreenContent.fittedHeight(lockPresentation))
        }
        let visible = currentScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = MenuGeometry.confinement(visibleFrame: visible)
        let top = HeaderView.height + effect.bannerHeight + effect.batchRowHeight
        let height = top + min(max(contentHeight, MenuMetrics.minimumListHeight), max(area.height - top, 0))
        return NSSize(width: max(contentWidth, MenuGeometry.rootWidth), height: height)
    }

    private func setFrame(animated: Bool, screen: NSScreen) {
        let area = MenuGeometry.confinement(visibleFrame: screen.visibleFrame)
        let frame = MenuGeometry.frame(topLeft: topLeft, size: panelSize, in: area)
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.075
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        effect.needsLayout = true
        menu.root.list.setFrameSize(NSSize(width: frame.width, height: menu.root.list.contentHeight))
        // An animated frame settles later and lays out as it goes. Otherwise the list is final as of now, for whatever is placed against it next.
        if !animated { effect.layoutSubtreeIfNeeded() }
        panel.invalidateShadow()
    }

    func menuRootNeedsLayout(contentWidth: CGFloat, contentHeight: CGFloat) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        header.showsSeparator = headerSeparatorVisible
        guard !session.locked, !animatingLock, let screen = currentScreen else { return }
        setFrame(animated: panel.isVisible && !menu.isReopeningSubmenus, screen: screen)
    }

    /// The line under the search field, while it is empty. A group header right below draws its own line, and two would sit 5 pt apart.
    private var headerSeparatorVisible: Bool {
        menu.query.isEmpty && menu.root.rows.first?.kind != .header
    }

    // MARK: Browser extension

    private func bindBridge() {
        guard let bridge else { return }
        bridge.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.bridgeStateChanged() } }
            .store(in: &cancellables)
        bridge.onPageChanged = { [weak self] in
            guard let self, self.panel.isVisible, !self.session.locked else { return }
            self.menu.siteSectionChanged()
        }
    }

    /// The banner follows the front browser's extension state while the panel is open, so it goes once the extension connects.
    private func bridgeStateChanged() {
        guard panel.isVisible else { return }
        updateBanner()
        if !session.locked, !animatingLock, let screen = currentScreen { setFrame(animated: true, screen: screen) }
    }

    private func updateBanner() {
        shownBanner = session.locked ? nil : bridge?.banner(for: previousApp)
        if let shownBanner { banner.show(shownBanner) }
        effect.bannerHeight = shownBanner == nil ? 0 : ExtensionBannerView.height
    }

    /// A row in the panel, not a window: the rest of the panel keeps working while the question waits.
    private func chromeBatchChanged(_ batch: ChromeBatch?) {
        batchRow.show(batch?.summary)
        effect.batchRowHeight = batch == nil ? 0 : ChromeBatchRowView.height
        if panel.isVisible, !session.locked, !animatingLock, let screen = currentScreen { setFrame(animated: true, screen: screen) }
    }

    private func installBannerExtension() {
        guard let shownBanner, let bridge else { return }
        hide(refocusPrevious: false)
        bridge.install(shownBanner)
    }

    /// The front browser's site and its accounts, for the top of the initial menu.
    private func siteSectionRows() -> [MenuRow] {
        guard let bridge, let browser = BrowserBridge.browser(forBundleID: previousApp?.bundleIdentifier),
              let page = bridge.pageURL(for: browser), let site = BrowserSite(url: page) else { return [] }
        let entries = SiteSuggestions.entries(session.allEntries, pageURL: page, lastUsed: session.lastUsedMap)
        return MenuBuilder.siteRows(site: site.key, entries: entries, sources: session.entrySources)
    }

    // MARK: Dragging

    private func savedTopLeft() -> NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let point = NSPointFromString(text)
        return NSScreen.screens.contains { $0.frame.contains(point) } ? point : nil
    }

    private func dragEnded() {
        menu.closeAll()
        guard !attached, let screen = currentScreen else { return }
        let origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let centered = MenuGeometry.centeredTopLeft(screenFrame: screen.frame)
        topLeft = origin
        if MenuGeometry.shouldSnapToCenter(topLeft: origin, centered: centered) {
            UserDefaults.standard.removeObject(forKey: positionKey)
            topLeft = centered
            setFrame(animated: true, screen: screen)
        } else {
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: positionKey)
        }
    }

    // MARK: Lock and unlock

    private func lockedChanged(to locked: Bool) {
        updateBanner()
        if locked {
            recall.forget()
            lockAnimation()
        } else {
            // An unlock can land while the lock scene still plays (Open Database… then a quick Touch ID).
            // End the scene first, so the panel is opaque again and its fade cannot hide the open menu.
            endLockScene()
            unlockAnimation()
        }
    }

    /// The locked card fades in over the menu while the panel folds to it, the logo settles as the padlock clicks,
    /// and the card lifts and fades out. A lock with the panel closed is silent.
    private func lockAnimation() {
        sceneGeneration &+= 1
        guard panel.isVisible else {
            applyLayout(locked: true)
            return
        }
        menu.closeAll()
        animatingLock = true
        lockingOut = true
        lockCardWidth = panel.frame.width
        lockModel.locking = true
        lockModel.open = true
        lockModel.turned = true
        // The locked card replaces the form; no keystroke should land in it.
        panel.makeFirstResponder(nil)
        applyLayout(locked: true)
        // The card starts with the menu's corners, so none of the menu shows past it.
        lockHost.layer?.cornerRadius = Self.menuRadius
        // The backdrop follows the card, so the menu's square top corners do not show through its rounded ones.
        effect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let scene = lockScene
        sceneStep(after: 0) { controller in
            controller.lockModel.open = false
            controller.foldIntoCard(duration: scene.fold)
        }
        sceneStep(after: scene.settle) {
            $0.lockModel.turned = false
            $0.playSound(.lock)
        }
        sceneStep(after: scene.fadeStart) { controller in
            let generation = controller.sceneGeneration
            var lifted = controller.panel.frame
            lifted.origin.y += LockScene.lift
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = scene.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                controller.panel.animator().alphaValue = 0
                controller.panel.animator().setFrame(lifted, display: true)
            }, completionHandler: { [weak controller] in
                MainActor.assumeIsolated {
                    guard let controller, controller.sceneGeneration == generation else { return }
                    controller.hide()
                }
            })
        }
    }

    /// The panel folds from the menu's frame to the locked card, from the same top-left corner, as both layers round
    /// their corners from the menu's to the card's.
    private func foldIntoCard(duration: TimeInterval) {
        guard let screen = currentScreen else { return }
        let area = MenuGeometry.confinement(visibleFrame: screen.visibleFrame)
        let corner = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let card = MenuGeometry.frame(topLeft: corner, size: panelSize, in: area)
        for layer in [lockHost.layer, effect.layer].compactMap({ $0 }) {
            let rounding = CABasicAnimation(keyPath: "cornerRadius")
            rounding.fromValue = layer.cornerRadius
            rounding.toValue = Self.lockRadius
            rounding.duration = duration
            rounding.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.cornerRadius = Self.lockRadius
            layer.add(rounding, forKey: "cornerRadius")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(card, display: true)
        }
        panel.invalidateShadow()
    }

    /// An attached menu hangs from the status item, so only its bottom corners are rounded.
    private var menuMaskedCorners: CACornerMask {
        attached
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    static let menuRadius: CGFloat = 5
    static let lockRadius: CGFloat = 16

    /// Runs one step of the current lock scene, unless the scene has ended since.
    private func sceneStep(after delay: TimeInterval, _ body: @escaping (PanelController) -> Void) {
        let generation = sceneGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lockingOut, self.sceneGeneration == generation else { return }
            body(self)
        }
    }

    /// Stops the lock scene where it is: the panel is opaque again and the form comes back.
    private func endLockScene() {
        guard lockingOut else { return }
        sceneGeneration &+= 1
        lockingOut = false
        lockModel.locking = false
        animatingLock = false
        lockModel.open = false
        lockModel.turned = false
        // A fold still in flight must not hold the presentation at a radius the model no longer has.
        lockHost.layer?.removeAnimation(forKey: "cornerRadius")
        effect.layer?.removeAnimation(forKey: "cornerRadius")
        lockHost.layer?.cornerRadius = Self.lockRadius
        effect.layer?.cornerRadius = Self.menuRadius
        effect.layer?.maskedCorners = menuMaskedCorners
        // A zero-length animation replaces a fade still in flight, which would otherwise finish at 0.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        // Still on screen, the card grows into the lock form; otherwise the next showing places it.
        applyLayout(locked: session.locked, animated: panel.isVisible)
    }

    /// The mark pulses, then the form fades for 0.3 s before the menu takes over.
    private func unlockAnimation() {
        header.searchField.stringValue = ""
        menu.reset()
        guard panel.isVisible else {
            applyLayout(locked: false)
            return
        }
        sceneGeneration &+= 1
        let generation = sceneGeneration
        // Unlocking in the open panel is the moment Chrome may ask. The menu stays up while the read runs.
        session.noteChromePanelShown()
        animatingLock = true
        effect.isHidden = false
        header.isHidden = false
        menu.root.scroll.isHidden = false
        lockHost.isHidden = false
        panel.makeFirstResponder(nil)
        lockModel.turned = true
        playSound(.unlock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.sceneGeneration == generation else { return }
            self.lockModel.open = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.sceneGeneration == generation else { return }
                self.animatingLock = false
                self.applyLayout(locked: false)
                if let screen = self.currentScreen { self.setFrame(animated: true, screen: screen) }
                self.panel.makeFirstResponder(self.header.searchField)
            }
        }
    }

    private func wrongPassword() {
        shake()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.session.locked else { return }
            self.session.message = "Incorrect password. Please try again."
            self.lockModel.fields.primary?.selectText(nil)
        }
    }

    /// Window shake: 8 px, three swings, 0.5 s.
    private func shake() {
        guard panel.isVisible else { return }
        let home = panel.frame.origin
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = (CACurrentMediaTime() - start) / 0.5
                if t >= 1 {
                    self.panel.setFrameOrigin(home)
                    timer.invalidate()
                } else {
                    self.panel.setFrameOrigin(NSPoint(x: home.x + 8 * sin(t * 3 * 2 * .pi), y: home.y))
                }
            }
        }
    }

    func passwordTyped() {
        if !session.message.isEmpty { session.message = "" }
    }

    // MARK: Header actions

    func headerSearchChanged(_ text: String) {
        menu.setQuery(text)
        header.showsSeparator = headerSeparatorVisible
    }

    func headerKey(_ key: MenuKey) -> Bool {
        guard !session.locked else { return false }
        return menu.handle(key)
    }

    func headerShortcut(_ shortcut: QuickAccessShortcut) -> Bool {
        guard !session.locked else { return true }
        runQuickAccess(shortcut)
        return true
    }

    func headerEscape() {
        switch quickAccessEscape(searchIsEmpty: searchText.isEmpty) {
        case .clearSearch:
            header.searchField.stringValue = ""
            header.searchField.currentEditor()?.string = ""
            headerSearchChanged("")
        case .close:
            closeAsDone()
        }
    }

    /// The field editor holds the text while the search field is focused.
    private var searchText: String {
        header.searchField.currentEditor()?.string ?? header.searchField.stringValue
    }

    func headerLogoClicked(_ view: NSView) {
        let menu = NSMenu()
        add(to: menu, "Open Database…", #selector(openDatabase))
        add(to: menu, "New Database…", #selector(newDatabase))
        popUp(menu, from: view)
    }

    func headerGearClicked(_ view: NSView) {
        popUp(gearMenu(), from: view)
    }

    func showGearMenu() {
        popUp(gearMenu(), from: header.subviews.last ?? header)
    }

    func menuHide() { hide() }

    /// The empty database's rows. Sync Chrome only opens its section: switching it on asks macOS for the Chrome key,
    /// which the user has not asked for yet.
    func menuPerform(_ action: MenuAction) {
        switch action {
        case .importPasswords: showPreferences(at: .importPasswords)
        case .syncChrome:
            #if PP_DIRECT
            showPreferences(at: .chrome)
            #else
            showPreferences(at: nil)
            #endif
        case .newItem: newItem()
        }
    }

    private func showPreferences(at section: PreferencesSection?) {
        hide(refocusPrevious: false)
        AppDelegate.shared?.showPreferences(at: section)
    }

    private func popUp(_ menu: NSMenu, from view: NSView) {
        self.menu.root.list.selectedIndex = nil
        self.menu.closeAll()
        keepOpen { _ = menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: view.bounds.maxY), in: view) }
    }

    private func gearMenu() -> NSMenu {
        let gear = NSMenu()
        if session.locked {
            add(to: gear, "Preferences…", #selector(openPreferences))
            add(to: gear, "Open Database…", #selector(openDatabase))
            gear.addItem(.separator())
            add(to: gear, "Quit PasswordPie", #selector(quit))
            return gear
        }
        let major = add(to: gear, "Search Major Fields", #selector(searchMajor))
        major.state = session.searchAll ? .off : .on
        let all = add(to: gear, "Search All Fields", #selector(searchAll))
        all.state = session.searchAll ? .on : .off
        gear.addItem(.separator())
        add(to: gear, "New Item…", #selector(newItem), key: "n")
        add(to: gear, "Lock", #selector(lockNow), key: "l")
        gear.addItem(.separator())
        add(to: gear, "Preferences…", #selector(openPreferences), key: ",")
        add(to: gear, "Open Database…", #selector(openDatabase))
        add(to: gear, "New Database…", #selector(newDatabase))
        gear.addItem(.separator())
        add(to: gear, "Quit PasswordPie", #selector(quit))
        return gear
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func searchMajor() { session.searchAll = false }
    @objc private func searchAll() { session.searchAll = true }
    @objc private func newItem() { hide(refocusPrevious: false); session.newEntry() }
    @objc private func lockNow() { session.lock() }
    @objc private func openPreferences() { hide(refocusPrevious: false); AppDelegate.shared?.showPreferences() }
    @objc private func openDatabase() { session.chooseDatabase() }
    @objc private func newDatabase() { session.newDatabase() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Key equivalents

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "\r", flags == .command, !session.locked, menu.handleCommandReturn() { return true }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        if !session.locked,
           let shortcut = quickAccessShortcut(QuickAccessKeyPress(
               key: key,
               command: true,
               shift: shift,
               option: option,
               control: control
           )) {
            runQuickAccess(shortcut)
            return true
        }
        // No main menu is relied on: the standard edit commands go straight down the responder chain.
        // Item shortcuts above already consumed ⌥⌘C. Plain ⌘C copies the search text.
        if !shift, let action = Self.editActions[key] {
            let selection = (panel.firstResponder as? NSTextView)?.selectedRange().length
            if editCommandWouldEmptyClipboard(key: key, selectionLength: selection) { return true }
            return NSApp.sendAction(action, to: nil, from: nil)
        }
        if key == "z", shift { return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        guard !session.locked else { return key == "," ? { showGearMenu(); return true }() : false }
        switch (key, shift) {
        case (",", false):
            showGearMenu()
        case ("n", false):
            newItem()
        case ("l", false):
            lockNow()
        case ("e", _):
            guard let id = menu.currentEntryID else { return true }
            hide(refocusPrevious: false)
            session.edit(id)
        default:
            return false
        }
        return true
    }

    /// Copies dismiss Quick Access only when there is something to put on the clipboard.
    private func runQuickAccess(_ shortcut: QuickAccessShortcut) {
        guard let id = menu.currentEntryID else { return }
        switch shortcut {
        case .copyPrimary, .copyPassword, .copyOneTimePassword:
            switch session.runCopyShortcut(shortcut, of: id) {
            case .copied: hide()
            // The plans take the keyboard, so focus does not go back to the app underneath.
            case .premiumRequired: hide(refocusPrevious: false)
            case .nothingToCopy: break
            }
        case .pinItem:
            session.pinEntry(id)
        case .openAndFill:
            let website = session.entry(id).flatMap { otherWebsite(of: $0, matching: menu.query) }
            session.fill(id, .openAndFill, website: website)
        case .fillFocusedApp:
            session.fill(id, .fill)
        }
    }

    private static let editActions: [String: Selector] = [
        "x": #selector(NSText.cut(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "a": #selector(NSText.selectAll(_:)),
        "z": Selector(("undo:"))
    ]
}
