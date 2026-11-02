import Foundation

/// One inner-header field kept across a save, in its original order.
/// Stream id, stream key, and the end marker are not included: a save writes a fresh id and key.
enum InnerPiece: Equatable, Sendable {
    /// KDBX 4 binary. `flags` is the leading byte (KeePassXC writes `0x01`); `data` is the raw file bytes.
    case binary(flags: UInt8, data: Data)
    case other(type: UInt8, payload: Data)
}

struct HeaderField: Equatable, Sendable {
    var type: UInt8
    var payload: Data
}

/// `.nodePreserveAll` minus entity and character-reference preservation. With those two on, XMLDocument
/// keeps a raw copy of text that mixes `&amp;` and `&#13;`, and writes it back unescaped and partly repeated.
let kdbxXMLOptions: XMLNode.Options = XMLNode.Options.nodePreserveAll
    .subtracting([.nodePreserveEntities, .nodePreserveCharacterReferences])
    .union(.nodeLoadExternalEntitiesNever)

/// Plaintext KeePass XML plus the header and binary pool needed to write the same file back.
/// Protected values stay decrypted here. A save encrypts a copy so the next edit cannot encrypt twice.
final class KDBXPreserve: @unchecked Sendable {
    let document: XMLDocument
    var pieces: [InnerPiece]
    var version: UInt32
    var headerFields: [HeaderField]
    var compressed: Bool
    /// Byte range of the KDF salt inside the type-11 header payload. The salt is replaced in place.
    var kdfSaltRange: Range<Int>

    init(
        document: XMLDocument,
        pieces: [InnerPiece],
        version: UInt32,
        headerFields: [HeaderField],
        compressed: Bool,
        kdfSaltRange: Range<Int>
    ) {
        self.document = document
        self.pieces = pieces
        self.version = version
        self.headerFields = headerFields
        self.compressed = compressed
        self.kdfSaltRange = kdfSaltRange
    }

    var binaryPayloads: [Data] {
        pieces.compactMap { piece in
            if case .binary(_, let data) = piece { return data }
            return nil
        }
    }

    /// A document the caller can edit without changing this one. Header bytes are values, so they are copied too.
    func isolatedCopy() throws -> KDBXPreserve {
        guard let copied = document.copy() as? XMLDocument else {
            throw KDBXError.xml("Could not copy the database XML.")
        }
        return KDBXPreserve(
            document: copied,
            pieces: pieces,
            version: version,
            headerFields: headerFields,
            compressed: compressed,
            kdfSaltRange: kdfSaltRange
        )
    }

    func makeVault(kdf: KDFParameters) -> Vault {
        let walked = walkDatabase()
        var vault = Vault(name: walked.databaseName, rootName: walked.rootName, entries: walked.entries.map(\.model), kdf: kdf)
        vault.preserve = self
        return vault
    }

    /// Updates only entries the model changed. Every other element is left alone.
    func applyEdits(_ vault: Vault) throws {
        let walked = walkDatabase()
        let fallbackTime = firstTimeText(named: "LastModificationTime")
        var consumed = Set<ObjectIdentifier>()
        for model in vault.entries {
            if let live = walked.entries.first(where: { $0.id == model.id && !consumed.contains(ObjectIdentifier($0.element)) }) {
                consumed.insert(ObjectIdentifier(live.element))
                try update(live, to: model, timeSample: fallbackTime, rootName: walked.rootName)
            } else {
                let created = newEntry(model, timeSample: fallbackTime)
                let parent = try targetGroup(for: model, fallbackName: walked.rootName)
                parent.addChild(created)
            }
        }
        for live in walked.entries where !consumed.contains(ObjectIdentifier(live.element)) {
            // Already in the recycle bin: leaving it out of the model is not a permanent delete.
            if live.location.trashed { continue }
            try rememberPreviousVersion(of: live.element)
            setTime(named: "LastModificationTime", in: live.element, sample: fallbackTime)
            setTime(named: "LocationChanged", in: live.element, sample: fallbackTime)
            let bin = try ensureRecycleBin(fallbackName: walked.rootName)
            move(live.element, to: bin)
        }
    }

    func encryptedXML(streamKey: Data) throws -> Data {
        guard let copy = document.copy() as? XMLDocument else {
            throw KDBXError.xml("Could not copy the database XML.")
        }
        try cryptProtectedValues(in: copy, streamKey: streamKey, encrypting: true)
        return escapingCarriageReturns(copy.xmlData(options: kdbxXMLOptions))
    }

