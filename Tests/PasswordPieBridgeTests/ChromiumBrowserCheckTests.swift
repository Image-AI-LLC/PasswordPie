import AppKit
import PasswordPieBridge
import XCTest

/// What the host and the app check of the browser that started the host: docs/BROWSER_EXTENSION.md, "Other Chromium browsers".
final class ChromiumBrowserCheckTests: XCTestCase {
    func testAChromiumBrowserIsKnownByItsApplicationClass() {
        XCTAssertTrue(ChromiumBrowserCheck.isChromium(info: ["NSPrincipalClass": "BrowserCrApplication"]))
        XCTAssertFalse(ChromiumBrowserCheck.isChromium(info: ["NSPrincipalClass": "AtomApplication"]), "an Electron app is no browser")
        XCTAssertFalse(ChromiumBrowserCheck.isChromium(info: ["NSPrincipalClass": "NSApplication"]))
        XCTAssertFalse(ChromiumBrowserCheck.isChromium(info: nil))
    }

    func testTheSignerIsTheCertificatesOrganization() {
        XCTAssertEqual(ChromiumBrowserCheck.organization(fromCertificateSummary: "Developer ID Application: CITRO LABS PTE. LIMITED (JGQLC6YQYJ)"), "CITRO LABS PTE. LIMITED")
        XCTAssertEqual(ChromiumBrowserCheck.organization(fromCertificateSummary: "Developer ID Application: Google LLC (EQHXZ8M8AV)"), "Google LLC")
        XCTAssertNil(ChromiumBrowserCheck.organization(fromCertificateSummary: "Apple Mac OS Application Signing"))
    }

    func testThisTestRunnerIsNoBrowser() {
        XCTAssertNil(ChromiumBrowserCheck.identity(ofProcess: getpid()))
        XCTAssertNil(ChromiumBrowserCheck.parentPID(of: -1))
    }

    func testThePeerOfASocketAndItsParentAreFound() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertEqual(ChromiumBrowserCheck.peerPID(pair[0]), getpid())
        XCTAssertEqual(ChromiumBrowserCheck.parentPID(of: getpid()), getppid() > 1 ? getppid() : nil)
    }

    /// On a Mac with a Chromium browser running (Chrome, ego lite…), its signature reads as the browser's.
    func testARunningChromiumBrowserIsRecognized() throws {
        let browsers = NSWorkspace.shared.runningApplications.filter { app in
            guard let url = app.bundleURL?.appendingPathComponent("Contents/Info.plist"),
                  let info = NSDictionary(contentsOf: url) as? [String: Any] else { return false }
            return ChromiumBrowserCheck.isChromium(info: info)
        }
        guard let browser = browsers.first else { throw XCTSkip("no Chromium browser is running") }
        let identity = try XCTUnwrap(ChromiumBrowserCheck.identity(ofProcess: browser.processIdentifier))
        XCTAssertEqual(identity.bundleID, browser.bundleIdentifier)
        XCTAssertFalse(identity.teamID.isEmpty)
        XCTAssertEqual(identity.bundleURL.standardizedFileURL.path, browser.bundleURL?.standardizedFileURL.path)
    }
}
