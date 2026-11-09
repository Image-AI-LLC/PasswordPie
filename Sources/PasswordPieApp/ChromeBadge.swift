import AppKit
import PasswordPieCore
import SwiftUI

/// The one mark an icon carries in its bottom-right corner. A favorite shows its star and no badge:
/// the badge only says where an account came from, and a favorite is already known to its owner.
enum IconMark: Equatable {
    case none, favoriteStar, chrome
}

func iconMark(favorite: Bool, fromChrome: Bool) -> IconMark {
    if favorite { return .favoriteStar }
    return fromChrome ? .chrome : .none
}

enum ChromeBadge {
    static let listRatio: CGFloat = 0.44
    static let detailsRatio: CGFloat = 0.38
    static let tooltip = "Includes data from Chrome"
    /// Line drawn around the badge, in the colour of the row behind it.
    static let listRing: CGFloat = 1
    static let detailsRing: CGFloat = 1.5

    /// Where the mark goes on an icon: the bottom-right corner, reaching past it by the ring's width. `flipped` is true for a y-down view.
    static func rect(icon: CGRect, ratio: CGFloat, ring: CGFloat, flipped: Bool) -> CGRect {
        let side = icon.width * ratio
        let y = flipped ? icon.maxY - side + ring : icon.minY - ring
        return CGRect(x: icon.maxX - side + ring, y: y, width: side, height: side)
    }

    private static let red = NSColor(srgbRed: 0.918, green: 0.263, blue: 0.208, alpha: 1)
    private static let yellow = NSColor(srgbRed: 0.984, green: 0.737, blue: 0.020, alpha: 1)
    private static let green = NSColor(srgbRed: 0.204, green: 0.659, blue: 0.325, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1)

    /// Drawn, not sampled: the app icon's padding leaves nothing readable at 7 pt.
    static func image(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            for (color, start, end) in [(red, CGFloat(30), CGFloat(150)), (green, 150, 270), (yellow, 270, 390)] {
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
                wedge.close()
                color.setFill()
                wedge.fill()
            }
            let disc = { (fraction: CGFloat, color: NSColor) in
                let r = radius * fraction
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
            }
            disc(0.54, .white)
            disc(0.40, blue)
            return true
        }
    }

    /// In a list row, on top of the icon.
    @MainActor
    static func draw(icon: CGRect, selected: Bool) {
        let mark = rect(icon: icon, ratio: listRatio, ring: listRing, flipped: true)
        (selected ? MenuPalette.selectionFill : MenuPalette.backdrop).setFill()
        NSBezierPath(ovalIn: mark.insetBy(dx: -listRing, dy: -listRing)).fill()
        image(side: mark.width).draw(in: mark, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The Chrome mark beside text: on the `password` label, a previous password and the failure line.
struct ChromeGlyph: View {
    var side: CGFloat = 11

    var body: some View {
        Image(nsImage: ChromeBadge.image(side: side))
            .resizable()
            .frame(width: side, height: side)
            .accessibilityLabel("Chrome")
    }
}
