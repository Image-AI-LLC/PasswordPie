import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

/// Preferences shows one pane at a time, and other parts of the app open it at a pane (docs/UX.md, "Preferences in
/// panes").
@MainActor
final class PreferencesNavigatorTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow?
    /// The view holds its session as an observed object; keep it for the window's life.
    private var session: VaultSession?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        session = nil
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    func testANewWindowStartsOnGeneral() {
        let navigator = PreferencesNavigator()
        navigator.pane = .database
        navigator.open(at: nil, newWindow: true)
        XCTAssertEqual(navigator.pane, .general)
    }

    func testAnOpenWindowKeepsItsPaneUnlessItIsSentSomewhere() {
        let navigator = PreferencesNavigator()
        navigator.pane = .database
        navigator.open(at: nil, newWindow: false)
        XCTAssertEqual(navigator.pane, .database)
        navigator.open(at: .importPasswords, newWindow: false)
        XCTAssertEqual(navigator.pane, .importPasswords)
    }

    func testEveryPlaceTheAppOpensPreferencesAtHasItsPane() {
        let navigator = PreferencesNavigator()
        navigator.open(at: .importPasswords, newWindow: true)
        XCTAssertEqual(navigator.pane, .importPasswords)
        navigator.open(at: .browserExtensions, newWindow: true)
        XCTAssertEqual(navigator.pane, .browsers)
        #if PP_DIRECT
        navigator.pane = .general
        navigator.open(at: .chrome, newWindow: false)
        XCTAssertEqual(navigator.pane, .browsers)
        #endif
    }

    func testAPaneWithNothingInItIsLeftOutOfTheList() {
        let session = VaultSession(writes: .inline)
        session.restore()
        let bare = PreferencesView(session: session, navigator: PreferencesNavigator())
        XCTAssertFalse(bare.panes.contains(.importPasswords), "no import flow, no Import pane")
        #if !PP_DIRECT
        XCTAssertFalse(bare.panes.contains(.browsers), "the App Store app without the Safari bridge has nothing for Browsers")
        #endif
        let full = PreferencesView(session: session, navigator: PreferencesNavigator(), importFlow: ImportFlow(session: session))
        XCTAssertEqual(full.panes.first, .general)
        XCTAssertEqual(full.panes.last, .premium)
        XCTAssertTrue(full.panes.contains(.importPasswords))
    }

    /// Every pane, and every source's page in Import, draws in the window `AppDelegate.showPreferences` builds.
    func testEveryPaneAndEverySourceDraws() async throws {
        let session = VaultSession(writes: .inline)
        session.restore()
        self.session = session
        let navigator = PreferencesNavigator()
        let flow = ImportFlow(session: session)
        let size = AppDelegate.preferencesMinSize
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PreferencesView(session: session, navigator: navigator, importFlow: flow))
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        for pane in PreferencesPane.allCases {
            navigator.pane = pane
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds), pane.title)
        }
        navigator.pane = .importPasswords
        for tile in ImportTile.all {
            flow.choose(tile)
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(flow.tile, tile)
        }
        XCTAssertEqual(host.frame.size, size, "the content fits the smallest window without growing it")
    }
}
