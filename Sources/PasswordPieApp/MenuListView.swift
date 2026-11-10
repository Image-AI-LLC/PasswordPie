import AppKit
import PasswordPieCore

enum MenuMetrics {
    static let itemHeight: CGFloat = 21
    static let separatorHeight: CGFloat = 11
    static let headerHeight: CGFloat = 16
    static let minimumListHeight: CGFloat = 24
    static let iconX: CGFloat = 16
    static let titleX: CGFloat = 38
    static let arrowSlot: CGFloat = 16
    static let arrowInset: CGFloat = 26
    static let autoScrollZone: CGFloat = 30
    static let font = NSFont.menuFont(ofSize: 14)
    static let headerFont = NSFont.menuFont(ofSize: 11)
}

/// Warm brown lines and fills on a light menu, cream on a dark one.
func menuInk(_ alpha: CGFloat) -> NSColor { MenuPalette.ink(alpha) }

@MainActor
protocol MenuListDelegate: AnyObject {
    /// The pointer moved onto `index` (nil: onto no selectable row).
    func menuList(_ list: MenuListView, pointerMovedTo index: Int?)
    func menuList(_ list: MenuListView, pressed index: Int)
    func menuList(_ list: MenuListView, released index: Int?)
    func menuListPointerExited(_ list: MenuListView)
}

