import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

final class IconGeometryTests: XCTestCase {
    func testAspectFitCentersLandscapePortraitAndSquareImages() {
        let slot = CGRect(x: 10, y: 20, width: 16, height: 16)
        XCTAssertEqual(IconGeometry.aspectFit(CGSize(width: 18, height: 12), in: slot), CGRect(x: 10, y: 20 + 8.0 / 3, width: 16, height: 32.0 / 3))
        let portrait = IconGeometry.aspectFit(CGSize(width: 12, height: 18), in: slot)
        XCTAssertEqual(portrait.minX, 10 + 8.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(portrait.minY, 20)
        XCTAssertEqual(portrait.width, 32.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(portrait.height, 16)
        XCTAssertEqual(IconGeometry.aspectFit(CGSize(width: 16, height: 16), in: slot), slot)
    }

    func testAspectFitRejectsInvalidGeometry() {
        let slot = CGRect(x: 10, y: 20, width: 16, height: 16)
        for size in [CGSize.zero, CGSize(width: -1, height: 4), CGSize(width: CGFloat.infinity, height: 4), CGSize(width: 4, height: CGFloat.nan)] {
            XCTAssertEqual(IconGeometry.aspectFit(size, in: slot), .zero)
        }
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 4), CGRect(x: CGFloat.infinity, y: 0, width: 4, height: 4)] {
            XCTAssertEqual(IconGeometry.aspectFit(CGSize(width: 18, height: 12), in: rect), .zero)
        }
    }

    @MainActor
    func testActualSymbolsKeepAspectRatioInBothSlots() async throws {
        for name in ["key.fill", "folder.fill", "creditcard.fill", "person.crop.rectangle.fill", "doc.fill", "note.text", "star.fill", "lock.square.fill", "tag.fill"] {
            let icon = try XCTUnwrap(MenuIcons.symbol(name, color: .labelColor))
            for side in [CGFloat(16), CGFloat(9)] {
                let slot = CGRect(x: 12, y: 24, width: side, height: side)
                let fitted = IconGeometry.aspectFit(icon.size, in: slot)
                XCTAssertEqual(fitted.width / fitted.height, icon.size.width / icon.size.height, accuracy: 0.000001, name)
                XCTAssertEqual(fitted.midX, slot.midX, accuracy: 0.000001, name)
                XCTAssertEqual(fitted.midY, slot.midY, accuracy: 0.000001, name)
                XCTAssertTrue(slot.contains(fitted), name)
            }
        }
    }

    func testSelectedPieAndMenuBarTemplate() {
        let path = MenuBarIcon.path()
        XCTAssertEqual(MenuBarIcon.size, CGSize(width: 18, height: 18))
        XCTAssertEqual(path.windingRule, .evenOdd)
        XCTAssertEqual(path.bounds.minX, 1.425, accuracy: 0.000001)
        XCTAssertEqual(path.bounds.minY, 1.425, accuracy: 0.000001)
        XCTAssertEqual(path.bounds.width, 15.15, accuracy: 0.000001)
        XCTAssertEqual(path.bounds.height, 15.15, accuracy: 0.000001)
        XCTAssertTrue(path.contains(CGPoint(x: 4, y: 6)))
        XCTAssertFalse(path.contains(CGPoint(x: 9, y: 6)))
        XCTAssertFalse(path.contains(CGPoint(x: 9, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 9, y: 14)))
        XCTAssertTrue(path.contains(CGPoint(x: 15, y: 9)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 9)))
        let image = MenuBarIcon.image()
        XCTAssertEqual(image.size, CGSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(PasswordPieShape().path(in: CGRect(origin: .zero, size: MenuBarIcon.size)).cgPath, path.cgPath)
    }

