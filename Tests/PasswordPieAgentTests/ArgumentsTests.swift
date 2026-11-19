import Foundation
import XCTest
@testable import PasswordPieAgent
@testable import PasswordPieCLI

final class ArgumentsTests: XCTestCase {
    func testRunCollectsSecretsInOrderAndTheCommand() throws {
        let command = try Arguments.parse(["run", "--env", "A=pp://X/a", "--file=B=pp://X/b/attachment/k.p8", "--stdin", "pp://X/c",
                                           "--reason", "Deploy", "--wait", "30", "--", "Scripts/deploy.sh", "--prod"])
        guard case .run(let options) = command else { return XCTFail("\(command)") }
        XCTAssertEqual(options.secrets, [
            AgentSecretRequest(name: "A", ref: "pp://X/a", delivery: .env),
            AgentSecretRequest(name: "B", ref: "pp://X/b/attachment/k.p8", delivery: .file),
            AgentSecretRequest(name: nil, ref: "pp://X/c", delivery: .stdin),
        ])
        XCTAssertEqual(options.reason, "Deploy")
        XCTAssertEqual(options.wait, 30)
        XCTAssertTrue(options.masking)
        XCTAssertEqual(options.command, ["Scripts/deploy.sh", "--prod"])
    }

    func testOptionsAfterTheCommandBelongToTheCommand() throws {
        guard case .run(let options) = try Arguments.parse(["run", "--env", "A=pp://X/a", "--", "env", "--no-masking"]) else { return XCTFail() }
        XCTAssertTrue(options.masking)
        XCTAssertEqual(options.command, ["env", "--no-masking"])
    }

    func testEnvFileLinesJoinTheRequest() throws {
        let file = "K=file:pp://D/k/attachment/a.p8\nI=pp://D/k/Key ID\nTEAM=2S468LUF8V\n"
        guard case .run(let options) = try Arguments.parse(["run", "--env-file", ".env.pp", "--", "true"], readFile: { _ in file }) else { return XCTFail() }
        XCTAssertEqual(options.secrets.map(\.delivery), [.file, .env])
        XCTAssertEqual(options.literals.map(\.name), ["TEAM"])
    }

    /// The usage lines name `--wait` for every command that takes it: an agent facing a locked vault reads them.
    func testUsageNamesWaitWhereverItIsTaken() throws {
        let lines = Arguments.usageText.split(separator: "\n").map(String.init)
        for (command, arguments) in [("run", ["run", "--env", "A=pp://X/a", "--wait", "5", "--", "true"]), ("read", ["read", "pp://X/a", "--wait", "5"]),
                                      ("login", ["login", "pp://X/a", "--wait", "5"]), ("list", ["list", "--wait", "5"])] {
            XCTAssertNoThrow(try Arguments.parse(arguments), command)
            let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("  passwordpie \(command) ") }, command)
            // A usage line may run on to the next (run's does).
            XCTAssertTrue(lines[start...].prefix(2).joined().contains("[--wait SECONDS]"), command)
        }
    }

    func testMistakesAreUsageErrors() {
        for arguments in [
            ["run", "--", "true"],
            ["run", "--env", "A=pp://X/a"],
            ["run", "--env", "A=pp://X/a", "--env", "A=pp://X/b", "--", "true"],
            ["run", "--env", "1A=pp://X/a", "--", "true"],
            ["run", "--wait", "601", "--env", "A=pp://X/a", "--", "true"],
            ["run", "--stdin", "pp://X/a", "--stdin", "pp://X/b", "--", "true"],
            ["read"],
            ["read", "pp://"],
            ["status", "--frob"],
        ] {
            XCTAssertThrowsError(try Arguments.parse(arguments), arguments.joined(separator: " "))
        }
    }

    func testFileNamesKeepTheAttachmentsExtension() {
        XCTAssertEqual(RunFolder.fileName(variable: "NOTARY_KEY", ref: "pp://D/k/attachment/AuthKey_ABC.p8"), "NOTARY_KEY.p8")
        XCTAssertEqual(RunFolder.fileName(variable: "TOKEN", ref: "pp://D/k"), "TOKEN")
        XCTAssertEqual(RunFolder.fileName(variable: "K", ref: "pp://D/k/attachment/../../x"), "K")
    }

    func testProgramPathFollowsPATH() {
        XCTAssertEqual(ProgramPath.resolve("sh", path: "/nowhere:/bin"), "/bin/sh")
        XCTAssertNil(ProgramPath.resolve("no-such-program-x", path: "/bin"))
        XCTAssertEqual(ProgramPath.resolve("./sh", path: nil, cwd: "/bin"), "/bin/sh")
    }

    func testExitCodes() {
        XCTAssertEqual(ChildProcess.exitCode(3 << 8), 3)
        XCTAssertEqual(ChildProcess.exitCode(9), 137)
    }
}
