import Foundation
import XCTest
@testable import PasswordPieUpdate

final class UpdateCheckTests: XCTestCase {
    private var scratch: URL!
    private var installed: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        scratch = try UpdateFixture.scratch()
        let applications = scratch.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        installed = try UpdateFixture.makeApp(in: applications, version: "0.2.0")
        cache = scratch.appendingPathComponent("cache", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.deletingLastPathComponent().path)
        try FileManager.default.removeItem(at: scratch)
    }

    /// A disk image with PasswordPie `version` inside.
    private func image(version: String, appSignedAs: String? = UpdateFixture.appID, imageSignedAs: String? = UpdateFixture.imageID) throws -> URL {
        // `hdiutil create` takes seconds, so each kind of image is made once for the class.
        let key = "\(version)-\(appSignedAs ?? "unsigned")-\(imageSignedAs ?? "unsigned")"
        if let made = Self.images[key] { return made }
        let stage = Self.imageFolder.appendingPathComponent("stage-\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let app = try UpdateFixture.makeApp(in: stage, version: version, signedAs: appSignedAs)
        let image = Self.imageFolder.appendingPathComponent("\(key).dmg")
        try UpdateFixture.makeImage(of: app, at: image, signedAs: imageSignedAs)
        Self.images[key] = image
        return image
    }

    private static var images: [String: URL] = [:]
    private static let imageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-update-images-\(UUID().uuidString)", isDirectory: true)

    override class func tearDown() {
        try? FileManager.default.removeItem(at: imageFolder)
        images = [:]
        super.tearDown()
    }

    private func check(_ transport: FakeTransport) -> UpdateOutcome {
        UpdateCheck(app: installed, cache: cache, policy: UpdateFixture.policy, transport: transport).run()
    }

    private var cacheContents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted()
    }

    func testABuildThatIsNotAReleaseAsksGitHubNothing() throws {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v9.0.0"))
        let outcome = UpdateCheck(app: installed, cache: cache, policy: .release, transport: transport).run()
        XCTAssertEqual(outcome, UpdateOutcome(.notEligible))
        XCTAssertTrue(transport.fetched.isEmpty)
        XCTAssertTrue(transport.downloaded.isEmpty)
    }

    func testTheLatestVersionIsUpToDate() {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.2.0"))
        XCTAssertEqual(check(transport), UpdateOutcome(.upToDate, version: "0.2.0"))
        XCTAssertEqual(transport.fetched, [ReleaseFeed.latestURL])
        XCTAssertTrue(transport.downloaded.isEmpty)
    }

    func testAnOlderReleaseIsNeverInstalled() {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.1.0"))
        XCTAssertEqual(check(transport).status, .upToDate)
        XCTAssertTrue(transport.downloaded.isEmpty)
    }

    func testANewerReleaseIsDownloadedCheckedAndStaged() throws {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0"))
        let outcome = check(transport)
        XCTAssertEqual(outcome.status, .staged, outcome.message ?? "")
        XCTAssertEqual(outcome.version, "0.3.0")
        let staged = URL(fileURLWithPath: try XCTUnwrap(outcome.path))
        XCTAssertEqual(staged.path, cache.appendingPathComponent("PasswordPie-0.3.0/PasswordPie.app").path)
        XCTAssertEqual(BundleInfo(app: staged)?.version, AppVersion("0.3.0"))
        XCTAssertEqual(transport.downloaded.map(\.absoluteString), ["https://github.com/Image-AI-LLC/PasswordPie/releases/download/v0.3.0/PasswordPie-0.3.0.dmg"])
        // The disk image is gone and nothing stays mounted.
        XCTAssertEqual(cacheContents, ["PasswordPie-0.3.0"])
        // The installed app is untouched by a check.
        XCTAssertEqual(BundleInfo(app: installed)?.version, AppVersion("0.2.0"))
    }

    func testAStagedCopyIsNotDownloadedTwice() throws {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0"))
        XCTAssertEqual(check(transport).status, .staged)
        XCTAssertEqual(check(transport).status, .staged)
        XCTAssertEqual(transport.downloaded.count, 1)
        // A staged copy that was changed since is thrown away and fetched again.
        try Data("x".utf8).write(to: cache.appendingPathComponent("PasswordPie-0.3.0/PasswordPie.app/Contents/extra"))
        XCTAssertEqual(check(transport).status, .staged)
        XCTAssertEqual(transport.downloaded.count, 2)
    }

    func testADiskImageThatIsNotOursIsNeverOpened() throws {
        for signedAs in [nil, "com.example.other"] {
            let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0", imageSignedAs: signedAs))
            let outcome = check(transport)
            XCTAssertEqual(outcome.status, .failed)
            XCTAssertEqual(outcome.message, "The download is not signed by PasswordPie's developer.")
            XCTAssertEqual(cacheContents, [], "nothing was mounted or kept")
        }
    }

    func testAnAppThatIsNotOursIsThrownAway() throws {
        for signedAs in [nil, "com.example.other"] {
            let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0", appSignedAs: signedAs))
            XCTAssertEqual(check(transport).status, .failed)
            XCTAssertEqual(cacheContents, [])
        }
    }

    func testTheAppInsideMustBeTheVersionTheReleaseNames() throws {
        // GitHub says 0.9.0; the image holds our 0.1.0 (a downgrade) or our 0.3.0 (not what was named).
        for inside in ["0.1.0", "0.3.0"] {
            let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.9.0"), image: try image(version: inside))
            XCTAssertEqual(check(transport).status, .failed, inside)
            XCTAssertEqual(cacheContents, [], inside)
        }
    }

    func testACopyThatCannotBeReplacedOnlyLearnsThereIsANewerVersion() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installed.deletingLastPathComponent().path)
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0"))
        XCTAssertEqual(check(transport), UpdateOutcome(.available, version: "0.3.0"))
        XCTAssertTrue(transport.downloaded.isEmpty)
    }

    func testAnAppMacOSMovedAtRandomCannotBeReplaced() {
        XCTAssertFalse(UpdateCheck.canReplace(URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/PasswordPie.app")))
        XCTAssertTrue(UpdateCheck.canReplace(installed))
    }

    func testFailuresSayWhy() throws {
        XCTAssertEqual(check(FakeTransport(feed: nil)), UpdateOutcome(.failed, message: "GitHub did not answer."))
        XCTAssertEqual(check(FakeTransport(feed: Data("oops".utf8))).status, .failed)
        XCTAssertEqual(check(FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: nil)), UpdateOutcome(.failed, message: "The download failed."))
        XCTAssertEqual(cacheContents, [])
    }

    func testBeingUpToDateEmptiesTheCache() throws {
        let transport = FakeTransport(feed: UpdateFixture.feed(tag: "v0.3.0"), image: try image(version: "0.3.0"))
        XCTAssertEqual(check(transport).status, .staged)
        transport.feed = UpdateFixture.feed(tag: "v0.2.0")
        XCTAssertEqual(check(transport).status, .upToDate)
        XCTAssertEqual(cacheContents, [])
    }
}
