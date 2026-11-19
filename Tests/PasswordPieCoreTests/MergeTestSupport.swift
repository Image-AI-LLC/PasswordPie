import Foundation
@testable import PasswordPieCore
import XCTest

// Two copies of one fixture database stand in for two Macs (docs/UX.md, "The same database on two Macs"). A fixture is
// written as KeePass XML with every time given, so a test says exactly which Mac changed what and when.

/// Seconds after the fixtures' zero, 2026-06-01 00:00:00 UTC, as a KDBX 4 time.
func mergeTime(_ offset: Int) -> String {
    formatTime(mergeDate(offset), like: nil)
}

func mergeDate(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: 1_780_272_000 + TimeInterval(offset))
}

/// `mergeID(0xA1)` is the same UUID in every fixture.
func mergeID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number))!
}

struct MergeItem {
    var id: Int
    var title: String
    var password = "pw"
    var modified = 0
    var located = 0
    var created = 0
    var fields: [(key: String, value: String, protected: Bool)] = []
    /// Attachments: a name and an index into the file's binaries.
    var binaries: [(name: String, ref: Int)] = []
    var history: [MergeItem] = []
    /// Raw XML put inside the entry: elements PasswordPie does not know.
    var extra = ""

    init(_ id: Int, _ title: String, password: String = "pw", modified: Int = 0, located: Int = 0,
         fields: [(key: String, value: String, protected: Bool)] = [], binaries: [(name: String, ref: Int)] = [],
         history: [MergeItem] = [], extra: String = "") {
        self.id = id
        self.title = title
        self.password = password
        self.modified = modified
        self.located = located
        self.fields = fields
        self.binaries = binaries
        self.history = history
        self.extra = extra
    }

    func xml(withHistory: Bool = true) -> String {
        var xml = "<Entry><UUID>\(base64UUID(mergeID(id)))</UUID><IconID>0</IconID>"
        xml += "<Times><CreationTime>\(mergeTime(created))</CreationTime><LastModificationTime>\(mergeTime(modified))</LastModificationTime>"
        xml += "<LastAccessTime>\(mergeTime(modified))</LastAccessTime><ExpiryTime>\(mergeTime(0))</ExpiryTime><Expires>False</Expires>"
        xml += "<UsageCount>0</UsageCount><LocationChanged>\(mergeTime(located))</LocationChanged></Times>"
        xml += "<String><Key>Title</Key><Value>\(title)</Value></String>"
        xml += "<String><Key>UserName</Key><Value>ada</Value></String>"
        xml += "<String><Key>Password</Key><Value Protected=\"True\">\(password)</Value></String>"
        for field in fields {
            xml += "<String><Key>\(field.key)</Key><Value\(field.protected ? " Protected=\"True\"" : "")>\(field.value)</Value></String>"
        }
        for binary in binaries {
            xml += "<Binary><Key>\(binary.name)</Key><Value Ref=\"\(binary.ref)\"/></Binary>"
        }
        xml += extra
        if withHistory {
            xml += "<History>" + history.map { $0.xml(withHistory: false) }.joined() + "</History>"
        }
        return xml + "</Entry>"
    }
}

struct MergeGroup {
    var id: Int
    var name: String
    var modified = 0
    var located = 0
    var items: [MergeItem] = []
    var groups: [MergeGroup] = []
    var extra = ""

    init(_ id: Int, _ name: String, modified: Int = 0, located: Int = 0, items: [MergeItem] = [], groups: [MergeGroup] = [], extra: String = "") {
        self.id = id
        self.name = name
        self.modified = modified
        self.located = located
        self.items = items
        self.groups = groups
        self.extra = extra
    }

    var xml: String {
        var xml = "<Group><UUID>\(base64UUID(mergeID(id)))</UUID><Name>\(name)</Name><IconID>48</IconID>"
        xml += "<Times><CreationTime>\(mergeTime(0))</CreationTime><LastModificationTime>\(mergeTime(modified))</LastModificationTime>"
        xml += "<LastAccessTime>\(mergeTime(modified))</LastAccessTime><ExpiryTime>\(mergeTime(0))</ExpiryTime><Expires>False</Expires>"
        xml += "<UsageCount>0</UsageCount><LocationChanged>\(mergeTime(located))</LocationChanged></Times>"
        xml += extra
        xml += items.map { $0.xml() }.joined()
        xml += groups.map(\.xml).joined()
        return xml + "</Group>"
    }
}

/// One copy of the fixture database. The root group is 0x01 and the Recycle Bin 0x02 unless a test says otherwise.
struct MergeCopy {
    var root = MergeGroup(0x01, "Passwords")
    var deleted: [(id: Int, at: Int)] = []
    var customData: [(key: String, value: String, modified: Int?)] = []
    var binaries: [Data] = []
    var recycleBin: Int? = 0x02
    var historyMaxItems = 10
    /// Raw XML inside `Meta`.
    var metaExtra = ""
    /// Raw XML inside `Root`, after the groups.
    var rootExtra = ""

    init(items: [MergeItem] = [], groups: [MergeGroup] = []) {
        root.items = items
        root.groups = groups
    }

