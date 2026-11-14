import XCTest

/// Keys App Store Connect needs from the app's Info.plist (docs/CHANNELS.md, "Releasing the App Store build").
final class AppStoreInfoPlistTests: XCTestCase {
    private func appInfo() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppHasAnAppStoreCategory() throws {
        XCTAssertEqual(try appInfo()["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
    }

    func testTheExportComplianceAnswerIsInTheBuild() throws {
        XCTAssertEqual(try appInfo()["ITSAppUsesNonExemptEncryption"] as? Bool, true)
    }
}
