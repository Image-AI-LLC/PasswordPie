import Foundation

public struct VaultAttachment: Equatable, Sendable {
    public var name: String
    public var data: Data
    /// What happens when the entry already holds another file under this name. False, for what an import of the entry
    /// itself hands over: this one takes its place (the version before stays in the entry's history). True, for a file
    /// that came with another account folded into this one: the entry's own file stays, and this one is added beside it
    /// under a free name.
    public var keepsHeld: Bool

    public init(name: String, data: Data, keepsHeld: Bool = false) {
        self.name = name
        self.data = data
        self.keepsHeld = keepsHeld
    }
}

public struct VaultField: Equatable, Sendable {
    public var key: String
    public var value: String
    public var protected: Bool

    public init(key: String, value: String, protected: Bool = false) {
        self.key = key
        self.value = value
        self.protected = protected
    }
}

public struct VaultEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var groupPath: [String]
    public var trashed: Bool
    public var tags: String
    public var fields: [VaultField]
    /// Attachments on their way into the file: what an import read, to be added to this entry by the next save, or to
    /// replace the attachment of the same name. A save empties this, and an entry read from a KDBX file has none here:
    /// what the file holds is read from it by name (`Vault.attachment(named:of:)`), and is never removed by a save.
    public var attachments: [VaultAttachment]

    public init(
        id: UUID = UUID(),
        groupPath: [String] = [],
        trashed: Bool = false,
        tags: String = "",
        fields: [VaultField] = [],
        attachments: [VaultAttachment] = []
    ) {
        self.id = id
        self.groupPath = groupPath
        self.trashed = trashed
        self.tags = tags
        self.fields = fields
        self.attachments = attachments
    }

    public var title: String {
        get { value(for: "Title") }
        set { setValue(newValue, for: "Title") }
    }

    public var username: String {
        get { value(for: "UserName") }
        set { setValue(newValue, for: "UserName") }
    }

    public var password: String {
        get { value(for: "Password") }
        set { setValue(newValue, for: "Password", protected: true) }
    }

    public var url: String {
        get { value(for: "URL") }
        set { setValue(newValue, for: "URL") }
    }

    public var notes: String {
        get { value(for: "Notes") }
        set { setValue(newValue, for: "Notes") }
    }

    public var otp: String {
        get { value(for: "otp") }
        set { setValue(newValue, for: "otp", protected: true) }
    }

    public var favorite: Bool {
        get {
            tagList.contains { $0.caseInsensitiveCompare("Favorite") == .orderedSame }
        }
        set {
            var tags = tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }
            if newValue {
                tags.append("Favorite")
            }
            self.tags = tags.joined(separator: ",")
        }
    }

    public var tagList: [String] {
        tags.split { $0 == "," || $0 == ";" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func value(for key: String) -> String {
        fields.first { $0.key == key }?.value ?? ""
    }

    public mutating func setValue(_ value: String, for key: String, protected: Bool? = nil) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].value = value
            if let protected {
                fields[index].protected = protected
            }
        } else if !value.isEmpty || protected == true {
            fields.append(VaultField(key: key, value: value, protected: protected ?? false))
        }
    }
}

/// One earlier version of an entry, from its history in the file.
public struct VaultEntryVersion: Equatable, Sendable, Identifiable {
    /// Its place in the history, 0 for the oldest.
    public var id: Int
    /// When this version was last changed. It was the current one from then until the next version's time.
    public var modified: Date?
    public var fields: [VaultField]
    public var tags: String

    public init(id: Int, modified: Date?, fields: [VaultField], tags: String) {
        self.id = id
        self.modified = modified
        self.fields = fields
        self.tags = tags
    }
}

