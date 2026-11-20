import CryptoKit
import Foundation
import IOKit

/// The broker's grant store: standing permissions kept in the open database's custom data. The app hands it how to read
/// and change that custom data, and its own Premium check; nothing in a request says anything about Premium. See
/// docs/AGENTS.md, "Standing permissions".
@MainActor
public final class StandingPermissions: AgentGrantStore {
    /// This Mac's identifier. A grant made on another Mac does not count here.
    public let mac: String
    public var clock: () -> Date = Date.init
    /// The app's own `appHasPremium()`. Without it no grant is made, and none is used.
    public var hasPremium: () -> Bool
    /// Whether the agent session a "this agent session" grant belongs to still runs.
    public var sessionAlive: (String) -> Bool = { AgentSessionLiveness.isAlive($0) }
    /// Agent access was turned off at this time: "this agent session" grants made before it have ended.
    public var sessionsEndedAt: Date?
    /// The grants changed (made, revoked): the Agents pane reads them again.
    public var onChange: (() -> Void)?

    /// The grants in the agents database, or nil while it is not open.
    private let read: () -> AgentGrants?
    /// Changes them in that database and writes the file, then says whether it was written. The app's memory keeps what
    /// the file holds until then, so what this store did meanwhile is kept here.
    private let write: (@escaping (inout AgentGrants) -> Void, @escaping (Bool) -> Void) -> Void
    /// Made and not written yet.
    private var pending: [AgentGrant] = []
    /// Revoked in this run of the app: never used again, whether or not the file was written.
    private var revoked: Set<UUID> = []
    private var revokedAllAt: Date?
    /// What each request's command was bound to when its window opened, by `AgentGrantQuery.id`: a lasting choice
    /// records that, and only if the files are still the same.
    private var offered: [UUID: AgentProgramBinding] = [:]
    /// Agent access was turned off while locked: the session grants are removed from the file at the next unlock.
    private var endSessionsAtUnlock = false

    public init(
        mac: String = AgentMacIdentity.current, hasPremium: @escaping () -> Bool, read: @escaping () -> AgentGrants?,
        write: @escaping (@escaping (inout AgentGrants) -> Void, @escaping (Bool) -> Void) -> Void
    ) {
        self.mac = mac
        self.hasPremium = hasPremium
        self.read = read
        self.write = write
    }

    /// The grants that count on this Mac now, Premium or not, for the Agents pane. Empty while locked.
    public var inForce: [AgentGrant] {
        guard var grants = read() else { return [] }
        for grant in pending where !grants.all.contains(where: { $0.id == grant.id }) { grants.add(grant) }
        let now = clock()
        return grants.inForce(mac: mac, now: now, sessionAlive: sessionAlive).filter { grant in
            if revoked.contains(grant.id) { return false }
            if let revokedAllAt, grant.created <= revokedAllAt { return false }
            if grant.session != nil, let ended = sessionsEndedAt, grant.created <= ended { return false }
            return true
        }
    }

    /// What a run's command is bound to, or why it asks every time.
    public func program(for query: AgentGrantQuery) -> AgentProgramVerdict {
        AgentProgramRule.bind(
            program: query.program, argv: query.argv, cwd: query.caller.cwd, project: query.caller.project,
            environment: query.caller.codeLoadingVariables, added: query.added
        )
    }

    // MARK: AgentGrantStore

    public func grant(covering query: AgentGrantQuery) -> String? {
        guard !query.raw, query.kind == .use || query.kind == .login, hasPremium() else { return nil }
        let grants = inForce
        if query.kind == .login { return AgentGrants.covering(query, program: nil, in: grants)?.description }
        guard !grants.isEmpty, case .bound(let binding) = program(for: query) else { return nil }
        return AgentGrants.covering(query, program: binding, in: grants)?.description
    }

    public func grants(for caller: AgentCaller) -> [String] {
        guard hasPremium() else { return [] }
        return AgentGrants.applying(to: caller, in: inForce).map { "\($0.description): \($0.program?.display ?? "login") (\($0.labels.joined(separator: ", ")))" }
    }

    public func covers(_ item: AgentItem, for caller: AgentCaller) -> Bool {
        guard hasPremium() else { return false }
        // `list` says whether running with the item would ask; a login grant does not cover that.
        return AgentGrants.applying(to: caller, in: inForce).contains { $0.kind == .use && $0.secrets.contains { $0.item == item.id } }
    }

