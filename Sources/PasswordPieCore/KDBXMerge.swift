import CryptoKit
import Foundation

// Merging two copies of one KDBX database, so the same file can live on several Macs (docs/UX.md, "The same database on
// two Macs"). The rules are those of KeePassXC's `Merger` in its Synchronize mode (src/core/Merger.cpp, 2.7.9), which
// follow KeePass 2's synchronization (keepass.info/help/v2/sync.html: "the last modification time of the object"
// decides, "on entry level", and the change that is not current is "stored as a history entry"):
//
// - Items and groups are the same when their UUIDs are. One only the other copy has is added.
// - The same item in both: the version with the later LastModificationTime becomes current. The other goes into the
//   item's history unless it is already there. The two histories are joined, in time order, without duplicates.
// - An item is where the later LocationChanged says, a group likewise, and a group's own properties follow its
//   LastModificationTime.
// - `DeletedObjects` are joined, the earlier time kept. A listed item is removed unless it changed after that time; a
//   listed group too, unless something is still in it.
//
// Where this differs from KeePassXC, on purpose:
//
// - Nothing depends on which copy is merged into which, so two Macs that each merge the other's copy end with the same
//   content and stop writing. KeePassXC keeps its own version when two differ with the same time; here the choice is
//   by content, and the other version goes into the history.
// - A history item is one version, by its time and content. KeePassXC keys history by time alone and drops one of two
//   different versions with the same time.
// - Moving an item to the Recycle Bin is how PasswordPie deletes. An item changed on the other Mac after that move stays
//   out of the bin, as an item changed after a `DeletedObjects` time stays in the database.
// - The database's custom data is merged key by key and never last-writer-wins as a whole (`KDBXCustomDataMerge.swift`).
//
// Everything is done on the decrypted XML documents. An element no rule names is never rewritten: it stays as the copy
// merged into has it, or comes with the item version it belongs to. Attachments move with their item, into the binary
// pool of the copy merged into, whose existing indexes never change.

/// What merging another copy into a database did. Titles and times, never a value.
public struct VaultMergeReport: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        /// When the version that is current now was last changed.
        public var kept: Date
        /// When the version that went into the history was.
        public var older: Date

        public init(id: UUID, title: String, kept: Date, older: Date) {
            self.id = id
            self.title = title
            self.kept = kept
            self.older = older
        }
    }

    /// Items the database did not have.
    public var added = 0
    /// Items whose current version is now the other copy's.
    public var updated = 0
    /// Items now in the folder the other copy has them in.
    public var moved = 0
    /// Items removed because the other copy lists them as deleted.
    public var removed = 0
    /// Items that had been changed in both copies: the older version is in the item's history.
    public var changedOnBoth: [Item] = []
    /// False when the database already held everything the other copy has: nothing needs to be written.
    public var changed = false

    public init() {}

    /// Adds what a second merge into the same database did.
    public mutating func add(_ other: VaultMergeReport) {
        added += other.added
        updated += other.updated
        moved += other.moved
        removed += other.removed
        for item in other.changedOnBoth where !changedOnBoth.contains(where: { $0.id == item.id }) {
            changedOnBoth.append(item)
        }
        changed = changed || other.changed
    }
}

public struct VaultMergeError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public enum VaultMerge {
    /// Merges `other` into `base` and returns the result; neither argument changes. Both must be KDBX databases this
    /// process read or wrote. The result keeps `base`'s header, keys, settings and the bytes it was read from, so it is
    /// saved as `base` would be. Changes either model holds that are not in its document yet are part of the merge.
    public static func merge(_ other: Vault, into base: Vault) throws -> (vault: Vault, report: VaultMergeReport) {
        let target = try settledDocument(of: base)
        let source = try settledDocument(of: other)
        let before = documentDigest(target)
        let merger = KDBXMerger(target: target, source: source)
        try merger.run()
        var report = merger.report
        report.changed = merger.touched && documentDigest(target) != before
        var merged = target.makeVault(kdf: base.kdf)
        merged.recovery = base.recovery
        merged.recoveryNotice = base.recoveryNotice
        if let baseline = base.fileBaseline { merged.noteFileContents(baseline) }
        return (merged, report)
    }

    /// The vault's document with the model's edits applied, as a save would write it. A copy: the vault's own document
    /// is not touched.
    private static func settledDocument(of vault: Vault) throws -> KDBXPreserve {
        guard let preserve = vault.preserve else {
            throw VaultMergeError("Only a KeePass .kdbx database that has been saved can be merged.")
        }
        var model = vault
        normalizeForXML(&model)
        let copy = try preserve.isolatedCopy()
        try copy.applyEdits(model)
        return copy
    }
}

