import SwiftUI

/// The same vector as the menu-bar mark, including its round-headed keyhole cutout.
struct PasswordPieShield: Shape {
    func path(in rect: CGRect) -> Path {
        let fitted = IconGeometry.aspectFit(MenuBarIcon.size, in: rect)
        guard fitted.width > 0 else { return Path() }
        let scale = fitted.width / MenuBarIcon.size.width
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: fitted.minX, ty: fitted.minY)
        return Path(MenuBarIcon.path().cgPath).applying(transform)
    }
}

/// Shared own-brand artwork. Use monochrome for template buttons and silver for hero marks.
struct PasswordPieMark: View {
    enum Style {
        case silver
        case monochrome
    }

    var size: CGFloat
    var turn: Double = 0
    var style: Style = .silver

    var body: some View {
        ZStack {
            switch style {
            case .monochrome:
                PasswordPieShield().fill(Color.primary, style: FillStyle(eoFill: true))
            case .silver:
                // Nonzero fill gives the silver keyhole a graphite backing across the door seam.
                // The slightly offset base also gives the shield a fine graphite edge.
                PasswordPieShield()
                    .fill(Color(hex: 0x373D46))
                    .offset(y: size / 96)
                    .shadow(color: .black.opacity(0.24), radius: size / 24, y: size / 32)
                PasswordPieShield()
                    .fill(
                        LinearGradient(stops: [
                            .init(color: Color(hex: 0xFFFFFF), location: 0),
                            .init(color: Color(hex: 0xDDE1E7), location: 0.3),
                            .init(color: Color(hex: 0xA4ABB5), location: 0.57),
                            .init(color: Color(hex: 0xE7EBEF), location: 0.82),
                            .init(color: Color(hex: 0xB0B7C0), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: FillStyle(eoFill: true)
                    )
                    .overlay {
                        PasswordPieShield().stroke(
                            LinearGradient(colors: [.white.opacity(0.95), Color(hex: 0x626A75)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: max(0.5, size / 96)
                        )
                    }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + 0.035 * turn)
        .brightness(0.06 * turn)
        .animation(.easeInOut(duration: 0.35), value: turn)
        .accessibilityHidden(true)
    }
}
