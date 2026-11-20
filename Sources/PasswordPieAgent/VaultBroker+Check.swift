import Foundation
import PasswordPieBridge

// `check`: compares a folder of dotenv files with the vault, for `passwordpie check-import` (docs/AGENTS.md, "Checking a
// folder against the vault"). The app reads the folder and compares inside its own process: no value goes to the tool
// and none comes from it. The answer is a word per name. It needs the owner's approval like any use, every time: what
// the agent learns is, for each name, whether a file it could write holds the same value as the vault.

/// One variable or key file of a folder, with where an import puts it and what the file holds.
public struct AgentCheckSubject: Equatable, Sendable {
    /// The file inside the folder: `stripe/work.env`.
    public var file: String
    /// The variable's name, or the key file's.
    public var name: String
    public var folder: [String]
    public var title: String
    public var field: AgentField
    public var expected: Data

    public init(file: String, name: String, folder: [String], title: String, field: AgentField, expected: Data) {
        self.file = file
        self.name = name
        self.folder = folder
        self.title = title
        self.field = field
        self.expected = expected
    }
}

/// Why a folder could not be read for a check, in words for the agent.
public struct AgentFolderProblem: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Reads a folder of dotenv files for a check. The app's is the importer's own reader, so a check sees a folder exactly
/// as an import does. Called off the main thread.
public protocol AgentFolderReader: Sendable {
    /// Every variable and key file of `folder`. `inside`: the folder in the database everything was put inside.
    func subjects(folder: String, inside: [String]) throws -> [AgentCheckSubject]
}