// MARK: The merge

final class KDBXMerger {
    let target: KDBXPreserve
    let source: KDBXPreserve
    private(set) var report = VaultMergeReport()
    /// True once the target document or its binaries were changed in any way. Whether anything is different in the end
    /// is decided by comparing the document before and after.
    private(set) var touched = false

    private var targetEntries: [UUID: XMLElement] = [:]
    private var targetGroups: [UUID: XMLElement] = [:]
    private let targetPool: BinaryPool
    private let sourcePool: BinaryPool
    private var targetBin: XMLElement?
    private var sourceBin: XMLElement?
    private var targetTop: XMLElement?
    private var deletions: [UUID: Deletion] = [:]
    private var conflicts: [MergeConflictLog.Record] = []
    /// The inner header's pieces as the target had them. Binaries that come with merged items are added after its own.
    private let originalPieces: [InnerPiece]

    private struct Deletion {
        var seconds: Int64
        var element: XMLElement
        var fromSource: Bool
    }

    private struct Version {
        var key: VersionKey
        var element: XMLElement
        var fromSource: Bool
        /// The current version of the item, not one from its history.
        var current = false
    }

    private struct VersionKey: Hashable, Comparable {
        var seconds: Int64
        var digest: String

        static func < (lhs: VersionKey, rhs: VersionKey) -> Bool {
            lhs.seconds != rhs.seconds ? lhs.seconds < rhs.seconds : lhs.digest < rhs.digest
        }
    }

    init(target: KDBXPreserve, source: KDBXPreserve) {
        self.target = target
        self.source = source
        targetPool = BinaryPool(target.pieces)
        sourcePool = BinaryPool(source.pieces)
        originalPieces = target.pieces
    }

    func run() throws {
        guard let targetRoot = rootContainer(target), let top = direct(targetRoot, "Group").first else {
            throw VaultMergeError("The database has no root group, so nothing can be merged into it.")
        }
        targetTop = top
        index(top)
        targetBin = recycleBin(of: target)
        sourceBin = recycleBin(of: source)
        collectDeletions()
        mergeCustomIcons()
        if let sourceRoot = rootContainer(source), let sourceTop = direct(sourceRoot, "Group").first {
            if let id = uuid(of: sourceTop), id == uuid(of: top) {
                resolveGroup(sourceTop, top, location: timeText(top, "LocationChanged"))
            }
            try mergeGroup(sourceTop, into: top)
            // A KDBX file has one root group. More than one is kept as folders of ours.
            for extra in direct(sourceRoot, "Group").dropFirst() {
                try mergeGroup(extra, into: try mappedGroup(extra, under: top))
            }
        }
        applyDeletions(in: targetRoot, top: top)
        mergeCustomData()
    }

    private func index(_ group: XMLElement) {
        if let id = uuid(of: group), targetGroups[id] == nil { targetGroups[id] = group }
        for entry in direct(group, "Entry") {
            if let id = uuid(of: entry), targetEntries[id] == nil { targetEntries[id] = entry }
        }
        for child in direct(group, "Group") { index(child) }
    }

    // MARK: Groups

    private func mergeGroup(_ source: XMLElement, into target: XMLElement) throws {
        for entry in direct(source, "Entry") {
            guard let id = uuid(of: entry) else { continue }
            if let existing = targetEntries[id] {
                try mergeEntry(entry, into: existing, sourceParent: source, targetParent: target)
            } else if let deletion = deletions[id], modified(entry) <= deletion.seconds {
                // Deleted here, and not changed there since.
                continue
            } else if let clone = try cloned(entry) {
                place(entry: clone, in: target)
                targetEntries[id] = clone
                report.added += 1
                touched = true
            }
        }
        for group in direct(source, "Group") {
            try mergeGroup(group, into: try mappedGroup(group, under: target))
        }
    }

