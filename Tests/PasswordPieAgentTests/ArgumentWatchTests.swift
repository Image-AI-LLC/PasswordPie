import Foundation
import XCTest
@testable import PasswordPieAgent

/// The argument watch against a scripted process table.
final class ArgumentWatchTests: XCTestCase {
    private final class Found: @unchecked Sendable {
        let lock = NSLock()
        var findings: [ArgumentWatch.Finding] = []
        func add(_ finding: ArgumentWatch.Finding) {
            lock.lock()
            findings.append(finding)
            lock.unlock()
        }
    }

    /// 10 → 11 → 12, and 10 → 13.
    private func facts(_ arguments: [Int32: [String]]) -> ArgumentWatch.Facts {
        ArgumentWatch.Facts(
            children: { [10: [11, 13], 11: [12]][$0] ?? [] },
            arguments: { pid in (arguments[pid] ?? []).map { Data($0.utf8) } },
            path: { "/usr/bin/tool\($0)" }
        )
    }

    private let value = ArgumentWatch.Watched(name: "APPLE_PASSWORD", ref: "pp://Dev/Apple", delivery: .env, value: Data("abcdef-secret".utf8))

    func testFindsAValueOnADescendantsCommandLineOncePerProcess() {
        let found = Found()
        let watch = ArgumentWatch(root: 10, watched: [value], facts: facts([
            10: ["sh", "-c", "release.sh"],
            12: ["notarytool", "submit", "--password", "abcdef-secret"],
            13: ["echo", "x=abcdef-secret;"],
        ]), report: found.add)
        watch.look()
        watch.look()
        XCTAssertEqual(found.findings.map(\.pid).sorted(), [12, 13])
        XCTAssertEqual(found.findings.first { $0.pid == 12 }?.program, "/usr/bin/tool12")
        let warning = found.findings[0].warning
        XCTAssertTrue(warning.hasPrefix("PasswordPie: the value of APPLE_PASSWORD (pp://Dev/Apple) appeared on the command line of tool"))
        XCTAssertFalse(warning.contains("abcdef-secret"))
    }

    func testShortValuesAndOtherTextAreNotReported() {
        let found = Found()
        let short = ArgumentWatch.Watched(name: "PIN", ref: "pp://Dev/Pin", delivery: .env, value: Data("1234".utf8))
        let watch = ArgumentWatch(root: 10, watched: [short, value], facts: facts([12: ["tool", "1234", "abcdef-secre"]]), report: found.add)
        watch.look()
        XCTAssertTrue(found.findings.isEmpty)
        XCTAssertTrue(ArgumentWatch(root: 10, watched: [short], facts: facts([:]), report: found.add).isEmpty)
    }

    /// The kernel's record of a process holds its environment after its arguments (when it shows it at all); only the
    /// arguments are read.
    func testTheRecordIsReadUpToItsArgumentsNotTheEnvironment() {
        var record: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { record += $0 }
        record += Array("/usr/bin/notarytool".utf8) + [0, 0, 0]
        record += Array("notarytool".utf8) + [0] + Array("submit".utf8) + [0]
        record += Array("APPLE_PASSWORD=abcdef-secret".utf8) + [0]
        let arguments = ArgumentWatch.arguments(fromRecord: record).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(arguments, ["notarytool", "submit"])
    }

    func testTheLiveReaderReadsARealProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.environment = ["WATCHED": "in-the-environment-only"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let arguments = ArgumentWatch.liveArguments(process.processIdentifier).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(arguments, ["/bin/sleep", "5"])
        XCTAssertTrue(ArgumentWatch.liveChildren(getpid()).contains(process.processIdentifier))
        XCTAssertEqual(ArgumentWatch.livePath(process.processIdentifier), "/bin/sleep")
    }
}

final class AgentMCPSetupTests: XCTestCase {
    func testLinesForClaudeCodeCodexAndCursor() throws {
        let hosts = AgentMCPSetup.hosts(tool: "/Applications/Pass Word Pie.app/Contents/Helpers/passwordpie")
        XCTAssertEqual(hosts.map(\.name), ["Claude Code", "Codex", "Cursor"])
        XCTAssertEqual(hosts[0].text, "claude mcp add --scope user passwordpie -- '/Applications/Pass Word Pie.app/Contents/Helpers/passwordpie' mcp")
        XCTAssertEqual(hosts[1].text, "[mcp_servers.passwordpie]\ncommand = \"/Applications/Pass Word Pie.app/Contents/Helpers/passwordpie\"\nargs = [\"mcp\"]\ntool_timeout_sec = 3900")
        let cursor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\(hosts[2].text)}".utf8)) as? [String: [String: Any]])
        XCTAssertEqual(cursor["passwordpie"]?["command"] as? String, "/Applications/Pass Word Pie.app/Contents/Helpers/passwordpie")
        XCTAssertEqual(cursor["passwordpie"]?["args"] as? [String], ["mcp"])
        XCTAssertEqual(AgentMCPSetup.shellQuoted("/a/it's"), "'/a/it'\\''s'")
    }

    func testMCPRefusalsNameTheCodeAndEndWithTheGuidance() {
        for code in AgentErrorCode.allCases {
            let text = AgentRefusal.mcp(code, ref: "pp://A/B")
            XCTAssertTrue(text.hasPrefix("\(code.rawValue): PasswordPie: "), text)
            XCTAssertTrue(text.hasSuffix(AgentConstants.mcpGuidance), text)
            XCTAssertFalse(text.contains("passwordpie list"), "MCP text names the tool, not the command: \(text)")
            XCTAssertFalse(text.contains("--wait"), text)
        }
        XCTAssertTrue(AgentConstants.mcpGuidance.contains("You never receive a password unless you use passwordpie_read and the owner approves."))
        XCTAssertTrue(AgentConstants.mcpGuidance.contains("Don't ask the person to type or paste a password into this conversation"))
    }
}
