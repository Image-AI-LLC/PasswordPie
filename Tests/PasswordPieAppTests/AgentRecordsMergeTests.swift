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

    private func proposal(_ id: String) -> AgentProposal {
        AgentProposal(
            id: id, created: now, mac: "air", agent: "com.anthropic.claude-code", agentName: "Claude Code", signature: "Anthropic PBC",
            project: "/Users/ada/shop", reason: "Webhook key", via: nil, item: nil, folder: ["Agents"], title: "Stripe \(id)",
            field: .custom("API key"), change: .newItem, value: Data("PLANTED-proposal-\(id)".utf8)
        )
    }

    /// Saves agents proposed, merged record by record: each Mac's proposals survive, and one answered on either Mac stays
    /// answered (and without its value) whichever copy is merged into which.
    func testProposalsOfBothMacsSurviveAndAnAnsweredOneIsNotPendingAgain() throws {
        let both = proposal("AAAA0001"), fromAir = proposal("BBBB0002"), fromPro = proposal("CCCC0003"), twice = proposal("DDDD0004")
        let air = AgentProposals([both, fromAir, twice.answered(.rejected, at: now)])
        let pro = AgentProposals([both.answered(.saved, at: now, item: UUID()), fromPro, twice.answered(.saved, at: now, item: UUID())])
        let onAir = try copy { air.write(into: &$0) }
        let onPro = try copy { pro.write(into: &$0) }
        for (base, source) in [(onPro, onAir), (onAir, onPro)] {
            let merged = AgentProposals(customData: try VaultMerge.merge(source, into: base).vault.customData)
            let states = Dictionary(uniqueKeysWithValues: merged.all.map { ($0.id, $0.state) })
            XCTAssertEqual(states, ["AAAA0001": .saved, "BBBB0002": .pending, "CCCC0003": .pending, "DDDD0004": .saved])
            XCTAssertNil(merged.all.first { $0.id == "AAAA0001" }?.value, "the value does not come back from the copy that held it pending")
            XCTAssertEqual(merged.all.first { $0.id == "BBBB0002" }, fromAir, "every field as written")
        }
    }

    /// The answered record wins by its state, not by how its text happens to sort: here the pending one sorts first.
    func testAnAnsweredProposalWinsWhicheverSortsFirst() {
        let pending = #"{"proposals":[{"a":"0","id":"X1","state":"pending","value":"UExBTlRFRA=="}],"version":1}"#
        let saved = #"{"proposals":[{"id":"X1","state":"saved","z":"1"}],"version":1}"#
        let rejected = #"{"proposals":[{"id":"X1","state":"rejected","zz":"1"}],"version":1}"#
        for (a, b) in [(pending, saved), (saved, pending)] {
            XCTAssertTrue(AgentProposalsRecord.merged(a, b)?.contains(#""state":"saved""#) ?? false)
        }
        for (a, b) in [(rejected, saved), (saved, rejected)] {
            XCTAssertTrue(AgentProposalsRecord.merged(a, b)?.contains(#""state":"saved""#) ?? false, "saved over rejected")
        }
    }
}
#endif
