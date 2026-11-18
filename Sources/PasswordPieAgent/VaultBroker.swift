import Foundation
import PasswordPieBridge

// The broker: the one place in the app where a request that is not the owner clicking in PasswordPie is answered. It
// (1) takes the caller as the app worked it out from the kernel, (2) resolves references against shared items only,
// (3) decides through the grant store or the approval window, and (4) writes one activity line. The command-line tool,
// and later the MCP server and the browser login, are thin relays that hold no vault. See docs/AGENTS.md.

/// What the broker needs from the open database. The app's session implements it.
@MainActor
public protocol AgentVault: AnyObject {
    /// True while no database is unlocked. Nothing is handed out then.
    var agentVaultLocked: Bool { get }
    /// The items shared with agents in the database PasswordPie unlocked, without the Recycle Bin. One database: a
    /// reference does not name one, and the same item UUID can be in two copies of a file.
    func agentSharedItems() -> [AgentItem]
    /// The bytes of one field or attachment of a shared item. Nil when it has none.
    func agentSecret(_ item: AgentItem, field: AgentField) -> Data?
}

/// One secret of a request, resolved.
public struct AgentResolvedSecret: Equatable, Sendable {
    public var item: AgentItem
    public var field: AgentField
    public var delivery: AgentDelivery
    /// The environment variable, for `env` and `file`.
    public var name: String?
    /// The reference as the agent typed it.
    public var ref: String

    /// For the activity log: "Developer/App Store Connect API key › attachment AuthKey.p8".
    public var logLabel: String {
        let place = item.folder.isEmpty ? item.title : item.folderText + "/" + item.title
        return "\(place) › \(field.label)"
    }

    public var deliveryLabel: String {
        switch delivery {
        case .env: return "env \(name ?? "")"
        case .file: return "file \(name ?? "")"
        case .stdin: return "stdin"
        case .shown: return "shown"
        case .fill: return "fill"
        }
    }
}

/// Everything a standing permission could be matched against.
public struct AgentGrantQuery: Sendable {
    public var caller: AgentCaller
    public var kind: AgentRequestKind
    /// The agent can end up with the value (a read, or masking off). Never covered or recorded by a standing permission.
    public var raw: Bool
    /// The resolved path of what the command runs, and the command as typed. From the tool: a claim, checked by the grant
    /// store against the file itself.
    public var program: String?
    public var argv: [String]
    public var secrets: [AgentResolvedSecret]
}

/// Standing permissions. Item A ships `NoAgentGrants`, which never grants; item B stores real ones.
@MainActor
public protocol AgentGrantStore: AnyObject {
    /// The description of the standing permission that covers every secret of `query` ("7 days, this project"), or nil
    /// to ask. Never called for a raw request.
    func grant(covering query: AgentGrantQuery) -> String?
    /// The standing permissions that apply to this agent and project, described, for `status`.
    func grants(for caller: AgentCaller) -> [String]
    /// True when a standing permission covers `item` for this agent and project, for `list`.
    func covers(_ item: AgentItem, for caller: AgentCaller) -> Bool
    /// The owner allowed `query` in the approval window with `decision`. Where a lasting choice is recorded.
    func approved(_ query: AgentGrantQuery, decision: AgentApprovalDecision)
}

@MainActor
public final class NoAgentGrants: AgentGrantStore {
    public init() {}
    public func grant(covering query: AgentGrantQuery) -> String? { nil }
    public func grants(for caller: AgentCaller) -> [String] { [] }
    public func covers(_ item: AgentItem, for caller: AgentCaller) -> Bool { false }
    public func approved(_ query: AgentGrantQuery, decision: AgentApprovalDecision) {}
}

/// One row of the approval window: a secret, never its value.
public struct AgentApprovalRow: Equatable, Sendable {
    public var title: String
    public var folder: String
    /// "password", "field Key ID", "attachment AuthKey.p8".
    public var field: String
    public var delivery: AgentDelivery
    public var name: String?
    /// Shorter than `AgentConstants.minimumMaskedLength`: the command's output is not masked for it.
    public var tooShortToMask: Bool
    /// `login`: the account's username, shown so the owner can tell two accounts of a site apart.
    public var username: String? = nil
    /// `login`: what happens with the two-step code, when the item has one.
    public var note: String? = nil
}

