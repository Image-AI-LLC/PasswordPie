import Foundation
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Who may get a two-step code in the browser: docs/ACCOUNTS.md, "Who decides".
@MainActor
final class BrowserCodeAccessTests: XCTestCase {
    func testTheAppsOwnPremiumIsEnough() {
        XCTAssertTrue(browserCodeAllowed(appPremium: { true }))
    }

    /// The extension has no account and carries no proof: without Premium on this Mac there is no code, in either channel.
    func testWithoutItThereIsNoCode() {
        XCTAssertFalse(browserCodeAllowed(appPremium: { false }))
    }

    /// The decision takes nothing from the request: no token an extension sends can change it.
    func testTheDecisionReadsNothingTheExtensionSent() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let channel = try String(contentsOf: sources.appendingPathComponent("PasswordPieApp/PremiumChannel.swift"), encoding: .utf8)
        XCTAssertTrue(channel.contains("func browserCodeAllowed(appPremium:"))
        let fill = try String(contentsOf: sources.appendingPathComponent("PasswordPieCore/BrowserFill.swift"), encoding: .utf8)
        XCTAssertFalse(fill.contains("var entitlement"), "the request has no field for a proof of Premium")
        XCTAssertFalse(fill.contains("var pass:"))
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