extension VaultBroker {
    func check(_ request: AgentRequest, caller: AgentCaller) async -> AgentResponse {
        func refuse(_ code: AgentErrorCode, _ outcome: AgentOutcome, detail: String? = nil, items: [String] = []) -> AgentResponse {
            log(request, caller: caller, outcome: outcome, items: items, delivery: [])
            var answer = AgentResponse.error(code, id: request.id)
            answer.detail = detail
            return answer
        }
        guard let folders, let folder = request.folder, folder.hasPrefix("/"), !folder.contains("\0") else {
            return refuse(.usage, .usage, detail: "check-import needs a folder.")
        }
        if limiter.isBlocked(caller.sessionKey, now: clock()) { return refuse(.tooManyRequests, .tooManyRequests) }
        let inside = (request.inside ?? "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Reading a folder can take a moment, and needs nothing of the vault.
        let read = await Task.detached(priority: .userInitiated) {
            Result { try folders.subjects(folder: folder, inside: inside) }
        }.value
        let subjects: [AgentCheckSubject]
        switch read {
        case .success(let found) where !found.isEmpty:
            subjects = found
        case .success:
            return refuse(.usage, .usage, detail: "No .env files or key files in \(folder).")
        case .failure(let problem):
            return refuse(.usage, .usage, detail: (problem as? AgentFolderProblem)?.message ?? "Could not read \(folder).")
        }
        // The answer must fit one frame with every name at the longest word. Said before anyone is asked, as for a use.
        var widest = AgentResponse(type: request.type.rawValue, id: request.id)
        widest.checks = subjects.map { AgentCheckLine(file: $0.file, name: $0.name, status: .notChecked) }
        if AgentCoding.encode(widest).count + 4 > BridgeFrame.maxLength {
            return refuse(.usage, .usage, detail: "\(folder) has too many names for one answer (an answer is at most 1 MiB).")
        }
        guard await waitForUnlock(request, caller: caller, count: subjects.count) else { return refuse(.locked, .locked) }

        // Where each name is, among shared items only. Not shared and not there are one answer: missing.
        var lines = subjects.map { AgentCheckLine(file: $0.file, name: $0.name, status: .missing) }
        var rows: [(subject: Int, item: AgentItem)] = []
        let shared = vault.agentSharedItems()
        for (index, subject) in subjects.enumerated() {
            let places = shared.filter { $0.folder == subject.folder && $0.title == subject.title }
            // A variable the file sets to nothing is a field with nothing in it, which an item does not list.
            let holders = places.filter { $0.has(subject.field) || (subject.expected.isEmpty && subject.field.isCustom) }
            if holders.count == 1 {
                rows.append((index, holders[0]))
            } else if holders.count > 1 {
                lines[index].status = .ambiguous
            }
        }
        func answer() -> AgentResponse {
            var answer = AgentResponse(type: request.type.rawValue, id: request.id)
            answer.checks = lines
            return answer
        }
        let labels = rows.map { label(subjects[$0.subject], in: $0.item) }
        guard !rows.isEmpty else {
            // Nothing shared is where the folder's names would be: there is nothing to ask about, and nothing to learn.
            log(request, caller: caller, outcome: .notAvailable, items: [], delivery: [])
            return answer()
        }

        // One prompt at a time per agent session, as for a use.
        await acquire(caller.sessionKey)
        defer { release(caller.sessionKey) }
        if Task.isCancelled { return refuse(.timeout, .timedOut, items: labels) }
        if limiter.isBlocked(caller.sessionKey, now: clock()) { return refuse(.tooManyRequests, .tooManyRequests, items: labels) }
        guard !vault.agentVaultLocked else { return refuse(.locked, .locked, items: labels) }
        let prompt = AgentApprovalPrompt(
            id: UUID(), kind: .check, raw: false, agent: caller.agentName, signature: caller.signatureText, agentPID: caller.agent?.pid,
            startedIn: Self.startedIn(caller), command: nil, program: nil, project: caller.project,
            reason: request.reason.flatMap { $0.isEmpty ? nil : $0 },
            rows: rows.map { row in
                let subject = subjects[row.subject]
                return AgentApprovalRow(
                    title: row.item.title, folder: row.item.folderText, field: subject.field.label, delivery: .compare, name: subject.name,
                    tooShortToMask: false, item: row.item.id
                )
            },
            // A check is never a standing permission's start: each one is an answer about values.
            lasting: .notOffered, via: Self.viaText(request), folder: folder
        )
        let selected: Set<Int>
        switch await ask(prompt) {
        case .allow(let ticked), .allowLasting(let ticked, _):
            selected = ticked
        case .deny:
            selected = []
        case .dismissed:
            let locked = vault.agentVaultLocked
            return refuse(locked ? .locked : .timeout, locked ? .locked : .timedOut, items: labels)
        }
        guard !selected.isEmpty else {
            limiter.recordDenial(caller.sessionKey, now: clock())
            return refuse(.denied, .denied, items: labels)
        }
        // The files are read again: the owner may have taken minutes, and a file changed since is not what was shown.
        let latest = await Task.detached(priority: .userInitiated) {
            Result { try folders.subjects(folder: folder, inside: inside) }
        }.value
        guard case .success(subjects) = latest else {
            return refuse(.usage, .usage, detail: "The files in \(folder) changed while PasswordPie waited. Run check-import again.", items: labels)
        }
        guard !vault.agentVaultLocked else { return refuse(.locked, .locked, items: labels) }
        for (position, row) in rows.enumerated() {
            let subject = subjects[row.subject]
            guard selected.contains(position) else {
                lines[row.subject].status = .notChecked
                continue
            }
            // Read now, not when the window opened: what is compared is what the vault holds at the answer.
            let held = vault.agentSecret(row.item, field: subject.field) ?? (subject.expected.isEmpty ? Data() : nil)
            lines[row.subject].status = held == nil ? .missing : held == subject.expected ? .same : .differs
        }
        let compared = rows.enumerated().filter { selected.contains($0.offset) }.map { labels[$0.offset] }
        log(request, caller: caller, outcome: .compared, items: compared, delivery: ["compare"])
        return answer()
    }

    /// "stripe/work › field STRIPE_SECRET_KEY", as a use logs it.
    private func label(_ subject: AgentCheckSubject, in item: AgentItem) -> String {
        AgentResolvedSecret(item: item, field: subject.field, delivery: .compare, name: subject.name, ref: "").logLabel
    }
}

private extension AgentField {
    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}
