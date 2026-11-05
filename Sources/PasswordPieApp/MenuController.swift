import AppKit
import PasswordPieCore
import SwiftUI

/// Keys the search field forwards to the deepest open menu level.
enum MenuKey {
    case up, down, left, right, enter
}

@MainActor
protocol MenuHost: AnyObject {
    var rootWindow: NSWindow { get }
    /// The root list needs `width` x `height` (list only, no header).
    func menuRootNeedsLayout(contentWidth: CGFloat, contentHeight: CGFloat)
    func menuHide()
}

/// A child window that never takes key status, so the search field in the root panel keeps the keyboard.
final class MenuChildPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuLevel {
    enum Content {
        case rows
        case generator(GeneratorModel)
    }

    var rows: [MenuRow]
    let list: MenuListView
    let scroll: NSScrollView
    var window: MenuChildPanel?
    var content: Content = .rows
    /// Screen-space top of the parent row that opened this level.
    var anchorTop: CGFloat = 0
    var parentIndex: Int?

    init(rows: [MenuRow]) {
        self.rows = rows
        list = MenuListView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        list.autoresizingMask = [.width]
        scroll = NSScrollView(frame: list.frame)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = list
        scroll.autoresizingMask = [.width, .height]
        list.setRows(rows)
    }

    var selectedRow: MenuRow? {
        list.selectedIndex.map { rows[$0] }
    }

    var firstSelectable: Int? { rows.firstIndex { $0.isSelectable } }
}

/// Drives the menu: levels of rows (the root list plus cascading child windows), hover timers, keys, and the details popover.
@MainActor
final class MenuController: NSObject, MenuListDelegate, NSPopoverDelegate {
    unowned let session: VaultSession
    weak var host: MenuHost?
    private(set) var levels: [MenuLevel] = []
    private(set) var query = ""
    private var popover: NSPopover?
    private var details: DetailsModel?
    private var detailsLevel: MenuLevel?
    private var popoverShownThisSession = false
    private var pendingOpen: DispatchWorkItem?
    private var pendingSelect: DispatchWorkItem?
    private var widest: CGFloat = MenuGeometry.rootWidth
    private var lastPointerScreen: NSPoint?
    /// Below the root: the rows `reopenSubmenus()` still has to walk to.
    private var submenusToReopen: [MenuRowRef] = []

    var root: MenuLevel { levels[0] }
    var deepest: MenuLevel { levels[levels.count - 1] }
    var popoverIsOpen: Bool { popover?.isShown ?? false }

    init(session: VaultSession) {
        self.session = session
        super.init()
        let level = MenuLevel(rows: [])
        level.list.delegate = self
        levels = [level]
    }

    // MARK: Building

    /// A showing with nothing to recall starts from the initial menu with the first row selected.
    func reset() {
        closeAll()
        query = ""
        widest = MenuGeometry.rootWidth
        submenusToReopen = []
        rebuildRoot(selectFirst: true)
    }

