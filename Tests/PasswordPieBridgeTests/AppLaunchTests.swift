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

    func testRetryStopsAtTheFirstSuccess() {
        var calls = 0
        XCTAssertTrue(AppLaunch.retry(for: 1, interval: 0.001) { calls += 1; return calls == 3 })
        XCTAssertEqual(calls, 3)
    }

    func testRetryGivesUpAfterItsTime() {
        let start = Date()
        XCTAssertFalse(AppLaunch.retry(for: 0.05, interval: 0.01) { false })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
