import Foundation
import PasswordPieBridge
import XCTest

/// The peer check trusts signing identifiers, and the socket lives in the App Group, so the bundle files, the
/// entitlements and the Makefile must say what `BridgeConstants` says, or the extensions stop connecting.
final class IdentifiersTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }

    func testTheNamespaceIsComPasswordpie() {
        XCTAssertEqual(BridgeConstants.appIdentifier, "com.passwordpie")
        XCTAssertEqual(BridgeConstants.safariExtensionIdentifier, "com.passwordpie.safari")
        XCTAssertEqual(BridgeConstants.chromeHostIdentifier, "com.passwordpie.browser-host")
        XCTAssertEqual(BridgeConstants.appGroup, "2S468LUF8V.com.passwordpie")
    }

    func testBundlesAreSignedWithTheIdentifiersThePeerCheckTrusts() throws {
        XCTAssertEqual(try plist("Sources/PasswordPieApp/Info.plist")["CFBundleIdentifier"] as? String, BridgeConstants.appIdentifier)
        XCTAssertEqual(try plist("Sources/PasswordPieSafari/Info.plist")["CFBundleIdentifier"] as? String, BridgeConstants.safariExtensionIdentifier)
        XCTAssertEqual(try plist("Sources/PasswordPieAutoFill/Info.plist")["CFBundleIdentifier"] as? String, "\(BridgeConstants.appIdentifier).autofill")
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        XCTAssertTrue(makefile.contains("HOST_ID := \(BridgeConstants.chromeHostIdentifier)\n"), "Makefile signs the Chrome host as chromeHostIdentifier")
    }

    func testEveryProcessOnTheBridgeSharesTheAppGroup() throws {
        for name in ["direct", "mas", "safari-extension", "browser-host"] {
            let groups = try plist("Entitlements/\(name).entitlements")["com.apple.security.application-groups"] as? [String]
            XCTAssertEqual(groups, [BridgeConstants.appGroup], name)
        }
    }
}
