import Foundation
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Who may get a two-step code in the browser: docs/ACCOUNTS.md, "Who decides". The same in both channels.
@MainActor
final class BrowserCodeAccessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_560_000)

    /// Signed with the public test key in extension/dev/test-key.json; good until 2100. Debug builds trust that key.
    private func sampleToken() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extension/dev/test-key.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        return try XCTUnwrap(json["sampleToken"])
    }

    func testAGoodTokenFromTheExtensionIsEnough() throws {
        XCTAssertTrue(browserCodeAllowed(entitlement: try sampleToken(), now: now, appAccount: { false }))
    }

    func testTheAppsOwnAccountIsEnough() {
        XCTAssertTrue(browserCodeAllowed(entitlement: nil, now: now, appAccount: { true }))
    }

    func testNeitherMeansNoCode() throws {
        XCTAssertFalse(browserCodeAllowed(entitlement: nil, now: now, appAccount: { false }))
        XCTAssertFalse(browserCodeAllowed(entitlement: "not.a.token", now: now, appAccount: { false }))
        var tampered = try sampleToken()
        let last = tampered.removeLast()
        tampered.append(last == "A" ? "B" : "A")
        XCTAssertFalse(browserCodeAllowed(entitlement: tampered, now: now, appAccount: { false }))
    }

    /// The direct app's codes are free in its own panel; that must not leak into the browser.
    func testTheStoreOrTheFreeDirectStatusDoesNotCount() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp")
        let text = try String(contentsOf: sources.appendingPathComponent("PremiumChannel.swift"), encoding: .utf8)
        let decision = try XCTUnwrap(text.range(of: "func browserCodeAllowed")).lowerBound
        let body = String(text[decision...])
        let code = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined()
        XCTAssertFalse(code.contains("hasPremium"))
        XCTAssertFalse(code.contains("directChannelCodesAreFree"), "free codes in the app never mean codes in the browser")
    }
}
