import XCTest

/// Keys App Store Connect needs from the app's Info.plist (docs/CHANNELS.md, "Releasing the App Store build").
final class AppStoreInfoPlistTests: XCTestCase {
    private func appInfo() throws -> [String: Any] {
        try info("Sources/PasswordPieApp/Info.plist")
    }

    private func info(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppHasAnAppStoreCategory() throws {
        XCTAssertEqual(try appInfo()["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
    }

    /// YES needs an export compliance code from approved documentation, and App Store Connect refuses the upload without
    /// one; NO would claim exempt encryption. With no key, App Store Connect asks for each build (APP_STORE_LISTING.md).
    func testTheExportComplianceAnswerIsGivenInAppStoreConnect() throws {
        XCTAssertNil(try appInfo()["ITSAppUsesNonExemptEncryption"])
    }

    /// App Store Connect refuses an extension without a display name.
    func testEveryBundleHasADisplayName() throws {
        for path in ["Sources/PasswordPieAutoFill/Info.plist", "Sources/PasswordPieSafari/Info.plist"] {
            XCTAssertEqual(try info(path)["CFBundleDisplayName"] as? String, "PasswordPie", path)
        }
    }
}