    /// The group of ours that `source` is, moved under `parent` when the other copy moved it later. One we do not have
    /// is made, empty; if it was deleted here it is removed again at the end unless something came into it.
    private func mappedGroup(_ source: XMLElement, under parent: XMLElement) throws -> XMLElement {
        let id = uuid(of: source)
        if let id, let existing = targetGroups[id] {
            var location = timeText(existing, "LocationChanged")
            let ours = time(existing, "LocationChanged"), theirs = time(source, "LocationChanged")
            if let current = existing.parent as? XMLElement, current !== parent, existing !== targetTop {
                let take = theirs > ours || (theirs == ours && orderKey(of: parent) > orderKey(of: current))
                // Never into itself or a group inside it.
                if take, !isSelfOrAncestor(existing, of: parent) {
                    existing.detach()
                    parent.addChild(existing)
                    location = timeText(source, "LocationChanged") ?? location
                    touched = true
                }
            } else if theirs > ours {
                // In the same place in both: the later of the two times.
                location = timeText(source, "LocationChanged") ?? location
            }
            if existing !== targetTop { resolveGroup(source, existing, location: location) }
            return existing
        }
        // Each copy made its own Recycle Bin: they are one.
        if source === sourceBin, let targetBin { return targetBin }
        guard let shell = source.copy() as? XMLElement else {
            throw KDBXError.xml("Could not copy a group.")
        }
        for child in shell.children ?? [] {
            if let element = child as? XMLElement, element.name == "Group" || element.name == "Entry" { element.detach() }
        }
        parent.addChild(shell)
        if let id { targetGroups[id] = shell }
        touched = true
        if source === sourceBin {
            targetBin = shell
            adoptRecycleBin(shell)
        }
        return shell
    }

    /// The later LastModificationTime gives the group its name, notes, icon and every other property. Its items and
    /// subgroups are merged one by one, never replaced.
    private func resolveGroup(_ source: XMLElement, _ existing: XMLElement, location: String?) {
        let ours = time(existing, "LastModificationTime"), theirs = time(source, "LastModificationTime")
        var take = theirs > ours
        if theirs == ours {
            let a = digest(of: source, pool: sourcePool, kind: .group), b = digest(of: existing, pool: targetPool, kind: .group)
            take = a != b && a > b
        }
        if take {
            for child in existing.children ?? [] {
                if let element = child as? XMLElement, element.name == "Group" || element.name == "Entry" { continue }
                child.detach()
            }
            var index = 0
            for child in source.children ?? [] {
                guard let element = child as? XMLElement, element.name != "Group", element.name != "Entry",
                      let copy = element.copy() as? XMLElement else { continue }
                existing.insertChild(copy, at: index)
                index += 1
            }
            touched = true
        }
        if let location { setTime("LocationChanged", of: existing, to: location) }
    }

    /// We had no Recycle Bin and the other copy's was just added: it becomes ours.
    private func adoptRecycleBin(_ bin: XMLElement) {
        guard target.recycleBinID() == nil, let id = direct(bin, "UUID").first?.stringValue,
              let file = target.document.rootElement() else { return }
        let meta = direct(file, "Meta").first ?? {
            let created = XMLElement(name: "Meta")
            file.insertChild(created, at: 0)
            return created
        }()
        func set(_ name: String, _ value: String, replacing: Bool) {
            if let existing = direct(meta, name).first {
                if replacing, existing.stringValue != value { existing.stringValue = value }
            } else {
                let element = XMLElement(name: name)
                element.stringValue = value
                meta.addChild(element)
            }
        }
        set("RecycleBinUUID", id, replacing: true)
        set("RecycleBinEnabled", "True", replacing: false)
        if let changed = source.document.rootElement().flatMap({ direct($0, "Meta").first })
            .flatMap({ direct($0, "RecycleBinChanged").first })?.stringValue {
            set("RecycleBinChanged", changed, replacing: true)
        }
    }

    // MARK: Items

