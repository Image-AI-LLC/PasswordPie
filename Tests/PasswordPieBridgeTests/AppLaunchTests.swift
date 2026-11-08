import Foundation
import PasswordPieBridge
import XCTest

final class AppLaunchTests: XCTestCase {
    func testOnlyShowRequestsStartTheApp() {
        XCTAssertTrue(AppLaunch.isShowRequest(Data(#"{"type":"show","id":3}"#.utf8)))
        XCTAssertFalse(AppLaunch.isShowRequest(Data(#"{"type":"tab","id":2,"url":"https://github.com/"}"#.utf8)))
        XCTAssertFalse(AppLaunch.isShowRequest(Data(#"{"type":"hello","id":1}"#.utf8)))
        XCTAssertFalse(AppLaunch.isShowRequest(Data("not json".utf8)))
    }

    func testFindsTheAppAroundTheHostAndTheSafariExtension() {
        let app = URL(fileURLWithPath: "/Users/me/Applications/PasswordPie.app")
        let host = app.appendingPathComponent("Contents/MacOS/PasswordPieBrowserHost")
        let safari = app.appendingPathComponent("Contents/PlugIns/PasswordPieSafari.appex/Contents/MacOS/PasswordPieSafari")
        XCTAssertEqual(AppLaunch.containingApp(of: host)?.path, app.path)
        XCTAssertEqual(AppLaunch.containingApp(of: safari)?.path, app.path)
        XCTAssertNil(AppLaunch.containingApp(of: URL(fileURLWithPath: "/usr/local/bin/PasswordPieBrowserHost")))
    }

    func testOnlyAShowOfAStoppedAppStartsIt() {
        let show = Data(#"{"type":"show","id":3}"#.utf8)
        let tab = Data(#"{"type":"tab","id":2,"url":"https://github.com/"}"#.utf8)
        XCTAssertEqual(AppLaunch.fallback(for: show, appRunning: false), .launch)
        XCTAssertEqual(AppLaunch.fallback(for: show, appRunning: true), .wait)
        XCTAssertEqual(AppLaunch.fallback(for: tab, appRunning: false), .none)
        XCTAssertEqual(AppLaunch.fallback(for: tab, appRunning: true), .none)
    }

    func testARunningAppThatDidNotAnswerIsNotSentToTheWebsite() {
        XCTAssertEqual(AppLaunch.failureCode(appRunning: true), AppLaunch.notRespondingCode)
        XCTAssertEqual(AppLaunch.failureCode(appRunning: false), "app-unavailable")
    }

    func testTheSafariShowStaysInsideTheExtensionsWait() {
        // First try (1 s timeout) + the wait + a last try that may run to its 1 s timeout, against the extension's 12 s.
        XCTAssertLessThan(1 + AppLaunch.showWaitSeconds + 1, 12)
    }

    func testRetryStopsAtTheFirstSuccess() {
        var calls = 0
        XCTAssertTrue(AppLaunch.retry(for: 1, interval: 0.001) { calls += 1; return calls == 3 })
        XCTAssertEqual(calls, 3)
    }

    func testRetryGivesUpAfterItsTime() {
        let start = Date()
        var calls = 0
        XCTAssertFalse(AppLaunch.retry(for: 0.05, interval: 0.01) { calls += 1; return false })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertLessThanOrEqual(calls, 5) // no attempt starts after the deadline
    }
}
