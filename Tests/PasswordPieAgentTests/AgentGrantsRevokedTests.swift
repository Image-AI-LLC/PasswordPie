import Foundation
@testable import PasswordPieAgent
import XCTest

/// A standing permission that is taken away stays in the file as taken away until it would have ended, so that
/// merging another Mac's copy of the database, which may still hold it, does not bring it back (docs/AGENTS.md,
/// "Standing permissions"; the merge is `AgentGrantsRecord.merged` in the core library).
final class AgentGrantsRevokedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_272_000)

    private func grant(_ length: AgentGrantLength = .days7, session: String? = nil) -> AgentGrant {
        AgentGrant(
            mac: "mac", created: now, length: length, session: session, kind: .use, agent: "agent", agentName: "Agent",
            project: "/project", program: nil, secrets: [], labels: []
        )
    }

    func testARemovedGrantIsRecordedAsRevokedUntilItWouldHaveEnded() throws {
        let (kept, taken) = (grant(), grant(.days30))
        var grants = AgentGrants([kept, taken])
        grants.remove(taken.id)
        XCTAssertEqual(grants.all, [kept])
        XCTAssertEqual(grants.revoked, [AgentGrants.Revoked(id: taken.id, ends: taken.ends)])

        var data: [String: String] = [:]
        grants.write(into: &data)
        let read = AgentGrants(customData: data)
        XCTAssertEqual(read, grants)
        // Plain JSON the core library can merge without knowing what a grant is: `grants` and `revoked`, each by `id`.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(data[AgentGrants.customDataKey]).utf8)) as? [String: Any])
        XCTAssertEqual((object["grants"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [kept.id.uuidString])
        XCTAssertEqual((object["revoked"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [taken.id.uuidString])
        XCTAssertNotNil((object["revoked"] as? [[String: Any]])?.first?["ends"] as? NSNumber)

        grants.forgetEnded(now: taken.ends.addingTimeInterval(-1))
        XCTAssertEqual(grants.revoked.count, 1)
        grants.forgetEnded(now: taken.ends)
        XCTAssertEqual(grants.revoked, [])
    }

    func testRevokingEverythingKeepsTheKeyUntilTheRecordsEnd() {
        var grants = AgentGrants([grant(), grant()])
        grants.removeAll { _ in true }
        XCTAssertTrue(grants.isEmpty)
        var data: [String: String] = ["other": "kept"]
        grants.write(into: &data)
        XCTAssertNotNil(data[AgentGrants.customDataKey], "the file must still say they were revoked")
        XCTAssertEqual(AgentGrants(customData: data).revoked.count, 2)
        grants.forgetEnded(now: now.addingTimeInterval(8 * 86_400))
        grants.write(into: &data)
        XCTAssertEqual(data, ["other": "kept"])
    }

    func testAFileWrittenBeforeRevokedGrantsWereRecordedIsRead() throws {
        var old = AgentGrants([grant()])
        var data: [String: String] = [:]
        old.write(into: &data)
        XCTAssertFalse(try XCTUnwrap(data[AgentGrants.customDataKey]).contains("revoked"), "nothing revoked, nothing written about it")
        XCTAssertEqual(AgentGrants(customData: data).all.count, 1)
        old.remove(UUID())
        XCTAssertEqual(old.revoked, [], "removing a grant that is not there records nothing")
    }

    /// The store drops what has ended on every change: a grant that ran out needs no record, and a record is dropped
    /// when its grant would have run out.
    @MainActor
    func testTheStoreForgetsRecordsOfGrantsThatWouldHaveEnded() {
        var clock = now
        let short = grant(.hours8), long = grant(.days30)
        var stored = AgentGrants([short, long])
        let store = StandingPermissions(
            mac: "mac", hasPremium: { true }, read: { stored },
            write: { edit, done in
                edit(&stored)
                done(true)
            }
        )
        store.clock = { clock }
        store.revoke(short.id)
        XCTAssertEqual(stored.revoked.map(\.id), [short.id])
        clock = now.addingTimeInterval(9 * 3600)
        store.revoke(long.id)
        XCTAssertEqual(stored.revoked.map(\.id), [long.id], "the 8-hour grant would have ended by now")
        XCTAssertEqual(stored.all, [])
    }
}