    // MARK: Recovery report

    /// Finds the fields a repair changed and any that still look wrong, including history. Holds no values.
    func locateRecovery(changedTexts: Set<String>, uncertainTexts: Set<String>, into recovery: inout KDBXRecovery) {
        guard let root = document.rootElement() else { return }
        var located = Set<String>()
        var found = recovery
        func visitEntry(_ entry: XMLElement, inHistory: Bool) {
            let strings = direct(entry, "String")
            let titleValue = strings.first { direct($0, "Key").first?.stringValue == "Title" }.flatMap { direct($0, "Value").first }
            let title = isInnerProtected(titleValue) ? "(protected title)" : titleValue?.stringValue ?? ""
            for string in strings {
                guard let value = direct(string, "Value").first else { continue }
                let text = value.stringValue ?? ""
                let location = KDBXRecovery.Location(
                    entryTitle: title,
                    fieldKey: direct(string, "Key").first?.stringValue ?? "",
                    inHistory: inHistory
                )
                if isInnerProtected(value) {
                    if text.unicodeScalars.contains("\u{FFFD}") {
                        found.unreadableProtectedFields.append(location)
                    }
                } else if uncertainTexts.contains(text) {
                    found.uncertainFields.append(location)
                    located.insert(text)
                } else if changedTexts.contains(text) {
                    found.repairedFields.append(location)
                    located.insert(text)
                } else if text.range(of: "&(#[0-9]+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);", options: .regularExpression) != nil {
                    found.suspectFields.append(location)
                }
            }
            for history in direct(entry, "History") {
                for old in direct(history, "Entry") {
                    visitEntry(old, inHistory: true)
                }
            }
        }
        walkElements(root) { element in
            guard element.name == "Group" else { return }
            for entry in direct(element, "Entry") {
                visitEntry(entry, inHistory: false)
            }
        }
        found.otherRepairedTexts = changedTexts.subtracting(located).count
        recovery = found
    }

    // MARK: Walking

    private struct LiveEntry {
        var element: XMLElement
        var id: UUID
        var location: EntryLocation
        var fields: [VaultField]
        var tags: String

        var model: VaultEntry {
            VaultEntry(id: id, groupPath: location.groupPath, trashed: location.trashed, tags: tags, fields: fields)
        }
    }

    private struct EntryLocation: Equatable {
        var groupPath: [String]
        var trashed: Bool
    }

    private struct GroupFrame {
        var name: String
        var trashed: Bool
    }

    private struct Walk {
        var databaseName: String
        var rootName: String
        var entries: [LiveEntry]
    }

