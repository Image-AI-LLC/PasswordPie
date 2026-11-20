import Foundation

// Saves an agent proposed (`passwordpie save`), kept in the agents database until the owner saves or rejects them. See
// docs/AGENTS.md, "Saving a secret". In the database's custom data, so a proposal waits through a restart on a Mac
// nobody sits at and comes with the file to the Mac the owner is at; the value stays under the master key, and is not an
// item: nothing lists, searches, fills or hands it out.

/// One save an agent proposed.
public struct AgentProposal: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending
        case saved
        case rejected
    }

    /// Eight hex digits, for the agent and the owner to name it by.
    public var id: String
    public var created: Date
    /// `AgentMacIdentity` of the Mac it was made on.
    public var mac: String
    /// The agent's identity as a grant keeps it (signing team and identifier, or the executable's path), for `status`.
    public var agent: String
    public var agentName: String
    public var signature: String
    public var project: String
    /// The agent's own words, shown as its claim.
    public var reason: String?
    /// "MCP" when it came through the MCP server.
    public var via: String?
    /// The shared item it changes, when one was there. Nil: a new item at `folder` and `title`.
    public var item: UUID?
    public var folder: [String]
    public var title: String
    /// The field as a reference spells it after the item (`["API key"]`, `["attachment", "AuthKey.p8"]`).
    public var field: [String]
    /// What it was when proposed. The owner's list says what it is now.
    public var change: AgentSaveChange
    /// The value, base64, while pending only. Saving or rejecting drops it.
    public var value: String?
    public var state: State
    public var decided: Date?
    /// The item it was saved into.
    public var savedItem: UUID?

    public init(
        id: String, created: Date, mac: String, agent: String, agentName: String, signature: String, project: String,
        reason: String?, via: String?, item: UUID?, folder: [String], title: String, field: AgentField, change: AgentSaveChange,
        value: Data
    ) {
        self.id = id
        self.created = created
        self.mac = mac
        self.agent = agent
        self.agentName = agentName
        self.signature = signature
        self.project = project
        self.reason = reason
        self.via = via
        self.item = item
        self.folder = folder
        self.title = title
        self.field = field.referenceSuffix
        self.change = change
        self.value = value.base64EncodedString()
        state = .pending
    }

    public var fieldValue: AgentField {
        if field.count == 2, field[0] == "attachment" { return .attachment(field[1]) }
        return AgentField(name: field.first ?? "password")
    }

    public var bytes: Data? { value.flatMap { Data(base64Encoded: $0) } }

    /// Where it goes, as a reference: `pp://Agents/Stripe/API key`.
    public var ref: String {
        AgentReference.path(folder: folder, title: title, field: fieldValue == .password ? nil : fieldValue)
    }

    /// For the activity log: "Agents/Stripe › field API key".
    public var logLabel: String {
        let place = folder.isEmpty ? title : folder.joined(separator: "/") + "/" + title
        return "\(place) › \(fieldValue.label)"
    }

    /// The proposal as answered: no value from now on.
    public func answered(_ state: State, at time: Date, item: UUID? = nil) -> AgentProposal {
        var copy = self
        copy.state = state
        copy.decided = time
        copy.value = nil
        copy.savedItem = item
        return copy
    }

    /// Eight hex digits that `taken` does not hold.
    public static func newID(avoiding taken: Set<String>) -> String {
        while true {
            let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            if !taken.contains(id) { return id }
        }
    }
}

/// Every proposal of one database, as kept in its custom data under `customDataKey`.
public struct AgentProposals: Equatable, Sendable {
    public static let customDataKey = "PasswordPie.AgentProposals"
    /// A proposal older than this counts as gone, answered or not, and is dropped on the next write.
    public static let lifetime: TimeInterval = 30 * 86_400
    /// At most this many wait at once.
    public static let maxPending = 20

    public private(set) var all: [AgentProposal] = []

    public init(_ proposals: [AgentProposal] = []) {
        all = proposals
    }

    private struct Stored: Codable {
        var version: Int
        var proposals: [AgentProposal]
    }

    /// What `customData` holds; nothing when it holds nothing readable.
    public init(customData: [String: String]) {
        guard let text = customData[Self.customDataKey], let stored = try? Self.decoder.decode(Stored.self, from: Data(text.utf8)) else { return }
        all = stored.proposals
    }

    /// Writes these into `customData`, or removes the key when there is nothing to keep.
    public func write(into customData: inout [String: String]) {
        guard !all.isEmpty, let data = try? Self.encoder.encode(Stored(version: 1, proposals: all.sorted { $0.id < $1.id })) else {
            customData[Self.customDataKey] = nil
            return
        }
        customData[Self.customDataKey] = String(decoding: data, as: UTF8.self)
    }

    /// The ones still kept at `now`: younger than `lifetime`.
    public func current(now: Date) -> [AgentProposal] {
        all.filter { now.timeIntervalSince($0.created) < Self.lifetime }.sorted { $0.created < $1.created }
    }

    public func pending(now: Date) -> [AgentProposal] {
        current(now: now).filter { $0.state == .pending }
    }

    public mutating func add(_ proposal: AgentProposal) {
        all.removeAll { $0.id == proposal.id }
        all.append(proposal)
    }

    public mutating func replace(_ proposal: AgentProposal) {
        guard let index = all.firstIndex(where: { $0.id == proposal.id }) else { return }
        all[index] = proposal
    }

    /// Drops what is past its lifetime, with its value.
    public mutating func forgetEnded(now: Date) {
        all = current(now: now)
    }

    // Times as seconds since 1970, which the core library's merge reads without this library.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// How a save the owner answered went, when the item is written.
public enum AgentSaveResult: Equatable, Sendable {
    /// Written into this item, which `change` describes.
    case saved(item: UUID, change: AgentSaveChange)
    /// Nothing written, and why, for the owner: the item is gone, no longer shared, or the place is two items now.
    case failed(String)
}

/// How keeping a new proposal went.
public enum AgentProposeResult: Equatable, Sendable {
    case kept
    /// `AgentProposals.maxPending` already wait: nothing was kept.
    case full
    /// The agents database could not be written.
    case notWritten
}

/// Where proposals are kept and how a saved one is written. The app's keeps them in the agents database (`AgentSaves`).
@MainActor
public protocol AgentSaveStore: AnyObject {
    /// The proposals in the agents database, without those past their lifetime, oldest first; nil while it is not open.
    var proposals: [AgentProposal]? { get }
    /// Keeps a new proposal in the agents database and writes the file, unless `AgentProposals.maxPending` already wait
    /// when it is written.
    func propose(_ proposal: AgentProposal) async -> AgentProposeResult
    /// The owner saved it: writes the value into the item and marks the proposal saved, in one write.
    func save(_ id: String) async -> AgentSaveResult
    /// The owner rejected it: marks it rejected, without its value. False when it could not be written.
    func reject(_ id: String) async -> Bool
}
