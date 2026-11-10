import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

/// The empty database's menu rows open Preferences at a section, whether or not the window is already open.
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

    /// A Preferences window shorter than its content, off screen, as `AppDelegate.showPreferences` builds it.
    private func openPreferences(_ navigator: PreferencesNavigator) async -> NSScrollView? {
        let session = VaultSession()
        session.restore()
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(session: session, navigator: navigator))
        window.orderFront(nil)
        self.window = window
        await wait(0.5)
        return scrollView(in: window.contentView)
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func offset(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.minY }

    func testAnOpenWindowScrollsToTheSection() async throws {
        let navigator = PreferencesNavigator()
        let opened = await openPreferences(navigator)
        let scroll = try XCTUnwrap(opened)
        let top = offset(scroll)

        navigator.target = .importPasswords
        await wait(0.8)
        XCTAssertGreaterThan(abs(offset(scroll) - top), 200, "Import passwords is far below the top")
        XCTAssertNil(navigator.target, "a request scrolls once")

        // The same request again, after the user scrolled back up, scrolls again.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        navigator.target = .importPasswords
        await wait(0.8)
        XCTAssertGreaterThan(abs(offset(scroll) - top), 200)
    }

    #if PP_DIRECT
    func testANewWindowOpensAtTheSection() async throws {
        let navigator = PreferencesNavigator()
        navigator.target = .chrome
        let opened = await openPreferences(navigator)
        let scroll = try XCTUnwrap(opened)
        await wait(0.5)
        XCTAssertGreaterThan(abs(offset(scroll)), 200, "the Chrome section is last")
        XCTAssertNil(navigator.target)
    }
    #endif
}
