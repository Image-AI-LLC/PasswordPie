import Foundation

// `save`: an agent hands PasswordPie a value it made (`passwordpie save`, `passwordpie_save`). See docs/AGENTS.md,
// "Saving a secret". The value is kept as a proposal in the agents database, the owner sees where it goes (folder, title,
// field, new or a change) and never the value, and only the owner's Save, with Touch ID, writes it into an item. No
// standing permission covers a save, and none is made by one. The answer never says anything about the value an item
// holds now.

extension VaultBroker {
    /// Where a save goes.
    enum SaveTarget: Equatable {
        /// A shared item that is there.
        case existing(AgentItem, AgentField)
        case new(folder: [String], title: String, field: AgentField)
    }

    func save(_ request: AgentRequest, caller: AgentCaller) async -> AgentResponse {
        func refuse(_ code: AgentErrorCode, _ outcome: AgentOutcome, detail: String? = nil, ref: String? = nil, refs: [String]? = nil, items: [String] = []) -> AgentResponse {
            log(request, caller: caller, outcome: outcome, items: items, delivery: [])
            var answer = AgentResponse.error(code, id: request.id, ref: ref, refs: refs)
            answer.detail = detail
            return answer
        }
        let asked = request.secrets ?? []
        guard let saves else { return refuse(.usage, .usage, detail: "This copy of PasswordPie cannot save secrets.") }
        guard asked.count == 1, asked[0].delivery == .save else {
            return refuse(.usage, .usage, detail: "save takes one reference: where the value goes.")
        }
        let ref = asked[0].ref
        guard let reference = try? AgentReference(ref) else { return refuse(.usage, .usage, ref: ref, items: [ref]) }
        guard let bytes = request.savedBytes, !bytes.isEmpty else {
            return refuse(.usage, .usage, detail: "Nothing to save: the value was empty.", ref: ref, items: [ref])
        }
        guard bytes.count <= AgentConstants.maxSaveBytes else {
            return refuse(.usage, .usage, detail: "The value is larger than \(AgentConstants.maxSaveBytes / 1024) KiB.", ref: ref, items: [ref])
        }
        if limiter.isBlocked(caller.sessionKey, now: clock()) { return refuse(.tooManyRequests, .tooManyRequests, items: [ref]) }
        guard await waitForUnlock(request, caller: caller, count: 1) else { return refuse(.locked, .locked, items: [ref]) }

        let target: SaveTarget
        switch Self.saveTarget(reference, in: vault.agentSharedItems()) {
        case .success(let found): target = found
        case .failure(let failure):
            return refuse(failure.code, failure.code == .ambiguous ? .ambiguous : .notAvailable, ref: ref, refs: failure.refs, items: [ref])
        }
        let field: AgentField
        let existing: AgentItem?
        let folder: [String], title: String
        switch target {
        case .existing(let item, let named):
            (existing, field, folder, title) = (item, named, item.folder, item.title)
        case .new(let place, let named, let fieldNamed):
            (existing, field, folder, title) = (nil, fieldNamed, place, named)
        }
        if let problem = Self.unsavable(field) { return refuse(.usage, .usage, detail: problem, ref: ref, items: [ref]) }
        if case .attachment = field {} else if String(data: bytes, encoding: .utf8) == nil {
            return refuse(.usage, .usage, detail: "The value is not text. Save a file as an attachment: …/attachment/<name>.", ref: ref, items: [ref])
        }
        // Whether the field holds something now decides the words "a change", never the answer's: the agent hears the
        // same whatever the item held, and nothing is compared with the value.
        let change: AgentSaveChange
        if let existing {
            let held = existing.has(field) ? vault.agentSecret(existing, field: field) : nil
            change = (held?.isEmpty ?? true) ? .newField : .changed
        } else {
            change = .newItem
        }
        let kept = saves.proposals ?? []
        let now = clock()
        guard kept.filter({ $0.state == .pending }).count < AgentProposals.maxPending else {
            return refuse(.tooManyRequests, .tooManyRequests, detail: nil, items: [ref])
        }
        let proposal = AgentProposal(
            id: AgentProposal.newID(avoiding: Set(kept.map(\.id))), created: now, mac: mac, agent: caller.grantIdentity,
            agentName: caller.agentName, signature: caller.signatureText, project: caller.project,
            reason: request.reason.flatMap { $0.isEmpty ? nil : $0 }, via: request.client == "mcp" ? "MCP" : nil,
            item: existing?.id, folder: folder, title: title, field: field, change: change, value: bytes
        )
        let labels = [proposal.logLabel]
        let delivery = [Self.saveDelivery(change)]
        guard await saves.propose(proposal) else {
            return refuse(.appUnavailable, .usage, detail: "PasswordPie could not write the agents database, so nothing was saved.", items: labels)
        }
        func pending() -> AgentResponse {
            log(request, caller: caller, outcome: .waiting, items: labels, delivery: delivery)
            var answer = AgentResponse(type: request.type.rawValue, id: request.id)
            answer.save = AgentSaveAnswer(outcome: .pending, proposal: proposal.id)
            return answer
        }

        // One window at a time per agent session, as for a use. The proposal is kept from here on, whatever happens.
        await acquire(caller.sessionKey)
        defer { release(caller.sessionKey) }
        if Task.isCancelled || vault.agentVaultLocked || limiter.isBlocked(caller.sessionKey, now: clock()) { return pending() }
        let prompt = AgentApprovalPrompt(
            id: UUID(), kind: .save, raw: false, agent: caller.agentName, signature: caller.signatureText, agentPID: caller.agent?.pid,
            startedIn: Self.startedIn(caller), command: nil, program: nil, project: caller.project, reason: proposal.reason,
            rows: [AgentApprovalRow(
                title: title, folder: folder.joined(separator: "/"), field: field.label, delivery: .save, name: nil, tooShortToMask: false,
                note: Self.changeText(change), item: existing?.id
            )],
            // A save is never a standing permission's start, and none covers one.
            lasting: .notOffered, via: Self.viaText(request)
        )
        switch await ask(prompt) {
        case .allow, .allowLasting:
            switch await saves.save(proposal.id) {
            case .saved(let item, let done):
                log(request, caller: caller, outcome: .saved, items: labels, delivery: [Self.saveDelivery(done)])
                var answer = AgentResponse(type: request.type.rawValue, id: request.id)
                answer.save = AgentSaveAnswer(
                    outcome: .saved, proposal: proposal.id, ref: AgentReference.id(item, field: field == .password ? nil : field), change: done
                )
                return answer
            case .failed:
                // The item went away or the database could not be written: it stays in the list, where the owner sees why.
                return pending()
            }
        case .deny:
            limiter.recordDenial(caller.sessionKey, now: clock())
            // Rejected, even if the write fails: the agent is told so, and the owner's list still offers Reject.
            _ = await saves.reject(proposal.id)
            log(request, caller: caller, outcome: .rejected, items: labels, delivery: delivery)
            return .error(.denied, id: request.id)
        case .dismissed:
            return pending()
        }
    }

