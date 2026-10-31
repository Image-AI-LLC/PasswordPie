import SwiftUI

/// Colors and metrics for the lock screen (door D6D6D6, seam band E6E6E6).
/// Everything is drawn in code.
enum Metrics {
    static let width: CGFloat = 300
    static let doorHeight: CGFloat = 96
    static let lockedHeight: CGFloat = 280
    static let createHeight: CGFloat = 330
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
    static let door = Color(hex: 0xD6D6D6)
    static let band = Color(hex: 0xE6E6E6)
    static let bandHighlight = Color(hex: 0xFAFAFA)
    static let bandLine = Color(hex: 0x666666)
    static let danger = Color(hex: 0xC8372D)
}
