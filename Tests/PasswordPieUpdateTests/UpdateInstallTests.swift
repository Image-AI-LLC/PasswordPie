import Foundation
import XCTest
@testable import PasswordPieUpdate

final class UpdateInstallTests: XCTestCase {
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
        try FileManager.default.removeItem(at: scratch)
    }

    private func stage(version: String, signedAs: String? = UpdateFixture.appID, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? cache.appendingPathComponent("PasswordPie-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try UpdateFixture.makeApp(in: folder, version: version, signedAs: signedAs)
    }

    private func install(_ staged: URL) throws {
        try UpdateInstall(app: installed, staged: staged, cache: cache, policy: UpdateFixture.policy).run()
    }

    private var installedVersion: String? { BundleInfo(app: installed)?.version.description }

    func testTheStagedAppTakesTheInstalledOnesPlace() throws {
        let staged = try stage(version: "0.3.0")
        try install(staged)
        XCTAssertEqual(installedVersion, "0.3.0")
        XCTAssertTrue(CodeSignature.satisfies(installed, requirement: UpdateFixture.policy.app, nested: true), "installed intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "nothing is left in the cache")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["PasswordPie.app"])
    }

    func testOnlyACopyFromTheCacheIsInstalled() throws {
        let elsewhere = try stage(version: "0.3.0", in: scratch.appendingPathComponent("elsewhere", isDirectory: true))
        XCTAssertThrowsError(try install(elsewhere))
        XCTAssertEqual(installedVersion, "0.2.0")
        // A path that only starts like the cache's.
        let sibling = try stage(version: "0.3.0", in: scratch.appendingPathComponent("cache-other", isDirectory: true))
        XCTAssertThrowsError(try install(sibling))
        // A link in the cache to an app outside it.
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let link = cache.appendingPathComponent("PasswordPie.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try install(link))
        XCTAssertEqual(installedVersion, "0.2.0")
    }

    func testACopyChangedAfterTheCheckIsNotInstalled() throws {
        let staged = try stage(version: "0.3.0")
        try Data("x".utf8).write(to: staged.appendingPathComponent("Contents/extra"))
        XCTAssertThrowsError(try install(staged))
        XCTAssertEqual(installedVersion, "0.2.0")
        XCTAssertTrue(CodeSignature.satisfies(installed, requirement: UpdateFixture.policy.app, nested: true))
    }

    func testNeitherAnotherAppNorAnOlderOneIsInstalled() throws {
        XCTAssertThrowsError(try install(try stage(version: "0.4.0", signedAs: "com.example.other")))
        XCTAssertThrowsError(try install(try stage(version: "0.4.1", signedAs: nil)))
        XCTAssertThrowsError(try install(try stage(version: "0.2.0")))
        XCTAssertThrowsError(try install(try stage(version: "0.1.0")))
        XCTAssertEqual(installedVersion, "0.2.0")
    }

    func testWaitsForTheAppToBeGone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        try process.run()
        XCTAssertFalse(UpdateInstall.waitForExit(of: process.processIdentifier, seconds: 0.05, interval: 0.01), "still running")
        process.waitUntilExit()
        XCTAssertTrue(UpdateInstall.waitForExit(of: process.processIdentifier, seconds: 2, interval: 0.01))
        XCTAssertFalse(UpdateInstall.waitForExit(of: getpid(), seconds: 0.05, interval: 0.01))
    }
}
