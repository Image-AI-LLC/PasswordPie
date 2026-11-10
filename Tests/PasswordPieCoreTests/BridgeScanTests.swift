import XCTest
@testable import PasswordPieCore

/// The `scan` request and the code the extension may fill after one is added (docs/BROWSER_EXTENSION.md, "`scan`").
final class BridgeScanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)
    private let demo = "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo"

    private func request(_ object: [String: Any]) -> BridgeRequest {
        try! JSONDecoder().decode(BridgeRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func object(_ response: BridgeResponse) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! [String: Any]
    }

    private func login(_ url: String = "https://example.com", code: Bool = true) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Demo"
        entry.username = "ada"
        entry.url = url
        if code { entry.otp = demo }
        return entry
    }

    func testAScanIsHandedOverAndTheAnswerOnlySaysItArrived() {
        var state = BridgeState()
        var received: [(ScannedOTP, String?, BridgeBrowser)] = []
        let scan: (ScannedOTP, String?, BridgeBrowser) -> Void = { received.append(($0, $1, $2)) }
        for locked in [false, true] {
            let answer = state.handle(
                request(["type": "scan", "id": 4, "otpauth": demo, "url": "https://www.example.com/"]),
                from: .chrome, locked: locked, now: start, scan: scan
            ) { _ in self.login() }
            XCTAssertEqual(object(answer) as NSDictionary, ["type": "scan", "id": 4])
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first?.0.issuer, "Demo")
        XCTAssertEqual(received.first?.1, "https://www.example.com")
        XCTAssertEqual(received.first?.2, .chrome)
    }

    func testAScanWithoutAWebPageStillArrives() {
        var state = BridgeState()
        var origins: [String?] = []
        _ = state.handle(request(["type": "scan", "id": 1, "otpauth": demo, "url": "chrome://newtab/"]), from: .chrome, locked: false, now: start,
                         scan: { _, origin, _ in origins.append(origin) }) { _ in nil }
        _ = state.handle(request(["type": "scan", "id": 2, "otpauth": demo]), from: .chrome, locked: false, now: start,
                         scan: { _, origin, _ in origins.append(origin) }) { _ in nil }
        XCTAssertEqual(origins, [nil, nil])
    }

    func testARefusedLinkIsAnErrorAndNothingIsHandedOver() {
        var state = BridgeState()
        var calls = 0
        for raw in ["otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP", "https://example.com", String(repeating: "a", count: 5000)] {
            let answer = state.handle(request(["type": "scan", "id": 3, "otpauth": raw, "url": "https://example.com/"]),
                                      from: .safari, locked: false, now: start, scan: { _, _, _ in calls += 1 }) { _ in nil }
            XCTAssertEqual(object(answer)["type"] as? String, "error")
            XCTAssertEqual(object(answer)["code"] as? String, raw.count > 4096 ? "bad-request" : "bad-otp")
        }
        let missing = state.handle(request(["type": "scan", "id": 5]), from: .safari, locked: false, now: start, scan: { _, _, _ in calls += 1 }) { _ in nil }
        XCTAssertEqual(object(missing)["code"] as? String, "bad-request")
        XCTAssertEqual(calls, 0)
    }

    func testAnAppThatTakesNoScansAnswersBadRequest() {
        var state = BridgeState()
        let answer = state.handle(request(["type": "scan", "id": 6, "otpauth": demo]), from: .chrome, locked: false, now: start) { _ in nil }
        XCTAssertEqual(object(answer)["code"] as? String, "bad-request")
    }

    // MARK: After Add

    func testTheNextTabReportOfThatSiteIsToldToWatchForTheCodeOnce() {
        var state = BridgeState()
        let entry = login()
        XCTAssertTrue(state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "https://example.com", now: start))
        let elsewhere = state.handle(request(["type": "tab", "id": 1, "url": "https://other.com/"]), from: .chrome, locked: false, now: start + 1) { _ in entry }
        XCTAssertNil(object(elsewhere)["expectCode"])
        let otherBrowser = state.handle(request(["type": "tab", "id": 2, "url": "https://example.com/"]), from: .safari, locked: false, now: start + 1) { _ in entry }
        XCTAssertNil(object(otherBrowser)["expectCode"])
        let first = object(state.handle(request(["type": "tab", "id": 3, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 2) { _ in entry })
        XCTAssertEqual(first["expectCode"] as? NSDictionary, ["origin": "https://example.com", "expiresIn": 28])
        XCTAssertNil(first["fill"])
        let again = object(state.handle(request(["type": "tab", "id": 4, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 3) { _ in entry })
        XCTAssertNil(again["expectCode"])
    }

    func testTheCodeRequestThenRunsUnderTheUsualPremiumCheck() {
        var state = BridgeState()
        let entry = login()
        _ = state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "https://example.com", now: start)
        _ = state.handle(request(["type": "tab", "id": 1, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 1) { _ in entry }
        let refused = object(state.handle(request(["type": "code", "id": 2, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 2,
                                          codeAllowed: { _ in false }) { _ in entry })
        XCTAssertEqual(refused["premium"] as? Bool, false)
        _ = state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "https://example.com", now: start)
        let code = object(state.handle(request(["type": "code", "id": 3, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 2,
                                       codeAllowed: { _ in true }) { _ in entry })
        XCTAssertNotNil(code["otp"])
    }

    func testNothingIsAnnouncedWhileLockedOrAfterItRanOut() {
        var state = BridgeState()
        let entry = login()
        _ = state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "https://example.com", now: start)
        let late = state.handle(request(["type": "tab", "id": 1, "url": "https://example.com/"]), from: .chrome, locked: false, now: start + 31) { _ in entry }
        XCTAssertNil(object(late)["expectCode"])
        _ = state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "https://example.com", now: start)
        let locked = state.handle(request(["type": "tab", "id": 2, "url": "https://example.com/"]), from: .chrome, locked: true, now: start + 1) { _ in entry }
        XCTAssertNil(object(locked)["expectCode"])
        XCTAssertFalse(state.expectCode(afterScanOf: entry.id, browser: .chrome, pageURL: "about:blank", now: start))
    }

    // MARK: History

    func testReplacingACodeKeepsTheOldOneInTheItemsHistory() throws {
        var entry = login()
        var vault = Vault(name: "Box", rootName: "Box", entries: [entry])
        vault = try KDBX.load(data: try KDBX.save(vault: &vault, password: "pw"), password: "pw")
        entry.otp = "otpauth://totp/Demo:ada?secret=GEZDGNBVGY3TQOJQ&issuer=Demo&period=30&digits=6"
        vault.entries[0] = entry
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "pw"), password: "pw")
        XCTAssertEqual(loaded.entries.first?.otp, entry.otp)
        let document = try XCTUnwrap(loaded.preserve?.document)
        let versions = try XCTUnwrap(document.nodes(forXPath: "//Entry/History/Entry") as? [XMLElement])
        let oldValues = versions.flatMap { direct($0, "String") }
            .filter { direct($0, "Key").first?.stringValue == "otp" }
            .compactMap { direct($0, "Value").first?.stringValue }
        XCTAssertEqual(oldValues, [demo])
    }
}
