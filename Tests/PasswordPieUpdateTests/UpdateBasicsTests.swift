import Foundation
import PasswordPieBridge
import XCTest
@testable import PasswordPieUpdate

final class AppVersionTests: XCTestCase {
    func testComparesNumberByNumber() throws {
        let v = { (text: String) in try XCTUnwrap(AppVersion(text)) }
        XCTAssertLessThan(try v("0.9.1"), try v("0.10.0"))
        XCTAssertLessThan(try v("0.2.0"), try v("0.2.1"))
        XCTAssertLessThan(try v("0.2"), try v("0.2.1"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertEqual(try v("1.0").hashValue, try v("1.0.0").hashValue)
        XCTAssertFalse(try v("1.0.0") > v("1.0"))
        XCTAssertEqual(try v("0.2.0").description, "0.2.0")
    }

    func testRejectsWhatIsNotAVersion() {
        for text in ["", "v1.0", "1.0-beta", "1..0", "1.0.", ".1", "1.2.3.4.5", "1.x", "１.0", "1.0 ", "-1.0", "1.0000000"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testATagIsVAndTheVersion() {
        XCTAssertEqual(AppVersion(tag: "v0.3.0")?.description, "0.3.0")
        XCTAssertNil(AppVersion(tag: "0.3.0"))
        XCTAssertNil(AppVersion(tag: "vv0.3.0"))
        XCTAssertNil(AppVersion(tag: "v0.3.0/../../x"))
    }
}

final class ReleaseFeedTests: XCTestCase {
    func testReadsTheTagAndBuildsTheDownloadAddressItself() throws {
        let release = try ReleaseFeed.parse(UpdateFixture.feed(tag: "v0.3.0"))
        XCTAssertEqual(release.version, AppVersion("0.3.0"))
        XCTAssertEqual(release.imageName, "PasswordPie-0.3.0.dmg")
        XCTAssertEqual(release.imageBytes, 4_000_000)
        // Not the address in GitHub's answer (the fixture's points elsewhere).
        XCTAssertEqual(release.imageURL.absoluteString, "https://github.com/Image-AI-LLC/PasswordPie/releases/download/v0.3.0/PasswordPie-0.3.0.dmg")
    }

    func testRefusesAnswersItCannotUse() {
        let refused: [(String, Data)] = [
            ("not JSON", Data("<html>".utf8)),
            ("no tag", Data("{}".utf8)),
            ("tag that is no version", UpdateFixture.feed(tag: "nightly")),
            ("draft", UpdateFixture.feed(tag: "v0.3.0", draft: true)),
            ("prerelease", UpdateFixture.feed(tag: "v0.3.0", prerelease: true)),
            ("no disk image for this version", UpdateFixture.feed(tag: "v0.3.0", assets: ["PasswordPie.dmg", "PasswordPie-0.2.0.dmg"])),
            ("empty file", UpdateFixture.feed(tag: "v0.3.0", bytes: 0)),
            ("huge file", UpdateFixture.feed(tag: "v0.3.0", bytes: ReleaseFeed.maxImageBytes + 1)),
        ]
        for (name, data) in refused {
            XCTAssertThrowsError(try ReleaseFeed.parse(data), name)
        }
    }

    func testTheAddressesAreGitHubs() {
        XCTAssertEqual(ReleaseFeed.latestURL.absoluteString, "https://api.github.com/repos/Image-AI-LLC/PasswordPie/releases/latest")
        XCTAssertEqual(ReleaseFeed.releasesPage.host, "github.com")
    }
}

final class UpdateOutcomeTests: XCTestCase {
    func testOneLineThereAndBack() {
        let outcome = UpdateOutcome(.staged, version: "0.3.0", path: "/tmp/a b/PasswordPie.app")
        let line = outcome.line()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(UpdateOutcome.parse(Data(line.utf8)), outcome)
    }

    func testReadsTheLastOutcomeAmongOtherOutput() {
        let output = "hdiutil: something\n\(UpdateOutcome(.upToDate, version: "0.2.0").line())\n"
        XCTAssertEqual(UpdateOutcome.parse(Data(output.utf8)), UpdateOutcome(.upToDate, version: "0.2.0"))
    }

    func testNoOutcomeIsNil() {
        XCTAssertNil(UpdateOutcome.parse(Data()))
        XCTAssertNil(UpdateOutcome.parse(Data("Segmentation fault\n".utf8)))
        XCTAssertNil(UpdateOutcome.parse(Data(#"{"status":"installed-something"}"#.utf8)))
    }
}

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    func testDueWhenNeverChecked() {
        XCTAssertTrue(UpdateSchedule.isDue(lastAnswer: nil, lastAttempt: nil, now: now))
    }

    func testOnceAWeekAfterAnAnswer() {
        XCTAssertFalse(UpdateSchedule.isDue(lastAnswer: now - 6.9 * day, lastAttempt: now - 6.9 * day, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastAnswer: now - 7 * day, lastAttempt: now - 7 * day, now: now))
    }

    func testADayAfterAFailure() {
        XCTAssertFalse(UpdateSchedule.isDue(lastAnswer: now - 30 * day, lastAttempt: now - 0.9 * day, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastAnswer: now - 30 * day, lastAttempt: now - day, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastAnswer: nil, lastAttempt: now - 60, now: now))
    }

    func testAClockSetBackDoesNotStopChecks() {
        XCTAssertTrue(UpdateSchedule.isDue(lastAnswer: now + 400 * day, lastAttempt: now + 400 * day, now: now))
    }
}

final class ReleasePolicyTests: XCTestCase {
    func testTheReleasePolicyNamesOurTeamAndApp() {
        XCTAssertEqual(ReleasePolicy.teamID, BridgeConstants.teamID)
        XCTAssertEqual(ReleasePolicy.appIdentifier, BridgeConstants.appIdentifier)
        let policy = ReleasePolicy.release
        for requirement in [policy.installed, policy.image, policy.app] {
            XCTAssertTrue(requirement.contains("anchor apple generic"), requirement)
            XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"2S468LUF8V\""), requirement)
            // Developer ID Application, not a development or App Store certificate.
            XCTAssertTrue(requirement.contains("field.1.2.840.113635.100.6.1.13"), requirement)
            var parsed: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &parsed), errSecSuccess, requirement)
        }
        XCTAssertTrue(policy.image.hasSuffix("and notarized"))
        XCTAssertTrue(policy.app.hasSuffix("and notarized"))
        XCTAssertTrue(policy.app.contains("identifier \"com.passwordpie\""))
    }

    func testAnAdHocBuildIsNotARelease() throws {
        let scratch = try UpdateFixture.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try UpdateFixture.makeApp(in: scratch, version: "0.1.0", bundleID: "com.passwordpie", signedAs: "com.passwordpie")
        XCTAssertTrue(CodeSignature.satisfies(app, requirement: "identifier \"com.passwordpie\"", nested: true))
        XCTAssertFalse(CodeSignature.satisfies(app, requirement: ReleasePolicy.release.installed, nested: false))
        XCTAssertFalse(CodeSignature.satisfies(app, requirement: ReleasePolicy.release.app, nested: true))
    }

    func testAChangedFileBreaksTheSignature() throws {
        let scratch = try UpdateFixture.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try UpdateFixture.makeApp(in: scratch, version: "0.3.0")
        XCTAssertEqual(try UpdateFixture.policy.verifyApp(app, newerThan: XCTUnwrap(AppVersion("0.2.0"))), AppVersion("0.3.0"))
        try Data("extra".utf8).write(to: app.appendingPathComponent("Contents/Resources.txt"))
        XCTAssertThrowsError(try UpdateFixture.policy.verifyApp(app, newerThan: XCTUnwrap(AppVersion("0.2.0"))))
    }

    func testAnAppMustBeNewerOursAndNotALink() throws {
        let scratch = try UpdateFixture.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try UpdateFixture.makeApp(in: scratch, version: "0.3.0")
        let policy = UpdateFixture.policy
        XCTAssertThrowsError(try policy.verifyApp(app, newerThan: XCTUnwrap(AppVersion("0.3.0"))), "the same version")
        XCTAssertThrowsError(try policy.verifyApp(app, newerThan: XCTUnwrap(AppVersion("1.0"))), "an older version")
        let link = scratch.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try policy.verifyApp(link, newerThan: XCTUnwrap(AppVersion("0.2.0"))), "a link to an app")
        let other = try UpdateFixture.scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        // Signed as ours, but its Info.plist names another app.
        let renamed = try UpdateFixture.makeApp(in: other, version: "0.3.0", bundleID: "com.example.other")
        XCTAssertThrowsError(try policy.verifyApp(renamed, newerThan: XCTUnwrap(AppVersion("0.2.0"))))
    }
}
