@testable import PasswordPieCore
import XCTest

final class EntryFieldsTests: XCTestCase {
    private func entry() -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Steam"
        entry.username = "ada"
        entry.password = "secret"
        entry.url = "https://store.steampowered.com"
        entry.otp = "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"
        entry.fields.append(VaultField(key: "URL (2)", value: "https://checkout.steampowered.com/login/"))
        entry.fields.append(VaultField(key: "no_name_eeaae", value: "Buy"))
        entry.fields.append(VaultField(key: "PIN", value: "1234", protected: true))
        entry.fields.append(VaultField(key: "TimeOtp-Secret-Base32", value: "JBSWY3DPEHPK3PXP"))
        entry.fields.append(VaultField(key: EntryMerge.keepSeparateKey, value: "1"))
        entry.fields.append(VaultField(key: "Empty", value: ""))
        return entry
    }

    func testRowsAreOtherWebsitesAndCustomFieldsOnly() {
        let entry = entry()
        XCTAssertEqual(EntryFields.websites(of: entry).map(\.value), ["https://checkout.steampowered.com/login/"])
        let custom = EntryFields.custom(of: entry)
        XCTAssertEqual(custom.map(\.name), ["no_name_eeaae", "PIN"])
        XCTAssertEqual(custom.map(\.protected), [false, true])
    }

    func testSavingUntouchedRowsChangesNothing() {
        let original = entry()
        var edited = original
        EntryFields.apply(websites: EntryFields.websites(of: original), custom: EntryFields.custom(of: original), to: &edited)
        XCTAssertEqual(edited, original)
    }

    func testDeletingARowRemovesTheField() {
        var edited = entry()
        let custom = EntryFields.custom(of: edited).filter { $0.name != "no_name_eeaae" }
        EntryFields.apply(websites: [], custom: custom, to: &edited)
        XCTAssertFalse(edited.fields.contains { $0.key == "no_name_eeaae" })
        XCTAssertFalse(edited.fields.contains { $0.key == "URL (2)" })
        XCTAssertEqual(edited.value(for: "PIN"), "1234")
        // What the editor does not list stays.
        XCTAssertEqual(edited.value(for: "TimeOtp-Secret-Base32"), "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(EntryMerge.keepsSeparate(edited))
        XCTAssertTrue(edited.fields.contains { $0.key == "Empty" })
    }

    func testRenamingAndChangingKeepsPlaceAndProtection() {
        let original = entry()
        var edited = original
        var custom = EntryFields.custom(of: original)
        custom[1].name = "Card PIN"
        custom[1].value = "9999"
        EntryFields.apply(websites: EntryFields.websites(of: original), custom: custom, to: &edited)
        XCTAssertEqual(edited.fields.map(\.key), original.fields.map { $0.key == "PIN" ? "Card PIN" : $0.key })
        let field = edited.fields.first { $0.key == "Card PIN" }
        XCTAssertEqual(field?.value, "9999")
        XCTAssertEqual(field?.protected, true)
    }

    func testAddedWebsitesGetNumberedNamesAndFill() {
        var edited = VaultEntry()
        edited.url = "https://store.steampowered.com"
        let added = [EditableField(value: " https://checkout.steampowered.com/login/ "), EditableField(value: "  "), EditableField(value: "https://steamcommunity.com")]
        EntryFields.apply(websites: added, custom: [], to: &edited)
        XCTAssertEqual(edited.value(for: "URL (2)"), "https://checkout.steampowered.com/login/")
        XCTAssertEqual(edited.value(for: "URL (3)"), "https://steamcommunity.com")
        XCTAssertEqual(entryWebsites(edited).count, 3)
        XCTAssertEqual(SiteSuggestions.matchingWebsite(of: edited, pageURL: "https://steamcommunity.com/login"), "https://steamcommunity.com")
    }

    func testClearedMainWebsiteIsReplacedByTheNext() {
        var edited = entry()
        edited.url = " "
        EntryFields.apply(websites: EntryFields.websites(of: edited), custom: [], to: &edited)
        XCTAssertEqual(edited.url, "https://checkout.steampowered.com/login/")
        XCTAssertEqual(EntryMerge.otherWebsites(edited), [])
    }

    func testNamesAreMadeUniqueAndNeverTakeAStandardField() {
        var edited = entry()
        var custom = EntryFields.custom(of: edited)
        custom.append(EditableField(name: "PIN", value: "5678"))
        custom.append(EditableField(name: "password", value: "not the password"))
        custom.append(EditableField(name: " ", value: "nameless"))
        custom.append(EditableField(name: "Dropped", value: ""))
        EntryFields.apply(websites: [], custom: custom, to: &edited)
        XCTAssertEqual(edited.value(for: "PIN"), "1234")
        XCTAssertEqual(edited.value(for: "PIN (2)"), "5678")
        XCTAssertEqual(edited.password, "secret")
        XCTAssertEqual(edited.value(for: "password (2)"), "not the password")
        XCTAssertEqual(edited.value(for: "Field"), "nameless")
        XCTAssertFalse(edited.fields.contains { $0.key == "Dropped" })
    }

    func testImportedExtraWebsitesAreWebsites() {
        var imported = VaultEntry()
        imported.url = "https://google.com"
        imported.fields.append(VaultField(key: "KP2A_URL_1", value: "https://gmail.com"))
        XCTAssertEqual(entryWebsites(imported), ["https://google.com", "https://gmail.com"])
        XCTAssertEqual(EntryFields.custom(of: imported), [])
        // Its name stays what other KeePass apps read.
        var edited = imported
        var rows = EntryFields.websites(of: imported)
        rows[0].value = "https://mail.google.com"
        EntryFields.apply(websites: rows, custom: [], to: &edited)
        XCTAssertEqual(edited.value(for: "KP2A_URL_1"), "https://mail.google.com")
    }

    func testUnnamedFormFieldsAreToldApart() {
        let names = EntryFields.custom(of: entry()).map(\.name)
        XCTAssertEqual(names.filter(EntryFields.isUnnamed), ["no_name_eeaae"])
        XCTAssertFalse(EntryFields.isUnnamed("Name"))
        XCTAssertTrue(EntryFields.isUnnamed("No_Name_12"))
    }

    func testACardNumberFieldMakesACard() {
        var card = VaultEntry()
        card.title = "Visa"
        EntryFields.apply(websites: [], custom: [EditableField(name: "Card number", value: "4111 1111 1111 1111")], to: &card)
        XCTAssertEqual(card.category, .creditCard)
    }
}
