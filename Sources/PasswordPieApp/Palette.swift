import SwiftUI

/// Compact branded lock form, drawn natively rather than from a screenshot.
enum Metrics {
    static let width: CGFloat = 300
    static let lockedHeight: CGFloat = 360
    static let createHeight: CGFloat = 410
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
    static let danger = Color(hex: 0xC8372D)
}
