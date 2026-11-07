import AppKit

/// "Add Chrome Extension…" above the search field: the browser's icon and the title, laid out like a menu row.
/// Hovering selects it; a click runs it. It never takes the keyboard from the search field.
final class ExtensionBannerView: NSView {
    static let height: CGFloat = 28
    var onClick: (() -> Void)?
    private var banner: ExtensionBanner?
    private var icon: NSImage?
    private var hovering = false {
        didSet { if oldValue != hovering { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// The panel moves by its background; without this a press here starts a drag and the click never arrives.
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ banner: ExtensionBanner) {
        guard banner != self.banner else { return }
        self.banner = banner
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: banner.browserBundleID) {
            icon = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            icon = nil
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(banner.title)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Tracks the press itself: the panel moves by its background, and its drag handling would otherwise take the mouse-up.
    /// Like a menu item, it runs when released over the row.
    override func mouseDown(with event: NSEvent) {
        hovering = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            hovering = inside
            if next.type == .leftMouseUp {
                if inside { onClick?() }
                return
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let banner else { return }
        let row = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1)
        if hovering {
            MenuPalette.selectionFill.setFill()
            row.fill()
        }
        if let icon {
            let slot = NSRect(x: MenuMetrics.iconX, y: row.midY - 8, width: 16, height: 16)
            icon.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MenuMetrics.font,
            .foregroundColor: hovering ? MenuPalette.selectionInk : MenuPalette.text,
            .paragraphStyle: style
        ]
        let font = MenuMetrics.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let text = NSRect(x: MenuMetrics.titleX, y: row.midY - lineHeight / 2, width: max(bounds.width - MenuMetrics.titleX - 10, 0), height: lineHeight)
        (banner.title as NSString).draw(with: text, options: [.usesLineFragmentOrigin], attributes: attributes)
        menuInk(0.25).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
