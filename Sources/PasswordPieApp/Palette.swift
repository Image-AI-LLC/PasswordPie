import AppKit
import SwiftUI

/// Compact branded lock form, drawn natively rather than from a screenshot. Its height follows its content.
enum Metrics {
    static let width: CGFloat = 300
    /// The card ⌘L folds the open menu into.
    static let lockCardHeight: CGFloat = 144
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

enum Palette {
    static let brandAccent = Color(hex: 0xEE8C32)
    static let onAccent = Color(hex: 0x302315)
    static func surface(dark: Bool) -> Color { Color(hex: dark ? 0x28231F : 0xFFF6E7) }
    static func text(dark: Bool) -> Color { Color(hex: dark ? 0xFFF6E7 : 0x302A24) }
    static func secondaryText(dark: Bool) -> Color { Color(hex: dark ? 0xD4C4B2 : 0x70604F) }
    static func fieldSurface(dark: Bool) -> Color { Color(hex: dark ? 0x37302A : 0xFFFFFF) }
    static func border(dark: Bool) -> Color { Color(hex: dark ? 0x776858 : 0xC8BBAA) }
    static func focus(dark: Bool) -> Color { Color(hex: dark ? 0xF6B469 : 0xA65312) }
    static func error(dark: Bool) -> Color { Color(hex: dark ? 0xFFA396 : 0xAA3027) }

    // MARK: Selection and accents. The system accent colour is never used: a blue Mac would bring blue back.

    static let selectionFill = brandAccent
    static let selectionInk = onAccent
    /// Orange that is dark or light enough to read as text. Links, one-time codes, the shortcut prompt.
    static func accentText(dark: Bool) -> Color { focus(dark: dark) }

    static let strengthWeak = Color(hex: 0xD6453A)
    static let strengthMedium = Color(hex: 0xE3B505)
    static let strengthStrong = Color(hex: 0x4C9F5B)

    static let favorite = Color(hex: 0xF4B400)

    static let largeTypeLetter = Color(hex: 0xFFF6E7)
    static let largeTypeDigit = Color(hex: 0xFFAD5C)
    static let largeTypeSymbol = Color(hex: 0x8CD6C3)

    // MARK: Surfaces after unlock

    /// Preferences and About. Fields and cards sit on it in `card(dark:)`.
    static func windowSurface(dark: Bool) -> Color { surface(dark: dark) }
    static func card(dark: Bool) -> Color { fieldSurface(dark: dark) }
}

extension NSColor {
    /// Resolves per appearance, so one colour can be handed to AppKit drawing code.
    static func palette(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: alpha
            )
        }
        return NSColor(name: nil) { appearance in
            make(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

/// The same tokens for AppKit drawing.
enum MenuPalette {
    static let text = NSColor.palette(light: 0x302A24, dark: 0xFFF6E7)
    static let secondaryText = NSColor.palette(light: 0x70604F, dark: 0xD4C4B2)
    static let tertiaryText = NSColor.palette(light: 0x8F7F6E, dark: 0xA39585)
    static let disabledText = NSColor.palette(light: 0x8F7F6E, dark: 0x8F8172)
    static let arrow = NSColor.palette(light: 0xA89A8A, dark: 0x94877A)
    static let selectionFill = NSColor.palette(light: 0xEE8C32, dark: 0xEE8C32)
    static let selectionInk = NSColor.palette(light: 0x302315, dark: 0x302315)
    static let caret = NSColor.palette(light: 0xA65312, dark: 0xF6B469)
    static let textSelection = NSColor.palette(light: 0xF6C993, dark: 0x7A4E22)

    /// Letter tiles stand in for site icons, so they vary, but only across hues that sit with the brand.
    static let tileHues: [CGFloat] = [14, 28, 42, 95, 168, 345].map { $0 / 360 }

    static let favorite = NSColor.palette(light: 0xF4B400, dark: 0xF4B400)
    static let error = NSColor.palette(light: 0xAA3027, dark: 0xFFA396)
    static let folder = NSColor.palette(light: 0xD18A32, dark: 0xE2A052)
    static let tag = NSColor.palette(light: 0x6F9A58, dark: 0x8DB877)
    static let neutralIcon = NSColor.palette(light: 0x8B7A69, dark: 0xB3A493)
    static let note = NSColor.palette(light: 0xD9A520, dark: 0xE8BC4C)
    static let identity = NSColor.palette(light: 0xB8694A, dark: 0xD48A6B)

    /// An empty database's action rows: an orange tile behind an `accent-text` symbol. 20 % reads as a tile on both
    /// surfaces (checked by eye on the dark one).
    static let actionTile = NSColor.palette(light: 0xEE8C32, dark: 0xEE8C32, alpha: 0.2)
    static let actionSymbol = NSColor.palette(light: 0xA65312, dark: 0xF6B469)
    static let selectedActionTile = NSColor.palette(light: 0x302315, dark: 0x302315, alpha: 0.14)
    static let selectedActionDetail = NSColor.palette(light: 0x302315, dark: 0x302315, alpha: 0.85)

    /// Warm lines and fills: brown on a light surface, cream on a dark one.
    static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor.palette(light: 0x302A24, dark: 0xFFF6E7, alpha: alpha)
    }

    /// Opaque warm fill behind panel, submenu and details, the same surface as the lock screen.
    static let backdrop = NSColor.palette(light: 0xFFF6E7, dark: 0x28231F)
}

/// Dark text on flat orange. The system's default-action button would be blue, or white on orange when tinted.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Palette.brandAccent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A flat fill drawn by appearance. AppKit reads the dynamic colour on every appearance change.
final class BackdropView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

extension NSWindow {
    /// Lets the warm content colour run under the title bar instead of leaving a grey strip on top.
    func applyWarmTitlebar() {
        titlebarAppearsTransparent = true
        backgroundColor = MenuPalette.backdrop
    }
}

extension NSVisualEffectView {
    /// Covers the material with the warm surface, behind every other subview.
    func applyMenuBackdrop() {
        let backdrop = BackdropView(color: MenuPalette.backdrop)
        backdrop.frame = bounds
        addSubview(backdrop, positioned: .below, relativeTo: nil)
    }
}
