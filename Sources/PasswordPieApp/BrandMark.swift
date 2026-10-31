import SwiftUI

/// The same pie vector as the menu bar, with a transparent keyhole cutout.
struct PasswordPieShape: Shape {
    func path(in rect: CGRect) -> Path { MenuBarIcon.fitted(MenuBarIcon.path(), in: rect) }
}

/// The scalloped outer pie, without the keyhole.
struct PasswordPieRimShape: Shape {
    func path(in rect: CGRect) -> Path { MenuBarIcon.fitted(MenuBarIcon.rimPath(), in: rect) }
}

/// The keyhole alone.
struct PasswordPieKeyholeShape: Shape {
    func path(in rect: CGRect) -> Path { MenuBarIcon.fitted(MenuBarIcon.keyholePath(), in: rect) }
}

extension MenuBarIcon {
    static func fitted(_ source: NSBezierPath, in rect: CGRect) -> Path {
        let fitted = IconGeometry.aspectFit(size, in: rect)
        guard fitted.width > 0 else { return Path() }
        let scale = fitted.width / size.width
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: fitted.minX, ty: fitted.minY)
        return Path(source.cgPath).applying(transform)
    }
}

/// The rim turns at a steady speed while a database decrypts. When the work ends it eases onto
/// the next scallop, so it stops looking exactly as it started, with no jump.
struct RimSpin: Equatable {
    /// The rim has 12 scallops, so a 30° turn looks identical.
    static let scallop = 30.0
    static let degreesPerSecond = 300.0

    private(set) var restAngle = 0.0
    private(set) var startedAt: Date?
    private(set) var settle: Settle?

    struct Settle: Equatable {
        var from: Double
        var to: Double
        var at: Date
        var duration: Double
    }

    var isSpinning: Bool { startedAt != nil }
    var isMoving: Bool { startedAt != nil || settle != nil }

    func angle(at date: Date) -> Double {
        if let startedAt {
            return restAngle + max(0, date.timeIntervalSince(startedAt)) * Self.degreesPerSecond
        }
        if let settle {
            let progress = min(1, max(0, date.timeIntervalSince(settle.at) / settle.duration))
            // Cubic ease-out starts at 3·distance/duration, which equals the spin speed.
            let eased = 1 - pow(1 - progress, 3)
            return settle.from + (settle.to - settle.from) * eased
        }
        return restAngle
    }

    mutating func start(at date: Date) {
        guard startedAt == nil else { return }
        restAngle = angle(at: date).truncatingRemainder(dividingBy: 360)
        settle = nil
        startedAt = date
    }

    /// Returns how long the rim needs to come to rest.
    @discardableResult
    mutating func stop(at date: Date) -> TimeInterval {
        guard startedAt != nil else { return 0 }
        let from = angle(at: date)
        // One to two scallops ahead: long enough to slow down without a visible brake.
        let to = (floor(from / Self.scallop) + 2) * Self.scallop
        let duration = 3 * (to - from) / Self.degreesPerSecond
        startedAt = nil
        restAngle = to
        settle = Settle(from: from, to: to, at: date, duration: duration)
        return duration
    }

    mutating func finishSettling(at date: Date) {
        // A timer may fire a moment early; the angle is already clamped to the end.
        guard let settle, date.timeIntervalSince(settle.at) >= settle.duration - 0.05 else { return }
        self.settle = nil
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
    /// Turns the outer rim while the keyhole stays still.
    var spinning = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = RimSpin()

    private var color: Color { style == .monochrome ? Color.primary : Palette.brandAccent }

    var body: some View {
        TimelineView(.animation(paused: !spin.isMoving)) { context in
            ZStack {
                PasswordPieRimShape()
                    .fill(color)
                    .rotationEffect(.degrees(spin.angle(at: context.date)))
                PasswordPieKeyholeShape()
                    .fill(Color.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + 0.035 * turn)
        .animation(.easeInOut(duration: 0.35), value: turn)
        .onAppear { update(spinning: spinning) }
        .onChange(of: spinning) { _, now in update(spinning: now) }
        .accessibilityHidden(true)
    }

    private func update(spinning: Bool) {
        let now = Date()
        if spinning && !reduceMotion {
            spin.start(at: now)
        } else if spin.isSpinning {
            let duration = spin.stop(at: now)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                spin.finishSettling(at: Date())
            }
        }
    }
}
