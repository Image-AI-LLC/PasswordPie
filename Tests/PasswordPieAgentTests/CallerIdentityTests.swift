import Darwin
import Foundation
import XCTest
@testable import PasswordPieAgent

/// A process table for the walk, without the kernel.
private struct TableFacts: ProcessFacts {
    var records: [Int32: ProcessRecord]
    var args: [Int32: [String]] = [:]
    var signatures: [Int32: (String?, String?, String?)] = [:]
    var sid: Int32 = 50
    var cwd = "/tmp"

    func info(_ pid: Int32) -> ProcessRecord? { records[pid] }
    func workingDirectory(_ pid: Int32) -> String? { cwd }
    func arguments(_ pid: Int32) -> [String] { args[pid] ?? [] }
    func sessionID(_ pid: Int32) -> Int32? { sid }
    func signature(_ pid: Int32) -> (team: String?, identifier: String?, signer: String?) {
        let entry = signatures[pid] ?? (nil, nil, nil)
        return (entry.0, entry.1, entry.2)
    }
}

final class CallerIdentityTests: XCTestCase {
    private func record(_ pid: Int32, parent: Int32, start: UInt64, _ path: String) -> ProcessRecord {
        ProcessRecord(pid: pid, parent: parent, startTime: start, path: path)
    }

    func testTheNearestKnownAgentIsTheAgentAndItsProcessTheSession() throws {
        let facts = TableFacts(
            records: [
                1: record(1, parent: 0, start: 1, "/sbin/launchd"),
                10: record(10, parent: 1, start: 10, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                20: record(20, parent: 10, start: 20, "/bin/zsh"),
                30: record(30, parent: 20, start: 30, "/Users/me/.local/share/claude/versions/2.1/claude"),
                40: record(40, parent: 30, start: 40, "/bin/zsh"),
                50: record(50, parent: 40, start: 50, "/Applications/PasswordPie.app/Contents/Helpers/passwordpie"),
            ],
            signatures: [
                30: ("Q6L2SF6YDW", "com.anthropic.claude-code", "Anthropic PBC"),
                10: (nil, "com.apple.Terminal", "Apple"),
                20: (nil, "com.apple.zsh", "Apple"),
                40: (nil, "com.apple.zsh", "Apple"),
            ]
        )
        let caller = try XCTUnwrap(CallerInspector.identify(pid: 50, facts: facts))
        XCTAssertEqual(caller.chain.map(\.pid), [40, 30, 20, 10, 1])
        XCTAssertEqual(caller.agentName, "Claude Code")
        XCTAssertEqual(caller.signatureText, "signed by Anthropic PBC")
        XCTAssertEqual(caller.sessionKey, "agent:30:30")
        XCTAssertEqual(caller.agent?.identity, "Q6L2SF6YDW:com.anthropic.claude-code")
    }

    func testAnAgentOnAnInterpreterIsNamedByItsScriptAndShownUnsigned() throws {
        let facts = TableFacts(
            records: [
                1: record(1, parent: 0, start: 1, "/sbin/launchd"),
                30: record(30, parent: 1, start: 30, "/opt/homebrew/bin/node"),
                50: record(50, parent: 30, start: 50, "/x/passwordpie"),
            ],
            args: [30: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]]
        )
        let caller = try XCTUnwrap(CallerInspector.identify(pid: 50, facts: facts))
        XCTAssertEqual(caller.agentName, "Codex")
        XCTAssertEqual(caller.signatureText, "not signed: /opt/homebrew/bin/node")
        XCTAssertEqual(caller.agent?.identity, "path:/opt/homebrew/bin/node")
    }

    /// With no known agent host, the agent is the first ancestor that is not a shell or terminal, and the session is the
    /// tool's POSIX session.
    func testWithoutAKnownAgentTheSessionIsThePOSIXSession() throws {
        let facts = TableFacts(
            records: [
                1: record(1, parent: 0, start: 1, "/sbin/launchd"),
                9: record(9, parent: 1, start: 9, "/usr/local/bin/mytool"),
                20: record(20, parent: 9, start: 20, "/bin/bash"),
                50: record(50, parent: 20, start: 50, "/x/passwordpie"),
                77: record(77, parent: 1, start: 77, "/bin/bash"),
            ],
            sid: 77
        )
        let caller = try XCTUnwrap(CallerInspector.identify(pid: 50, facts: facts))
        XCTAssertEqual(caller.agentName, "mytool")
        XCTAssertEqual(caller.sessionKey, "session:77:77")
    }

