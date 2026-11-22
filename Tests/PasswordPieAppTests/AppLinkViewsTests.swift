import AppKit
@testable import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// What an app link looks like: the line under the account's title, and the bubble at the bottom of the screen.
@MainActor
final class AppLinkViewsTests: XCTestCase {
    private var directory: URL!
    private let harbor = LinkedApp(bundleID: "com.apple.finder", teamID: nil, name: "Harbor")
    private let ledger = LinkedApp(bundleID: "example.not.installed", teamID: nil, name: "Ledger")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("applinkviews-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func account(apps: [LinkedApp]) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Northwind SSO"
        entry.username = "ada@northwind.example"
        entry.password = "secret"
        entry.url = "https://sso.northwind.example"
        for app in apps { AppLinks.link(app, to: &entry) }
        return entry
    }

    private func session(with entry: VaultEntry) -> VaultSession {
        let session = VaultSession(pasteboard: FakePasteboard(), writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.saveEditing(entry)
        return session
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func draw(_ host: NSView, name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["PP_TEST_DUMP"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    // MARK: The line under the title

    func testTheDetailsListTheAccountsAppsAndGrowOnlyByTheLine() async throws {
        var heights: [Bool: CGFloat] = [:]
        for linked in [false, true] {
            for dark in [false, true] {
                let session = VaultSession(writes: .inline)
                let model = DetailsModel(entry: account(apps: linked ? [harbor, ledger] : []), session: session, done: {})
                XCTAssertEqual(model.linkedApps, linked ? [harbor, ledger] : [])
                var measured: CGFloat = 0
                let host = NSHostingView(rootView: DetailsView(model: model) { measured = $0 })
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(x: 0, y: 0, width: 400, height: 260)
                try await settle(host)
                _ = try draw(host, name: "app-link-details-\(linked ? "linked" : "plain")-\(dark ? "dark" : "light")")
                heights[linked] = measured
                withExtendedLifetime(session) {}
            }
        }
        let plain = try XCTUnwrap(heights[false]), linked = try XCTUnwrap(heights[true])
        XCTAssertGreaterThan(plain, 0)
        XCTAssertEqual(linked - plain, 0, accuracy: 1.5, "header stays a fixed 60 pt whether empty (+ Add app) or linked")
    }

    func testTheLineSaysWhatTheGroupDoes() {
        XCTAssertEqual(linkedAppsLabel, "Shown first in")
        XCTAssertEqual(linkedAppsEmptyLabel, "Add app")
        XCTAssertEqual(linkedAppsOverflow(hidden: 2), "2 more")
    }

    func testDetailsModelPickerOrdersActiveThenRunningAndMarksRemovedApps() throws {
        let relay = LinkedApp(bundleID: "example.relay", teamID: nil, name: "Relay")
        let session = session(with: account(apps: [harbor]))
        let entry = try XCTUnwrap(session.entries.first { $0.title == "Northwind SSO" })
        // Link then remove Relay so it is refused on this account
        session.linkApp(relay, to: entry.id, manual: true)
        session.unlinkApp(relay, from: entry.id)

        session.copyTargetApp = { self.ledger }
        session.runningLinkableApps = { excluding in
            [self.harbor, self.ledger, relay].filter { !excluding.contains($0.bundleID.lowercased()) }
        }

        let model = DetailsModel(entry: try XCTUnwrap(session.entry(entry.id)), session: session, done: {})
        let options = model.pickerOptions()
        XCTAssertEqual(options.active, ledger, "active frontmost app sits first")
        XCTAssertEqual(options.running, [relay], "already-linked harbor and active ledger are omitted from Running apps")
        XCTAssertEqual(options.refusedBundleIDs, ["example.relay"], "previously removed app is flagged for the quiet trace")

        model.link(relay)
        XCTAssertEqual(model.linkedApps, [harbor, relay])
        XCTAssertEqual(model.refusedApps, [], "manual re-link clears the refusal")

        var capturedPrompt: String?
        session.chooseAppPanel = { prompt, done in
            capturedPrompt = prompt
            done(self.ledger)
        }
        model.chooseAndLinkApp()
        XCTAssertEqual(capturedPrompt, "Add")
        XCTAssertEqual(model.linkedApps, [harbor, relay, ledger])
    }

    func testAClickOnAnAppUnlinksItAndTheBubbleOffersUndo() throws {
        let session = session(with: account(apps: [harbor, ledger]))
        var notices: [AppLinkNotice] = []
        session.onAppLink = { notices.append($0) }
        let entry = try XCTUnwrap(session.entries.first { $0.title == "Northwind SSO" })
        let model = DetailsModel(entry: entry, session: session, done: {})
        XCTAssertEqual(model.linkedApps, [harbor, ledger])

        model.unlink(harbor)
        XCTAssertEqual(model.linkedApps, [ledger], "the open details follow the saved account")
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice, .unlinked(entry: entry.id, title: "Northwind SSO", app: harbor))
        XCTAssertEqual(notice.message, "Northwind SSO is no longer shown first in Harbor")
        XCTAssertEqual(notice.action, "Undo")

        // Undo on that bubble links it again, and says nothing more.
        session.linkApp(notice.app, to: try XCTUnwrap(notice.entry))
        XCTAssertEqual(model.linkedApps, [ledger, harbor])
        XCTAssertEqual(notices.count, 1)
    }

    func testUndoOnTheLinkedBubbleSaysNothingMore() throws {
        let session = session(with: account(apps: [harbor]))
        var notices: [AppLinkNotice] = []
        session.onAppLink = { notices.append($0) }
        let id = try XCTUnwrap(session.entries.first { $0.title == "Northwind SSO" }?.id)
        session.unlinkApp(harbor, from: id)
        XCTAssertEqual(notices, [], "one bubble does not call up another")
    }

    func testAnAppThatIsNotOnThisMacStillHasAnIcon() {
        XCTAssertGreaterThan(AppIdentity.icon(for: ledger).size.width, 0)
        XCTAssertGreaterThan(AppIdentity.icon(for: harbor).size.width, 0)
    }

    // MARK: The bubble

    func testTheBubbleStaysSixSecondsAndWaitsUnderThePointer() {
        var countdown = BubbleCountdown()
        countdown.start(at: start)
        XCTAssertEqual(countdown.timeLeft(at: start.addingTimeInterval(2)), 4, accuracy: 0.001)
        countdown.pause(at: start.addingTimeInterval(2))
        XCTAssertFalse(countdown.isRunning)
        XCTAssertEqual(countdown.timeLeft(at: start.addingTimeInterval(60)), 4, accuracy: 0.001, "the pointer on it stops the clock")
        countdown.resume(at: start.addingTimeInterval(60))
        XCTAssertEqual(countdown.timeLeft(at: start.addingTimeInterval(63)), 1, accuracy: 0.001)
        XCTAssertEqual(countdown.timeLeft(at: start.addingTimeInterval(90)), 0)
        countdown.start(at: start.addingTimeInterval(100))
        XCTAssertEqual(countdown.timeLeft(at: start.addingTimeInterval(100)), BubbleCountdown.stay, "a new bubble starts again")
    }

    func testTheBubbleSitsCentredAboveTheBottomOfTheScreen() {
        let frame = CGRect(x: 100, y: 80, width: 1440, height: 800)
        let origin = appLinkBubbleOrigin(visibleFrame: frame, size: CGSize(width: 420, height: 44))
        XCTAssertEqual(origin, CGPoint(x: 100 + 720 - 210, y: 80 + 48))
    }

    func testTheBubbleIsOneLineWithOneButtonAndNeverTakesTheKeyboard() async throws {
        let panel = AppLinkBubblePanel(contentRect: .zero)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)

        let notices: [AppLinkNotice] = [
            .linked(entry: UUID(), title: "Northwind SSO", app: harbor),
            .autoStopped(app: harbor),
            .linked(entry: UUID(), title: String(repeating: "A very long account title ", count: 8), app: harbor),
        ]
        XCTAssertGreaterThanOrEqual(appLinkSwapGuardInterval(systemDoubleClick: 0.3), 0.5)
        XCTAssertEqual(appLinkSwapGuardInterval(systemDoubleClick: 0.8), 0.8)
        for (index, notice) in notices.enumerated() {
            for dark in [false, true] {
                let icon: BubbleIconKind = switch notice {
                case .autoStopped(let app): .appStopped(appIcon: AppIdentity.icon(for: app))
                case .linked, .unlinked: .account(title: "Northwind SSO", siteHost: nil, appIcon: AppIdentity.icon(for: harbor))
                }
                let view = AppLinkBubbleView(message: notice.message, action: notice.action, icon: icon, onAct: {}, onHover: { _ in })
                let host = FirstMouseHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                XCTAssertEqual(size.height, AppLinkBubbleView.height)
                XCTAssertLessThanOrEqual(size.width, AppLinkBubbleView.maxWidth, "a long title is cut in the middle, not the bubble widened")
                XCTAssertGreaterThan(size.width, 200)
                host.frame = CGRect(origin: .zero, size: size)
                try await settle(host)
                _ = try draw(host, name: "app-link-bubble-\(index)-\(dark ? "dark" : "light")")
            }
        }
    }
}