    private func mergeEntry(_ source: XMLElement, into existing: XMLElement, sourceParent: XMLElement, targetParent: XMLElement) throws {
        guard let id = uuid(of: existing) else { return }
        let ours = modified(existing), theirs = modified(source)

        // Where it is: the later move wins. Moving to the Recycle Bin is a deletion, and loses against a change made
        // after it in the other copy, as a `DeletedObjects` time does.
        var location = timeText(existing, "LocationChanged")
        var move = false
        let movedHere = time(existing, "LocationChanged"), movedThere = time(source, "LocationChanged")
        if let current = existing.parent as? XMLElement, current !== targetParent {
            let trashedHere = isTrashed(existing, bin: targetBin), trashedThere = isTrashed(source, bin: sourceBin)
            move = movedThere > movedHere || (movedThere == movedHere && orderKey(of: targetParent) > orderKey(of: current))
            if move, trashedThere, !trashedHere, ours > movedThere {
                move = false
            } else if !move, trashedHere, !trashedThere, theirs > movedHere {
                move = true
            }
        } else if movedThere > movedHere {
            // In the same place in both: the later of the two times, so that every copy says the same about it when a
            // third copy that moved it comes along.
            location = timeText(source, "LocationChanged") ?? location
        }

        // Which version is current: the later one. With the same time and different content the choice must not
        // depend on which copy is which, so it is made by content.
        let ourContent = digest(of: existing, pool: targetPool, kind: .content)
        let theirContent = digest(of: source, pool: sourcePool, kind: .content)
        let differs = ourContent != theirContent
        let sourceWins = ours != theirs ? theirs > ours : (differs && theirContent > ourContent)

        // The history: both histories, and the current version that lost unless the winner already has it there.
        let history = direct(existing, "History").first
        let ourVersions = (history.map { direct($0, "Entry") } ?? []).map {
            Version(key: versionKey($0, pool: targetPool), element: $0, fromSource: false)
        }
        let theirVersions = direct(source, "History").flatMap { direct($0, "Entry") }.map {
            Version(key: versionKey($0, pool: sourcePool), element: $0, fromSource: true)
        }
        var known = Set(ourVersions.map(\.key))
        var versions = ourVersions
        for version in theirVersions where known.insert(version.key).inserted { versions.append(version) }
        var changedOnBoth = false
        if differs {
            let loser = sourceWins ? existing : source
            let loserKey = versionKey(loser, pool: sourceWins ? targetPool : sourcePool)
            let winnersHistory = Set((sourceWins ? theirVersions : ourVersions).map(\.key))
            if known.insert(loserKey).inserted {
                versions.append(Version(key: loserKey, element: loser, fromSource: !sourceWins, current: true))
            }
            // In the winner's history already: the winner was made from it, so only one copy changed. Bookkeeping
            // PasswordPie writes without a new version (older passwords) is not a change of the item either.
            if !winnersHistory.contains(loserKey) {
                changedOnBoth = digest(of: existing, pool: targetPool, kind: .reportable)
                    != digest(of: source, pool: sourcePool, kind: .reportable)
            }
        }
        if versions.count > ourVersions.count {
            var elements: [XMLElement] = []
            for version in versions.sorted(by: { $0.key < $1.key }) {
                if !version.fromSource && !version.current {
                    elements.append(version.element)
                    continue
                }
                let copy: XMLElement?
                if version.fromSource {
                    copy = try cloned(version.element)
                } else {
                    copy = version.element.copy() as? XMLElement
                }
                guard let copy else { continue }
                for nested in direct(copy, "History") { nested.detach() }
                elements.append(copy)
            }
            let container = history ?? {
                let created = XMLElement(name: "History")
                existing.addChild(created)
                return created
            }()
            for old in direct(container, "Entry") { old.detach() }
            for element in elements { container.addChild(element) }
            target.trimHistory(container)
            touched = true
        }

        if sourceWins {
            let keep = direct(existing, "History").first
            for child in existing.children ?? [] where child !== keep { child.detach() }
            var index = 0
            for child in source.children ?? [] {
                guard let element = child as? XMLElement, element.name != "History", let copy = try cloned(element) else { continue }
                existing.insertChild(copy, at: index)
                index += 1
            }
            if differs { report.updated += 1 }
            touched = true
        }

        if move {
            existing.detach()
            place(entry: existing, in: targetParent)
            location = timeText(source, "LocationChanged") ?? location
            report.moved += 1
            touched = true
        }
        if let location { setTime("LocationChanged", of: existing, to: location) }

        if changedOnBoth {
            let kept = Date(timeIntervalSince1970: TimeInterval(max(ours, theirs)))
            let older = Date(timeIntervalSince1970: TimeInterval(min(ours, theirs)))
            report.changedOnBoth.append(VaultMergeReport.Item(id: id, title: title(of: existing), kept: kept, older: older))
            conflicts.append(MergeConflictLog.Record(item: id, kept: max(ours, theirs), older: min(ours, theirs)))
        }
    }

    /// After the group's other items and before its subgroups, where KeePass apps write items.
    private func place(entry: XMLElement, in group: XMLElement) {
        let children = group.children ?? []
        if let last = children.lastIndex(where: { ($0 as? XMLElement)?.name == "Entry" }) {
            group.insertChild(entry, at: last + 1)
        } else if let first = children.firstIndex(where: { ($0 as? XMLElement)?.name == "Group" }) {
            group.insertChild(entry, at: first)
        } else {
            group.addChild(entry)
        }
    }