    func testTypedInATerminalTheTerminalAsks() throws {
        let facts = TableFacts(
            records: [
                1: record(1, parent: 0, start: 1, "/sbin/launchd"),
                10: record(10, parent: 1, start: 10, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                15: record(15, parent: 10, start: 15, "/usr/bin/login"),
                20: record(20, parent: 15, start: 20, "/bin/zsh"),
                50: record(50, parent: 20, start: 50, "/x/passwordpie"),
            ],
            signatures: [10: (nil, "com.apple.Terminal", "Apple"), 15: (nil, "com.apple.login", "Apple"), 20: (nil, "com.apple.zsh", "Apple")]
        )
        let caller = try XCTUnwrap(CallerInspector.identify(pid: 50, facts: facts))
        XCTAssertEqual(caller.agentName, "Terminal")
        XCTAssertEqual(caller.signatureText, "signed by Apple")
    }

    /// A parent that started after its child is a later process that got an exited parent's pid: the walk stops there.
    func testAReusedParentPIDEndsTheWalk() throws {
        let facts = TableFacts(records: [
            1: record(1, parent: 0, start: 1, "/sbin/launchd"),
            30: record(30, parent: 1, start: 999, "/usr/local/bin/claude"),
            50: record(50, parent: 30, start: 50, "/x/passwordpie"),
        ])
        let caller = try XCTUnwrap(CallerInspector.identify(pid: 50, facts: facts))
        XCTAssertTrue(caller.chain.isEmpty)
        XCTAssertNotEqual(caller.agentName, "Claude Code")
    }

    func testTheProjectIsTheNearestFolderWithGit() throws {
        let root = try shortTemporaryFolder("ppproj")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertEqual(CallerInspector.project(for: deep.path), deep.path, "no .git: the folder itself")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(CallerInspector.project(for: deep.path), root.standardizedFileURL.path)
    }

    /// The kernel walk on a real process: a child started in a folder, read by pid.
    func testTheLiveWalkReadsTheWorkingFolderAndChain() throws {
        let folder = try shortTemporaryFolder("ppwalk")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.currentDirectoryURL = folder
        try child.run()
        defer { child.terminate() }
        let caller = try XCTUnwrap(CallerInspector.identify(pid: child.processIdentifier))
        let real = try XCTUnwrap(realpath(folder.path, nil).map { String(cString: $0) })
        func resolved(_ path: String) -> String? { realpath(path, nil).map { String(cString: $0) } }
        XCTAssertEqual(resolved(caller.cwd), real)
        XCTAssertEqual(resolved(caller.project), real)
        XCTAssertEqual(caller.chain.first?.pid, getpid())
        XCTAssertEqual(caller.chain.last?.pid, 1)
        XCTAssertTrue(caller.chain.allSatisfy { $0.startTime > 0 })
        XCTAssertEqual(caller.cli.path, "/bin/sleep")
        XCTAssertEqual(caller.chain.map(\.pid).filter { $0 == 1 }.count, 1, "through processes of other users (login) up to launchd")
        XCTAssertEqual(LiveProcessFacts.shared.signature(child.processIdentifier).signer, "Apple")
    }

    func testSignerNames() {
        XCTAssertEqual(CodeSignature.signerName("Developer ID Application: Anthropic PBC (Q6L2SF6YDW)", team: "Q6L2SF6YDW"), "Anthropic PBC")
        XCTAssertEqual(CodeSignature.signerName("Software Signing", team: nil), "Apple")
    }
}

final class AgentActivityLogTests: XCTestCase {
    func testOneLinePerRecordModeOwnerOnlyAndNoValue() throws {
        let folder = try shortTemporaryFolder("ppact")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AgentActivityLog(url: folder.appendingPathComponent("agent-activity.jsonl"))
        let caller = Callers.make()
        for outcome in [AgentOutcome.allowedOnce, .denied, .timedOut, .locked, .notAvailable] {
            log.append(AgentActivityRecord(time: Date(), kind: "run", outcome: outcome, caller: caller, command: "Scripts/release.sh",
                                           items: ["Agents/Token › password"], delivery: ["env T"], reason: "because"))
        }
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(log.records().map(\.outcome), [.allowedOnce, .denied, .timedOut, .locked, .notAvailable])
        XCTAssertEqual(log.records().first?.chain.map(\.path), ["/bin/zsh", "/usr/local/bin/claude"])
    }

    func testLinesOlderThanNinetyDaysAreDropped() throws {
        let folder = try shortTemporaryFolder("ppact")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("agent-activity.jsonl")
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let writer = AgentActivityLog(url: url, clock: { now })
        writer.append(AgentActivityRecord(time: now.addingTimeInterval(-91 * 86_400), kind: "run", outcome: .denied, caller: nil, command: nil, items: [], delivery: [], reason: nil))
        writer.append(AgentActivityRecord(time: now.addingTimeInterval(-89 * 86_400), kind: "run", outcome: .allowedOnce, caller: nil, command: nil, items: [], delivery: [], reason: nil))
        now = now.addingTimeInterval(7200)
        writer.append(AgentActivityRecord(time: now, kind: "read", outcome: .shown, caller: nil, command: nil, items: [], delivery: [], reason: nil))
        XCTAssertEqual(writer.records().map(\.outcome), [.allowedOnce, .shown])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }
}