public struct AgentApprovalPrompt: Equatable, Sendable {
    public var id: UUID
    public var kind: AgentRequestKind
    /// The agent will see the value: "Show to Agent", never covered by a standing permission.
    public var raw: Bool
    public var agent: String
    public var signature: String
    public var agentPID: Int32?
    /// The terminal or app the agent runs in, when the chain shows one.
    public var startedIn: String?
    public var command: String?
    /// The resolved path of what the command runs, as the tool found it on the PATH.
    public var program: String?
    public var project: String
    /// The agent's `--reason`: its claim, shown in quotes and never reworded.
    public var reason: String?
    public var rows: [AgentApprovalRow]
    /// `login`: the site ("github.com"), the browser and profile, and whether the form is sent after the fill. With more
    /// than one row the owner picks exactly one.
    public var site: String? = nil
    public var browser: String? = nil
    public var submit: Bool = false
}

public enum AgentApprovalDecision: Equatable, Sendable {
    case deny
    /// The rows the owner left ticked, by index. Confirmed with Touch ID or the login password.
    case allow(Set<Int>)
    /// The window went away without an answer: the broker withdrew it, or the vault locked.
    case dismissed
}

/// Draws the approval window. The app's shows it over whatever is in front and asks for Touch ID on Allow.
@MainActor
public protocol AgentApprover: AnyObject {
    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision
    /// Closes the window for `id` (timed out, or the vault locked). `present` then returns `.dismissed`.
    func withdraw(_ id: UUID)
}

/// A request waiting for the owner to unlock, for the lock screen's line.
public struct AgentWaiting: Equatable, Sendable {
    public var agent: String
    public var count: Int

    /// "Claude Code is waiting for 2 secrets."
    public static func lockScreenLine(_ waiting: [AgentWaiting]) -> String? {
        guard let first = waiting.first else { return nil }
        let count = waiting.filter { $0.agent == first.agent }.reduce(0) { $0 + $1.count }
        let agents = Set(waiting.map(\.agent)).count
        let secrets = count == 1 ? "1 secret" : "\(count) secrets"
        if agents == 1 { return "\(first.agent) is waiting for \(secrets)." }
        let total = waiting.reduce(0) { $0 + $1.count }
        return "\(agents) agents are waiting for \(total == 1 ? "1 secret" : "\(total) secrets")."
    }
}

/// After 3 denials in 10 minutes, one agent session gets `too-many-requests` without a prompt for 10 minutes.
public struct DenialLimiter: Sendable {
    public static let denials = 3
    public static let window: TimeInterval = 600
    public static let block: TimeInterval = 600

    private var recent: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init() {}

    public func isBlocked(_ session: String, now: Date) -> Bool {
        guard let until = blockedUntil[session] else { return false }
        return now < until
    }

    public mutating func recordDenial(_ session: String, now: Date) {
        // Forget sessions whose block ended and whose denials are old: session keys are unique per agent process.
        blockedUntil = blockedUntil.filter { now < $0.value }
        recent = recent.filter { $0.value.contains { now.timeIntervalSince($0) < Self.window } }
        var list = (recent[session] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        list.append(now)
        if list.count >= Self.denials {
            blockedUntil[session] = now.addingTimeInterval(Self.block)
            list = []
        }
        recent[session] = list
    }
}

@MainActor
public final class VaultBroker {
    public let vault: AgentVault
    public let approver: AgentApprover
    public let grants: AgentGrantStore
    public let activity: AgentActivityLogging
    /// The browser side of `login`. Without it a login answers `usage`.
    public var logins: AgentBrowserLogins?
    /// Agent access is on (Preferences > Agents).
    public var isEnabled: () -> Bool
    public var clock: () -> Date = Date.init
    public var approvalSeconds: TimeInterval = AgentConstants.approvalSeconds
    /// Called when a request starts waiting for an unlock: the app shows its lock screen.
    public var onNeedsUnlock: (() -> Void)?
    /// The requests waiting for an unlock changed.
    public var onWaitingChanged: (([AgentWaiting]) -> Void)?

    public private(set) var waiting: [UUID: AgentWaiting] = [:] {
        didSet { onWaitingChanged?(Array(waiting.values)) }
    }

    var limiter = DenialLimiter()
    private var stateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var busySessions: Set<String> = []
    private var sessionQueues: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(vault: AgentVault, approver: AgentApprover, grants: AgentGrantStore, activity: AgentActivityLogging, isEnabled: @escaping () -> Bool) {
        self.vault = vault
        self.approver = approver
        self.grants = grants
        self.activity = activity
        self.isEnabled = isEnabled
    }