    public func lastingChoice(for query: AgentGrantQuery) -> AgentLastingChoice {
        guard !query.raw else { return .notOffered }
        if query.kind == .login, query.site != nil { return query.caller.agent == nil ? .sessionOnly : .offered }
        guard query.kind == .use else { return .notOffered }
        switch program(for: query) {
        case .asksEveryTime(let why):
            return .unavailable(why)
        case .bound(let binding):
            if offered.count > 64 { offered.removeAll() }
            offered[query.id] = binding
            return query.caller.agent == nil ? .sessionOnly : .offered
        }
    }

    @discardableResult
    public func approved(_ query: AgentGrantQuery, decision: AgentApprovalDecision) -> String? {
        let shown = offered.removeValue(forKey: query.id)
        if query.kind == .login { return approvedLogin(query, decision: decision) }
        guard case .allowLasting(let selected, let length) = decision, !query.raw, query.kind == .use, hasPremium(),
              length == .session || query.caller.agent != nil,
              // What the owner saw when the window opened, and the files are still the same now.
              let shown, case .bound(let binding) = program(for: query), binding.key == shown.key else { return nil }
        let chosen = query.secrets.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        guard !chosen.isEmpty else { return nil }
        let grant = AgentGrant(
            mac: mac, created: clock(), length: length, session: length == .session ? query.caller.sessionKey : nil, kind: query.kind,
            agent: query.caller.grantIdentity, agentName: query.caller.agentName, project: query.caller.project, program: binding,
            secrets: chosen.map(AgentGrantSecret.init), labels: chosen.map(\.logLabel)
        )
        pending.append(grant)
        change({ $0.add(grant) }) { [weak self] _ in self?.pending.removeAll { $0.id == grant.id } }
        return grant.description
    }

    /// A login grant: the item the owner picked, its site, this agent; no program and no project to bind.
    private func approvedLogin(_ query: AgentGrantQuery, decision: AgentApprovalDecision) -> String? {
        guard case .allowLasting(let selected, let length) = decision, !query.raw, hasPremium(), let site = query.site,
              length == .session || query.caller.agent != nil else { return nil }
        let chosen = query.secrets.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        guard chosen.count == 1 else { return nil }
        let grant = AgentGrant(
            mac: mac, created: clock(), length: length, session: length == .session ? query.caller.sessionKey : nil, kind: .login,
            agent: query.caller.grantIdentity, agentName: query.caller.agentName, project: query.caller.project, program: nil,
            secrets: chosen.map(AgentGrantSecret.init), labels: chosen.map { "\($0.item.folder.isEmpty ? $0.item.title : $0.item.folderText + "/" + $0.item.title) › login" },
            site: site
        )
        pending.append(grant)
        change({ $0.add(grant) }) { [weak self] _ in self?.pending.removeAll { $0.id == grant.id } }
        return grant.description
    }

    // MARK: Revoking

    /// Counts at once, also before the file is written.
    public func revoke(_ id: UUID) {
        revoked.insert(id)
        pending.removeAll { $0.id == id }
        change { $0.remove(id) }
    }

    /// Every grant in the database, this Mac's and other Macs'.
    public func revokeAll() {
        revokedAllAt = clock()
        pending.removeAll()
        change { $0.removeAll { _ in true } }
    }

    /// Agent access was turned off: every "this agent session" grant ends. The others stay and do nothing while it is off.
    public func endSessions() {
        sessionsEndedAt = clock()
        pending.removeAll { $0.session != nil }
        guard read() != nil else {
            endSessionsAtUnlock = true
            return
        }
        change { $0.removeAll { $0.session != nil } }
    }

    /// The vault was unlocked: what had to wait for it is written now.
    public func unlocked() {
        guard endSessionsAtUnlock, read() != nil else { return }
        endSessionsAtUnlock = false
        change { $0.removeAll { $0.session != nil } }
    }

    /// Applies `edit` after dropping what has ended: grants past their time, and this Mac's session grants whose agent quit.
    private func change(_ edit: @escaping (inout AgentGrants) -> Void, then done: @escaping (Bool) -> Void = { _ in }) {
        let now = clock()
        let mac = mac
        let alive = sessionAlive
        write({ grants in
            grants.removeAll { grant in
                !grant.isInForce(at: now) || (grant.mac == mac && grant.session.map { !alive($0) } ?? false)
            }
            edit(&grants)
            grants.forgetEnded(now: now)
        }, { [weak self] written in
            done(written)
            self?.onChange?()
        })
        onChange?()
    }
}

/// This Mac's identifier for grants: a hash of the hardware UUID with PasswordPie's own label, so the database holds no
/// hardware identifier that means anything elsewhere.
public enum AgentMacIdentity {
    public static let current: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = (IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? ""
        return identifier(hardwareUUID: uuid)
    }()

    public static func identifier(hardwareUUID: String) -> String {
        let digest = SHA256.hash(data: Data("PasswordPie agent grants \(hardwareUUID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