public struct Vault: Equatable, Sendable {
    public var name: String
    public var rootName: String
    public var entries: [VaultEntry]
    public var kdf: KDFParameters
    /// The database's custom data (`Meta/CustomData`): settings that belong to the file, such as what is shared with agents.
    public var customData: [String: String] = [:]
    /// Decrypted KDBX document for a file this process opened or created. Nil until the first save of a new database.
    var preserve: KDBXPreserve?
    /// Set when this document was read by repairing damaged XML and the file on disk is still damaged.
    public var recovery: KDBXRecovery?
    /// One line for the person when opening the file repaired it or could not.
    public var recoveryNotice: String?
    /// The bytes last read from or written to this file. A background write is refused if the file no longer holds them.
    public private(set) var fileBaseline: Data?

    public init(
        name: String = "PasswordPie",
        rootName: String = "PasswordPie",
        entries: [VaultEntry] = [],
        kdf: KDFParameters = .default
    ) {
        self.name = name
        self.rootName = rootName
        self.entries = entries
        self.kdf = kdf
        self.preserve = nil
    }

    /// When each entry's current password was set, as far as the file can tell. Entries in the recycle bin are left out.
    public func passwordDates() -> [UUID: Date] {
        preserve?.passwordDates() ?? [:]
    }

    /// The names of an entry's attachments, as the file holds them. Empty for a database not read from a KDBX file.
    public func attachmentNames(of id: UUID) -> [String] {
        preserve?.attachments(of: id).map(\.name) ?? []
    }

    /// The attachment names of the live entries in `ids` (every entry when nil), read in one pass without decoding.
    public func attachmentNames(of ids: Set<UUID>? = nil) -> [UUID: [String]] {
        preserve?.attachmentNames(of: ids) ?? [:]
    }

    /// One attachment's bytes.
    public func attachment(named name: String, of id: UUID) -> Data? {
        preserve?.attachments(of: id).first { $0.name == name }?.data
    }

    /// The earlier versions of an entry that the file keeps in its history, oldest first. Empty for a database not read
    /// from a KDBX file.
    public func versions(of id: UUID) -> [VaultEntryVersion] {
        preserve?.versions(of: id) ?? []
    }

    /// When the current version of an entry was last changed, as the file says.
    public func modified(_ id: UUID) -> Date? {
        preserve?.modified(id)
    }

    /// The UUID of the database's root group, which every copy of one database shares: a file with another root group
    /// is another database, not a copy of this one. Nil for a database not read from a KDBX file.
    public var rootGroupID: UUID? {
        preserve?.rootGroupID()
    }

    /// Records what the file holds after a read or a write.
    public mutating func noteFileContents(_ data: Data) {
        fileBaseline = data
    }

    public static func == (lhs: Vault, rhs: Vault) -> Bool {
        lhs.name == rhs.name && lhs.rootName == rhs.rootName && lhs.entries == rhs.entries && lhs.kdf == rhs.kdf
            && lhs.customData == rhs.customData
    }
}

public enum KDFKind: Equatable, Sendable {
    case aes(rounds: UInt64)
    case argon2id(memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32, version: UInt32)
    case argon2d(memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32, version: UInt32)
}

public struct KDFParameters: Equatable, Sendable {
    public var kind: KDFKind

    public init(kind: KDFKind) {
        self.kind = kind
    }

    /// Argon2id, 64 MiB, 3 passes, 2 lanes: what a new database gets. KeePassXC-compatible, and about 0.1 s to unlock on
    /// an M2. An existing database keeps the parameters in its own header; saving never changes them.
    public static let `default` = KDFParameters(
        kind: .argon2id(memoryKiB: 64 * 1024, iterations: 3, parallelism: 2, version: 0x13)
    )

    public static let fastTest = KDFParameters(kind: .aes(rounds: 100))
}

public enum KDBXError: Error, Equatable, CustomStringConvertible {
    case truncated
    case notKDBX
    case unsupported(String)
    case wrongPassword
    case crypto(String)
    case xml(String)

    public var description: String {
        switch self {
        case .truncated: return "The database file is truncated."
        case .notKDBX: return "This is not a KDBX file."
        case .unsupported(let message): return message
        case .wrongPassword: return "Wrong password."
        case .crypto(let message): return message
        case .xml(let message): return message
        }
    }
}