    /// The vault locked or unlocked: requests waiting for it look again.
    public func vaultStateChanged() {
        let waiters = stateWaiters
        stateWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    public func handle(_ request: AgentRequest, from caller: AgentCaller) async -> AgentResponse {
        guard isEnabled() else { return .error(.accessOff, id: request.id) }
        switch request.type {
        case .hello:
            var answer = AgentResponse(type: "hello", id: request.id)
            answer.version = AgentConstants.protocolVersion
            answer.locked = vault.agentVaultLocked
            answer.access = true
            return answer
        case .status:
            var answer = AgentResponse(type: "status", id: request.id)
            answer.status = AgentStatusInfo(
                locked: vault.agentVaultLocked,
                access: true,
                agent: "\(caller.agentName) (\(caller.signatureText))",
                project: caller.project,
                grants: vault.agentVaultLocked ? [] : grants.grants(for: caller)
            )
            return answer
        case .list:
            return await list(request, caller: caller)
        case .use, .read:
            return await use(request, caller: caller)
        case .login:
            return await login(request, caller: caller)
        }
    }

    // MARK: list

    private func list(_ request: AgentRequest, caller: AgentCaller) async -> AgentResponse {
        guard await waitForUnlock(request, caller: caller, count: 0) else {
            log(request, caller: caller, outcome: .locked, items: [], delivery: [])
            return .error(.locked, id: request.id)
        }
        let found = AgentResolver.search(request.query, in: vault.agentSharedItems())
        var answer = AgentResponse(type: "list", id: request.id)
        answer.items = found.map { $0.listed(covered: grants.covers($0, for: caller)) }
        log(request, caller: caller, outcome: .listed, items: found.map { AgentReference.path(folder: $0.folder, title: $0.title) }, delivery: [])
        return answer
    }

    // MARK: use and read

    private func use(_ request: AgentRequest, caller: AgentCaller) async -> AgentResponse {
        let asked = request.secrets ?? []
        var references: [AgentReference] = []
        for secret in asked {
            guard let reference = try? AgentReference(secret.ref) else {
                log(request, caller: caller, outcome: .usage, items: [secret.ref], delivery: [])
                return .error(.usage, id: request.id, ref: secret.ref)
            }
            references.append(reference)
        }
        guard !asked.isEmpty, request.type != .read || asked.count == 1, !asked.contains(where: { $0.delivery == .fill }) else {
            log(request, caller: caller, outcome: .usage, items: [], delivery: [])
            return .error(.usage, id: request.id)
        }
        let raw = request.isRaw
        if limiter.isBlocked(caller.sessionKey, now: clock()) {
            log(request, caller: caller, outcome: .tooManyRequests, items: asked.map(\.ref), delivery: [])
            return .error(.tooManyRequests, id: request.id)
        }
        guard await waitForUnlock(request, caller: caller, count: asked.count) else {
            log(request, caller: caller, outcome: .locked, items: asked.map(\.ref), delivery: [])
            return .error(.locked, id: request.id)
        }
        let resolved: [AgentResolvedSecret]
        switch resolve(asked, references) {
        case .success(let found):
            resolved = found
        case .failure(let failure):
            log(request, caller: caller, outcome: failure.code == .ambiguous ? .ambiguous : .notAvailable, items: [failure.ref], delivery: [])
            return .error(failure.code, id: request.id, ref: failure.ref, refs: failure.refs)
        }
        // The answer must fit one frame, encoded as it would be sent with everything allowed. Said before anyone is asked,
        // not after the owner approved. The values stay in this process.
        if AgentCoding.encode(answer(request, resolved: resolved, selected: Set(resolved.indices), by: "once")).count + 4 > BridgeFrame.maxLength {
            log(request, caller: caller, outcome: .usage, items: resolved.map(\.logLabel), delivery: [])
            var refusal = AgentResponse.error(.usage, id: request.id, ref: resolved.first?.ref)
            refusal.detail = "The values asked for are too large to hand over (an answer is at most 1 MiB)."
            return refusal
        }
        let query = AgentGrantQuery(caller: caller, kind: request.type, raw: raw, program: request.program, argv: request.argv ?? [], secrets: resolved)
        if !raw, let grant = grants.grant(covering: query) {
            return deliver(request, caller: caller, resolved: resolved, selected: Set(resolved.indices), outcome: .allowedByGrant, grant: grant)
        }

        // One prompt at a time per agent session; a second request waits behind it.
        await acquire(caller.sessionKey)
        defer { release(caller.sessionKey) }
        // The tool hung up while this waited its turn: nobody would get the answer.
        if Task.isCancelled {
            log(request, caller: caller, outcome: .timedOut, items: resolved.map(\.logLabel), delivery: [])
            return .error(.timeout, id: request.id)
        }
        if limiter.isBlocked(caller.sessionKey, now: clock()) {
            log(request, caller: caller, outcome: .tooManyRequests, items: resolved.map(\.logLabel), delivery: [])
            return .error(.tooManyRequests, id: request.id)
        }
        guard !vault.agentVaultLocked else {
            log(request, caller: caller, outcome: .locked, items: resolved.map(\.logLabel), delivery: [])
            return .error(.locked, id: request.id)
        }
        let prompt = makePrompt(request, caller: caller, resolved: resolved, raw: raw)
        let decision = await ask(prompt)
        switch decision {
        case .allow(let selected) where !selected.isEmpty:
            guard !vault.agentVaultLocked else {
                log(request, caller: caller, outcome: .locked, items: resolved.map(\.logLabel), delivery: [])
                return .error(.locked, id: request.id)
            }
            // What was approved must still be there, and still fit, after the wait.
            let approved = resolved.indices.filter { selected.contains($0) }
            if let gone = approved.first(where: { vault.agentSecret(resolved[$0].item, field: resolved[$0].field) == nil }) {
                log(request, caller: caller, outcome: .notAvailable, items: [resolved[gone].ref], delivery: [])
                return .error(.notAvailable, id: request.id, ref: resolved[gone].ref)
            }
            if AgentCoding.encode(answer(request, resolved: resolved, selected: selected, by: "once")).count + 4 > BridgeFrame.maxLength {
                log(request, caller: caller, outcome: .usage, items: resolved.map(\.logLabel), delivery: [])
                return .error(.usage, id: request.id, ref: resolved.first?.ref)
            }
            // A raw approval is never a standing permission's start.
            if !raw { grants.approved(query, decision: decision) }
            return deliver(request, caller: caller, resolved: resolved, selected: selected, outcome: raw ? .shown : .allowedOnce, grant: nil)
        case .allow, .deny:
            limiter.recordDenial(caller.sessionKey, now: clock())
            log(request, caller: caller, outcome: .denied, items: resolved.map(\.logLabel), delivery: resolved.map(\.deliveryLabel))
            return .error(.denied, id: request.id)
        case .dismissed:
            let locked = vault.agentVaultLocked
            log(request, caller: caller, outcome: locked ? .locked : .timedOut, items: resolved.map(\.logLabel), delivery: resolved.map(\.deliveryLabel))
            return .error(locked ? .locked : .timeout, id: request.id)
        }
    }

    private struct Failure: Error {
        var code: AgentErrorCode
        var ref: String
        var refs: [String]?
    }

    private func resolve(_ asked: [AgentSecretRequest], _ references: [AgentReference]) -> Result<[AgentResolvedSecret], Failure> {
        let shared = vault.agentSharedItems()
        var resolved: [AgentResolvedSecret] = []
        for (secret, reference) in zip(asked, references) {
            switch AgentResolver.resolve(reference, in: shared) {
            case .found(let item, let field):
                // Two-step codes are not handed to agents in this version: as if the field did not exist.
                guard field != .otp else { return .failure(Failure(code: .notAvailable, ref: secret.ref)) }
                resolved.append(AgentResolvedSecret(item: item, field: field, delivery: secret.delivery, name: secret.name, ref: secret.ref))
            case .notAvailable:
                return .failure(Failure(code: .notAvailable, ref: secret.ref))
            case .ambiguous(let refs):
                return .failure(Failure(code: .ambiguous, ref: secret.ref, refs: refs))
            }
        }
        return .success(resolved)
    }

    private func deliver(
        _ request: AgentRequest, caller: AgentCaller, resolved: [AgentResolvedSecret], selected: Set<Int>, outcome: AgentOutcome, grant: String?
    ) -> AgentResponse {
        let answer = answer(request, resolved: resolved, selected: selected, by: grant ?? "once")
        let given = resolved.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        log(request, caller: caller, outcome: outcome, grant: grant, items: given.map(\.logLabel), delivery: given.map(\.deliveryLabel))
        return answer
    }

    private func answer(_ request: AgentRequest, resolved: [AgentResolvedSecret], selected: Set<Int>, by: String) -> AgentResponse {
        var answer = AgentResponse(type: request.type.rawValue, id: request.id)
        answer.secrets = resolved.enumerated().map { index, secret in
            let bytes = selected.contains(index) ? (vault.agentSecret(secret.item, field: secret.field) ?? Data()) : nil
            return AgentSecretValue(name: secret.name, ref: secret.ref, bytes: bytes)
        }
        answer.by = by
        return answer
    }

    private func makePrompt(_ request: AgentRequest, caller: AgentCaller, resolved: [AgentResolvedSecret], raw: Bool) -> AgentApprovalPrompt {
        let rows = resolved.map { secret in
            let length = vault.agentSecret(secret.item, field: secret.field)?.count ?? 0
            return AgentApprovalRow(
                title: secret.item.title,
                folder: secret.item.folderText,
                field: secret.field.label,
                delivery: raw ? .shown : secret.delivery,
                name: secret.name,
                tooShortToMask: !raw && length < AgentConstants.minimumMaskedLength
            )
        }
        return AgentApprovalPrompt(
            id: UUID(),
            kind: request.type,
            raw: raw,
            agent: caller.agentName,
            signature: caller.signatureText,
            agentPID: caller.agent?.pid,
            startedIn: Self.startedIn(caller),
            command: Self.commandText(request.argv),
            program: request.program,
            project: caller.project,
            reason: request.reason.flatMap { $0.isEmpty ? nil : $0 },
            rows: rows
        )
    }

    /// The terminal or app the agent runs in, when the chain shows one.
    static func startedIn(_ caller: AgentCaller) -> String? {
        let terminal = caller.chain.first { process in
            process.identifier.map(AgentHosts.terminals.contains) ?? false
        }
        return terminal.map { ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
    }

    /// The command as typed, each argument that needs it in single quotes. Nil for a raw read.
    public static func commandText(_ argv: [String]?) -> String? {
        guard let argv, !argv.isEmpty else { return nil }
        return argv.map { argument in
            let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_./=:@%+,".unicodeScalars.contains($0)
            }
            return plain ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// The approval window's answer, or `.dismissed` when nobody answered in time.
    func ask(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        let answered = await firstOf(seconds: approvalSeconds) { [approver] in await approver.present(prompt) }
        guard let answered else {
            approver.withdraw(prompt.id)
            return .dismissed
        }
        return answered
    }

    // MARK: Waiting

    /// True once the vault is unlocked, at once when it is. While waiting, the lock screen says who waits for how many.
    func waitForUnlock(_ request: AgentRequest, caller: AgentCaller, count: Int) async -> Bool {
        guard vault.agentVaultLocked else { return true }
        let seconds = Double(min(max(request.wait ?? AgentConstants.defaultWaitSeconds, 0), AgentConstants.maxWaitSeconds))
        let deadline = clock().addingTimeInterval(seconds)
        let token = UUID()
        waiting[token] = AgentWaiting(agent: caller.agentName, count: max(count, 1))
        defer { waiting[token] = nil }
        onNeedsUnlock?()
        while vault.agentVaultLocked {
            if Task.isCancelled { return false }
            let remaining = deadline.timeIntervalSince(clock())
            guard remaining > 0 else { return false }
            let key = UUID()
            _ = await firstOf(seconds: remaining) { [weak self] in
                await withCheckedContinuation { continuation in
                    // Unlocked between the loop's check and this task starting: no change would wake it.
                    guard let self, self.vault.agentVaultLocked else { return continuation.resume() }
                    self.stateWaiters[key] = continuation
                }
            }
            if let left = stateWaiters.removeValue(forKey: key) { left.resume() }
        }
        return true
    }

    func acquire(_ session: String) async {
        guard busySessions.contains(session) else {
            busySessions.insert(session)
            return
        }
        await withCheckedContinuation { continuation in
            sessionQueues[session, default: []].append(continuation)
        }
    }

    func release(_ session: String) {
        if var queue = sessionQueues[session], !queue.isEmpty {
            let next = queue.removeFirst()
            sessionQueues[session] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busySessions.remove(session)
        }
    }

    /// `work`'s result, or nil when `seconds` pass first or the calling task is cancelled (the tool hung up). `work` keeps
    /// running; its result is then dropped.
    private func firstOf<T: Sendable>(seconds: TimeInterval, _ work: @escaping @MainActor () async -> T) async -> T? {
        let box = FirstResult<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                box.continuation = continuation
                if Task.isCancelled {
                    box.finish(nil)
                    return
                }
                Task { @MainActor in box.finish(await work()) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                    box.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in box.finish(nil) }
        }
    }

    func log(
        _ request: AgentRequest, caller: AgentCaller, outcome: AgentOutcome, grant: String? = nil, items: [String], delivery: [String]
    ) {
        let kind: String
        switch request.type {
        case .use: kind = "run"
        case .read: kind = "read"
        default: kind = request.type.rawValue
        }
        activity.append(AgentActivityRecord(
            time: clock(),
            kind: kind,
            outcome: outcome,
            grant: grant,
            caller: caller,
            command: Self.commandText(request.argv),
            items: items,
            delivery: delivery,
            reason: request.reason
        ))
    }
}

@MainActor
private final class FirstResult<T> {
    var continuation: CheckedContinuation<T?, Never>?

    func finish(_ value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
