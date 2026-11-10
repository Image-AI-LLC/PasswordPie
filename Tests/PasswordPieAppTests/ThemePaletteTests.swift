import AppKit
import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

final class ThemePaletteTests: XCTestCase {
    private func luminance(_ color: NSColor) throws -> CGFloat {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
    }

    private func contrast(_ one: Color, _ other: Color) throws -> CGFloat {
        let first = try luminance(NSColor(one))
        let second = try luminance(NSColor(other))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testSelectedRowInkIsReadableOnTheOrangeSelection() throws {
        XCTAssertGreaterThanOrEqual(try contrast(Palette.selectionInk, Palette.selectionFill), 4.5)
    }

    /// `top` drawn over the opaque `bottom` in `appearance`, as the menu list draws it.
    private func composite(_ top: NSColor, over bottom: NSColor, in appearance: NSAppearance.Name) throws -> NSColor {
        var result: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let upper = top.usingColorSpace(.sRGB), let lower = bottom.usingColorSpace(.sRGB) else { return }
            let alpha = upper.alphaComponent
            func mix(_ one: CGFloat, _ two: CGFloat) -> CGFloat { alpha * one + (1 - alpha) * two }
            result = NSColor(
                srgbRed: mix(upper.redComponent, lower.redComponent),
                green: mix(upper.greenComponent, lower.greenComponent),
                blue: mix(upper.blueComponent, lower.blueComponent),
                alpha: 1
            )
        }
        return try XCTUnwrap(result)
    }

    private func contrast(_ one: NSColor, _ other: NSColor) throws -> CGFloat {
        let first = try luminance(one)
        let second = try luminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testAnActionRowsLineIsReadableOnTheSelection() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let line = try composite(MenuPalette.selectedActionDetail, over: MenuPalette.selectionFill, in: name)
            let fill = try composite(MenuPalette.selectionFill, over: MenuPalette.selectionFill, in: name)
            XCTAssertGreaterThanOrEqual(try contrast(line, fill), 4.5, name.rawValue)
        }
    }

    /// The light tile is the approved look; the dark surface must not lose it.
    func testAnActionTileStandsOutOnTheDarkSurfaceAsMuchAsOnTheLightOne() throws {
        func tileContrast(_ name: NSAppearance.Name) throws -> CGFloat {
            let tile = try composite(MenuPalette.actionTile, over: MenuPalette.backdrop, in: name)
            let surface = try composite(MenuPalette.backdrop, over: MenuPalette.backdrop, in: name)
            return try contrast(tile, surface)
        }
        XCTAssertGreaterThanOrEqual(try tileContrast(.darkAqua), try tileContrast(.aqua))
    }

    func testWhiteOnBrandOrangeWouldFailSoSelectionMustNotUseIt() throws {
        XCTAssertLessThan(try contrast(Color(hex: 0xFFFFFF), Palette.selectionFill), 4.5)
    }

    func testAccentTextIsReadableOnEveryWarmSurface() throws {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(try contrast(Palette.accentText(dark: dark), Palette.surface(dark: dark)), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(Palette.accentText(dark: dark), Palette.fieldSurface(dark: dark)), 4.5)
        }
    }

    func testBodyTextIsReadableOnEveryWarmSurface() throws {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(try contrast(Palette.text(dark: dark), Palette.surface(dark: dark)), 7)
            XCTAssertGreaterThanOrEqual(try contrast(Palette.secondaryText(dark: dark), Palette.surface(dark: dark)), 4.5)
        }
    }

    func testErrorRedIsReadableOnEveryWarmSurface() throws {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(try contrast(Palette.error(dark: dark), Palette.surface(dark: dark)), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(Palette.error(dark: dark), Palette.fieldSurface(dark: dark)), 4.5)
        }
    }

    /// Medium strength must not look like the brand, or a warning reads as decoration.
    func testMediumPasswordStrengthIsNotTheBrandOrange() {
        XCTAssertNotEqual(NSColor(Palette.strengthMedium), NSColor(Palette.brandAccent))
    }

    /// Digits and symbols stay distinct from each other and from letters in Large Type.
    func testLargeTypeInksStayDistinct() {
        let inks = [Palette.largeTypeLetter, Palette.largeTypeDigit, Palette.largeTypeSymbol].map { NSColor($0) }
        XCTAssertEqual(Set(inks).count, 3)
    }

    /// System accent would bring the blue back on any Mac whose accent colour is blue.
    func testAppCodeDoesNotReachForTheSystemAccentColor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp")
        let banned = ["Color.accentColor", ".accentColor", "selectedContentBackgroundColor", "keyboardFocusIndicatorColor", "controlAccentColor"]
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for term in banned {
                XCTAssertFalse(text.contains(term), "\(file.lastPathComponent) uses \(term)")
            }
        }
    }

    @MainActor
    func testSelectedRowIsDrawnInBrandOrangeInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let list = MenuListView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            list.appearance = NSAppearance(named: name)
            list.setRows([MenuRow(kind: .submenu, title: "Logins", icon: .tags)])
            list.selectedIndex = 0
            let rep = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.bounds))
            list.cacheDisplay(in: list.bounds, to: rep)
            // Inside the selected row, clear of the icon, title and arrow. colorAt counts y from the top of the bitmap.
            let sample = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide * 3 / 4, y: rep.pixelsHigh / 6)?.usingColorSpace(.sRGB))
            let brand = try XCTUnwrap(NSColor(Palette.brandAccent).usingColorSpace(.sRGB))
            XCTAssertEqual(sample.redComponent, brand.redComponent, accuracy: 0.02, name.rawValue)
            XCTAssertEqual(sample.greenComponent, brand.greenComponent, accuracy: 0.02, name.rawValue)
            XCTAssertEqual(sample.blueComponent, brand.blueComponent, accuracy: 0.02, name.rawValue)
        }
    }
}
