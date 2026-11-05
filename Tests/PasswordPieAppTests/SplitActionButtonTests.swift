import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

@MainActor
final class SplitActionButtonTests: XCTestCase {
    private func render<V: View>(_ view: V, dark: Bool) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.padding(4))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func pixelCount(_ bitmap: NSBitmapImageRep, where matches: (CGFloat, CGFloat, CGFloat) -> Bool) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                if matches(color.redComponent, color.greenComponent, color.blueComponent) { count += 1 }
            }
        }
        return count
    }

    private let item = SplitActionButton.Item(title: "More") {}

    func testRegularSizeMatchesThePasswordWellAndCompactFitsADetailRow() {
        XCTAssertEqual(SplitActionButton.Size.regular.height, 28)
        XCTAssertLessThanOrEqual(SplitActionButton.Size.compact.height, 21)
    }

    func testArrowIsAtLeastAsWideAsItIsTallInDetails() {
        XCTAssertGreaterThanOrEqual(SplitActionButton.Size.compact.arrowWidth, SplitActionButton.Size.compact.height)
    }

    /// A borderless Menu's arrow takes the control tint and ignores its label's colour, which is how orange or a blue system accent got in.
    func testQuietButtonDrawsNoAccentColourEvenUnderABrandTint() throws {
        for dark in [false, true] {
            let view = SplitActionButton(title: "Copy", size: .regular, prominence: .quiet, items: [item]) {}
                .tint(Palette.brandAccent)
            let bitmap = try render(view, dark: dark)
            let saturated = pixelCount(bitmap) { red, _, blue in abs(red - blue) > 0.35 }
            XCTAssertEqual(saturated, 0, "dark: \(dark)")
        }
    }

    func testPrimaryButtonFillsWithBrandAccent() throws {
        let bitmap = try render(SplitActionButton(title: "Copy", size: .regular, prominence: .primary, items: [item]) {}, dark: false)
        let accent = pixelCount(bitmap) { red, green, blue in
            abs(red - 0.933) < 0.08 && abs(green - 0.549) < 0.08 && abs(blue - 0.196) < 0.08
        }
        XCTAssertGreaterThan(accent, bitmap.pixelsWide * bitmap.pixelsHigh / 3)
    }

    func testLabelsAreReadableOnTheirFills() throws {
        func luminance(_ color: Color) throws -> CGFloat {
            let srgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            func channel(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
        }
        func contrast(_ one: Color, _ other: Color) throws -> CGFloat {
            let first = try luminance(one), second = try luminance(other)
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }
        for dark in [false, true] {
            for prominence in [SplitActionButton.Prominence.quiet, .primary] {
                let colors = prominence.colors(dark: dark)
                XCTAssertGreaterThanOrEqual(try contrast(colors.label, colors.fill), 4.5)
                XCTAssertGreaterThanOrEqual(try contrast(colors.arrow, colors.fill), 4.5)
            }
        }
    }
}
