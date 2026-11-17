import PasswordPieCore
import XCTest
@testable import PasswordPie

/// What Preferences > Import offers, and what each source's page says (docs/UX.md, "Import with a guide").
final class ImportGuideTests: XCTestCase {
    private func guide(_ id: String, exchange: Bool = false, macOS: Int = 15) throws -> ImportGuide {
        ImportGuide.guide(for: try XCTUnwrap(ImportTile.tile(id)), exchange: exchange, macOS: macOS)
    }

    func testTheSourcesAreTheOnesTheGuideNames() {
        XCTAssertEqual(ImportTile.all.filter { $0.group == .browser }.map(\.name), ["Chrome", "Safari", "Firefox", "Edge", "Brave"])
        XCTAssertEqual(
            ImportTile.all.filter { $0.group == .manager }.map(\.name),
            ["Apple Passwords", "1Password", "Bitwarden", "Proton Pass", "LastPass", "Dashlane", "KeePass", "Another App"]
        )
        XCTAssertEqual(Set(ImportTile.all.map(\.id)).count, ImportTile.all.count)
    }

    func testEveryImportSourceHasATile() {
        let sources = Set(ImportTile.all.compactMap(\.source))
        XCTAssertEqual(sources, Set(BrowserImportSource.allCases))
    }

    func testEverySourceSaysHowToExportAndWhichFileItWants() throws {
        for tile in ImportTile.all where tile.source != nil {
            let guide = ImportGuide.guide(for: tile, exchange: false, macOS: 15)
            let export = try XCTUnwrap(guide.export, tile.name)
            XCTAssertGreaterThanOrEqual(export.steps.count, 3, "\(tile.name) is led through its export")
            XCTAssertFalse(guide.files.isEmpty, tile.name)
            XCTAssertTrue(guide.after.contains("“\(try XCTUnwrap(tile.source).label)” group"), tile.name)
        }
    }

    func testChromeIsLedToTheDownloadButton() throws {
        let export = try XCTUnwrap(guide("chrome").export)
        XCTAssertEqual(export.steps.count, 5)
        XCTAssertTrue(export.steps[0].contains("**Passwords and autofill > Google Password Manager**"))
        XCTAssertTrue(export.steps[2].contains("**Download file**"))
        XCTAssertEqual(export.address, "chrome://password-manager/settings")
        XCTAssertEqual(try guide("chrome").files, "Chrome Passwords.csv")
    }

    func testSafariAndApplePasswordsShareOneImport() throws {
        XCTAssertEqual(ImportTile.tile("safari")?.source, .applePasswords)
        XCTAssertEqual(ImportTile.tile("apple-passwords")?.source, .applePasswords)
        let safari = try guide("safari")
        XCTAssertEqual(safari.intro, "Safari keeps its passwords in Apple’s Passwords app.")
        XCTAssertNil(try guide("apple-passwords").intro)
        XCTAssertTrue(try XCTUnwrap(safari.export).steps[1].contains("**File > Export All Passwords to File…**"))
        XCTAssertTrue(safari.files.contains("Export Browsing Data to File…"))
    }

    func testApplePasswordsBeforeThePasswordsAppIsInSystemSettings() throws {
        let export = try XCTUnwrap(guide("apple-passwords", macOS: 14).export)
        XCTAssertTrue(export.steps[0].contains("**System Settings > Passwords**"))
        XCTAssertNil(export.opens)
    }

    func testApplePasswordsLeadsWithNoFileWhenPasswordsCanSendToThisApp() throws {
        XCTAssertNil(try guide("apple-passwords").withoutFile)
        let direct = try XCTUnwrap(guide("apple-passwords", exchange: true, macOS: 26).withoutFile)
        XCTAssertTrue(direct.steps[1].contains("**File > Export All Items to App…**"))
        XCTAssertNotNil(try guide("safari", exchange: true, macOS: 26).withoutFile)
        XCTAssertNil(try guide("chrome", exchange: true, macOS: 26).withoutFile, "only Apple Passwords sends its items")
    }

    func testABrowsersGuideSaysMissingSitesGoToTheRecycleBinAndAPasswordManagersDoesNot() throws {
        XCTAssertTrue(try guide("firefox").after.contains("Recycle Bin"))
        XCTAssertFalse(try guide("bitwarden").after.contains("Recycle Bin"))
        XCTAssertTrue(try guide("bitwarden").after.contains("Nothing is removed"))
        XCTAssertTrue(try guide("1password").after.contains("with their folders"))
        XCTAssertFalse(try guide("csv").after.contains("with their folders"))
    }

    func testKeePassHasNothingToExport() throws {
        let keePass = try guide("keepass")
        XCTAssertNil(keePass.export)
        XCTAssertNil(ImportTile.tile("keepass")?.source)
        XCTAssertTrue(try XCTUnwrap(keePass.intro).contains("nothing to export"))
    }

    func testBitwardenSaysWhichEncryptedExportCanBeRead() throws {
        let steps = try XCTUnwrap(guide("bitwarden").export).steps.joined(separator: " ")
        XCTAssertTrue(steps.contains("**Password protected**"))
    }
}
