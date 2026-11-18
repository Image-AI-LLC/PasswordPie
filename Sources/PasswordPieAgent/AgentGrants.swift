import Foundation

// Standing permissions ("do not ask me every time", Premium). A grant covers a later request only when the items and
// fields, the delivery, the agent, the project, the program and this Mac all match, and its time has not run out. Grants
// are kept in the database's custom data (Decided 2), never in the app's preferences, so `defaults write` cannot add one.
// Only the approval window, after Touch ID, creates one. See docs/AGENTS.md, "Standing permissions".

/// How long a standing permission lasts. 30 days is the most.
public enum AgentGrantLength: String, Codable, CaseIterable, Sendable {
    /// Until the agent process ends, and at most 12 hours.
    case session
    case hours8 = "8h"
    case days7 = "7d"
    case days30 = "30d"

    public var seconds: TimeInterval {
        switch self {
        case .session: return 12 * 3600
        case .hours8: return 8 * 3600
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        }
    }

    /// "this agent session", "8 hours", "7 days", "30 days".
    public var label: String {
        switch self {
        case .session: return "this agent session"
        case .hours8: return "8 hours"
        case .days7: return "7 days"
        case .days30: return "30 days"
        }
    }

    /// The menu's words: "This agent session", "8 hours".
    public var menuTitle: String {
        self == .session ? "This agent session" : label
    }

    /// Preselected the first time.
    public static let `default` = AgentGrantLength.days7
}

/// What the approval window may offer beside Allow Once.
public enum AgentLastingChoice: Equatable, Sendable {
    /// Not offered at all: a raw read, or a request that is not a run.
    case notOffered
    /// Shown greyed, with why (inline code, an unknown launcher…).
    case unavailable(String)
    case offered
    /// Only "this agent session": no agent was found in the processes that started the tool, so a longer one could
    /// not be bound to one (it would cover whatever else ends up with no agent in its chain).
    case sessionOnly
}

/// One secret a grant covers: which item and field, and how it is handed over.
public struct AgentGrantSecret: Codable, Equatable, Hashable, Sendable {
    public var item: UUID
    /// The field as a reference spells it after the item: ["password"], ["Key ID"], ["attachment", "AuthKey.p8"].
    public var field: [String]
    public var delivery: AgentDelivery
    public var name: String?

    public init(item: UUID, field: [String], delivery: AgentDelivery, name: String?) {
        self.item = item
        self.field = field
        self.delivery = delivery
        self.name = name
    }

    public init(_ secret: AgentResolvedSecret) {
        self.init(item: secret.item.id, field: secret.field.referenceSuffix, delivery: secret.delivery, name: secret.name)
    }
}

public struct AgentGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// This Mac's identifier (`AgentMacIdentity`): the same database opened on another Mac does not use it.
    public var mac: String
    public var created: Date
    public var ends: Date
    public var length: AgentGrantLength
    /// For "this agent session": the agent session it belongs to (`AgentCaller.sessionKey`).
    public var session: String?
    /// `run` (`use`), or `login`.
    public var kind: AgentRequestKind
    /// The agent program's identity (`AgentProcess.identity`), or "none" with no agent in the chain.
    public var agent: String
    public var agentName: String
    public var project: String
    public var program: AgentProgramBinding?
    public var secrets: [AgentGrantSecret]
    /// "Developer/Token › password", for the Agents pane. Names, never values.
    public var labels: [String]
    /// `login`: the site ("github.com"). A login grant is bound to the item, this site and the agent, in any project.
    public var site: String?

    public init(
        id: UUID = UUID(), mac: String, created: Date, length: AgentGrantLength, session: String?, kind: AgentRequestKind, agent: String,
        agentName: String, project: String, program: AgentProgramBinding?, secrets: [AgentGrantSecret], labels: [String],
        site: String? = nil
    ) {
        self.id = id
        self.mac = mac
        self.created = created
        ends = created.addingTimeInterval(length.seconds)
        self.length = length
        self.session = session
        self.kind = kind
        self.agent = agent
        self.agentName = agentName
        self.project = project
        self.program = program
        self.secrets = secrets
        self.labels = labels
        self.site = site
    }

    /// "7 days, this project": Activity's "allowed by …" and the tool's `status`.
    public var description: String {
        kind == .login ? "\(length.label), \(site ?? "this site")" : "\(length.label), this project"
    }

    public func isInForce(at now: Date) -> Bool { now < ends }
}

