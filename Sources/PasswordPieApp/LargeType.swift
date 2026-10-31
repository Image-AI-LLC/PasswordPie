import AppKit
import SwiftUI

struct LargeTypeCell: Equatable {
    enum Kind: Equatable {
        case letter, digit, symbol, space
    }

    var character: Character
    var kind: Kind

    /// A password space is a visible mark. An inserted gap would look like a space, and a real space would disappear.
    var shown: String { kind == .space ? "␣" : String(character) }
}

enum LargeType {
    static let groupSize = 4

    static func groups(in text: String) -> [[LargeTypeCell]] {
        let cells = text.map { character in
            LargeTypeCell(character: character, kind: kind(of: character))
        }
        return stride(from: 0, to: cells.count, by: groupSize).map { start in
            Array(cells[start..<min(start + groupSize, cells.count)])
        }
    }

    static func kind(of character: Character) -> LargeTypeCell.Kind {
        if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .space
        }
        if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return .digit
        }
        if character.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            return .letter
        }
        return .symbol
    }

    /// Packs whole groups onto rows. A group that is wider than `maxWidth` stays on its own row.
    static func rowRanges(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [Range<Int>] {
        guard !widths.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let next = index == start ? width : used + spacing + width
            if index > start, next > maxWidth {
                ranges.append(start..<index)
                start = index
                used = width
            } else {
                used = next
            }
        }
        ranges.append(start..<widths.count)
        return ranges
    }
}

struct LargeTypeLayout: Equatable {
    var fontSize: CGFloat = 54
    /// Tests pin one width. Live layout leaves this nil and measures each glyph.
    var uniformCellWidth: CGFloat?
    var groupHeight: CGFloat
    var groupSpacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var stripePaddingH: CGFloat = 10
    var outerPadding: CGFloat = 24
    /// Last-resort shrink after the font is already at its floor. 1 means the font itself fits.
    var scale: CGFloat = 1

    static let preferredFontSize: CGFloat = 54

    static func metrics(fontSize: CGFloat) -> LargeTypeLayout {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let factor = fontSize / preferredFontSize
        return LargeTypeLayout(
            fontSize: fontSize,
            groupHeight: ceil(font.ascender - font.descender + font.leading) + 12 * factor,
            groupSpacing: 8 * factor,
            lineSpacing: 8 * factor,
            stripePaddingH: 10 * factor,
            outerPadding: 24 * factor
        )
    }

    func cellWidth(for shown: String) -> CGFloat {
        if let uniformCellWidth { return uniformCellWidth }
        return LargeTypeMetrics.glyphWidth(shown, fontSize: fontSize)
    }

    func groupWidth(_ cells: [LargeTypeCell]) -> CGFloat {
        cells.reduce(CGFloat(0)) { $0 + cellWidth(for: $1.shown) } + stripePaddingH * 2
    }
}

struct LargeTypeArrangement: Equatable {
    var rows: [Range<Int>]
    var size: CGSize
}

struct LargeTypeFit: Equatable {
    var layout: LargeTypeLayout
    var rows: [Range<Int>]
    /// Size before `layout.scale`. The window uses `size`.
    var unscaled: CGSize
    var size: CGSize
}

enum LargeTypeMetrics {
    /// Reflow down to 1 pt before the last-resort scale. A higher floor leaves a huge unscaled layout.
    static let minimumFontSize: CGFloat = 1

