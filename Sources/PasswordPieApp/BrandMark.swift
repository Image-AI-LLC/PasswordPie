import SwiftUI

/// The same pie vector as the menu bar, with a transparent keyhole cutout.
struct PasswordPieShape: Shape {
    func path(in rect: CGRect) -> Path {
        let fitted = IconGeometry.aspectFit(MenuBarIcon.size, in: rect)
        guard fitted.width > 0 else { return Path() }
        let scale = fitted.width / MenuBarIcon.size.width
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: fitted.minX, ty: fitted.minY)
        return Path(MenuBarIcon.path().cgPath).applying(transform)
    }
}

/// Flat orange own-brand artwork, or monochrome for the header/template buttons.
struct PasswordPieMark: View {
    enum Style {
        case orange
        case monochrome
    }

    var size: CGFloat
    var turn: Double = 0
    var style: Style = .orange

    var body: some View {
        PasswordPieShape()
            .fill(style == .monochrome ? Color.primary : Color(hex: 0xEE8C32),
                  style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .scaleEffect(1 + 0.035 * turn)
            .animation(.easeInOut(duration: 0.35), value: turn)
            .accessibilityHidden(true)
    }
}
