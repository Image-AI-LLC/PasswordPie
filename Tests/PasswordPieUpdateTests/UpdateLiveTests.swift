import Foundation
import XCTest
@testable import PasswordPieUpdate
@testable import PasswordPieUpdater

/// The real thing, against GitHub: `PP_UPDATER_LIVE=1 swift test --filter UpdateLiveTests`. Skipped otherwise, so the
/// ordinary test run stays offline.
final class UpdateLiveTests: XCTestCase {
    func testStagesAndInstallsTheLatestReleaseOverAnOlderStandIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PP_UPDATER_LIVE"] == "1", "set PP_UPDATER_LIVE=1 to ask GitHub")
        let scratch = try UpdateFixture.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        // The installed stand-in is ad hoc, so only that one requirement is relaxed. The download must pass the release policy.
        let installed = try UpdateFixture.makeApp(in: applications, version: "0.0.1", bundleID: ReleasePolicy.appIdentifier, signedAs: ReleasePolicy.appIdentifier)
        var policy = ReleasePolicy.release
        policy.installed = "identifier \"\(ReleasePolicy.appIdentifier)\""
        let cache = scratch.appendingPathComponent("cache", isDirectory: true)

        let outcome = UpdateCheck(app: installed, cache: cache, policy: policy, transport: GitHubTransport()).run()
        XCTAssertEqual(outcome.status, .staged, outcome.message ?? "")
        let staged = URL(fileURLWithPath: try XCTUnwrap(outcome.path))
        XCTAssertTrue(CodeSignature.satisfies(staged, requirement: ReleasePolicy.release.app, nested: true))

        try UpdateInstall(app: installed, staged: staged, cache: cache, policy: policy).run()
        XCTAssertEqual(BundleInfo(app: installed)?.version.description, outcome.version)
        XCTAssertTrue(CodeSignature.satisfies(installed, requirement: ReleasePolicy.release.app, nested: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testOnlyGitHubOverHTTPSIsAllowed() {
        for allowed in ["https://api.github.com/repos/x/y/releases/latest", "https://github.com/x/y/releases/download/v1/a.dmg",
                        "https://release-assets.githubusercontent.com/a", "https://objects.githubusercontent.com/a"] {
            XCTAssertTrue(GitHubTransport.allowed(URL(string: allowed)), allowed)
        }
        for refused in ["http://github.com/x", "https://github.com.evil.example/x", "https://evilgithub.com/x",
                        "https://githubusercontent.com.evil.example/x", "https://example.com/github.com", "file:///etc/passwd", "https://xgithubusercontent.com/a"] {
            XCTAssertFalse(GitHubTransport.allowed(URL(string: refused)), refused)
        }
        XCTAssertFalse(GitHubTransport.allowed(nil))
    }
}
