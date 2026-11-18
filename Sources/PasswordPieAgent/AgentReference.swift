import Foundation

/// Which part of an item a reference names.
public enum AgentField: Equatable, Hashable, Sendable {
    case password
    case username
    case url
    case notes
    /// The current two-step code. Not offered to agents yet.
    case otp
    /// A custom field, by its exact (case-sensitive) name.
    case custom(String)
    case attachment(String)

    /// From the last part of a reference: `password`, `username`, `url`, `notes`, `otp`, or a custom field's name.
    public init(name: String) {
        switch name {
        case "password": self = .password
        case "username": self = .username
        case "url": self = .url
        case "notes": self = .notes
        case "otp": self = .otp
        default: self = .custom(name)
        }
    }

    /// The KeePass key of a string field.
    public var keePassKey: String? {
        switch self {
        case .password: return "Password"
        case .username: return "UserName"
        case .url: return "URL"
        case .notes: return "Notes"
        case .otp: return "otp"
        case .custom(let name): return name
        case .attachment: return nil
        }
    }

    /// How the reference spells it, after the item.
    public var referenceSuffix: [String] {
        switch self {
        case .password: return ["password"]
        case .username: return ["username"]
        case .url: return ["url"]
        case .notes: return ["notes"]
        case .otp: return ["otp"]
        case .custom(let name): return [name]
        case .attachment(let name): return ["attachment", name]
        }
    }

    /// For the prompt and the activity log: "password", "field Key ID", "attachment AuthKey.p8".
    public var label: String {
        switch self {
        case .password, .username, .url, .notes, .otp: return referenceSuffix[0]
        case .custom(let name): return "field \(name)"
        case .attachment(let name): return "attachment \(name)"
        }
    }
}

/// `pp://<folder path>/<item title>[/<field>]` or `pp://id/<item UUID>[/<field>]`. See docs/AGENTS.md, "References".
/// A path reference can be read more than one way (is the last part a field, or the title?), so it keeps every reading
/// and the resolver tries them all against the shared items.
public struct AgentReference: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        public var folder: [String]
        public var title: String
        public var field: AgentField
    }

    public enum Target: Equatable, Sendable {
        case id(UUID, AgentField)
        case path([Reading])
    }

    public static let scheme = "pp://"

    public let text: String
    public let target: Target

    public enum ParseError: Error, Equatable {
        case notAReference
        case empty
        case badEncoding
    }

    public init(_ text: String) throws {
        self.text = text
        guard text.hasPrefix(Self.scheme) else { throw ParseError.notAReference }
        let body = String(text.dropFirst(Self.scheme.count))
        guard !body.isEmpty else { throw ParseError.empty }
        let raw = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var segments: [String] = []
        for part in raw {
            guard !part.isEmpty else { throw ParseError.empty }
            guard let decoded = part.removingPercentEncoding else { throw ParseError.badEncoding }
            segments.append(decoded)
        }
        if segments.count >= 2, segments[0] == "id", let uuid = UUID(uuidString: segments[1]) {
            let rest = Array(segments.dropFirst(2))
            switch rest.count {
            case 0: target = .id(uuid, .password)
            case 1: target = .id(uuid, AgentField(name: rest[0]))
            case 2 where rest[0] == "attachment": target = .id(uuid, .attachment(rest[1]))
            default: throw ParseError.empty
            }
            return
        }
        var readings = [Reading(folder: Array(segments.dropLast()), title: segments[segments.count - 1], field: .password)]
        if segments.count >= 2 {
            readings.append(Reading(folder: Array(segments.dropLast(2)), title: segments[segments.count - 2], field: AgentField(name: segments[segments.count - 1])))
        }
        if segments.count >= 3, segments[segments.count - 2] == "attachment" {
            readings.append(Reading(folder: Array(segments.dropLast(3)), title: segments[segments.count - 3], field: .attachment(segments[segments.count - 1])))
        }
        target = .path(readings)
    }

    /// Percent-encodes what a reference cannot hold as is: `/`, `%` and control characters. Spaces stay.
    public static func encode(_ segment: String) -> String {
        var out = ""
        for scalar in segment.unicodeScalars {
            if scalar == "/" || scalar == "%" || scalar.properties.generalCategory == .control {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func path(folder: [String], title: String, field: AgentField? = nil) -> String {
        let parts = folder + [title] + (field?.referenceSuffix ?? [])
        return scheme + parts.map(encode).joined(separator: "/")
    }

    public static func id(_ id: UUID, field: AgentField? = nil) -> String {
        scheme + (["id", id.uuidString] + (field?.referenceSuffix ?? []).map(encode)).joined(separator: "/")
    }
}

/// A shared item as an agent may see it: where it is and what it holds, never a value.
public struct AgentItem: Equatable, Sendable {
    /// The item's KeePass UUID.
    public var id: UUID
    /// The database file it is in. References do not name a database; with several open, all are searched.
    public var database: String
    public var folder: [String]
    public var title: String
    /// The custom fields' names (not Title, UserName, Password, URL, Notes, or PasswordPie's own bookkeeping).
    public var fields: [String]
    public var attachments: [String]

    public init(id: UUID, database: String, folder: [String], title: String, fields: [String], attachments: [String]) {
        self.id = id
        self.database = database
        self.folder = folder
        self.title = title
        self.fields = fields
        self.attachments = attachments
    }

    public func has(_ field: AgentField) -> Bool {
        switch field {
        case .password, .username, .url, .notes: return true
        case .otp: return false
        case .custom(let name): return fields.contains(name)
        case .attachment(let name): return attachments.contains(name)
        }
    }

    public var folderText: String { folder.joined(separator: "/") }

    public func listed(covered: Bool) -> AgentListedItem {
        AgentListedItem(
            ref: AgentReference.path(folder: folder, title: title),
            idRef: AgentReference.id(id),
            title: title,
            folder: folderText,
            fields: fields,
            attachments: attachments,
            covered: covered
        )
    }
}

public enum AgentResolution: Equatable, Sendable {
    case found(AgentItem, AgentField)
    /// Not shared, or no such item or field: one answer for both.
    case notAvailable
    /// The `pp://id/` references of the shared items that match.
    case ambiguous([String])
}

public enum AgentResolver {
    /// Resolves against shared items only, so nothing about an unshared item can be learned from the answer.
    public static func resolve(_ reference: AgentReference, in shared: [AgentItem]) -> AgentResolution {
        var matches: [(AgentItem, AgentField)] = []
        switch reference.target {
        case .id(let id, let field):
            matches = shared.filter { $0.id == id && $0.has(field) }.map { ($0, field) }
        case .path(let readings):
            for reading in readings {
                for item in shared where item.folder == reading.folder && item.title == reading.title && item.has(reading.field) {
                    if !matches.contains(where: { $0.0 == item && $0.1 == reading.field }) {
                        matches.append((item, reading.field))
                    }
                }
            }
        }
        switch matches.count {
        case 0: return .notAvailable
        case 1: return .found(matches[0].0, matches[0].1)
        default: return .ambiguous(matches.map { AgentReference.id($0.0.id, field: $0.1 == .password ? nil : $0.1) })
        }
    }

    /// The shared items whose title, folder, field or attachment names contain `query`, ignoring case. All of them for
    /// an empty query.
    public static func search(_ query: String?, in shared: [AgentItem]) -> [AgentItem] {
        let needle = (query ?? "").trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return shared }
        return shared.filter { item in
            ([item.title, item.folderText] + item.fields + item.attachments).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
}