    func setQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        closeAll()
        rebuildRoot(selectFirst: true)
    }

    /// Entries changed (favorite toggled, item saved): rebuild without losing the query or the selected row.
    /// While the popover is open (its star toggles a favorite) the rebuild waits for the next showing instead of closing it.
    func refresh() {
        guard !popoverIsOpen else { return }
        rebuild(at: place)
        // A hidden panel has no parent to hang a child window from.
        if host?.rootWindow.isVisible == true { reopenSubmenus() }
    }

    /// Where the keyboard is now. Stops at the first level with no selected row.
    var place: MenuPlace {
        var path: [MenuRowRef] = []
        for level in levels {
            guard let row = level.selectedRow else { break }
            path.append(MenuRowRef(row))
        }
        return MenuPlace(query: query, path: path)
    }

    /// Brings back `place` in the root list. Child windows are placed against the panel's final frame, so call
    /// `reopenSubmenus()` once the panel is on screen.
    func restore(_ place: MenuPlace) {
        widest = MenuGeometry.rootWidth
        rebuild(at: place)
    }

    private func rebuild(at place: MenuPlace) {
        closeAll()
        query = place.query
        rebuildRoot(selectFirst: false)
        submenusToReopen = Array(place.path.dropFirst())
        guard let first = place.path.first, let index = reveal(first, in: root) else {
            selectFirst(in: root)
            submenusToReopen = []
            return
        }
        root.list.selectedIndex = index
    }

    /// Opens the submenus `restore` could not, each with its row selected, and scrolls the selection into view.
    /// A row that is gone ends the walk at its parent, with the first row of that list selected.
    func reopenSubmenus() {
        let path = submenusToReopen
        submenusToReopen = []
        for ref in path {
            let parent = deepest
            guard let index = parent.list.selectedIndex, parent.rows[index].kind == .submenu else { break }
            parent.list.scrollToVisible(row: index)
            openChild(of: parent, at: index, rows: parent.rows[index].children, content: .rows, selectFirst: false)
            guard let found = reveal(ref, in: deepest) else {
                selectFirst(in: deepest)
                break
            }
            deepest.list.selectedIndex = found
        }
        for level in levels {
            if let index = level.list.selectedIndex { level.list.scrollToVisible(row: index) }
        }
    }

    /// The row's index in `level`, expanding the "Show N more" row that hides it if there is one.
    private func reveal(_ ref: MenuRowRef, in level: MenuLevel) -> Int? {
        if let index = level.rows.firstIndex(where: ref.matches) { return index }
        guard let more = level.rows.firstIndex(where: { row in
            row.kind == .showMore && row.children.contains(where: ref.matches)
        }) else { return nil }
        expand(level, at: more)
        return level.rows.firstIndex(where: ref.matches)
    }

    private func rebuildRoot(selectFirst first: Bool) {
        let rows = query.isEmpty ? topLevelRows() : searchRows()
        root.rows = rows
        root.list.setRows(rows)
        if first { selectFirst(in: root) }
        layoutRoot()
    }

    /// Built in the background by the session. Until the first build for this unlock is done, one placeholder row shows.
    private func topLevelRows() -> [MenuRow] {
        session.topLevelRows ?? [MenuRow(kind: .disabled, title: "Loading…")]
    }

    /// Searches what the session has indexed so far. More results appear as indexing goes on.
    private func searchRows() -> [MenuRow] {
        let rows = MenuBuilder.searchResults(
            index: session.searchIndex,
            query: query,
            scope: session.searchAll ? .allFields : .major,
            lastUsed: session.lastUsedMap,
            sources: session.entrySources
        )
        guard session.indexing, rows.count == 1, rows[0].kind == .disabled else { return rows }
        return [MenuRow(kind: .disabled, title: "Searching…")]
    }

    /// The session finished more background work. Only the visible list is rebuilt, so an open submenu is not closed by
    /// indexing that does not change it.
    func catalogUpdated(topLevel: Bool) {
        guard topLevel == query.isEmpty else { return }
        refresh()
    }

    private func layoutRoot() {
        let screenWidth = (host?.rootWindow.screen ?? NSScreen.main)?.frame.width ?? 1440
        let preferred = MenuListView.preferredWidth(of: root.rows)
        let width = MenuGeometry.width(widestRow: preferred, minimum: MenuGeometry.rootWidth, screenWidth: screenWidth)
        // The width never shrinks while the panel is open.
        widest = max(widest, width)
        host?.menuRootNeedsLayout(contentWidth: widest, contentHeight: root.list.contentHeight)
    }

    private func selectFirst(in level: MenuLevel) {
        level.list.selectedIndex = level.firstSelectable
    }

    // MARK: Keys

    /// Returns true when the key was consumed; false lets the text field handle it (caret movement).
    func handle(_ key: MenuKey) -> Bool {
        cancelPending()
        if popoverIsOpen, let details {
            switch key {
            case .up: details.move(-1); return true
            case .down: details.move(1); return true
            case .left: closePopover(); return true
            case .right: return true
            case .enter: details.activateFocused(); return true
            }
        }
        if case .generator(let model) = deepest.content {
            switch key {
            case .left: closeChildren(after: levels.count - 2); return true
            case .enter: model.copyAndHide(); return true
            default: return true
            }
        }
        let level = deepest
        switch key {
        case .up: move(in: level, by: -1); return true
        case .down: move(in: level, by: 1); return true
        case .right:
            guard let index = level.list.selectedIndex else { return false }
            return open(level, index, selectFirst: true)
        case .enter:
            guard let index = level.list.selectedIndex else { return true }
            _ = activate(level, index, viaKeyboard: true)
            return true
        case .left:
            guard levels.count > 1 else { return false }
            closeChildren(after: levels.count - 2)
            return true
        }
    }

    private func move(in level: MenuLevel, by delta: Int) {
        let rows = level.rows
        guard !rows.isEmpty else { return }
        guard let current = level.list.selectedIndex else {
            if delta > 0 { level.list.selectedIndex = level.firstSelectable }
            return
        }
        var next = current + delta
        while rows.indices.contains(next), !rows[next].isSelectable { next += delta }
        guard rows.indices.contains(next) else { return }
        level.list.selectedIndex = next
        level.list.scrollToVisible(row: next)
    }

    // MARK: Opening

    /// Opens the submenu or details for `index` now. Returns false when the row opens nothing.
    @discardableResult
    private func open(_ level: MenuLevel, _ index: Int, selectFirst first: Bool) -> Bool {
        let row = level.rows[index]
        switch row.kind {
        case .submenu:
            openChild(of: level, at: index, rows: row.children, content: .rows, selectFirst: first)
            return true
        case .generator:
            openChild(of: level, at: index, rows: [], content: .generator(GeneratorModel(session: session)), selectFirst: false)
            return true
        case .entry(let id):
            showDetails(for: id, in: level, at: index)
            return true
        case .showMore:
            expand(level, at: index)
            return true
        default:
            return false
        }
    }

    private func activate(_ level: MenuLevel, _ index: Int, viaKeyboard: Bool) -> Bool {
        let row = level.rows[index]
        switch row.kind {
        case .submenu, .generator:
            // Return opens with the first row selected; a click only opens.
            return open(level, index, selectFirst: viaKeyboard)
        case .showMore:
            expand(level, at: index)
            return true
        case .entry(let id):
            blink(level, index) { [weak self] in self?.performAction(for: id) }
            return true
        default:
            return false
        }
    }

    /// Deselect, reselect after 50 ms, act 150 ms later.
    private func blink(_ level: MenuLevel, _ index: Int, then action: @escaping () -> Void) {
        level.list.selectedIndex = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak level] in
            level?.list.selectedIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
        }
    }

    /// Login: open the site and fill. Password: fill the previous app. Everything else has no default action.
    private func performAction(for id: UUID) {
        guard let entry = session.entry(id) else { return }
        switch entry.category {
        case .login: session.fill(id, .openAndFill, website: otherWebsite(of: entry, matching: query))
        case .password: session.fill(id, .fill)
        default: break
        }
    }

    private func expand(_ level: MenuLevel, at index: Int) {
        let row = level.rows[index]
        level.rows.replaceSubrange(index...index, with: row.children)
        level.list.setRows(level.rows)
        level.list.selectedIndex = index
        if level === root {
            layoutRoot()
        } else {
            place(level)
        }
    }

    // MARK: Child windows

    private func levelIndex(_ level: MenuLevel) -> Int? { levels.firstIndex { $0 === level } }

    private func openChild(of parent: MenuLevel, at index: Int, rows: [MenuRow], content: MenuLevel.Content, selectFirst first: Bool) {
        guard let parentPosition = levelIndex(parent) else { return }
        // Already open for this row.
        if levels.count > parentPosition + 1, levels[parentPosition + 1].parentIndex == index {
            if first, case .rows = levels[parentPosition + 1].content { selectFirst(in: levels[parentPosition + 1]) }
            return
        }
        closeChildren(after: parentPosition)
        closePopover()
        parent.list.selectedIndex = index
        let child = MenuLevel(rows: rows)
        child.list.delegate = self
        child.content = content
        child.parentIndex = index
        let rowRect = screenRect(of: index, in: parent)
        child.anchorTop = rowRect.maxY
        let window = makeChildWindow(for: child)
        child.window = window
        levels.append(child)
        place(child)
        if let parentWindow = parent.window ?? host?.rootWindow {
            parentWindow.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
        if first, case .rows = content { selectFirst(in: child) }
    }

    private func makeChildWindow(for level: MenuLevel) -> MenuChildPanel {
        let window = MenuChildPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.level = menuWindowLevel
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = menuEffectView()
        effect.layer?.cornerRadius = 5
        window.contentView = effect
        switch level.content {
        case .rows:
            effect.addSubview(level.scroll)
        case .generator(let model):
            let hosting = NSHostingView(rootView: GeneratorView(model: model))
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
        }
        return window
    }

    private func place(_ level: MenuLevel) {
        guard let window = level.window, let parentPosition = levelIndex(level), parentPosition > 0 else { return }
        let parent = levels[parentPosition - 1]
        let parentFrame = (parent.window ?? host?.rootWindow)?.frame ?? .zero
        let screen = host?.rootWindow.screen ?? NSScreen.main
        let area = MenuGeometry.confinement(visibleFrame: screen?.visibleFrame ?? .zero)
        let inset = MenuGeometry.submenuInset
        var size: CGSize
        switch level.content {
        case .rows:
            let width = MenuGeometry.width(widestRow: MenuListView.preferredWidth(of: level.rows), minimum: 50, screenWidth: screen?.frame.width ?? 1440)
            size = CGSize(width: width, height: level.list.contentHeight + 2 * inset)
        case .generator:
            size = CGSize(width: 412, height: 300)
        }
        let frame = MenuGeometry.childFrame(parent: parentFrame, rowTop: level.anchorTop, size: size, in: area)
        window.setFrame(frame, display: true)
        if case .rows = level.content {
            level.scroll.frame = NSRect(x: 0, y: inset, width: frame.width, height: frame.height - 2 * inset)
            level.list.setFrameSize(NSSize(width: frame.width, height: level.list.contentHeight))
        }
    }

    private func screenRect(of index: Int, in level: MenuLevel) -> NSRect {
        let local = level.list.rect(of: index)
        let inWindow = level.list.convert(local, to: nil)
        let window = level.window ?? host?.rootWindow
        return window?.convertToScreen(inWindow) ?? .zero
    }

    func closeChildren(after position: Int) {
        pendingOpen?.cancel()
        while levels.count > position + 1 {
            let level = levels.removeLast()
            if let window = level.window {
                window.parent?.removeChildWindow(window)
                window.orderOut(nil)
            }
        }
        if levels.count == 1 || position < 0 {
            // Parent row stays selected after its child closes.
        }
    }

    func closeAll() {
        cancelPending()
        closePopover()
        closeChildren(after: 0)
    }

    private func cancelPending() {
        pendingOpen?.cancel()
        pendingOpen = nil
        pendingSelect?.cancel()
        pendingSelect = nil
    }

    // MARK: Details popover

    private func showDetails(for id: UUID, in level: MenuLevel, at index: Int) {
        guard let entry = session.entry(id) else { return }
        guard let position = levelIndex(level) else { return }
        closeChildren(after: position)
        closePopover()
        level.list.selectedIndex = index
        let model = DetailsModel(entry: entry, session: session) { [weak self] in self?.host?.menuHide() }
        let controller = NSHostingController(rootView: DetailsView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = !popoverShownThisSession
        popover.delegate = self
        popoverShownThisSession = true
        self.popover = popover
        details = model
        detailsLevel = level
        popover.show(relativeTo: level.list.rect(of: index), of: level.list, preferredEdge: .maxX)
        // Behind the content, inside the popover's frame view, so the arrow takes the same fill.
        if let frameView = controller.view.window?.contentView?.superview {
            let backdrop = BackdropView(color: MenuPalette.backdrop)
            backdrop.frame = frameView.bounds
            frameView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        }
    }

    func closePopover() {
        popover?.delegate = nil
        popover?.close()
        popover = nil
        details = nil
        detailsLevel = nil
    }

    /// The window of the popover, so the panel does not hide when it becomes key.
    var popoverWindow: NSWindow? { popover?.contentViewController?.view.window }
    var auxiliaryWindows: [NSWindow] { levels.compactMap(\.window) + [popoverWindow].compactMap { $0 } }

    // MARK: Pointer

    func menuList(_ list: MenuListView, pointerMovedTo index: Int?) {
        guard let level = levels.first(where: { $0.list === list }), let position = levelIndex(level) else { return }
        guard let index else { return }
        if level.list.selectedIndex == index {
            // Same row: keep any pending open, but a deeper level means the pointer returned to its parent row.
            return
        }
        // NSMenu-style aim: heading for the open child delays the change of selection.
        if levels.count > position + 1, isAimingAtChild(of: level, position: position) {
            pendingSelect?.cancel()
            let item = DispatchWorkItem { [weak self, weak level] in
                guard let self, let level else { return }
                self.hoverSelect(level, index)
            }
            pendingSelect = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
            return
        }
        pendingSelect?.cancel()
        hoverSelect(level, index)
    }

    private func isAimingAtChild(of level: MenuLevel, position: Int) -> Bool {
        let now = NSEvent.mouseLocation
        defer { lastPointerScreen = now }
        guard let last = lastPointerScreen, let childWindow = levels[position + 1].window else { return false }
        let dx = now.x - last.x
        let dy = now.y - last.y
        let childIsRight = childWindow.frame.minX >= (level.window ?? host?.rootWindow)?.frame.midX ?? 0
        let towards = childIsRight ? dx : -dx
        return towards > 0 && abs(dx) >= 0.25 * abs(dy)
    }

    private func hoverSelect(_ level: MenuLevel, _ index: Int) {
        guard let position = levelIndex(level) else { return }
        cancelPending()
        if levels.count > position + 1 || popoverIsOpen {
            closeChildren(after: position)
            closePopover()
        }
        level.list.selectedIndex = index
        let row = level.rows[index]
        let delay: TimeInterval
        switch row.kind {
        case .submenu, .generator: delay = 0.2
        case .entry: delay = popoverShownThisSession ? 0 : 0.7
        default: return
        }
        let item = DispatchWorkItem { [weak self, weak level] in
            guard let self, let level, level.list.selectedIndex == index, level.rows.indices.contains(index) else { return }
            switch level.rows[index].kind {
            case .submenu: self.open(level, index, selectFirst: false)
            case .generator: self.open(level, index, selectFirst: false)
            case .entry: self.open(level, index, selectFirst: false)
            default: break
            }
        }
        pendingOpen = item
        if delay == 0 { item.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item) }
    }

    func menuList(_ list: MenuListView, pressed index: Int) {
        guard let level = levels.first(where: { $0.list === list }) else { return }
        cancelPending()
        level.list.selectedIndex = index
    }

    func menuList(_ list: MenuListView, released index: Int?) {
        guard let index, let level = levels.first(where: { $0.list === list }), level.list.selectedIndex == index else { return }
        _ = activate(level, index, viaKeyboard: false)
    }

    func menuListPointerExited(_ list: MenuListView) {
        // Leaving every window clears the selection unless a child is open.
        guard let level = levels.first(where: { $0.list === list }), let position = levelIndex(level) else { return }
        if levels.count == position + 1, !popoverIsOpen, pendingOpen == nil {
            let mouse = NSEvent.mouseLocation
            let inside = levels.contains { $0.window?.frame.contains(mouse) ?? false } || (host?.rootWindow.frame.contains(mouse) ?? false)
            if !inside { level.list.selectedIndex = nil }
        }
    }

    // MARK: Selection queries

    /// The entry the keyboard shortcuts act on: the one in the open popover, else the selected row.
    var currentEntryID: UUID? {
        if popoverIsOpen, let id = details?.entryID { return id }
        return deepest.selectedRow?.entryID
    }

    /// Label of the focused details field (debug status and tests).
    var focusedFieldLabel: String? {
        guard popoverIsOpen, let details, details.fields.indices.contains(details.focused) else { return nil }
        return details.fields[details.focused].label
    }

    var selectedTitle: String? {
        if popoverIsOpen, let title = details?.title { return title }
        return deepest.selectedRow?.title
    }

    // MARK: Debug navigation

    #if DEBUG
    /// Moves the pointer onto the row titled `title` in the deepest level, through the same path a real mouse move takes.
    func debugHover(_ title: String) {
        let level = deepest
        guard let index = level.rows.firstIndex(where: { $0.title == title && $0.isSelectable }) else { return }
        menuList(level.list, pointerMovedTo: index)
    }

    /// Opens a path of row titles ("Logins/GitHub") the way the keyboard would.
    func debugOpen(path: [String]) {
        for title in path {
            let level = deepest
            guard let index = level.rows.firstIndex(where: { $0.title == title && $0.isSelectable }) else { return }
            level.list.selectedIndex = index
            if !open(level, index, selectFirst: false) { return }
        }
    }
    #endif
}

// MARK: Shared window pieces

let menuWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

@MainActor
func menuEffectView() -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .menu
    view.blendingMode = .behindWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.applyMenuBackdrop()
    return view
}
