import PasswordPieCore
import XCTest
@testable import PasswordPie

final class BrowserFillPlanTests: XCTestCase {
    private func login(_ url: String, other: String? = nil) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Account"
        entry.url = url
        entry.username = "octocat"
        entry.password = "hunter2"
        if let other { entry.setValue(other, for: "URL (2)") }
        return entry
    }

    func testReturnOnTheSiteFillsThisTab() {
        let plan = browserFillPlan(entry: login("https://github.com"), mode: .fillOrOpen, preferredWebsite: nil, pageURL: "https://github.com/login")
        XCTAssertEqual(plan, .thisTab(website: "https://github.com"))
    }

    func testReturnOnAnotherSiteOpensANewTab() {
        let plan = browserFillPlan(entry: login("https://github.com/login"), mode: .fillOrOpen, preferredWebsite: nil, pageURL: "https://example.com/")
        XCTAssertEqual(plan, .newTab(website: "https://github.com/login", url: URL(string: "https://github.com/login")!))
    }

    func testShiftReturnBehavesLikeReturn() {
        let entry = login("github.com")
        XCTAssertEqual(browserFillPlan(entry: entry, mode: .fill, preferredWebsite: nil, pageURL: "https://gist.github.com/"), .thisTab(website: "github.com"))
        XCTAssertEqual(browserFillPlan(entry: entry, mode: .fill, preferredWebsite: nil, pageURL: "https://example.com/"),
                       .newTab(website: "github.com", url: URL(string: "https://github.com")!))
    }

    func testOptionReturnAlwaysOpensANewTab() {
        let plan = browserFillPlan(entry: login("https://github.com"), mode: .openAndFill, preferredWebsite: nil, pageURL: "https://github.com/login")
        XCTAssertEqual(plan, .newTab(website: "https://github.com", url: URL(string: "https://github.com")!))
    }

    func testUnknownPageOpensANewTab() {
        let plan = browserFillPlan(entry: login("https://github.com"), mode: .fillOrOpen, preferredWebsite: nil, pageURL: nil)
        XCTAssertEqual(plan, .newTab(website: "https://github.com", url: URL(string: "https://github.com")!))
    }

    func testTheMatchingOtherWebsiteIsUsed() {
        let entry = login("https://atlassian.com", other: "https://acme.atlassian.net")
        let plan = browserFillPlan(entry: entry, mode: .fillOrOpen, preferredWebsite: nil, pageURL: "https://acme.atlassian.net/login")
        XCTAssertEqual(plan, .thisTab(website: "https://acme.atlassian.net"))
    }

    func testTheSearchedWebsiteOpens() {
        let entry = login("https://atlassian.com", other: "https://acme.atlassian.net")
        let plan = browserFillPlan(entry: entry, mode: .fillOrOpen, preferredWebsite: "https://acme.atlassian.net", pageURL: "https://example.com")
        XCTAssertEqual(plan, .newTab(website: "https://acme.atlassian.net", url: URL(string: "https://acme.atlassian.net")!))
    }

    func testNoWebsiteMeansKeystrokes() {
        var note = VaultEntry()
        note.password = "x"
        XCTAssertEqual(browserFillPlan(entry: note, mode: .fill, preferredWebsite: nil, pageURL: "https://github.com"), .keystrokes)
        XCTAssertEqual(browserFillPlan(entry: login("ssh://server"), mode: .fillOrOpen, preferredWebsite: nil, pageURL: nil), .keystrokes)
    }

    func testDowngradedPageIsNotFilledInPlace() {
        let plan = browserFillPlan(entry: login("https://github.com"), mode: .fillOrOpen, preferredWebsite: nil, pageURL: "http://github.com/login")
        XCTAssertEqual(plan, .newTab(website: "https://github.com", url: URL(string: "https://github.com")!))
    }

    func testOpenIsNeverAFill() {
        XCTAssertEqual(browserFillPlan(entry: login("https://github.com"), mode: .open, preferredWebsite: nil, pageURL: "https://github.com"), .keystrokes)
    }
}

final class ResolvedPageURLTests: XCTestCase {
    func testTheExtensionReportWinsWhenItAgreesWithTheWindow() {
        XCTAssertEqual(resolvedPageURL(extensionURL: "https://github.com/login", windowURL: "https://github.com/"), "https://github.com/login")
    }

    func testAStaleReportLosesToTheWindow() {
        XCTAssertEqual(resolvedPageURL(extensionURL: "http://localhost:8765/login.html", windowURL: "http://127.0.0.1:8765/two-step.html"),
                       "http://127.0.0.1:8765/two-step.html")
    }

    func testEitherAlone() {
        XCTAssertEqual(resolvedPageURL(extensionURL: "https://github.com/", windowURL: nil), "https://github.com/")
        XCTAssertEqual(resolvedPageURL(extensionURL: nil, windowURL: "https://github.com/"), "https://github.com/")
        XCTAssertNil(resolvedPageURL(extensionURL: nil, windowURL: nil))
    }
}

final class ExtensionBannerTests: XCTestCase {
    func testChromeWithoutItsExtension() {
        XCTAssertEqual(extensionBanner(frontBundleID: "com.google.Chrome", chromeConnected: false, safariEnabled: true, chromeSupported: true), .addChrome)
        XCTAssertNil(extensionBanner(frontBundleID: "com.google.Chrome", chromeConnected: true, safariEnabled: false, chromeSupported: true))
    }

    func testNoChromeBannerWhereChromeIsNotSupported() {
        XCTAssertNil(extensionBanner(frontBundleID: "com.google.Chrome", chromeConnected: false, safariEnabled: false, chromeSupported: false))
    }

    func testSafari() {
        XCTAssertEqual(extensionBanner(frontBundleID: "com.apple.Safari", chromeConnected: false, safariEnabled: false, chromeSupported: true), .enableSafari)
        XCTAssertNil(extensionBanner(frontBundleID: "com.apple.Safari", chromeConnected: false, safariEnabled: true, chromeSupported: true))
    }

    func testOtherAppsNever() {
        for id in ["com.apple.TextEdit", "org.mozilla.firefox", nil] {
            XCTAssertNil(extensionBanner(frontBundleID: id, chromeConnected: false, safariEnabled: false, chromeSupported: true))
        }
    }

    func testTitles() {
        XCTAssertEqual(ExtensionBanner.addChrome.title, "Add Chrome Extension…")
        XCTAssertEqual(ExtensionBanner.enableSafari.title, "Enable Safari Extension…")
    }
}

#if PP_DIRECT
final class ChromeHostManifestTests: XCTestCase {
    func testManifestNamesTheHostAndOnlyOurExtension() throws {
        let data = ChromeHostManifest.manifest(hostPath: "/Applications/PasswordPie.app/Contents/MacOS/PasswordPieBrowserHost")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "com.oldcai.passwordpie")
        XCTAssertEqual(object["type"] as? String, "stdio")
        XCTAssertEqual(object["path"] as? String, "/Applications/PasswordPie.app/Contents/MacOS/PasswordPieBrowserHost")
        XCTAssertEqual(object["allowed_origins"] as? [String], ["chrome-extension://pbbiimlkojflhpopeplkbfeecanbbdoj/"])
    }

    func testABareBinaryWritesNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The test runner is not an .app bundle.
        ChromeHostManifest.install(bundle: .main, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chrome.appendingPathComponent("NativeMessagingHosts").path))
    }
}
#endif
