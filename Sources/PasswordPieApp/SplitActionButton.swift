import SwiftUI

/// The one button that runs an action and, through its arrow, offers more: details fields and the generator.
/// The arrow appears only when `items` is not empty. Items never repeat the word on the button.
struct SplitActionButton: View {
    struct Item: Identifiable {
        var title: String
        var action: () -> Void
        var id: String { title }
    }

    enum Size {
        /// A hover action inside a details row.
        case compact
        /// Sits beside the 28 pt generator well.
        case regular

        var height: CGFloat { self == .compact ? 20 : 28 }
        var fontSize: CGFloat { self == .compact ? 11 : 12 }
        var labelPadding: CGFloat { self == .compact ? 7 : 10 }
        var arrowWidth: CGFloat { self == .compact ? 20 : 24 }
        var arrowSize: CGFloat { self == .compact ? 8 : 9 }
    }

    enum Prominence {
        /// Repeated actions: field surface and a hairline.
        case quiet
        /// The surface's one main action: `on-accent` on `brand-accent`.
        case primary

        struct Colors {
            var fill: Color
            var label: Color
            var arrow: Color
            var line: Color
            var hover: Color
            var pressed: Color
        }

        func colors(dark: Bool) -> Colors {
            switch self {
            case .quiet:
                let ink = Palette.text(dark: dark)
                return Colors(
                    fill: Palette.fieldSurface(dark: dark),
                    label: ink,
                    arrow: Palette.secondaryText(dark: dark),
                    line: ink.opacity(0.25),
                    hover: ink.opacity(0.1),
                    pressed: ink.opacity(0.18)
                )
            case .primary:
                let ink = Palette.onAccent
                return Colors(
                    fill: Palette.brandAccent,
                    label: ink,
                    arrow: ink,
                    line: ink.opacity(0.28),
                    hover: ink.opacity(0.1),
                    pressed: ink.opacity(0.18)
                )
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    var title: String
    var size: Size = .compact
    var prominence: Prominence = .quiet
    /// Semibold only for Upgrade to unlock, the one word a locked code row has.
    var weight: Font.Weight = .regular
    var items: [Item] = []
    var action: () -> Void

    var body: some View {
        let colors = prominence.colors(dark: colorScheme == .dark)
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: size.fontSize, weight: weight))
                    .foregroundStyle(colors.label)
                    .padding(.horizontal, size.labelPadding)
                    .frame(height: size.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SegmentStyle(hover: colors.hover, pressed: colors.pressed))
            .help(title)
            if !items.isEmpty {
                Rectangle().fill(colors.line).frame(width: 0.5)
                ArrowSegment(items: items, size: size, colors: colors)
            }
        }
        .fixedSize()
        .background(colors.fill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if prominence == .quiet {
                RoundedRectangle(cornerRadius: 5).strokeBorder(colors.line, lineWidth: 0.5)
            }
        }
    }
}

private struct SegmentStyle: ButtonStyle {
    var hover: Color
    var pressed: Color

    func makeBody(configuration: Configuration) -> some View {
        Segment(isPressed: configuration.isPressed, hover: hover, pressed: pressed) { configuration.label }
    }
}

private struct Segment<Label: View>: View {
    var isPressed = false
    var hover: Color
    var pressed: Color
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        label
            .background(isPressed ? pressed : hovering ? hover : Color.clear)
            .onHover { hovering = $0 }
    }
}

/// `.button` draws the label as written. `.borderlessButton` hands it to AppKit, which ignores the size and paints it in the control tint.
private struct ArrowSegment: View {
    var items: [SplitActionButton.Item]
    var size: SplitActionButton.Size
    var colors: SplitActionButton.Prominence.Colors

    var body: some View {
        Segment(hover: colors.hover, pressed: colors.pressed) {
            Menu {
                ForEach(items) { item in
                    Button(item.title, action: item.action)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: size.arrowSize, weight: .semibold))
                    .foregroundStyle(colors.arrow)
                    .frame(width: size.arrowWidth, height: size.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More actions")
        }
    }
}
