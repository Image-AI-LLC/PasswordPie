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

    /// `--env-file` more than once: a later file's line replaces an earlier file's line of the same name, whatever kind
    /// of line it is, so a file kept on one Mac can add or change what the committed one says (docs/AGENTS.md, ".env.pp").
    func testALaterEnvFileOverridesAnEarlierOne() throws {
        let files = [
            ".env.pp": "TOKEN=pp://Agents/Token\nREGION=eu\nKEY=file:pp://Agents/Token/attachment/AuthKey.p8\nKEEP=pp://Agents/Keep\n",
            ".env.local": "REGION=us\nTOKEN=pp://Local/Token\nKEY=/Users/me/key.p8\nCONFIGS_DIR=/Users/me/configs\nEXTRA=pp://Local/Extra\n",
        ]
        guard case .run(let options) = try Arguments.parse(
            ["run", "--env-file", ".env.pp", "--env-file=.env.local", "--", "true"], readFile: { files[$0] ?? "" }
        ) else { return XCTFail() }
        XCTAssertEqual(options.secrets, [
            AgentSecretRequest(name: "TOKEN", ref: "pp://Local/Token", delivery: .env),
            AgentSecretRequest(name: "KEEP", ref: "pp://Agents/Keep", delivery: .env),
            AgentSecretRequest(name: "EXTRA", ref: "pp://Local/Extra", delivery: .env),
        ])
        XCTAssertEqual(options.literals.map(\.name), ["REGION", "KEY", "CONFIGS_DIR"], "a plain line replaces a reference too")
        XCTAssertEqual(options.literals.map(\.value), ["us", "/Users/me/key.p8", "/Users/me/configs"])

        // The other way round, the committed file wins: the order on the command line decides.
        guard case .run(let reversed) = try Arguments.parse(
            ["run", "--env-file", ".env.local", "--env-file", ".env.pp", "--", "true"], readFile: { files[$0] ?? "" }
        ) else { return XCTFail() }
        XCTAssertEqual(reversed.secrets.first { $0.name == "TOKEN" }?.ref, "pp://Agents/Token")
        XCTAssertEqual(reversed.secrets.first { $0.name == "KEY" }?.delivery, .file)
        XCTAssertEqual(reversed.literals.map(\.name), ["REGION", "CONFIGS_DIR"])
        XCTAssertEqual(reversed.literals.first?.value, "eu")
    }

    /// A flag wins over a file wherever it stands; within one file, and between two flags, a name twice is a mistake.
    func testAFlagWinsOverAFileAndRepeatsAreMistakes() throws {
        let file = "TOKEN=pp://Agents/Token\nREGION=eu\n"
        for arguments in [
            ["run", "--env", "TOKEN=pp://Flag/Token", "--env-file", ".env.pp", "--", "true"],
            ["run", "--env-file", ".env.pp", "--env", "TOKEN=pp://Flag/Token", "--", "true"],
        ] {
            guard case .run(let options) = try Arguments.parse(arguments, readFile: { _ in file }) else { return XCTFail() }
            XCTAssertEqual(options.secrets, [AgentSecretRequest(name: "TOKEN", ref: "pp://Flag/Token", delivery: .env)])
            XCTAssertEqual(options.literals.map(\.name), ["REGION"])
        }
        // A flag that replaces a file's plain line: the variable is the secret, not set twice.
        guard case .run(let options) = try Arguments.parse(["run", "--file", "REGION=pp://Flag/Region", "--env-file", ".env.pp", "--", "true"], readFile: { _ in file }) else { return XCTFail() }
        XCTAssertEqual(options.secrets.map(\.name), ["REGION", "TOKEN"])
        XCTAssertTrue(options.literals.isEmpty)

        XCTAssertThrowsError(try Arguments.parse(["run", "--env-file", "twice.pp", "--", "true"], readFile: { _ in "A=pp://X/a\nA=pp://X/b\n" })) { error in
            XCTAssertEqual((error as? UsageError)?.message, "twice.pp: A is given twice.")
        }
        XCTAssertThrowsError(try Arguments.parse(["run", "--env-file", "twice.pp", "--", "true"], readFile: { _ in "A=1\nA=pp://X/b\n" }))
        XCTAssertThrowsError(try Arguments.parse(["run", "--env-file", "a.pp", "--env-file", "bad.pp", "--", "true"], readFile: { $0 == "a.pp" ? "A=pp://X/a\n" : "not a line\n" })) { error in
            XCTAssertEqual((error as? UsageError)?.message, "bad.pp, line 1: expected NAME=value.")
        }
        XCTAssertThrowsError(try Arguments.parse(["run", "--env-file", "a.pp", "--env-file", "gone.pp", "--", "true"], readFile: { path in
            if path == "gone.pp" { throw CocoaError(.fileNoSuchFile) }
            return "A=pp://X/a\n"
        })) { error in
            XCTAssertEqual((error as? UsageError)?.message, "Could not read gone.pp.")
        }
        // Files that leave no reference: a second file turned the only one into a plain line.
        XCTAssertThrowsError(try Arguments.parse(["run", "--env-file", "a.pp", "--env-file", "b.pp", "--", "true"], readFile: { $0 == "a.pp" ? "A=pp://X/a\n" : "A=plain\n" }))
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