/// The agent a grant is bound to: its signing identity, or with no agent in the chain, "none".
public extension AgentCaller {
    var grantIdentity: String { agent?.identity ?? "none" }
}

/// Every grant of one database, as kept in its custom data under `customDataKey`.
public struct AgentGrants: Equatable, Sendable {
    public static let customDataKey = "PasswordPie.AgentGrants"

    public private(set) var all: [AgentGrant] = []

    public init(_ grants: [AgentGrant] = []) {
        all = grants
    }

    /// What `customData` holds; nothing when it holds nothing readable.
    public init(customData: [String: String]) {
        guard let text = customData[Self.customDataKey],
              let stored = try? Self.decoder.decode(Stored.self, from: Data(text.utf8)) else { return }
        all = stored.grants
    }

    public var isEmpty: Bool { all.isEmpty }

    /// Writes these into `customData`, or removes the key when there are none.
    public func write(into customData: inout [String: String]) {
        guard !all.isEmpty else {
            customData[Self.customDataKey] = nil
            return
        }
        let data = (try? Self.encoder.encode(Stored(version: 1, grants: all))) ?? Data()
        customData[Self.customDataKey] = String(decoding: data, as: UTF8.self)
    }

    public mutating func add(_ grant: AgentGrant) {
        all.append(grant)
    }

    public mutating func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
    }

    public mutating func removeAll(where predicate: (AgentGrant) -> Bool) {
        all.removeAll(where: predicate)
    }

    /// The grants that count on this Mac now: this Mac's, not ended, and a session grant only while its agent session
    /// runs (`sessionAlive`).
    public func inForce(mac: String, now: Date, sessionAlive: (String) -> Bool) -> [AgentGrant] {
        all.filter { grant in
            grant.mac == mac && grant.isInForce(at: now) && (grant.session.map(sessionAlive) ?? true)
        }
    }

    /// The grant among `grants` that covers every secret of `query` bound to `program`, if one does.
    public static func covering(_ query: AgentGrantQuery, program: AgentProgramBinding?, in grants: [AgentGrant]) -> AgentGrant? {
        guard !query.raw, !query.secrets.isEmpty else { return nil }
        let asked = Set(query.secrets.map(AgentGrantSecret.init))
        return grants.first { grant in
            guard grant.kind == query.kind, grant.agent == query.caller.grantIdentity,
                  grant.session == nil || grant.session == query.caller.sessionKey,
                  asked.isSubset(of: Set(grant.secrets)) else { return false }
            if query.kind == .login {
                // The item, the site and the agent: a login runs no command, and the same browser serves every project.
                guard let site = query.site else { return false }
                return grant.site == site
            }
            return grant.project == query.caller.project && grant.program?.key == program?.key
        }
    }

    /// The grants for this agent in this project.
    public static func applying(to caller: AgentCaller, in grants: [AgentGrant]) -> [AgentGrant] {
        grants.filter { grant in
            grant.agent == caller.grantIdentity && (grant.kind == .login || grant.project == caller.project)
                && (grant.session == nil || grant.session == caller.sessionKey)
        }
    }

    private struct Stored: Codable {
        var version: Int
        var grants: [AgentGrant]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// Whether the agent session a session grant belongs to still runs: its key names a process by pid and start time.
public enum AgentSessionLiveness {
    public static func isAlive(_ sessionKey: String, facts: ProcessFacts = LiveProcessFacts.shared) -> Bool {
        let parts = sessionKey.split(separator: ":")
        guard parts.count == 3, let pid = Int32(parts[1]), let start = UInt64(parts[2]) else { return false }
        return facts.info(pid)?.startTime == start
    }
}