    func testPieFitsNonSquareCanvasWithoutStretching() {
        for rect in [CGRect(x: 10, y: 20, width: 36, height: 18),
                     CGRect(x: 10, y: 20, width: 18, height: 36)] {
            let bounds = PasswordPieShape().path(in: rect).boundingRect
            // SwiftUI Path stores transformed bounds at single-precision accuracy.
            XCTAssertEqual(bounds.width, 15.15, accuracy: 0.00001)
            XCTAssertEqual(bounds.height, 15.15, accuracy: 0.00001)
            XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.00001)
            XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.00001)
        }
    }

    func testPieOutlineMatchesEverySelectedSVGVertex() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let svg = try String(contentsOf: root.appendingPathComponent("art/source/mark.svg"), encoding: .utf8)
        // Read only this fixed SVG's polygon, not a general SVG parser.
        let outline = try XCTUnwrap(svg.components(separatedBy: "d=\"").last?.components(separatedBy: " Z ").first)
        let expression = try NSRegularExpression(pattern: "[ML]([0-9.]+) ([0-9.]+)")
        let matches = expression.matches(in: outline, range: NSRange(outline.startIndex..., in: outline))
        XCTAssertEqual(matches.count, 120)
        let path = MenuBarIcon.path()
        guard path.elementCount >= matches.count else {
            return XCTFail("Native pie is missing selected SVG vertices")
        }
        var points = [NSPoint](repeating: .zero, count: 3)
        for (index, match) in matches.enumerated() {
            let xRange = try XCTUnwrap(Range(match.range(at: 1), in: outline))
            let yRange = try XCTUnwrap(Range(match.range(at: 2), in: outline))
            let x = try XCTUnwrap(Double(outline[xRange]))
            let y = try XCTUnwrap(Double(outline[yRange]))
            XCTAssertEqual(path.element(at: index, associatedPoints: &points), index == 0 ? .moveTo : .lineTo)
            XCTAssertEqual(points[0].x, x * 0.75, accuracy: 0.000000001)
            XCTAssertEqual(points[0].y, y * 0.75, accuracy: 0.000000001)
        }
    }

    func testKeyholeCircularArcAndVerticalSymmetry() {
        let path = MenuBarIcon.path()
        let centerY = 11.6 - sqrt(3 * 3 - 1.35 * 1.35)
        // Upper semicircle must agree with the SVG's radius-3 circular arc.
        for degrees in stride(from: 185.0, through: 355.0, by: 5) {
            let angle = degrees * .pi / 180
            for (radius, filled) in [(2.99999, false), (3.00001, true)] {
                let point = CGPoint(x: (12 + radius * cos(angle)) * 0.75,
                                    y: (centerY + radius * sin(angle)) * 0.75)
                XCTAssertEqual(path.contains(point), filled, "radius=\(radius), angle=\(degrees)")
            }
        }
        for x in stride(from: 0.125, to: 9.0, by: 0.25) {
            for y in stride(from: 0.125, to: 18.0, by: 0.25) {
                XCTAssertEqual(path.contains(CGPoint(x: x, y: y)), path.contains(CGPoint(x: 18 - x, y: y)))
            }
        }
    }

    func testCanonicalSVGAssetsShareSelectedGeometryAndFullScale() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("art/source")
        let mark = try String(contentsOf: source.appendingPathComponent("mark.svg"), encoding: .utf8)
        let menubar = try String(contentsOf: source.appendingPathComponent("menubar.svg"), encoding: .utf8)
        let icon = try String(contentsOf: source.appendingPathComponent("icon.svg"), encoding: .utf8)
        func pathData(_ svg: String) throws -> String {
            let expression = try NSRegularExpression(pattern: "<path[^>]* d=\"([^\"]+)\"")
            let match = try XCTUnwrap(expression.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)))
            return String(svg[try XCTUnwrap(Range(match.range(at: 1), in: svg))])
        }
        XCTAssertEqual(try pathData(mark), try pathData(menubar))
        XCTAssertEqual(try pathData(mark), try pathData(icon))
        XCTAssertTrue(mark.contains("viewBox=\"0 0 24 24\""))
        XCTAssertTrue(menubar.contains("width=\"18\" height=\"18\" viewBox=\"0 0 24 24\""))
        XCTAssertTrue(icon.contains("transform=\"translate(0 0) scale(42.6666666667)\""))
        XCTAssertTrue(icon.contains("viewBox=\"0 0 1024 1024\""))
        XCTAssertTrue(icon.contains("color=\"#EE8C32\""))
    }

    @MainActor
    func testMenuBarRasterPreservesTransparentKeyhole() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        MenuBarIcon.image().draw(in: CGRect(x: 0, y: 0, width: 180, height: 180), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 90, y: 60)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 90, y: 100)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 150, y: 90)).alphaComponent, 1)
    }

    @MainActor
    func testBrandMarkRendersFlatOrangeWithTransparentKeyhole() throws {
        let renderer = ImageRenderer(content: PasswordPieMark(size: 180))
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(rep.colorSpace, NSColorSpace.sRGB)
        XCTAssertEqual(rep.bitsPerSample, 8)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 90, y: 60)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 90, y: 100)).alphaComponent, 0)
        for point in [(45, 90), (150, 90), (90, 150)] {
            // Read the verified sRGB bitmap directly: colorAt labels its values as
            // NSCalibratedRGBColorSpace, so converting that NSColor would change them.
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: point.0, y: point.1)
            XCTAssertEqual(pixel, [238, 140, 50, 255])
        }
    }
}