    // MARK: Answering from the list

    /// The owner saved a waiting proposal from Preferences > Agents, after Touch ID. One activity line, with the agent that
    /// proposed it.
    public func saveProposal(_ id: String) async -> AgentSaveResult {
        guard let saves, let proposal = saves.proposals?.first(where: { $0.id == id && $0.state == .pending }) else {
            return .failed("It is no longer waiting.")
        }
        let result = await saves.save(id)
        if case .saved(_, let change) = result {
            logAnswer(proposal, outcome: .savedFromList, delivery: Self.saveDelivery(change))
        }
        return result
    }

    /// The owner rejected a waiting proposal from Preferences > Agents.
    @discardableResult
    public func rejectProposal(_ id: String) async -> Bool {
        guard let saves, let proposal = saves.proposals?.first(where: { $0.id == id && $0.state == .pending }) else { return false }
        guard await saves.reject(id) else { return false }
        logAnswer(proposal, outcome: .rejected, delivery: Self.saveDelivery(proposal.change))
        return true
    }

    private func logAnswer(_ proposal: AgentProposal, outcome: AgentOutcome, delivery: String) {
        var record = AgentActivityRecord(
            time: clock(), kind: "save", outcome: outcome, caller: nil, command: nil, items: [proposal.logLabel], delivery: [delivery],
            reason: proposal.reason, via: proposal.via
        )
        record.agent = proposal.agentName
        record.signature = proposal.signature
        record.project = proposal.project
        activity.append(record)
    }