    /// A copy of an element of the other document for ours: every attachment it names points into our binary pool,
    /// which gets the bytes if it does not have them. Nil for an attachment that names bytes the other file lacks.
    private func cloned(_ element: XMLElement) throws -> XMLElement? {
        guard let copy = element.copy() as? XMLElement else {
            throw KDBXError.xml("Could not copy an item.")
        }
        var dangling: [XMLElement] = []
        walkElements(copy) { binary in
            guard binary.name == "Binary" else { return }
            for value in direct(binary, "Value") {
                guard let attribute = value.attribute(forName: "Ref") else { continue }
                guard let index = Int(attribute.stringValue ?? ""), let payload = sourcePool.payload(at: index) else {
                    dangling.append(binary)
                    continue
                }
                attribute.stringValue = String(targetPool.index(holding: payload))
            }
        }
        if targetPool.count != target.binaryPayloads.count {
            // At once, not at the end: the history's size limit counts the attachments its versions name.
            target.pieces = targetPool.pieces(replacingBinariesOf: originalPieces)
            touched = true
        }
        if dangling.contains(where: { $0 === copy }) { return nil }
        for binary in dangling { binary.detach() }
        return copy
    }

    // MARK: Deletions

    private func collectDeletions() {
        for (preserve, fromSource) in [(target, false), (source, true)] {
            guard let root = rootContainer(preserve) else { continue }
            for object in direct(root, "DeletedObjects").flatMap({ direct($0, "DeletedObject") }) {
                guard let id = uuid(of: object) else { continue }
                // A time that cannot be read deletes nothing: everything is later than it.
                let seconds = direct(object, "DeletionTime").first?.stringValue.flatMap(parseTime).map(wholeSeconds) ?? .min
                if let known = deletions[id], known.seconds <= seconds { continue }
                deletions[id] = Deletion(seconds: seconds, element: object, fromSource: fromSource)
            }
        }
    }

