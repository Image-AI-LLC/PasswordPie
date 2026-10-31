import XCTest
@testable import PasswordPie

final class WebURLTests: XCTestCase {
    func testBareHostsGetHTTPS() {
        XCTAssertEqual(webURL("github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(webURL("  github.com/login ")?.absoluteString, "https://github.com/login")
        XCTAssertEqual(webURL("localhost:3000")?.absoluteString, "https://localhost:3000")
    }

    func testHTTPAndHTTPSOpenAsWritten() {
        XCTAssertEqual(webURL("http://example.com/a")?.absoluteString, "http://example.com/a")
        XCTAssertEqual(webURL("HTTPS://Example.com")?.scheme?.lowercased(), "https")
    }

    func testOtherSchemesNeverOpenOrReceiveTypedPasswords() {
        for raw in ["android://hash@com.example.app/", "ssh://host", "file:///etc/hosts", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference"] {
            XCTAssertNil(webURL(raw), raw)
        }
    }

    func testEmptyInputIsNil() {
        XCTAssertNil(webURL(""))
        XCTAssertNil(webURL("   "))
    }
}
