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

    func testCanonicalShieldAndMenuBarTemplateRemainUnchanged() {
        let path = MenuBarIcon.path()
        XCTAssertEqual(MenuBarIcon.size, CGSize(width: 18, height: 18))
        XCTAssertEqual(path.elementCount, 17)
        XCTAssertEqual(path.windingRule, .evenOdd)
        XCTAssertEqual(path.bounds, CGRect(x: 1.5, y: 1, width: 15, height: 16))
        XCTAssertTrue(path.contains(CGPoint(x: 4, y: 6)))
        XCTAssertFalse(path.contains(CGPoint(x: 9, y: 6)))
        XCTAssertFalse(path.contains(CGPoint(x: 9, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 9, y: 14)))
        let image = MenuBarIcon.image()
        XCTAssertEqual(image.size, CGSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(PasswordPieShield().path(in: CGRect(origin: .zero, size: MenuBarIcon.size)).cgPath, path.cgPath)
    }

    func testShieldFitsNonSquareCanvasWithoutStretching() {
        let shape = PasswordPieShield().path(in: CGRect(x: 10, y: 20, width: 36, height: 18))
        XCTAssertEqual(shape.boundingRect, CGRect(x: 20.5, y: 21, width: 15, height: 16))
    }
}
