import AppKit
import XCTest
@testable import PasswordPie

/// A source whose app is not on this Mac shows the icon that ships with PasswordPie (docs/UX.md, "Import with a guide").
@MainActor
final class ImportIconTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Apple's own apps are on every Mac that runs PasswordPie, and "Another App" is no app at all.
    private let withoutBundledIcon: Set<String> = ["safari", "apple-passwords", "csv"]

    func testEverySourceThatMayNotBeInstalledHasABundledIcon() throws {
        let folder = root.appendingPathComponent("Assets/ImportIcons", isDirectory: true)
        for tile in ImportTile.all where !withoutBundledIcon.contains(tile.id) {
            for suffix in ["", "@2x"] {
                let file = folder.appendingPathComponent(tile.id + suffix + ".png")
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: file)), file.lastPathComponent)
                XCTAssertEqual(rep.pixelsWide, suffix.isEmpty ? 64 : 128, file.lastPathComponent)
                XCTAssertEqual(rep.pixelsHigh, rep.pixelsWide, file.lastPathComponent)
            }
        }
    }

    func testASourceWithoutABundledIconHasASymbolToFallBackOn() {
        for id in withoutBundledIcon {
            XCTAssertNotNil(ImportTile.tile(id)?.symbol, id)
        }
    }

    func testTheBundledIconIsReadFromTheAppsResources() throws {
        let saved = ImportIcon.bundledDirectory
        defer { ImportIcon.bundledDirectory = saved }
        ImportIcon.bundledDirectory = root.appendingPathComponent("Assets/ImportIcons", isDirectory: true)
        let icon = try XCTUnwrap(ImportIcon.bundledIcon(try XCTUnwrap(ImportTile.tile("bitwarden"))))
        XCTAssertEqual(icon.representations.count, 2, "64 px and 128 px")
        XCTAssertNil(ImportIcon.bundledIcon(try XCTUnwrap(ImportTile.tile("csv"))))
    }

    func testTheAppBundleGetsTheIcons() throws {
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        XCTAssertTrue(makefile.contains(#"cp Assets/ImportIcons/*.png "$(2)/Contents/Resources/ImportIcons/""#))
    }
}
