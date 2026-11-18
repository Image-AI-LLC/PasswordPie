import XCTest
@testable import PasswordPieCore

/// The database's custom data (`Meta/CustomData`), where PasswordPie keeps what is shared with agents, and attachments read
/// on demand for agents.
final class KDBXCustomDataTests: XCTestCase {
    private func id(_ text: String) -> String { base64UUID(UUID(uuidString: text)!) }

    private func xml(customData: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <KeePassFile><Meta><DatabaseName>Box</DatabaseName>\(customData)</Meta>
        <Root><Group><UUID>\(id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))</UUID><Name>Root</Name>
        <Entry><UUID>\(id("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))</UUID>
        <String><Key>Title</Key><Value>Key</Value></String>
        <String><Key>Password</Key><Value Protected="True">pw</Value></String>
        <Binary><Key>AuthKey.p8</Key><Value Ref="0"/></Binary>
        <Binary><Key>inline.txt</Key><Value>aW5saW5l</Value></Binary>
        <Binary><Key>dangling.bin</Key><Value Ref="7"/></Binary>
        </Entry></Group></Root></KeePassFile>
        """
    }

    func testCustomDataIsReadSavedAndKeptBesideOtherKeys() throws {
        let other = "<CustomData><Item><Key>KPXC_DECRYPTION_TIME_PREFERENCE</Key><Value>1000</Value></Item></CustomData>"
        var vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml(customData: other), password: "secret"), password: "secret")
        XCTAssertEqual(vault.customData, ["KPXC_DECRYPTION_TIME_PREFERENCE": "1000"])
        vault.customData["PasswordPie.AgentSharing"] = #"{"items":[]}"#
        let saved = try KDBX.save(vault: &vault, password: "secret")
        let reloaded = try KDBX.load(data: saved, password: "secret")
        XCTAssertEqual(reloaded.customData, ["KPXC_DECRYPTION_TIME_PREFERENCE": "1000", "PasswordPie.AgentSharing": #"{"items":[]}"#])
        var removed = reloaded
        removed.customData["PasswordPie.AgentSharing"] = nil
        let again = try KDBX.load(data: try KDBX.save(vault: &removed, password: "secret"), password: "secret")
        XCTAssertEqual(again.customData, ["KPXC_DECRYPTION_TIME_PREFERENCE": "1000"])
    }

    func testANewDatabaseKeepsItsCustomData() throws {
        var vault = Vault(name: "New", rootName: "New", entries: [VaultEntry(fields: [VaultField(key: "Title", value: "One")])], kdf: .fastTest)
        vault.customData = ["PasswordPie.AgentSharing": "<&>"]
        let saved = try KDBX.save(vault: &vault, password: "secret")
        XCTAssertEqual(try KDBX.load(data: saved, password: "secret").customData, ["PasswordPie.AgentSharing": "<&>"])
    }

    func testOnlyCustomDataChangingStillCountsAsAChange() throws {
        let vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml(), password: "secret"), password: "secret")
        var changed = vault
        changed.customData["x"] = "y"
        XCTAssertNotEqual(vault, changed)
    }

    func testAttachmentsAreReadByName() throws {
        let key = Data("-----BEGIN PRIVATE KEY-----".utf8)
        let vault = try KDBX.load(data: try KDBX.testingDatabase(xml: xml(), binaries: [key], password: "secret"), password: "secret")
        let entry = try XCTUnwrap(vault.entries.first)
        XCTAssertEqual(vault.attachmentNames(of: entry.id), ["AuthKey.p8", "inline.txt"])
        XCTAssertEqual(vault.attachment(named: "AuthKey.p8", of: entry.id), key)
        XCTAssertEqual(vault.attachment(named: "inline.txt", of: entry.id), Data("inline".utf8))
        XCTAssertNil(vault.attachment(named: "missing", of: entry.id))
        XCTAssertEqual(vault.attachmentNames(of: UUID()), [])
    }
}

#if PP_DIRECT
final class AgentSharingTests: XCTestCase {
    func testNothingIsSharedByDefault() {
        let sharing = AgentSharing(customData: [:])
        XCTAssertTrue(sharing.isEmpty)
        XCTAssertFalse(sharing.covers(VaultEntry(groupPath: ["Agents"])))
    }

    func testItemsAndFoldersWithSubfoldersButNeverTheRecycleBin() {
        var sharing = AgentSharing()
        let item = VaultEntry(groupPath: ["Personal"])
        sharing.set(item: item.id, shared: true)
        sharing.set(folder: ["Developer"], shared: true)
        XCTAssertTrue(sharing.covers(item))
        XCTAssertTrue(sharing.covers(VaultEntry(groupPath: ["Developer"])))
        XCTAssertTrue(sharing.covers(VaultEntry(groupPath: ["Developer", "Apple"])))
        XCTAssertFalse(sharing.covers(VaultEntry(groupPath: ["Developers"])))
        XCTAssertFalse(sharing.covers(VaultEntry(groupPath: ["Developer"], trashed: true)))
        var trashed = item
        trashed.trashed = true
        XCTAssertFalse(sharing.covers(trashed))
    }

    func testRoundTripsThroughCustomDataAndEmptyRemovesTheKey() {
        var sharing = AgentSharing()
        let id = UUID()
        sharing.set(item: id, shared: true)
        sharing.set(folder: ["A", "B"], shared: true)
        var data: [String: String] = ["other": "kept"]
        sharing.write(into: &data)
        XCTAssertEqual(AgentSharing(customData: data), sharing)
        sharing.set(item: id, shared: false)
        sharing.set(folder: ["A", "B"], shared: false)
        sharing.write(into: &data)
        XCTAssertEqual(data, ["other": "kept"])
    }

    func testUnreadableDataSharesNothing() {
        XCTAssertTrue(AgentSharing(customData: [AgentSharing.customDataKey: "{not json"]).isEmpty)
    }
}
#endif
