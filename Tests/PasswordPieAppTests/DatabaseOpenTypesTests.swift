import UniformTypeIdentifiers
import XCTest
@testable import PasswordPie

final class DatabaseOpenTypesTests: XCTestCase {
    func testChooserAcceptsAnOpVaultPackage() throws {
        let types = VaultSession.databaseContentTypes()
        let opvault = types.first { $0.identifier == "com.agilebits.opvault" || $0.preferredFilenameExtension == "opvault" }
        let match = try XCTUnwrap(opvault)
        XCTAssertTrue(match.conforms(to: .package) || match.identifier == "com.agilebits.opvault")
    }
}