    /// This agent's proposals made on this Mac, for `status`.
    func proposalLines(for caller: AgentCaller) -> [AgentProposalLine] {
        (saves?.proposals ?? []).filter { $0.mac == mac && $0.agent == caller.grantIdentity }.map {
            AgentProposalLine(id: $0.id, ref: $0.ref, state: $0.state, created: $0.created)
        }
    }

    // MARK: Where a save goes

    struct SaveFailure: Error, Equatable {
        var code: AgentErrorCode
        var refs: [String]?
    }

    /// A shared item at the place one reading names (whatever fields it has) is changed; two are `ambiguous`. With none, a
    /// new item: the last part is the field when the reference has three parts or more, or two and the last is a standard
    /// field's name; else the last part is the title. `pp://id/` names a shared item or nothing.
    nonisolated static func saveTarget(_ reference: AgentReference, in shared: [AgentItem]) -> Result<SaveTarget, SaveFailure> {
        switch reference.target {
        case .id(let id, let field):
            guard let item = shared.first(where: { $0.id == id }) else { return .failure(SaveFailure(code: .notAvailable)) }
            return .success(.existing(item, field))
        case .path(let readings):
            var matches: [(AgentItem, AgentField)] = []
            for reading in readings {
                for item in shared where item.folder == reading.folder && item.title == reading.title {
                    if !matches.contains(where: { $0.0.id == item.id && $0.1 == reading.field }) { matches.append((item, reading.field)) }
                }
            }
            if matches.count == 1 { return .success(.existing(matches[0].0, matches[0].1)) }
            if matches.count > 1 {
                var refs: [String] = []
                for (item, field) in matches {
                    let ref = AgentReference.id(item.id, field: field == .password ? nil : field)
                    if !refs.contains(ref) { refs.append(ref) }
                }
                return .failure(SaveFailure(code: .ambiguous, refs: refs))
            }
            let parts = readings[0].folder.count + 1
            let standard: Set<String> = ["password", "username", "url", "notes"]
            let reading: AgentReference.Reading
            if readings.count >= 3 {
                reading = readings[2]
            } else if readings.count >= 2, parts >= 3 || standard.contains(readings[0].title) {
                reading = readings[1]
            } else {
                reading = readings[0]
            }
            return .success(.new(folder: reading.folder, title: reading.title, field: reading.field))
        }
    }

    /// Why a save cannot write `field`, or nil. Never the title (a save does not rename), a two-step secret, or
    /// PasswordPie's own fields.
    nonisolated public static func unsavable(_ field: AgentField) -> String? {
        switch field {
        case .otp:
            return "A save cannot set a two-step code."
        case .custom(let name):
            let lower = name.lowercased()
            let standard: Set<String> = ["title", "username", "password", "url", "notes", "otp", "totp seed", "totp settings"]
            if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The field needs a name." }
            if standard.contains(lower) || lower.hasPrefix("timeotp") || lower.hasPrefix("passwordpie.") {
                return "A save cannot set the field \(name): name the field in lower case (password, username, url, notes) or choose another name."
            }
            return nil
        case .attachment(let name):
            if name.isEmpty || name.contains("/") { return "The attached file needs a name without /." }
            return nil
        case .password, .username, .url, .notes:
            return nil
        }
    }

    /// The activity line's delivery: "save: new item", "save: new field", "save: change".
    nonisolated static func saveDelivery(_ change: AgentSaveChange) -> String {
        switch change {
        case .newItem: return "save: new item"
        case .newField: return "save: new field"
        case .changed: return "save: change"
        }
    }

    /// The window's line under the item.
    nonisolated public static func changeText(_ change: AgentSaveChange) -> String {
        switch change {
        case .newItem: return "a new item"
        case .newField: return "a new field of this item"
        case .changed: return "changes it: the value it has now goes into the item's history"
        }
    }
}