/// A flat list of menu rows drawn by hand: rows are 21 pt, separators 11 pt, group headers 16 pt, and the selection is a flat full-width fill.
final class MenuListView: NSView {
    weak var delegate: MenuListDelegate?
    private(set) var rows: [MenuRow] = []
    private var offsets: [CGFloat] = [0]
    var selectedIndex: Int? {
        didSet { if oldValue != selectedIndex { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    private var scrollTimer: Timer?
    private var scrollStep: CGFloat = 4
    private var scrollDirection: CGFloat = 0
    private var lastPointer: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func setRows(_ newRows: [MenuRow]) {
        rows = newRows
        offsets = [0]
        for row in rows { offsets.append(offsets.last! + Self.height(of: row)) }
        selectedIndex = nil
        setFrameSize(NSSize(width: frame.width, height: contentHeight))
        enclosingScrollView?.contentView.scroll(to: .zero)
        needsDisplay = true
        // An icon the browser extension hands over shows up without reopening the panel.
        SiteIconStore.shared.observe(self) { [weak self] in self?.needsDisplay = true }
        updateBadgeToolTips()
    }

    /// The read that finds an account in Chrome often finishes while the list is already on screen.
    func chromeAccountsChanged() {
        updateBadgeToolTips()
        needsDisplay = true
    }

    private func updateBadgeToolTips() {
        removeAllToolTips()
        for index in rows.indices {
            guard let id = rows[index].entryID,
                  iconMark(favorite: rows[index].favorite, fromChrome: MenuIcons.chromeAccounts.contains(id)) == .chrome else { continue }
            addToolTip(NSRect(x: MenuMetrics.iconX, y: rect(of: index).midY - 8, width: 16, height: 16), owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        ChromeBadge.tooltip
    }

    var contentHeight: CGFloat { max(offsets.last ?? 0, MenuMetrics.minimumListHeight) }

    static func height(of row: MenuRow) -> CGFloat {
        switch row.kind {
        case .separator: return MenuMetrics.separatorHeight
        case .header: return MenuMetrics.headerHeight
        default: return MenuMetrics.itemHeight
        }
    }

    func rect(of index: Int) -> NSRect {
        NSRect(x: 0, y: offsets[index], width: bounds.width, height: offsets[index + 1] - offsets[index])
    }

    func index(at point: NSPoint) -> Int? {
        guard point.y >= 0, point.y < (offsets.last ?? 0) else { return nil }
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if point.y < offsets[mid] { high = mid - 1 } else if point.y >= offsets[mid + 1] { low = mid + 1 } else { return mid }
        }
        return nil
    }

    func scrollToVisible(row index: Int) {
        scrollToVisible(rect(of: index))
    }

    // MARK: Width

    /// Item width = ceil(title + 20) + icon 16 + 22 + username + 28 for the arrow.
    static func preferredWidth(of rows: [MenuRow]) -> CGFloat {
        var widest: CGFloat = 0
        for row in rows {
            switch row.kind {
            case .separator, .header: continue
            default: break
            }
            var width = ceil(textWidth(row.title, MenuMetrics.font) + 20) + 16 + 22
            if !row.username.isEmpty { width += ceil(textWidth(" — " + row.username, MenuMetrics.font)) }
            if row.opensSubmenu || row.kind == .submenu { width += 28 }
            widest = max(widest, width)
        }
        return widest
    }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only real movement counts: a window that appears under a resting pointer must not select anything.
        if let last = lastPointer, abs(last.x - point.x) < 0.5, abs(last.y - point.y) < 0.5, scrollDirection == 0 { return }
        lastPointer = point
        updateAutoScroll(for: point)
        let index = index(at: point).flatMap { rows[$0].isSelectable ? $0 : nil }
        delegate?.menuList(self, pointerMovedTo: index)
    }

    override func mouseExited(with event: NSEvent) {
        stopAutoScroll()
        lastPointer = nil
        delegate?.menuListPointerExited(self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = index(at: point), rows[index].isSelectable {
            delegate?.menuList(self, pressed: index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateAutoScroll(for: point)
        if let index = index(at: point), rows[index].isSelectable {
            delegate?.menuList(self, pressed: index)
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
        let point = convert(event.locationInWindow, from: nil)
        let index = index(at: point).flatMap { rows[$0].isSelectable ? $0 : nil }
        delegate?.menuList(self, released: index)
    }

    // MARK: Hover auto-scroll (30 pt zones, 0.04 s timer, 4 pt x 1.1 per tick up to 20 pt)

    private func updateAutoScroll(for point: NSPoint) {
        guard let scroll = enclosingScrollView, contentHeight > scroll.contentView.bounds.height + 0.5 else {
            stopAutoScroll()
            return
        }
        let visible = scroll.contentView.bounds
        var direction: CGFloat = 0
        if point.y < visible.minY + MenuMetrics.autoScrollZone { direction = -1 }
        if point.y > visible.maxY - MenuMetrics.autoScrollZone { direction = 1 }
        guard direction != scrollDirection else { return }
        stopAutoScroll()
        guard direction != 0 else { return }
        scrollDirection = direction
        scrollStep = 4
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
    }

    private func autoScrollTick() {
        guard let scroll = enclosingScrollView else { return stopAutoScroll() }
        let clip = scroll.contentView
        let maxY = max(contentHeight - clip.bounds.height, 0)
        let next = min(max(clip.bounds.origin.y + scrollDirection * scrollStep, 0), maxY)
        clip.scroll(to: NSPoint(x: 0, y: next))
        scroll.reflectScrolledClipView(clip)
        scrollStep = min(scrollStep * 1.1, 20)
        if next == 0 || next == maxY { stopAutoScroll() }
    }

    private func stopAutoScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollDirection = 0
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for index in rows.indices {
            let rect = rect(of: index)
            guard rect.intersects(dirtyRect) else { continue }
            draw(row: rows[index], in: rect, selected: index == selectedIndex)
        }
    }

    private func draw(row: MenuRow, in rect: NSRect, selected: Bool) {
        switch row.kind {
        case .separator:
            menuInk(0.25).setFill()
            NSRect(x: 0, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
        case .header:
            drawHeader(row, in: rect)
        case .disabled:
            drawText(row.title, in: rect, x: MenuMetrics.titleX, color: MenuPalette.disabledText, width: rect.width - MenuMetrics.titleX - 10)
        case .showMore:
            if selected { fillSelection(rect) }
            drawText(row.title, in: rect, x: 42, color: selected ? MenuPalette.selectionInk : MenuPalette.tertiaryText, width: rect.width - 52)
        case .entry, .submenu, .generator, .action:
            drawItem(row, in: rect, selected: selected)
        }
    }

    private func fillSelection(_ rect: NSRect) {
        MenuPalette.selectionFill.setFill()
        rect.fill()
    }

    private func drawHeader(_ row: MenuRow, in rect: NSRect) {
        menuInk(0.03).setFill()
        rect.fill()
        menuInk(0.2).setFill()
        NSRect(x: 0, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        drawText(row.title.uppercased(), in: rect, x: 6, color: MenuPalette.secondaryText, width: rect.width - 12, font: MenuMetrics.headerFont)
    }

    private func drawItem(_ row: MenuRow, in rect: NSRect, selected: Bool) {
        if selected { fillSelection(rect) }
        let hasArrow = row.opensSubmenu || row.kind == .submenu
        if let icon = MenuIcons.image(for: row, selected: selected) {
            let iconRect = NSRect(x: MenuMetrics.iconX, y: rect.midY - 8, width: 16, height: 16)
            icon.draw(in: IconGeometry.aspectFit(icon.size, in: iconRect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawMark(on: row, icon: iconRect, selected: selected)
        }
        let textColor: NSColor = selected ? MenuPalette.selectionInk : MenuPalette.text
        let reserved: CGFloat = hasArrow ? 28 : 10
        let available = rect.width - MenuMetrics.titleX - reserved
        let titleWidth = min(ceil(Self.textWidth(row.title, MenuMetrics.font)), available)
        drawText(row.title, in: rect, x: MenuMetrics.titleX, color: textColor, width: titleWidth, truncation: .byTruncatingMiddle)
        if !row.username.isEmpty, available - titleWidth > 8 {
            drawText(
                " — " + row.username,
                in: rect,
                x: MenuMetrics.titleX + titleWidth,
                color: selected ? MenuPalette.selectionInk : MenuPalette.secondaryText,
                width: available - titleWidth,
                truncation: .byTruncatingTail
            )
        }
        if hasArrow { drawArrow(in: rect, selected: selected) }
    }

    /// A favorite keeps its star where it has always been. See `iconMark`.
    private func drawMark(on row: MenuRow, icon iconRect: NSRect, selected: Bool) {
        guard let id = row.entryID else { return }
        switch iconMark(favorite: row.favorite, fromChrome: MenuIcons.chromeAccounts.contains(id)) {
        case .favoriteStar:
            guard let star = selected ? MenuIcons.selectedFavoriteBadge : MenuIcons.favoriteBadge else { return }
            let badgeSlot = NSRect(x: iconRect.maxX - 7, y: iconRect.maxY - 7, width: 9, height: 9)
            star.draw(in: IconGeometry.aspectFit(star.size, in: badgeSlot), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .chrome:
            ChromeBadge.draw(icon: iconRect, selected: selected)
        case .none:
            break
        }
    }

    private func drawArrow(in rect: NSRect, selected: Bool) {
        let slot = NSRect(x: rect.width - MenuMetrics.arrowInset, y: rect.midY - 8, width: MenuMetrics.arrowSlot, height: MenuMetrics.arrowSlot)
        let triangle = NSBezierPath()
        let width: CGFloat = 8.5
        let height: CGFloat = 10
        let originX = slot.midX - width / 2
        triangle.move(to: NSPoint(x: originX, y: slot.midY - height / 2))
        triangle.line(to: NSPoint(x: originX + width, y: slot.midY))
        triangle.line(to: NSPoint(x: originX, y: slot.midY + height / 2))
        triangle.close()
        (selected ? MenuPalette.selectionInk : MenuPalette.arrow).setFill()
        triangle.fill()
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        x: CGFloat,
        color: NSColor,
        width: CGFloat,
        font: NSFont = MenuMetrics.font,
        truncation: NSLineBreakMode = .byTruncatingTail
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let target = NSRect(x: x, y: rect.midY - lineHeight / 2, width: max(width, 0), height: lineHeight)
        (text as NSString).draw(with: target, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}

/// Row icons. An entry uses its site icon when one is bundled or cached, and a letter tile when it is not.
@MainActor
enum MenuIcons {
    private static var tiles: [String: NSImage] = [:]
    /// Rows with something from Chrome in them. Set whenever the catalog changes; rows are redrawn then.
    static var chromeAccounts: Set<UUID> = []

    static func image(for row: MenuRow, selected: Bool) -> NSImage? {
        if row.entryID != nil {
            if let icon = SiteIconStore.shared.image(forHost: row.siteHost) { return icon }
            return tile(row.title)
        }
        let name: String
        let tint: NSColor
        switch row.icon {
        case .favorites: name = "star.fill"; tint = MenuPalette.favorite
        case .generator: name = "key.fill"; tint = MenuPalette.neutralIcon
        case .folders, .folder: name = "folder.fill"; tint = MenuPalette.folder
        case .tags, .tag: name = "tag.fill"; tint = MenuPalette.tag
        case .importPasswords: name = "square.and.arrow.down.fill"; tint = MenuPalette.neutralIcon
        case .syncChrome: name = "arrow.triangle.2.circlepath"; tint = MenuPalette.neutralIcon
        case .newItem: name = "plus.square.fill"; tint = MenuPalette.neutralIcon
        case nil:
            guard let category = row.category else { return nil }
            (name, tint) = symbol(for: category)
        }
        return symbol(name, color: selected ? MenuPalette.selectionInk : tint)
    }

    private static func symbol(for category: ItemCategory) -> (String, NSColor) {
        switch category {
        case .login: return ("lock.square.fill", MenuPalette.neutralIcon)
        case .secureNote: return ("note.text", MenuPalette.note)
        case .creditCard: return ("creditcard.fill", MenuPalette.neutralIcon)
        case .identity: return ("person.crop.rectangle.fill", MenuPalette.identity)
        case .password: return ("key.fill", MenuPalette.neutralIcon)
        case .document: return ("doc.fill", MenuPalette.neutralIcon)
        }
    }

    static func symbol(_ name: String, color: NSColor, size: CGFloat = 13) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static let favoriteBadge: NSImage? = symbol("star.fill", color: MenuPalette.favorite, size: 8)
    /// The gold star disappears on the orange selection.
    static let selectedFavoriteBadge: NSImage? = symbol("star.fill", color: MenuPalette.selectionInk, size: 8)

    /// Letter tile tinted by a stable hash of the title. Shown until the extension hands over the site's icon, and kept when it does not.
    static func tile(_ title: String) -> NSImage {
        if let cached = tiles[title] { return cached }
        let letter = title.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
        var hash: UInt32 = 2166136261
        for byte in title.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = MenuPalette.tileHues[Int(hash % UInt32(MenuPalette.tileHues.count))]
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            NSGradient(
                starting: NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1),
                ending: NSColor(hue: hue, saturation: 0.7, brightness: 0.78, alpha: 1)
            )?.draw(in: shape, angle: -90)
            NSColor.black.withAlphaComponent(0.25).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        tiles[title] = image
        return image
    }
}
