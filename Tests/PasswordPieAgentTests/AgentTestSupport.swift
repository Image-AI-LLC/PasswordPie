import Darwin
import Foundation
import XCTest
@testable import PasswordPieAgent

/// A database with a few items, some shared. Values are planted so tests can grep for them.
@MainActor
final class FakeVault: AgentVault {
    var locked = false
    var items: [AgentItem] = []
    var shared: Set<UUID> = []
    var values: [UUID: [AgentField: Data]] = [:]
    var secretReads = 0

    var agentVaultLocked: Bool { locked }

    func agentSharedItems() -> [AgentItem] {
        items.filter { shared.contains($0.id) }
    }

    func agentSecret(_ item: AgentItem, field: AgentField) -> Data? {
        secretReads += 1
        return values[item.id]?[field]
    }

    @discardableResult
    func add(_ title: String, folder: [String] = ["Agents"], password: String, fields: [String: String] = [:], attachments: [String: Data] = [:], shared isShared: Bool = true) -> AgentItem {
        let item = AgentItem(id: UUID(), database: "/tmp/test.kdbx", folder: folder, title: title, fields: fields.keys.sorted(), attachments: attachments.keys.sorted())
        items.append(item)
        if isShared { shared.insert(item.id) }
        var stored: [AgentField: Data] = [.password: Data(password.utf8), .username: Data("user".utf8), .url: Data(), .notes: Data()]
        for (key, value) in fields { stored[.custom(key)] = Data(value.utf8) }
        for (key, value) in attachments { stored[.attachment(key)] = value }
        values[item.id] = stored
        return item
    }
}

/// Answers prompts from a script. With nothing scripted it never answers, as an owner who is away.
@MainActor
final class FakeApprover: AgentApprover {
    var script: [AgentApprovalDecision] = []
    var prompts: [AgentApprovalPrompt] = []
    var withdrawn: [UUID] = []
    /// Called when a prompt is shown, before it is answered.
    var onPresent: ((AgentApprovalPrompt) -> Void)?
    private var open: [UUID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]
    /// How many prompts are on screen now.
    var showing: Int { open.count }

    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        prompts.append(prompt)
        onPresent?(prompt)
        if !script.isEmpty { return script.removeFirst() }
        return await withCheckedContinuation { open[prompt.id] = $0 }
    }

    func withdraw(_ id: UUID) {
        withdrawn.append(id)
        open.removeValue(forKey: id)?.resume(returning: .dismissed)
    }

    /// Answers the prompt on screen.
    func answer(_ decision: AgentApprovalDecision) {
        guard let (id, continuation) = open.first else { return }
        open[id] = nil
        continuation.resume(returning: decision)
    }
}

/// Grants everything that is not raw, to show which requests never consult it.
@MainActor
final class GrantEverything: AgentGrantStore {
    var asked = 0
    func grant(covering query: AgentGrantQuery) -> String? {
        asked += 1
        return "test grant"
    }
    func grants(for caller: AgentCaller) -> [String] { ["test grant"] }
    func covers(_ item: AgentItem, for caller: AgentCaller) -> Bool { true }
    func approved(_ query: AgentGrantQuery, decision: AgentApprovalDecision) {}
}

final class MemoryActivity: AgentActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentActivityRecord] = []

    var records: [AgentActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ record: AgentActivityRecord) {
        lock.lock()
        stored.append(record)
        lock.unlock()
    }
}

enum Callers {
    static func make(session: String = "agent:100:1", agent: String = "claude", project: String = "/tmp/project") -> AgentCaller {
        let agentProcess = AgentProcess(pid: 100, startTime: 1, path: "/usr/local/bin/\(agent)", name: AgentHosts.byName[agent] ?? agent)
        return AgentCaller(
            cli: AgentProcess(pid: 200, startTime: 2, path: "/Applications/PasswordPie.app/Contents/Helpers/passwordpie", name: "passwordpie"),
            chain: [AgentProcess(pid: 150, startTime: 1, path: "/bin/zsh", name: "zsh"), agentProcess],
            agent: agentProcess,
            sessionKey: session,
            cwd: project,
            project: project
        )
    }
}

extension AgentRequest {
    static func use(_ secrets: [AgentSecretRequest], argv: [String] = ["Scripts/release.sh"], masking: Bool = true, wait: Int? = 0, reason: String? = nil) -> AgentRequest {
        var request = AgentRequest(type: .use, id: 7)
        request.secrets = secrets
        request.program = "/tmp/project/Scripts/release.sh"
        request.argv = argv
        request.masking = masking
        request.wait = wait
        request.reason = reason
        return request
    }

    static func read(_ ref: String, wait: Int? = 0) -> AgentRequest {
        var request = AgentRequest(type: .read, id: 8)
        request.secrets = [AgentSecretRequest(name: nil, ref: ref, delivery: .shown)]
        request.wait = wait
        return request
    }
}

/// A folder under /tmp short enough for a socket path (104 bytes).
func shortTemporaryFolder(_ prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(prefix)-\(getpid())-\(Int.random(in: 0..<1_000_000))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Waits on the main actor without blocking it, so main-actor work (the broker) keeps running.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