    private func walkDatabase() -> Walk {
        guard let file = document.rootElement() else {
            return Walk(databaseName: "PasswordPie", rootName: "PasswordPie", entries: [])
        }
        var databaseName = "PasswordPie"
        if let meta = direct(file, "Meta").first, let name = direct(meta, "DatabaseName").first {
            databaseName = name.stringValue ?? ""
        }
        let recycleID = recycleBinID()
        var rootName = "PasswordPie"
        var seenRootName = false
        var entries: [LiveEntry] = []
        guard let root = direct(file, "Root").first else {
            return Walk(databaseName: databaseName, rootName: rootName, entries: [])
        }
        // Document order. rootName is the first group Name, including an empty one, and is known
        // before that group's entries are recorded.
        func visit(_ group: XMLElement, ancestors: [GroupFrame]) {
            let nameNode = direct(group, "Name").first
            let name = nameNode?.stringValue ?? ""
            if !seenRootName, nameNode != nil {
                rootName = name
                seenRootName = true
            }
            let uuid = direct(group, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") }
            var trashed = ancestors.last?.trashed ?? false
            if name.caseInsensitiveCompare("Recycle Bin") == .orderedSame || (uuid != nil && uuid == recycleID) {
                trashed = true
            }
            let frames = ancestors + [GroupFrame(name: name, trashed: trashed)]
            for child in group.children ?? [] {
                guard let element = child as? XMLElement else { continue }
                if element.name == "Group" {
                    visit(element, ancestors: frames)
                } else if element.name == "Entry" {
                    entries.append(readEntry(element, frames: frames, rootName: rootName))
                }
            }
        }
        for group in direct(root, "Group") {
            visit(group, ancestors: [])
        }
        return Walk(databaseName: databaseName, rootName: rootName, entries: entries)
    }

    private func readEntry(_ element: XMLElement, frames: [GroupFrame], rootName: String) -> LiveEntry {
        let id: UUID
        if let existing = direct(element, "UUID").first, let parsed = uuidFromBase64(existing.stringValue ?? "") {
            id = parsed
        } else {
            id = UUID()
            let node = direct(element, "UUID").first ?? {
                let created = leaf("UUID", "")
                element.insertChild(created, at: 0)
                return created
            }()
            node.stringValue = base64UUID(id)
        }
        let tags = direct(element, "Tags").first?.stringValue ?? ""
        let fields = direct(element, "String").map { stringElement in
            let key = direct(stringElement, "Key").first?.stringValue ?? ""
            let valueElement = direct(stringElement, "Value").first
            return VaultField(
                key: key,
                value: valueElement?.stringValue ?? "",
                protected: isInnerProtected(valueElement)
            )
        }
        return LiveEntry(
            element: element,
            id: id,
            location: location(of: frames, rootName: rootName),
            fields: fields,
            tags: tags
        )
    }

    /// Same path rules as the previous reader: drop the database root and any "Recycle Bin" segment.
    private func location(of frames: [GroupFrame], rootName: String) -> EntryLocation {
        let trashed = frames.last?.trashed ?? false
        if frames.count <= 1 {
            return EntryLocation(groupPath: [], trashed: trashed)
        }
        var path = frames.map(\.name).filter { !$0.isEmpty && $0.caseInsensitiveCompare("Recycle Bin") != .orderedSame }
        if path.first == rootName {
            path.removeFirst()
        }
        return EntryLocation(groupPath: path, trashed: trashed)
    }

    // MARK: Entry edits

    private func update(_ live: LiveEntry, to model: VaultEntry, timeSample: String?, rootName: String) throws {
        let fieldsDiffer = live.fields != model.fields
        let tagsDiffer = live.tags != model.tags
        let moved = moved(live.location, toward: model)
        guard fieldsDiffer || tagsDiffer || moved else { return }
        try rememberPreviousVersion(of: live.element)
        if fieldsDiffer {
            try applyFields(model.fields, to: live.element)
        }
        if tagsDiffer {
            applyTags(model.tags, to: live.element)
        }
        setTime(named: "LastModificationTime", in: live.element, sample: timeSample)
        if moved {
            setTime(named: "LocationChanged", in: live.element, sample: timeSample)
            let parent = try targetGroup(for: model, fallbackName: rootName)
            move(live.element, to: parent)
        }
    }

    /// An entry already in the bin stays there even if the model still carries its old folder.
    private func moved(_ location: EntryLocation, toward model: VaultEntry) -> Bool {
        if model.trashed && location.trashed { return false }
        if model.trashed != location.trashed { return true }
        return model.groupPath != location.groupPath
    }

    private func applyFields(_ fields: [VaultField], to entry: XMLElement) throws {
        let strings = direct(entry, "String")
        var used = Set<ObjectIdentifier>()
        for field in fields where !field.key.isEmpty {
            let match = strings.first { element in
                guard !used.contains(ObjectIdentifier(element)) else { return false }
                return direct(element, "Key").first?.stringValue == field.key
            }
            let stringElement: XMLElement
            if let match {
                used.insert(ObjectIdentifier(match))
                stringElement = match
            } else {
                stringElement = XMLElement(name: "String")
                stringElement.addChild(leaf("Key", field.key))
                stringElement.addChild(XMLElement(name: "Value"))
                insert(stringElement, into: entry, before: ["Binary", "AutoType", "CustomData", "History"])
            }
            let value = valueNode(in: stringElement)
            if (value.stringValue ?? "") != field.value {
                value.stringValue = field.value
            }
            try setProtected(field.protected, on: value)
        }
        for field in fields where field.key.isEmpty {
            guard let match = strings.first(where: { element in
                guard !used.contains(ObjectIdentifier(element)) else { return false }
                return (direct(element, "Key").first?.stringValue ?? "").isEmpty
            }) else { continue }
            used.insert(ObjectIdentifier(match))
            let value = valueNode(in: match)
            if (value.stringValue ?? "") != field.value {
                value.stringValue = field.value
            }
            try setProtected(field.protected, on: value)
        }
        for element in strings where !used.contains(ObjectIdentifier(element)) {
            element.detach()
        }
    }

    private func applyTags(_ tags: String, to entry: XMLElement) {
        if let existing = direct(entry, "Tags").first {
            if (existing.stringValue ?? "") != tags {
                existing.stringValue = tags
            }
            return
        }
        guard !tags.isEmpty else { return }
        insert(leaf("Tags", tags), into: entry, before: ["Times", "String", "Binary", "AutoType", "CustomData", "History"])
    }

    private func newEntry(_ model: VaultEntry, timeSample: String?) -> XMLElement {
        let entry = XMLElement(name: "Entry")
        entry.addChild(leaf("UUID", base64UUID(model.id)))
        entry.addChild(leaf("IconID", "0"))
        if !model.tags.isEmpty {
            entry.addChild(leaf("Tags", model.tags))
        }
        entry.addChild(timesElement(sample: timeSample))
        for field in model.fields where !field.key.isEmpty {
            let stringElement = XMLElement(name: "String")
            stringElement.addChild(leaf("Key", field.key))
            let value = XMLElement(name: "Value")
            value.stringValue = field.value
            if field.protected, let attribute = XMLNode.attribute(withName: "Protected", stringValue: "True") as? XMLNode {
                value.addAttribute(attribute)
            }
            stringElement.addChild(value)
            entry.addChild(stringElement)
        }
        entry.addChild(XMLElement(name: "History"))
        return entry
    }

    private func move(_ entry: XMLElement, to parent: XMLElement) {
        if entry.parent === parent { return }
        entry.detach()
        parent.addChild(entry)
    }

    // MARK: History

    /// KeePassXC drops the oldest items down to HistoryMaxItems, then drops the item that crosses HistoryMaxSize and everything older.
    private func rememberPreviousVersion(of entry: XMLElement) throws {
        guard let clone = entry.copy() as? XMLElement else {
            throw KDBXError.xml("Could not copy an entry into its history.")
        }
        for history in direct(clone, "History") {
            history.detach()
        }
        let history = direct(entry, "History").first ?? {
            let created = XMLElement(name: "History")
            entry.addChild(created)
            return created
        }()
        history.addChild(clone)
        trimHistory(history)
    }

    private func trimHistory(_ history: XMLElement) {
        let limits = historyLimits()
        var items = direct(history, "Entry")
        if limits.items >= 0, items.count > limits.items {
            for item in items.prefix(items.count - limits.items) {
                item.detach()
            }
            items = direct(history, "Entry")
        }
        guard limits.bytes >= 0 else { return }
        var total = 0
        var keepFrom = 0
        var overflow = false
        for index in stride(from: items.count - 1, through: 0, by: -1) {
            let size = entrySize(items[index])
            if total + size > limits.bytes {
                keepFrom = index + 1
                overflow = true
                break
            }
            total += size
        }
        guard overflow else { return }
        for item in items.prefix(keepFrom) {
            item.detach()
        }
    }

    private func historyLimits() -> (items: Int, bytes: Int) {
        let meta = document.rootElement().flatMap { direct($0, "Meta").first }
        func integer(_ name: String, default fallback: Int) -> Int {
            guard let meta, let text = direct(meta, name).first?.stringValue else { return fallback }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed) else { return fallback }
            return value < -1 ? fallback : value
        }
        return (integer("HistoryMaxItems", default: 10), integer("HistoryMaxSize", default: 6 * 1024 * 1024))
    }