    var xml: String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><KeePassFile><Meta><Generator>Fixture</Generator>"
        xml += "<DatabaseName>Fixture</DatabaseName><HistoryMaxItems>\(historyMaxItems)</HistoryMaxItems><HistoryMaxSize>6291456</HistoryMaxSize>"
        if let recycleBin {
            xml += "<RecycleBinEnabled>True</RecycleBinEnabled><RecycleBinUUID>\(base64UUID(mergeID(recycleBin)))</RecycleBinUUID>"
        }
        xml += metaExtra
        if !customData.isEmpty {
            xml += "<CustomData>"
            for item in customData {
                xml += "<Item><Key>\(item.key)</Key><Value>\(escaped(item.value))</Value>"
                if let modified = item.modified { xml += "<LastModificationTime>\(mergeTime(modified))</LastModificationTime>" }
                xml += "</Item>"
            }
            xml += "</CustomData>"
        }
        xml += "</Meta><Root>" + root.xml
        if !deleted.isEmpty {
            xml += "<DeletedObjects>"
            for object in deleted {
                xml += "<DeletedObject><UUID>\(base64UUID(mergeID(object.id)))</UUID><DeletionTime>\(mergeTime(object.at))</DeletionTime></DeletedObject>"
            }
            xml += "</DeletedObjects>"
        }
        return xml + rootExtra + "</Root></KeePassFile>"
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    func data(password: String = "secret") throws -> Data {
        try KDBX.testingDatabase(xml: xml, binaries: binaries, password: password)
    }

    /// The copy as a Mac has it open.
    func vault(password: String = "secret") throws -> Vault {
        let data = try data(password: password)
        var vault = try KDBX.load(data: data, password: password)
        vault.noteFileContents(data)
        return vault
    }
}

/// The Recycle Bin group of the fixtures, holding `items`.
func mergeBin(_ items: [MergeItem] = [], id: Int = 0x02) -> MergeGroup {
    MergeGroup(id, "Recycle Bin", items: items)
}

/// Everything a person or another app could tell two databases apart by, in an order that does not depend on where an
/// item sits in the file: items with their folder, fields, history and attachments, the deleted objects and the custom
/// data. Two merges that give the same lines gave the same database.
func mergeContents(_ vault: Vault, file: StaticString = #filePath, line: UInt = #line) -> [String] {
    var lines: [String] = []
    for entry in vault.entries {
        let fields = entry.fields.map { "\($0.key)=\($0.value)\($0.protected ? "*" : "")" }.joined(separator: ",")
        let history = vault.versions(of: entry.id).map { version in
            "\(version.modified.map { Int($0.timeIntervalSince1970) - 1_780_272_000 } ?? -1):" + version.fields.map(\.value).joined(separator: ",")
        }
        let attachments = vault.attachmentNames(of: entry.id).map { name in
            "\(name)=\(vault.attachment(named: name, of: entry.id).map { String(decoding: $0, as: UTF8.self) } ?? "?")"
        }
        let modified = vault.modified(entry.id).map { Int($0.timeIntervalSince1970) - 1_780_272_000 } ?? -1
        lines.append("item \(entry.id) at \(entry.trashed ? "bin" : entry.groupPath.joined(separator: "/")) modified \(modified) [\(fields)] history \(history) attachments \(attachments)")
    }
    for (key, value) in vault.customData { lines.append("custom \(key)=\(value)") }
    if let root = vault.preserve?.document.rootElement().flatMap({ direct($0, "Root").first }) {
        for object in direct(root, "DeletedObjects").flatMap({ direct($0, "DeletedObject") }) {
            let id = direct(object, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") }
            let at = direct(object, "DeletionTime").first?.stringValue.flatMap(parseTime).map { Int($0.timeIntervalSince1970) - 1_780_272_000 }
            lines.append("deleted \(id?.uuidString ?? "?") at \(at ?? -1)")
        }
    }
    return lines.sorted()
}

extension Vault {
    func item(_ id: Int) -> VaultEntry? {
        entries.first { $0.id == mergeID(id) }
    }

    /// The times of an item's earlier versions, in seconds after the fixtures' zero.
    func historyTimes(_ id: Int) -> [Int] {
        versions(of: mergeID(id)).map { $0.modified.map { Int($0.timeIntervalSince1970) - 1_780_272_000 } ?? -1 }
    }

    func historyPasswords(_ id: Int) -> [String] {
        versions(of: mergeID(id)).map { $0.fields.first { $0.key == "Password" }?.value ?? "" }
    }
}

/// Merges `other` into `base`, and checks on the way that the result is what a save would write and read back.
func merged(_ other: Vault, into base: Vault, file: StaticString = #filePath, line: UInt = #line) throws -> (vault: Vault, report: VaultMergeReport) {
    let outcome = try VaultMerge.merge(other, into: base)
    var saved = outcome.vault
    let data = try KDBX.save(vault: &saved, password: "secret")
    let reloaded = try KDBX.load(data: data, password: "secret")
    XCTAssertEqual(mergeContents(reloaded), mergeContents(outcome.vault), "the merged database reads back differently", file: file, line: line)
    return outcome
}
