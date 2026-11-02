import XCTest
@testable import PasswordPieCore

final class SiteIconHostTests: XCTestCase {
    func testWebsiteHostDropsSchemeWwwPathQueryAndPort() {
        XCTAssertEqual(websiteHost(forWebsite: "https://www.github.com/login"), "github.com")
        XCTAssertEqual(websiteHost(forWebsite: "http://GitHub.com/settings?token=secret"), "github.com")
        XCTAssertEqual(websiteHost(forWebsite: "  github.com "), "github.com")
        XCTAssertEqual(websiteHost(forWebsite: "https://localhost:3000/admin"), "localhost")
        XCTAssertEqual(websiteHost(forWebsite: "https://github.com."), "github.com")
    }

    func testSubdomainsStayOnTheirOwnHost() {
        XCTAssertEqual(websiteHost(forWebsite: "https://mail.google.com/mail"), "mail.google.com")
        XCTAssertEqual(websiteHost(forWebsite: "https://accounts.google.com"), "accounts.google.com")
    }

    func testUserinfoAndOtherSchemesNeverBecomeTheLookupHost() {
        XCTAssertEqual(websiteHost(forWebsite: "https://user:secret@github.com/login?token=abc"), "github.com")
        for raw in ["", "   ", "android://hash@com.example.app/", "ssh://host", "file:///etc/hosts", "javascript:alert(1)"] {
            XCTAssertNil(websiteHost(forWebsite: raw), raw)
        }
    }

    func testInternationalHostIsPunycode() {
        XCTAssertEqual(websiteHost(forWebsite: "https://münchen.de/start"), "xn--mnchen-3ya.de")
    }

    func testEntryUsesItsWebsiteAndNotItsTitle() {
        var entry = VaultEntry()
        entry.title = "github.com"
        entry.url = "https://www.gitlab.com/profile"
        XCTAssertEqual(websiteHost(of: entry), "gitlab.com")

        entry.url = ""
        for title in ["github.com", "GitHub", "github.com/login", "backup.zip", "meeting-notes.md"] {
            entry.title = title
            XCTAssertNil(websiteHost(of: entry), title)
        }
    }

    func testMenuRowsRememberTheWebsiteHost() {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.url = "https://www.github.com/login"
        entry.favorite = true
        let rows = MenuBuilder.topLevel(entries: [entry])
        let favorites = rows.first { $0.title == "Favorites" }
        XCTAssertEqual(favorites?.children.first?.siteHost, "github.com")

        var note = VaultEntry()
        note.title = "Notes"
        XCTAssertNil(MenuBuilder.entryRows([note]).first?.siteHost)
    }
}
