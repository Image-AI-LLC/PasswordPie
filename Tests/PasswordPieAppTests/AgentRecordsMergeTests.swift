#if PP_DIRECT
import Foundation
@testable import PasswordPieAgent
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Standing permissions and sharing as the app really writes them, through a merge of two copies of a database
/// (docs/AGENTS.md, "Standing permissions"). The merge reads the permissions as plain JSON, because the core library does
/// not link the agent library: this is where the two are held together.
final class AgentRecordsMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_272_000.25)

    private func copy(_ edit: (inout [String: String]) -> Void) throws -> Vault {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Two Macs</DatabaseName></Meta><Root><Group><UUID>\(base64UUID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))</UUID><Name>Root</Name></Group></Root></KeePassFile>
        """
        var vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml, password: "secret"), password: "secret")
        edit(&vault.customData)
        return try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
    }

    private func grant(mac: String, length: AgentGrantLength = .days7) -> AgentGrant {
        AgentGrant(
            mac: mac, created: now, length: length, session: nil, kind: .use, agent: "com.anthropic.claude-code", agentName: "Claude Code",
            project: "/Users/ada/project", program: nil,
            secrets: [AgentGrantSecret(item: UUID(), field: ["password"], delivery: .env, name: "TOKEN")],
            labels: ["Agents/Token › password"]
        )
    }

    func testEachMacsGrantsSurviveAMergeAndARevokedOneDoesNotComeBack() throws {
        let shared = grant(mac: "pro"), fromPro = grant(mac: "pro", length: .days30), fromAir = grant(mac: "air", length: .hours8)
        // The Pro revoked the grant both had and made one. The Air still holds the old one and made its own.
        var pro = AgentGrants([shared])
        pro.remove(shared.id)
        pro.add(fromPro)
        var air = AgentGrants([shared])
        air.add(fromAir)
        let onPro = try copy { pro.write(into: &$0) }
        let onAir = try copy { air.write(into: &$0) }

        for (base, other) in [(onPro, onAir), (onAir, onPro)] {
            let merged = AgentGrants(customData: try VaultMerge.merge(other, into: base).vault.customData)
            XCTAssertEqual(Set(merged.all.map(\.id)), [fromPro.id, fromAir.id])
            XCTAssertEqual(merged.revoked, [AgentGrants.Revoked(id: shared.id, ends: shared.ends)])
            // Every field of a grant comes through as it was written, dates to the fraction of a second.
            XCTAssertEqual(merged.all.first { $0.id == fromPro.id }, fromPro)
            XCTAssertEqual(merged.all.first { $0.id == fromAir.id }, fromAir)
            XCTAssertEqual(merged.inForce(mac: "air", now: now, sessionAlive: { _ in true }).map(\.id), [fromAir.id])
        }
    }

    func testAMergeWithNothingNewLeavesTheGrantsTextAsTheAppWroteIt() throws {
        var grants = AgentGrants([grant(mac: "pro"), grant(mac: "air")])
        grants.remove(grants.all[0].id)
        let mine = try copy { grants.write(into: &$0) }
        let same = try copy { grants.write(into: &$0) }
        let outcome = try VaultMerge.merge(same, into: mine)
        XCTAssertFalse(outcome.report.changed)
        XCTAssertEqual(outcome.vault.customData, mine.customData)
    }

    func testAnItemUnsharedOnOneMacIsNotSharedAgainByTheOtherMacsCopy() throws {
        let (token, other) = (UUID(), UUID())
        var before = AgentSharing()
        before.set(item: token, shared: true, at: now)
        var pro = before
        pro.set(item: token, shared: false, at: now.addingTimeInterval(60))
        var air = before
        air.set(item: other, shared: true, at: now.addingTimeInterval(30))
        let onPro = try copy { pro.write(into: &$0) }
        let onAir = try copy { air.write(into: &$0) }

        for (base, source) in [(onPro, onAir), (onAir, onPro)] {
            let merged = AgentSharing(customData: try VaultMerge.merge(source, into: base).vault.customData)
            XCTAssertEqual(merged.items, [other])
            XCTAssertFalse(merged.covers(VaultEntry(id: token)))
        }
    }
}
#endif
