import AppKit
import SwiftUI

@MainActor
protocol HeaderDelegate: AnyObject {
    func headerSearchChanged(_ text: String)
    func headerKey(_ key: MenuKey) -> Bool
    func headerEscape()
    func headerLogoClicked(_ view: NSView)
    func headerGearClicked(_ view: NSView)
}

/// The search field that owns the keyboard. Arrow keys, Tab, Return and Escape go to the menu; everything else is text.
final class SearchField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

/// 40 pt of header plus a 5 pt separator band: logo, an 18 pt search field with no chrome, and the gear.
final class HeaderView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 45
    weak var delegate: HeaderDelegate?
    let searchField = SearchField()
    private let logo = NSButton()
    private let gear = NSButton()
    var showsSeparator = true {
        didSet { if oldValue != showsSeparator { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .minYMargin]

        logo.setAccessibilityLabel("PasswordPie menu")
        logo.isBordered = false
        logo.image = Self.logoImage
        logo.imageScaling = .scaleProportionallyDown
        logo.target = self
        logo.action = #selector(logoClicked)
        logo.focusRingType = .none
        logo.refusesFirstResponder = true
        addSubview(logo)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 18)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search PasswordPie",
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.secondaryLabelColor]
        )
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        addSubview(searchField)

        gear.setAccessibilityLabel("Settings")
        gear.isBordered = false
        gear.image = MenuIcons.symbol("gearshape.fill", color: .secondaryLabelColor, size: 16)
        gear.imageScaling = .scaleProportionallyDown
        gear.target = self
        gear.action = #selector(gearClicked)
        gear.focusRingType = .none
        gear.refusesFirstResponder = true
        addSubview(gear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Own-brand shield, rendered once and tinted by AppKit for the current appearance.
    @MainActor
    private static let logoImage: NSImage? = {
        let renderer = ImageRenderer(content: PasswordPieMark(size: 32, style: .monochrome).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }()

    override func layout() {
        super.layout()
        let width = bounds.width
        logo.frame = NSRect(x: 4, y: 4, width: 32, height: 32)
        searchField.frame = NSRect(x: 38, y: 8, width: max(width - 74, 40), height: 24)
        gear.frame = NSRect(x: width - 34, y: 5, width: 30, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator else { return }
        menuInk(0.25).setFill()
        NSRect(x: 0, y: bounds.height - 4.5 - 0.5, width: bounds.width, height: 1).fill()
    }

    @objc private func logoClicked() { delegate?.headerLogoClicked(logo) }
    @objc private func gearClicked() { delegate?.headerGearClicked(gear) }

    func controlTextDidChange(_ notification: Notification) {
        delegate?.headerSearchChanged(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            return delegate?.headerKey(.up) ?? false
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            return delegate?.headerKey(.down) ?? false
        case #selector(NSResponder.moveRight(_:)):
            return delegate?.headerKey(.right) ?? false
        case #selector(NSResponder.moveLeft(_:)):
            return delegate?.headerKey(.left) ?? false
        case #selector(NSResponder.insertNewline(_:)):
            return delegate?.headerKey(.enter) ?? false
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.headerEscape()
            return true
        default:
            return false
        }
    }
}