    private func applyDeletions(in root: XMLElement, top: XMLElement) {
        var kept: [UUID: Deletion] = [:]
        var groups: [(id: UUID, depth: Int)] = []
        for (id, deletion) in deletions {
            if let entry = targetEntries[id], entry.parent != nil {
                // Changed after it was deleted: it stays, and the deletion is forgotten.
                guard modified(entry) <= deletion.seconds else { continue }
                entry.detach()
                targetEntries[id] = nil
                report.removed += 1
                touched = true
                kept[id] = deletion
            } else if let group = targetGroups[id], group.parent != nil {
                groups.append((id, depth(of: group)))
            } else {
                kept[id] = deletion
            }
        }
        // Subgroups first, so a group emptied by them can go too.
        for (id, _) in groups.sorted(by: { $0.depth != $1.depth ? $0.depth > $1.depth : $0.id.uuidString < $1.id.uuidString }) {
            guard let group = targetGroups[id], let deletion = deletions[id], group !== top else { continue }
            guard time(group, "LastModificationTime") <= deletion.seconds,
                  direct(group, "Entry").isEmpty, direct(group, "Group").isEmpty else { continue }
            group.detach()
            targetGroups[id] = nil
            if group === targetBin { targetBin = nil }
            touched = true
            kept[id] = deletion
        }

        var container = direct(root, "DeletedObjects").first
        var listed = Set<UUID>()
        for object in container.map({ direct($0, "DeletedObject") }) ?? [] {
            guard let id = uuid(of: object) else { continue }
            guard let deletion = kept[id] else {
                object.detach()
                touched = true
                continue
            }
            listed.insert(id)
            // The other copy deleted it earlier.
            if deletion.fromSource, let text = direct(deletion.element, "DeletionTime").first?.stringValue {
                let node = direct(object, "DeletionTime").first ?? {
                    let created = XMLElement(name: "DeletionTime")
                    object.addChild(created)
                    return created
                }()
                if node.stringValue != text {
                    node.stringValue = text
                    touched = true
                }
            }
        }
        let missing = kept.keys.filter { !listed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        guard !missing.isEmpty else { return }
        if container == nil {
            let created = XMLElement(name: "DeletedObjects")
            root.addChild(created)
            container = created
        }
        for id in missing {
            guard let copy = kept[id]?.element.copy() as? XMLElement else { continue }
            container?.addChild(copy)
        }
        touched = true
    }

    // MARK: Database settings

    /// Icons the other copy has and ours lacks, so an item that came with one still shows it.
    private func mergeCustomIcons() {
        guard let theirs = meta(of: source).flatMap({ direct($0, "CustomIcons").first }) else { return }
        let incoming = direct(theirs, "Icon")
        guard !incoming.isEmpty, let file = target.document.rootElement() else { return }
        let ours = meta(of: target).flatMap { direct($0, "CustomIcons").first }
        var have = Set((ours.map { direct($0, "Icon") } ?? []).compactMap { uuid(of: $0) })
        var container = ours
        for icon in incoming {
            // KDBX 4.1 lists a deleted icon in `DeletedObjects`.
            guard let id = uuid(of: icon), !have.contains(id), deletions[id] == nil,
                  let copy = icon.copy() as? XMLElement else { continue }
            if container == nil {
                let meta = direct(file, "Meta").first ?? {
                    let created = XMLElement(name: "Meta")
                    file.insertChild(created, at: 0)
                    return created
                }()
                let created = XMLElement(name: "CustomIcons")
                meta.addChild(created)
                container = created
            }
            container?.addChild(copy)
            have.insert(id)
            touched = true
        }
    }

    private struct CustomItem {
        var element: XMLElement
        var value: String
        var modified: Date?
    }

    private func customItems(of preserve: KDBXPreserve) -> [String: CustomItem] {
        guard let custom = meta(of: preserve).flatMap({ direct($0, "CustomData").first }) else { return [:] }
        var items: [String: CustomItem] = [:]
        for item in direct(custom, "Item") {
            guard let key = direct(item, "Key").first?.stringValue, items[key] == nil else { continue }
            items[key] = CustomItem(
                element: item,
                value: direct(item, "Value").first?.stringValue ?? "",
                modified: direct(item, "LastModificationTime").first?.stringValue.flatMap(parseTime)
            )
        }
        return items
    }

    /// `Meta/CustomData`, key by key. What agents may ask for, standing permissions and the list of items changed in
    /// both copies are merged record by record (`KDBXCustomDataMerge.swift`). Any other key is kept if only one copy has
    /// it; when both do, the later KDBX 4.1 `LastModificationTime` wins, and without one the choice is by value, so it
    /// is the same whichever copy is merged into which.
    private func mergeCustomData() {
        let ours = customItems(of: target), theirs = customItems(of: source)
        for key in Set(ours.keys).union(theirs.keys).union(conflicts.isEmpty ? [] : [MergeConflictLog.customDataKey]).sorted() {
            let (mine, other) = (ours[key], theirs[key])
            switch key {
            case AgentSharingRecord.customDataKey:
                setCustomData(key, to: AgentSharingRecord.merged(mine?.value, other?.value), ours: mine)
            case AgentGrantsRecord.customDataKey:
                setCustomData(key, to: AgentGrantsRecord.merged(mine?.value, other?.value), ours: mine)
            case MergeConflictLog.customDataKey:
                setCustomData(key, to: MergeConflictLog.merged(mine?.value, other?.value, adding: conflicts), ours: mine)
            default:
                guard let other else { continue }
                guard let mine else {
                    addCustomData(other.element)
                    continue
                }
                guard mine.value != other.value else { continue }
                let takeTheirs: Bool
                if let a = mine.modified, let b = other.modified, a != b {
                    takeTheirs = b > a
                } else {
                    takeTheirs = other.value > mine.value
                }
                guard takeTheirs, let copy = other.element.copy() as? XMLElement,
                      let parent = mine.element.parent as? XMLElement else { continue }
                parent.replaceChild(at: mine.element.index, with: copy)
                touched = true
            }
        }
    }

    private func setCustomData(_ key: String, to value: String?, ours: CustomItem?) {
        guard value != ours?.value else { return }
        if let ours {
            if let value, let node = direct(ours.element, "Value").first {
                node.stringValue = value
            } else if let value {
                let node = XMLElement(name: "Value")
                node.stringValue = value
                ours.element.addChild(node)
            } else {
                ours.element.detach()
            }
            touched = true
            return
        }
        guard let value else { return }
        let item = XMLElement(name: "Item")
        let keyNode = XMLElement(name: "Key")
        keyNode.stringValue = key
        let valueNode = XMLElement(name: "Value")
        valueNode.stringValue = value
        item.addChild(keyNode)
        item.addChild(valueNode)
        addCustomData(item)
    }

    private func addCustomData(_ item: XMLElement) {
        guard let file = target.document.rootElement(),
              let copy = item.parent == nil ? item : item.copy() as? XMLElement else { return }
        let meta = direct(file, "Meta").first ?? {
            let created = XMLElement(name: "Meta")
            file.insertChild(created, at: 0)
            return created
        }()
        let custom = direct(meta, "CustomData").first ?? {
            let created = XMLElement(name: "CustomData")
            meta.addChild(created)
            return created
        }()
        custom.addChild(copy)
        touched = true
    }

    // MARK: Reading the documents

    private func rootContainer(_ preserve: KDBXPreserve) -> XMLElement? {
        preserve.document.rootElement().flatMap { direct($0, "Root").first }
    }

    private func meta(of preserve: KDBXPreserve) -> XMLElement? {
        preserve.document.rootElement().flatMap { direct($0, "Meta").first }
    }

    private func uuid(of element: XMLElement) -> UUID? {
        direct(element, "UUID").first.flatMap { uuidFromBase64($0.stringValue ?? "") }
    }

    /// For choosing between two parents when nothing else does: any order that both copies agree on.
    private func orderKey(of group: XMLElement) -> String {
        direct(group, "UUID").first?.stringValue ?? ""
    }

    private func title(of entry: XMLElement) -> String {
        let field = direct(entry, "String").first { direct($0, "Key").first?.stringValue == "Title" }
        return field.flatMap { direct($0, "Value").first }?.stringValue ?? ""
    }

    private func timeText(_ element: XMLElement, _ name: String) -> String? {
        direct(element, "Times").first.flatMap { direct($0, name).first }?.stringValue
    }

    /// Whole seconds, which is all the file holds. A missing or unreadable time is earlier than any other.
    private func time(_ element: XMLElement, _ name: String) -> Int64 {
        timeText(element, name).flatMap(parseTime).map(wholeSeconds) ?? .min
    }

    private func modified(_ entry: XMLElement) -> Int64 {
        time(entry, "LastModificationTime")
    }

    private func setTime(_ name: String, of element: XMLElement, to text: String) {
        guard let times = direct(element, "Times").first else { return }
        if let node = direct(times, name).first {
            guard node.stringValue != text else { return }
            node.stringValue = text
        } else {
            let node = XMLElement(name: name)
            node.stringValue = text
            times.addChild(node)
        }
        touched = true
    }

    private func isSelfOrAncestor(_ group: XMLElement, of other: XMLElement) -> Bool {
        var current: XMLNode? = other
        while let node = current {
            if node === group { return true }
            current = node.parent
        }
        return false
    }

    private func depth(of element: XMLElement) -> Int {
        var count = 0
        var current = element.parent
        while let node = current {
            count += 1
            current = node.parent
        }
        return count
    }

    /// As the app reads it: in the group `Meta/RecycleBinUUID` names, or in one called "Recycle Bin".
    private func recycleBin(of preserve: KDBXPreserve) -> XMLElement? {
        guard let root = rootContainer(preserve) else { return nil }
        var groups: [XMLElement] = []
        var pending = direct(root, "Group")
        while !pending.isEmpty {
            let group = pending.removeFirst()
            groups.append(group)
            pending.append(contentsOf: direct(group, "Group"))
        }
        if let id = preserve.recycleBinID(), let named = groups.first(where: { uuid(of: $0) == id }) { return named }
        return groups.first { isNamedRecycleBin($0) }
    }

    private func isNamedRecycleBin(_ group: XMLElement) -> Bool {
        (direct(group, "Name").first?.stringValue ?? "").caseInsensitiveCompare("Recycle Bin") == .orderedSame
    }

    private func isTrashed(_ entry: XMLElement, bin: XMLElement?) -> Bool {
        var current = entry.parent
        while let group = current as? XMLElement, group.name == "Group" {
            if group === bin || isNamedRecycleBin(group) { return true }
            current = group.parent
        }
        return false
    }

    // MARK: Comparing versions

    private enum DigestKind {
        /// Everything of an item but its history, where it is, and its use counters.
        case content
        /// `content` and the modification time: one version of an item.
        case version
        /// `content` without PasswordPie's own bookkeeping field.
        case reportable
        /// A group's properties, without its items and subgroups.
        case group
    }

    private func versionKey(_ entry: XMLElement, pool: BinaryPool) -> VersionKey {
        VersionKey(seconds: modified(entry), digest: digest(of: entry, pool: pool, kind: .version))
    }

    private func digest(of element: XMLElement, pool: BinaryPool, kind: DigestKind) -> String {
        var canon = Canon()
        for child in element.children ?? [] {
            guard let part = child as? XMLElement else { continue }
            switch part.name ?? "" {
            case "History", "PreviousParentGroup":
                continue
            case "Group", "Entry":
                if kind == .group { continue }
                canon.add(part)
            case "Times":
                canon.line("<Times")
                for time in part.children ?? [] {
                    guard let time = time as? XMLElement, let name = time.name else { continue }
                    if ["LastAccessTime", "UsageCount", "LocationChanged"].contains(name) { continue }
                    if name == "LastModificationTime", kind != .version { continue }
                    let text = time.stringValue ?? ""
                    // The same moment whether the file writes it as seconds or as ISO 8601.
                    canon.line("\(name)=\(parseTime(text).map { String(wholeSeconds($0)) } ?? text)")
                }
                canon.line(">")
            case "String":
                if kind == .reportable, direct(part, "Key").first?.stringValue == PreviousPasswords.key { continue }
                canon.add(part)
            case "Binary":
                canon.line("<Binary")
                canon.line("Key=\(direct(part, "Key").first?.stringValue ?? "")")
                for value in direct(part, "Value") {
                    if let ref = value.attribute(forName: "Ref")?.stringValue {
                        // The bytes, not their place in this file's pool.
                        canon.line("Ref=\(Int(ref).flatMap { pool.key(at: $0) } ?? "missing")")
                    } else {
                        canon.add(value)
                    }
                }
                canon.line(">")
            default:
                canon.add(part)
            }
        }
        return canon.finish()
    }
}

/// Whole seconds since 1970, as a KDBX 4 time holds them.
private func wholeSeconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970.rounded(.down))
}

