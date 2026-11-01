import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

@MainActor
final class AboutScreenTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepositoryAndLicenceCopy() {
        XCTAssertEqual(AboutCopy.menuTitle, "About PasswordPie")
        XCTAssertEqual(AboutCopy.repositoryURL.scheme, "https")
        XCTAssertEqual(AboutCopy.repositoryURL.host, "github.com")
        XCTAssertEqual(AboutCopy.repositoryURL.path, "/Image-AI-LLC/PasswordPie")
        XCTAssertEqual(AboutCopy.repositoryLabel, "github.com/Image-AI-LLC/PasswordPie")
        XCTAssertEqual(
            AboutCopy.attribution,
            "Site popularity in search comes from the [Majestic Million](https://majestic.com/reports/majestic-million), licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)."
        )
        XCTAssertFalse(AboutCopy.attribution.contains("CC BY-SA"))
        XCTAssertEqual(AboutCopy.versionLabel(short: "0.1.0", build: "1"), "Version 0.1.0 (1)")
        XCTAssertEqual(AboutCopy.versionLabel(short: "0.1.0", build: "0.1.0"), "Version 0.1.0")
        XCTAssertEqual(AboutCopy.versionLabel(short: " 2.0 ", build: "  "), "Version 2.0")
        XCTAssertEqual(AboutCopy.versionLabel(short: nil, build: "9"), "Version 0.1.0")
        XCTAssertEqual(AboutCopy.versionLabel(short: "", build: "9"), "Version 0.1.0")
    }

    func testAboutViewUsesTheSharedCreditAndPreferencesDoesNot() throws {
        let about = try String(contentsOf: sourceURL("AboutView.swift"), encoding: .utf8)
        XCTAssertTrue(about.contains("AboutCopy.repositoryURL"))
        XCTAssertTrue(about.contains("AboutCopy.repositoryLabel"))
        XCTAssertTrue(about.contains("AboutCopy.attributionText"))
        let preferences = try String(contentsOf: sourceURL("PreferencesView.swift"), encoding: .utf8)
        XCTAssertFalse(preferences.contains("Majestic"))
        XCTAssertFalse(preferences.contains("creativecommons.org"))
        XCTAssertFalse(preferences.contains("Changes are saved automatically."))
        XCTAssertFalse(preferences.contains("showAbout"))
    }

    func testAboutViewHugsItsContent() {
        let host = NSHostingView(rootView: AboutView(version: "Version 0.1.0 (1)"))
        host.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let fitted = host.fittingSize
        XCTAssertEqual(fitted.width, 440, accuracy: 1)
        XCTAssertGreaterThan(fitted.height, 200)
        XCTAssertLessThan(fitted.height, 420)
    }

    func testAboutIsOnlyOnTheAppMenu() throws {
        let session = VaultSession()
        let panel = PanelController(session: session)
        let locked = panel.gearMenu()
        XCTAssertEqual(itemTitles(locked), ["Preferences…", "Open Database…", "Quit PasswordPie"])
        XCTAssertNil(locked.items.first { $0.title == AboutCopy.menuTitle })

        session.locked = false
        let open = panel.gearMenu()
        XCTAssertEqual(itemTitles(open), [
            "Search Major Fields", "Search All Fields",
            "New Item…", "Lock",
            "Preferences…", "Open Database…", "New Database…",
            "Quit PasswordPie",
        ])
        XCTAssertEqual(open.items.first { $0.title == "Preferences…" }?.keyEquivalent, ",")

        let app = try String(contentsOf: sourceURL("PasswordPieApp.swift"), encoding: .utf8)
        let statusMenu = functionBody(app, named: "makeMenu")
        let appMenu = functionBody(app, named: "buildMainMenu")
        XCTAssertFalse(statusMenu.contains("About"))
        XCTAssertTrue(appMenu.contains("AboutCopy.menuTitle"))
    }

    private func functionBody(_ source: String, named name: String) -> String {
        guard let start = source.range(of: "func \(name)") else { return "" }
        var depth = 0
        var sawBrace = false
        let body = source[start.lowerBound...]
        var end = body.endIndex
        for index in body.indices {
            switch body[index] {
            case "{":
                depth += 1
                sawBrace = true
            case "}":
                depth -= 1
                if sawBrace && depth == 0 {
                    end = body.index(after: index)
                    return String(body[..<end])
                }
            default:
                break
            }
        }
        return String(body[..<end])
    }

    private func itemTitles(_ menu: NSMenu) -> [String] {
        menu.items.map(\.title).filter { !$0.isEmpty }
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PasswordPieApp/\(name)")
    }
}
