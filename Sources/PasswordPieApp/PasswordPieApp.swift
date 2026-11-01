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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// A borderless window that can take key status: Large Type closes on any key press or when it loses focus.
final class LargeTypeWindow: NSWindow {
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
    private(set) var panelController: PanelController!
    private var autoLock: AutoLockMonitor!
    private var hotKey: EventHotKeyRef?
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
    private var editorWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    #if DEBUG
    private var reporter: StatusReporter?
    private var hotKeyStatus = ""
    #endif

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
        panelController = PanelController(session: session)
        session.hidePanel = { [weak self] in self?.panelController.hide() }
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
                self?.largeTypeWindow?.close()
                self?.largeTypeWindow = nil
                let pinned = Array(self?.pinnedAccounts.values.map(\.panel) ?? [])
                pinned.forEach { $0.close() }
            }
            .store(in: &cancellables)
        session.$entries.combineLatest(session.$liveEntries) { VaultSession.visibleEntries(saved: $0, live: $1) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.refreshPinnedEntry(entries)
            }
            .store(in: &cancellables)
        applyDebugHooks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.flushClipboard()
    }

    // MARK: Panel

    func toggleFromHotkey() {
        autoLock.registerActivity()
        panelController.toggle(.hotkey)
    }

    func hidePanel() { panelController.hide() }

    /// Runs `body` (typically a modal file chooser) without the panel hiding when it loses key status.
    func keepOpen<T>(_ body: () -> T) -> T { panelController.keepOpen(body) }

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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
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
            pinnedAccounts[entry.id]?.panel.orderFrontRegardless()
        case .openNew(let index):
            let model = pinnedModel(for: entry, previous: nil)
            let panel = PinnedEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160))
            panel.delegate = self
            panel.title = model.title
            panel.contentView = FirstMouseHostingView(rootView: pinnedRoot(model))
            pinnedAccounts[entry.id] = PinnedAccount(panel: panel, model: model, snapshot: entry, contentHeight: 0)
            placePinned(panel, index: index)
            panel.orderFrontRegardless()
        }
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
            model.focused = min(previous.focused, max(model.fields.count - 1, 0))
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
            window.contentView = NSHostingView(rootView: EditorView(session: session))
            window.delegate = self
            window.center()
            editorWindow = window
        }
        editorWindow?.title = session.editingIsNew ? "New Item" : "Edit \(entry.title)"
        panelController.hide(refocusPrevious: false)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    func showPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.styleMask.insert(.resizable)
            window.title = "PasswordPie Preferences"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(session: session))
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

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === editorWindow {
            editorWindow = nil
            if session.editing != nil { session.cancelEditing() }
        } else if window === preferencesWindow {
            preferencesWindow = nil
        } else if let id = pinnedAccounts.first(where: { $0.value.panel === window })?.key {
            pinnedAccounts[id] = nil
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

    /// Without a main menu a menu-bar-only app has no Edit commands, so ⌘V and friends do nothing in text fields.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
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
    }

    /// Registers the configured shortcut again, replacing any earlier registration.
    func reregisterHotkey() {
        unregisterHotkey()
        registerHotkey()
    }

    #if DEBUG
    static func suppressesPreviewHotkey(_ environment: [String: String]) -> Bool {
        environment["PASSWORDPIE_PREFERENCES"] != nil || environment["PASSWORDPIE_DISABLE_HOTKEY"] != nil
    }
    #endif

    private func registerHotkey() {
        #if DEBUG
        // Preview bundles have separate defaults, but Carbon shortcuts are system-wide.
        // Apply this at the shared registration boundary, including recorder completion.
        let env = ProcessInfo.processInfo.environment
        if Self.suppressesPreviewHotkey(env) {
            hotKeyStatus = "disabled in preview"
            return
        }
        #endif
        if hotKey != nil || session.recordingHotKey { return }
        let target = GetEventDispatcherTarget()
        if !hotKeyHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(target, { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                if hotKeyID.signature == 0x50506965 {
                    DispatchQueue.main.async { AppDelegate.shared?.toggleFromHotkey() }
                }
                return noErr
            }, 1, &eventType, nil, nil)
            hotKeyHandlerInstalled = installed == noErr
        }
        let config = session.hotKey
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, target, 0, &hotKey)
        if status != noErr {
            hotKey = nil
        }
        session.hotKeyActive = status == noErr
        #if DEBUG
        hotKeyStatus = "\(config.display) status \(status)"
        #endif
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
        if env["PASSWORDPIE_PREFERENCES"] != nil {
            showPreferences()
            if let rawHeight = env["PASSWORDPIE_PREFERENCES_HEIGHT"], let height = Double(rawHeight), height.isFinite {
                preferencesWindow?.setContentSize(NSSize(width: 560, height: max(480, min(800, height))))
            }
            return
        }
        guard env["PASSWORDPIE_SHOW"] != nil else { return }
        if env["PASSWORDPIE_ANCHOR"] == "status" { showUnderStatusItem() } else { panelController.show(.hotkey) }
        guard !session.locked else { return }
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
        if let path = env["PASSWORDPIE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panelController.menu.debugOpen(path: path.split(separator: "/").map(String.init))
            }
        }
        #endif
    }

    #if DEBUG
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
            "popoverOpen": menu.popoverIsOpen,
            "detailsFocus": menu.focusedFieldLabel ?? NSNull(),
            "rootRows": menu.root.rows.map(\.title),
            "appActive": NSApp.isActive,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "panelFrame": NSStringFromRect(panel.frame),
            "systemIdleSeconds": SystemIdle.seconds(),
            "hotkey": hotKeyStatus
        ]
    }
    #endif
}