    static func glyphWidth(_ shown: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: max(fontSize, 1), weight: .medium)
        let size = (shown as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    static func arrange(text: String, maxWidth: CGFloat, layout: LargeTypeLayout) -> LargeTypeArrangement {
        let groups = LargeType.groups(in: text)
        let widths = groups.map { layout.groupWidth($0) }
        let contentLimit = max(maxWidth - layout.outerPadding * 2, widths.max() ?? 0)
        let rows = LargeType.rowRanges(widths: widths, spacing: layout.groupSpacing, maxWidth: contentLimit)
        guard !rows.isEmpty else {
            let pad = layout.outerPadding * 2
            return LargeTypeArrangement(rows: [], size: CGSize(width: pad, height: pad))
        }
        let rowWidth = rows.map { range -> CGFloat in
            let slice = range.map { widths[$0] }
            return slice.reduce(0, +) + layout.groupSpacing * CGFloat(slice.count - 1)
        }.max() ?? 0
        let count = CGFloat(rows.count)
        let body = count * layout.groupHeight + layout.lineSpacing * (count - 1)
        let size = CGSize(
            width: ceil(rowWidth + layout.outerPadding * 2),
            height: ceil(body + layout.outerPadding * 2)
        )
        return LargeTypeArrangement(rows: rows, size: size)
    }

    static func windowSize(text: String, maxWidth: CGFloat, layout: LargeTypeLayout = .metrics(fontSize: 54)) -> CGSize {
        arrange(text: text, maxWidth: maxWidth, layout: layout).size
    }

    /// Picks the largest font whose window fits in the box. A window that is still too big at the floor font is scaled down.
    static func fit(text: String, maxWidth: CGFloat, maxHeight: CGFloat) -> LargeTypeFit {
        let boxWidth = max(maxWidth, 1)
        let boxHeight = max(maxHeight, 1)
        func candidate(_ fontSize: CGFloat) -> (LargeTypeLayout, LargeTypeArrangement) {
            let layout = LargeTypeLayout.metrics(fontSize: fontSize)
            return (layout, arrange(text: text, maxWidth: boxWidth, layout: layout))
        }
        func inside(_ size: CGSize) -> Bool {
            size.width <= boxWidth + 0.5 && size.height <= boxHeight + 0.5
        }
        let preferred = candidate(LargeTypeLayout.preferredFontSize)
        if inside(preferred.1.size) {
            return packed(layout: preferred.0, arrangement: preferred.1, scale: 1, boxWidth: boxWidth, boxHeight: boxHeight)
        }
        var low = minimumFontSize
        var high = LargeTypeLayout.preferredFontSize
        var best = candidate(minimumFontSize)
        for _ in 0..<16 {
            let mid = (low + high) / 2
            let trial = candidate(mid)
            if inside(trial.1.size) {
                best = trial
                low = mid
            } else {
                high = mid
            }
        }
        let scale = inside(best.1.size) ? CGFloat(1) : scaleThatFits(unscaled: best.1.size, boxWidth: boxWidth, boxHeight: boxHeight)
        var layout = best.0
        layout.scale = scale
        return packed(layout: layout, arrangement: best.1, scale: scale, boxWidth: boxWidth, boxHeight: boxHeight)
    }

    /// Exact shrink so `unscaled * scale` lands in the box. A fixed floor would leave the drawing larger than the window.
    static func scaleThatFits(unscaled: CGSize, boxWidth: CGFloat, boxHeight: CGFloat) -> CGFloat {
        guard unscaled.width > 0, unscaled.height > 0, boxWidth > 0, boxHeight > 0 else { return 1 }
        let needed = min(boxWidth / unscaled.width, boxHeight / unscaled.height)
        return min(max(needed, 0), 1)
    }

    private static func packed(
        layout: LargeTypeLayout,
        arrangement: LargeTypeArrangement,
        scale: CGFloat,
        boxWidth: CGFloat,
        boxHeight: CGFloat
    ) -> LargeTypeFit {
        func axis(_ length: CGFloat, limit: CGFloat) -> CGFloat {
            let raw = length * scale
            if raw < 1 { return min(limit, 1) }
            return min(limit, floor(raw))
        }
        let scaled = CGSize(width: axis(arrangement.size.width, limit: boxWidth), height: axis(arrangement.size.height, limit: boxHeight))
        return LargeTypeFit(layout: layout, rows: arrangement.rows, unscaled: arrangement.size, size: scaled)
    }
}

struct LargeTypeView: View {
    var text: String
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        let fit = LargeTypeMetrics.fit(text: text, maxWidth: maxWidth, maxHeight: maxHeight)
        let groups = LargeType.groups(in: text)
        VStack(spacing: fit.layout.lineSpacing) {
            ForEach(Array(fit.rows.enumerated()), id: \.offset) { _, range in
                HStack(spacing: fit.layout.groupSpacing) {
                    ForEach(Array(range), id: \.self) { index in
                        stripe(groups[index], layout: fit.layout, filled: index.isMultiple(of: 2))
                    }
                }
            }
        }
        .frame(width: fit.unscaled.width, height: fit.unscaled.height)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.88)))
        .scaleEffect(fit.layout.scale)
        .frame(width: fit.size.width, height: fit.size.height)
    }

    private func stripe(_ cells: [LargeTypeCell], layout: LargeTypeLayout, filled: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.shown)
                    .font(.system(size: layout.fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink(cell.kind))
                    .lineLimit(1)
                    .frame(width: layout.cellWidth(for: cell.shown))
            }
        }
        .padding(.horizontal, layout.stripePaddingH)
        .frame(height: layout.groupHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(filled ? 0.18 : 0.09)))
    }

    private func ink(_ kind: LargeTypeCell.Kind) -> Color {
        switch kind {
        case .letter: Color(hex: 0xFFFFFF)
        case .digit: Color(hex: 0x5CB3FF)
        case .symbol: Color(hex: 0xFFBF59)
        case .space: Color.white.opacity(0.55)
        }
    }
}