// MARK: Attachments

/// The binaries of one file's inner header, in order, found by their content.
private final class BinaryPool {
    private var items: [(flags: UInt8, data: Data)] = []
    private var keys: [String] = []
    private var byKey: [String: Int] = [:]
    private var initialCount = 0

    init(_ pieces: [InnerPiece]) {
        for piece in pieces {
            guard case .binary(let flags, let data) = piece else { continue }
            add(flags: flags, data: data)
        }
        initialCount = items.count
    }

    var count: Int { items.count }

    @discardableResult
    private func add(flags: UInt8, data: Data) -> Int {
        var hasher = SHA256()
        hasher.update(data: Data([flags]))
        hasher.update(data: data)
        let key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        items.append((flags, data))
        keys.append(key)
        // Two equal binaries: an item pointing at either reads the same bytes, so the first serves.
        if byKey[key] == nil { byKey[key] = items.count - 1 }
        return items.count - 1
    }

    func key(at index: Int) -> String? {
        keys.indices.contains(index) ? keys[index] : nil
    }

    func payload(at index: Int) -> (flags: UInt8, data: Data)? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// The index of these bytes here, added at the end when this pool does not hold them. Existing indexes never move.
    func index(holding payload: (flags: UInt8, data: Data)) -> Int {
        var hasher = SHA256()
        hasher.update(data: Data([payload.flags]))
        hasher.update(data: payload.data)
        let key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let index = byKey[key] { return index }
        return add(flags: payload.flags, data: payload.data)
    }

