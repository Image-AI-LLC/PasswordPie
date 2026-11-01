import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PasswordPie

final class DatabaseOpenTypesTests: XCTestCase {
    func testChooserAcceptsAnOpVaultPackage() throws {
        let types = VaultSession.databaseContentTypes()
        let opvault = types.first { $0.identifier == "com.agilebits.opvault" || $0.preferredFilenameExtension == "opvault" }
        let match = try XCTUnwrap(opvault)
        XCTAssertTrue(match.conforms(to: .package) || match.identifier == "com.agilebits.opvault")
        XCTAssertFalse(types.contains { $0 == .folder })
    }

    func testDatabaseChooserDoesNotPreselectTheBrowsedFolder() {
        let panel = NSOpenPanel()
        DatabaseChooser.configure(panel)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
        XCTAssertFalse(panel.allowedContentTypes.contains { $0 == .folder })
        XCTAssertTrue(panel.allowedContentTypes.contains { $0.conforms(to: .package) })
    }
}