    /// Byte count KeePassXC uses for HistoryMaxSize: strings (including missing default keys), autotype, custom data, tags, and raw attachments.
    private func entrySize(_ entry: XMLElement) -> Int {
        var size = 0
        var seenKeys = Set<String>()
        for stringElement in direct(entry, "String") {
            let key = direct(stringElement, "Key").first?.stringValue ?? ""
            let value = direct(stringElement, "Value").first?.stringValue ?? ""
            size += key.utf8.count + value.utf8.count
            seenKeys.insert(key)
        }
        for key in ["Title", "UserName", "Password", "URL", "Notes"] where !seenKeys.contains(key) {
            size += key.utf8.count
        }
        if let autoType = direct(entry, "AutoType").first {
            for association in direct(autoType, "Association") {
                let window = direct(association, "Window").first?.stringValue ?? ""
                let sequence = direct(association, "KeystrokeSequence").first?.stringValue
                    ?? direct(association, "Sequence").first?.stringValue
                    ?? ""
                size += window.utf8.count + sequence.utf8.count
            }
        }
        if let custom = direct(entry, "CustomData").first {
            for item in direct(custom, "Item") {
                let key = direct(item, "Key").first?.stringValue ?? ""
                let value = direct(item, "Value").first?.stringValue ?? ""
                size += key.utf8.count + value.utf8.count
            }
        }
        if let tags = direct(entry, "Tags").first?.stringValue {
            var seen = Set<String>()
            for raw in tags.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" }) {
                let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
                size += tag.utf8.count
            }
        }
        let payloads = binaryPayloads
        for binary in direct(entry, "Binary") {
            let key = direct(binary, "Key").first?.stringValue ?? ""
            size += key.utf8.count
            guard let value = direct(binary, "Value").first else { continue }
            if let ref = value.attribute(forName: "Ref")?.stringValue, let index = Int(ref), payloads.indices.contains(index) {
                size += payloads[index].count
            } else if !isInnerProtected(value) {
                let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { continue }
                let compressed = value.attribute(forName: "Compressed")?.stringValue?.lowercased() == "true"
                if compressed, let raw = try? gzipDecompress(data) {
                    size += raw.count
                } else {
                    size += data.count
                }
            }
        }
        return size
    }

    // MARK: Groups

    private func targetGroup(for model: VaultEntry, fallbackName: String) throws -> XMLElement {
        if model.trashed {
            return try ensureRecycleBin(fallbackName: fallbackName)
        }
        return try group(at: model.groupPath, fallbackName: fallbackName)
    }

    private func group(at path: [String], fallbackName: String) throws -> XMLElement {
        var current = try firstRootGroup(fallbackName: fallbackName)
        for component in path {
            if let child = direct(current, "Group").first(where: { groupName($0) == component && !isRecycleGroup($0) }) {
                current = child
                continue
            }
            let created = makeGroup(named: component)
            current.addChild(created)
            current = created
        }
        return current
    }

    private func firstRootGroup(fallbackName: String) throws -> XMLElement {
        let root = try rootContainer()
        if let existing = direct(root, "Group").first {
            return existing
        }
        let name = fallbackName.isEmpty ? "PasswordPie" : fallbackName
        let created = makeGroup(named: name)
        root.addChild(created)
        return created
    }

    private func ensureRecycleBin(fallbackName: String) throws -> XMLElement {
        if let id = recycleBinID(), let found = findGroup(uuid: id) {
            return found
        }
        if let named = allGroups().first(where: { groupName($0).caseInsensitiveCompare("Recycle Bin") == .orderedSame }) {
            if let id = direct(named, "UUID").first.flatMap({ uuidFromBase64($0.stringValue ?? "") }), !isNilUUID(id) {
                try setMeta("RecycleBinUUID", base64UUID(id), replacing: false)
            }
            try setMeta("RecycleBinEnabled", "True", replacing: false)
            return named
        }
        let parent = try firstRootGroup(fallbackName: fallbackName)
        let bin = makeGroup(named: "Recycle Bin")
        parent.addChild(bin)
        let id = direct(bin, "UUID").first?.stringValue ?? base64UUID(UUID())
        try setMeta("RecycleBinUUID", id, replacing: true)
        try setMeta("RecycleBinEnabled", "True", replacing: false)
        let sample = firstTimeText(named: "LastModificationTime")
        try setMeta("RecycleBinChanged", formatTime(Date(), like: sample), replacing: true)
        return bin
    }

    private func makeGroup(named name: String) -> XMLElement {
        let group = XMLElement(name: "Group")
        group.addChild(leaf("UUID", base64UUID(UUID())))
        group.addChild(leaf("Name", name))
        group.addChild(leaf("IconID", "48"))
        group.addChild(timesElement(sample: firstTimeText(named: "LastModificationTime")))
        return group
    }

    private func findGroup(uuid: UUID) -> XMLElement? {
        allGroups().first { element in
            direct(element, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") } == uuid
        }
    }

    private func allGroups() -> [XMLElement] {
        guard let root = document.rootElement().flatMap({ direct($0, "Root").first }) else { return [] }
        var found: [XMLElement] = []
        var pending = direct(root, "Group")
        while !pending.isEmpty {
            let group = pending.removeFirst()
            found.append(group)
            pending.append(contentsOf: direct(group, "Group"))
        }
        return found
    }

    private func isRecycleGroup(_ group: XMLElement) -> Bool {
        if groupName(group).caseInsensitiveCompare("Recycle Bin") == .orderedSame { return true }
        guard let id = recycleBinID() else { return false }
        return direct(group, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") } == id
    }

    private func groupName(_ group: XMLElement) -> String {
        direct(group, "Name").first?.stringValue ?? ""
    }

    private func recycleBinID() -> UUID? {
        guard let file = document.rootElement(), let meta = direct(file, "Meta").first else { return nil }
        guard let text = direct(meta, "RecycleBinUUID").first?.stringValue, let id = uuidFromBase64(text), !isNilUUID(id) else {
            return nil
        }
        return id
    }

    /// `replacing` false leaves an existing element, including an explicit RecycleBinEnabled of False.
    private func setMeta(_ name: String, _ value: String, replacing: Bool) throws {
        guard let file = document.rootElement() else { throw KDBXError.xml("The database XML has no root.") }
        let meta: XMLElement
        if let existing = direct(file, "Meta").first {
            meta = existing
        } else {
            meta = XMLElement(name: "Meta")
            if let root = direct(file, "Root").first, let children = file.children, let index = children.firstIndex(where: { $0 === root }) {
                file.insertChild(meta, at: index)
            } else {
                file.addChild(meta)
            }
        }
        if let existing = direct(meta, name).first {
            if !replacing { return }
            if (existing.stringValue ?? "") != value {
                existing.stringValue = value
            }
            return
        }
        meta.addChild(leaf(name, value))
    }

    private func rootContainer() throws -> XMLElement {
        guard let file = document.rootElement(), let root = direct(file, "Root").first else {
            throw KDBXError.xml("The database XML has no root.")
        }
        return root
    }

    // MARK: Times

    private func setTime(named name: String, in entry: XMLElement, sample fallback: String?) {
        let times = direct(entry, "Times").first ?? {
            let created = XMLElement(name: "Times")
            insert(created, into: entry, before: ["History"])
            return created
        }()
        let node = direct(times, name).first ?? {
            let created = XMLElement(name: name)
            times.addChild(created)
            return created
        }()
        let existing = node.stringValue ?? ""
        let formatted = formatTime(Date(), like: existing.isEmpty ? fallback : existing)
        if (node.stringValue ?? "") != formatted {
            node.stringValue = formatted
        }
    }

    private func timesElement(sample: String?) -> XMLElement {
        let now = formatTime(Date(), like: sample)
        let times = XMLElement(name: "Times")
        for name in ["CreationTime", "LastModificationTime", "LastAccessTime", "ExpiryTime"] {
            times.addChild(leaf(name, now))
        }
        times.addChild(leaf("Expires", "False"))
        times.addChild(leaf("UsageCount", "0"))
        times.addChild(leaf("LocationChanged", now))
        return times
    }

    private func firstTimeText(named name: String) -> String? {
        guard let root = document.rootElement() else { return nil }
        var found: String?
        walkElements(root) { element in
            guard found == nil, element.name == name, let text = element.stringValue, !text.isEmpty else { return }
            found = text
        }
        return found
    }

    // MARK: XML helpers

    private func valueNode(in stringElement: XMLElement) -> XMLElement {
        if let value = direct(stringElement, "Value").first { return value }
        let value = XMLElement(name: "Value")
        stringElement.addChild(value)
        return value
    }

    private func setProtected(_ protected: Bool, on value: XMLElement) throws {
        if isInnerProtected(value) == protected { return }
        if let attribute = protectedAttribute(value) {
            if protected {
                attribute.stringValue = "True"
            } else if let name = attribute.name {
                value.removeAttribute(forName: name)
            }
            return
        }
        guard protected else { return }
        guard let attribute = XMLNode.attribute(withName: "Protected", stringValue: "True") as? XMLNode else {
            throw KDBXError.xml("Could not mark a value protected.")
        }
        value.addAttribute(attribute)
    }

    private func insert(_ child: XMLElement, into parent: XMLElement, before names: [String]) {
        if let children = parent.children {
            if let index = children.firstIndex(where: { node in
                guard let element = node as? XMLElement else { return false }
                return names.contains(element.name ?? "")
            }) {
                parent.insertChild(child, at: index)
                return
            }
        }
        parent.addChild(child)
    }

    private func leaf(_ name: String, _ value: String) -> XMLElement {
        let element = XMLElement(name: name)
        element.stringValue = value
        return element
    }
}

// MARK: Protected stream

/// Decrypts every non-empty `Protected="True"` value in document order, including history.
/// An empty protected value does not advance the stream, matching KeePassXC.
func decryptProtectedValues(in document: XMLDocument, streamKey: Data) throws {
    try cryptProtectedValues(in: document, streamKey: streamKey, encrypting: false)
}

func cryptProtectedValues(in document: XMLDocument, streamKey: Data, encrypting: Bool) throws {
    guard let root = document.rootElement() else { return }
    let parts = sha512SplitKey(protectedStreamKey: streamKey)
    var stream = ChaCha20(key: parts.key, nonce: parts.nonce, counter: 0)
    var failure: Error?
    walkElements(root) { element in
        guard failure == nil, element.name == "Value", isInnerProtected(element) else { return }
        let text = element.stringValue ?? ""
        if encrypting {
            guard !text.isEmpty else { return }
            element.stringValue = stream.xor(Data(text.utf8)).base64EncodedString()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let decoded = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            failure = KDBXError.xml("A protected value is not valid base64.")
            return
        }
        element.stringValue = String(decoding: stream.xor(decoded), as: UTF8.self)
    }
    if let failure { throw failure }
}

func parseKDBXDocument(_ data: Data) throws -> XMLDocument {
    let document: XMLDocument
    do {
        document = try XMLDocument(data: data, options: kdbxXMLOptions)
    } catch {
        throw KDBXError.xml(error.localizedDescription)
    }
    try requireTextOnlyValues(in: document)
    return document
}

/// The old writer could turn `&lt;b&gt;` in a note into a real element. A nested `Value Protected="True"` would then
/// shift the decryption stream for every later password, so such a document is damage even though it parses.
private func requireTextOnlyValues(in document: XMLDocument) throws {
    guard let root = document.rootElement() else { return }
    var damaged = false
    walkElements(root) { element in
        guard !damaged, element.name == "String" else { return }
        for value in direct(element, "Value") where value.children?.contains(where: { $0.kind == .element }) == true {
            damaged = true
        }
    }
    if damaged {
        throw KDBXError.xml("A field value contains XML elements.")
    }
}

func parseKDBXDocument(xml: String) throws -> XMLDocument {
    do {
        return try XMLDocument(xmlString: xml, options: kdbxXMLOptions)
    } catch {
        throw KDBXError.xml(error.localizedDescription)
    }
}

func isInnerProtected(_ element: XMLElement?) -> Bool {
    guard let element, let value = protectedAttribute(element)?.stringValue else { return false }
    return value.caseInsensitiveCompare("true") == .orderedSame
}

private func protectedAttribute(_ element: XMLElement) -> XMLNode? {
    for attribute in element.attributes ?? [] {
        if attribute.name?.caseInsensitiveCompare("Protected") == .orderedSame {
            return attribute
        }
    }
    return nil
}

func direct(_ element: XMLElement, _ name: String) -> [XMLElement] {
    (element.children ?? []).compactMap { node in
        guard let child = node as? XMLElement, child.name == name else { return nil }
        return child
    }
}

func walkElements(_ element: XMLElement, _ body: (XMLElement) -> Void) {
    body(element)
    for child in element.children ?? [] {
        guard let element = child as? XMLElement else { continue }
        walkElements(element, body)
    }
}

private func isNilUUID(_ id: UUID) -> Bool {
    id.uuidString == "00000000-0000-0000-0000-000000000000"
}

/// KeePass epoch is 0001-01-01 UTC. ISO is used only when the file already writes ISO timestamps.
func formatTime(_ date: Date, like sample: String?) -> String {
    if let sample, sample.contains("-") || sample.contains(":") {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    let seconds = Int64(date.timeIntervalSince1970.rounded()) + 62_135_596_800
    var value = UInt64(bitPattern: seconds)
    var data = Data(count: 8)
    for index in 0..<8 {
        data[index] = UInt8(truncatingIfNeeded: value)
        value >>= 8
    }
    return data.base64EncodedString()
}