    /// The inner header's pieces with the added binaries after the last one it had, every other piece where it was.
    func pieces(replacingBinariesOf pieces: [InnerPiece]) -> [InnerPiece] {
        let added = items[initialCount...].map { InnerPiece.binary(flags: $0.flags, data: $0.data) }
        guard let last = pieces.lastIndex(where: { if case .binary = $0 { return true } else { return false } }) else {
            return added + pieces
        }
        var result = pieces
        result.insert(contentsOf: added, at: last + 1)
        return result
    }
}

// MARK: Canonical form

/// One element as lines that do not depend on attribute order or on white space between elements, hashed.
private struct Canon {
    private var hasher = SHA256()

    mutating func line(_ text: String) {
        let bytes = Data(text.utf8)
        // Length first, so no text can pass for two lines.
        hasher.update(data: Data("\(bytes.count):".utf8))
        hasher.update(data: bytes)
    }

    mutating func add(_ element: XMLElement) {
        let attributes = (element.attributes ?? []).map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.sorted()
        line("<\(element.name ?? "") \(attributes.joined(separator: " "))")
        let children = element.children ?? []
        let hasElements = children.contains { $0.kind == .element }
        for child in children {
            if let nested = child as? XMLElement {
                add(nested)
            } else if child.kind == .comment {
                line("!\(child.stringValue ?? "")")
            } else if child.kind == .text {
                let text = child.stringValue ?? ""
                if text.isEmpty { continue }
                if !hasElements || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { line("=\(text)") }
            }
        }
        line(">")
    }

    mutating func finish() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The whole decrypted document and its binaries: equal before and after a merge that changed nothing.
func documentDigest(_ preserve: KDBXPreserve) -> String {
    var canon = Canon()
    if let root = preserve.document.rootElement() { canon.add(root) }
    for piece in preserve.pieces {
        switch piece {
        case .binary(let flags, let data):
            canon.line("binary \(flags) \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
        case .other(let type, let payload):
            canon.line("piece \(type) \(payload.base64EncodedString())")
        }
    }
    return canon.finish()
}
