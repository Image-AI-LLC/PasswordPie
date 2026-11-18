#if PP_DIRECT
import Foundation
import PasswordPieAgent
import PasswordPieCore

/// One agent login between the owner's Allow and the agent's answer: the pending fill waits for a tab of its site, then
/// for the tab to say how it went, then, when the account has a two-step code and this Mac has Premium and the form was
/// sent, for the code to go in. Holds no credential. See docs/AGENTS.md, "Website login".
@MainActor
final class AgentLoginWait {
    let token: UUID
    let code: AgentLoginCodePlan
    let submit: Bool
    private(set) var taken = false
    private(set) var result: AgentFillResult?
    /// The code request came before the result did.
    private var codeFilled: Bool?
    private(set) var end: AgentLoginEnd?
    private var continuation: CheckedContinuation<AgentLoginEnd, Never>?
    private var timer: Task<Void, Never>?
    /// Called once, when it ends.
    var onEnd: (() -> Void)?

    init(token: UUID, code: AgentLoginCodePlan, submit: Bool) {
        self.token = token
        self.code = code
        self.submit = submit
    }

    func wait() async -> AgentLoginEnd {
        if let end { return end }
        return await withCheckedContinuation { continuation in
            if let end { continuation.resume(returning: end) } else { self.continuation = continuation }
        }
    }

    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func finish(_ end: AgentLoginEnd) {
        guard self.end == nil else { return }
        self.end = end
        timer?.cancel()
        timer = nil
        continuation?.resume(returning: end)
        continuation = nil
        onEnd?()
    }

    func markTaken() {
        taken = true
    }

    /// The tab said how it went. Nil when the answer waits for the two-step code.
    func received(_ result: AgentFillResult) -> AgentLoginEnd? {
        self.result = result
        let outcome = Self.outcome(result)
        guard result != .noFields else { return .finished(outcome, code: nil, detail: nil) }
        switch code {
        case .none: return .finished(outcome, code: AgentLoginCode.none, detail: nil)
        case .needsPremium: return .finished(outcome, code: .premiumRequired, detail: nil)
        case .fill:
            if let codeFilled { return .finished(outcome, code: codeFilled ? .filled : .premiumRequired, detail: nil) }
            // Without the form sent, the code page comes when the agent presses the button: it goes in then.
            return result == .submitted ? nil : .finished(outcome, code: .waiting, detail: nil)
        }
    }

    /// The code request after the fill. Nil while the result is still to come.
    func receivedCode(filled: Bool) -> AgentLoginEnd? {
        codeFilled = filled
        guard let result else { return nil }
        return .finished(Self.outcome(result), code: filled ? .filled : .premiumRequired, detail: nil)
    }

    static func outcome(_ result: AgentFillResult) -> AgentLoginOutcome {
        switch result {
        case .filled: return .filled
        case .submitted: return .submitted
        case .noFields: return .noFields
        }
    }
}

extension BrowserBridge {
    /// Where an agent's login would go: the browser named, else Chrome when its extension is connected, else Safari when
    /// its extension is on. In Chrome, the profile in front, or the one used last when Chrome is not the app in front (the
    /// agent's terminal often is). The extension is asked for its tab now and given a moment to answer. Nil when no
    /// extension can fill there.
    func agentLoginTarget(_ name: AgentBrowserName?) async -> AgentLoginTarget? {
        let browser: BridgeBrowser
        switch name {
        case .chrome?: browser = .chrome
        case .safari?: browser = .safari
        case nil:
            if Self.chromeSupported, chromeConnected {
                browser = .chrome
            } else if safariEnabled {
                browser = .safari
            } else {
                return nil
            }
        }
        let peer: BridgePeer
        let link: Int?
        var profile: String?
        switch browser {
        case .chrome:
            guard Self.chromeSupported, let front = state.recent(.chrome) else { return nil }
            peer = front.peer
            link = front.peer.link
            if state.linkCount(.chrome) > 1 { profile = front.certain ? "the profile in front" : "the profile used last" }
        case .safari:
            guard safariEnabled else { return nil }
            peer = BridgePeer(.safari)
            link = nil
        }
        let asked = now()
        poke(browser, link: link)
        let deadline = Date().addingTimeInterval(agentPokeWait)
        while state.report(of: peer, since: asked) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let page: AgentLoginTarget.Page
        if let report = state.report(of: peer, since: asked) {
            page = report.url.map { .url($0) } ?? .notAWebsite
        } else {
            page = .unknown
        }
        return AgentLoginTarget(browser: browser == .chrome ? .chrome : .safari, profile: profile, link: link, page: page)
    }

    /// Hands an approved agent login to the extension: a pending fill bound to the plan's website and connection, then a
    /// poke. Waits for how it went. `entryID` is the account as the list knows it. Cancelling withdraws the fill.
    func agentLogin(_ plan: AgentLoginPlan, entryID: UUID) async -> AgentLoginEnd {
        guard !session.locked else { return .locked }
        let browser: BridgeBrowser = plan.target.browser == .chrome ? .chrome : .safari
        let token = UUID()
        guard var fill = PendingFill(entryID: entryID, browser: browser, website: plan.website, created: now(), link: plan.target.link) else {
            return .finished(.siteMismatch, code: nil, detail: nil)
        }
        fill.agent = AgentFillTicket(token: token, submit: plan.submit)
        // A newer login replaces one still waiting, as a new pick replaces the old.
        agentLogin?.finish(.finished(.timedOut, code: nil, detail: "A newer fill replaced it."))
        let wait = AgentLoginWait(token: token, code: plan.code, submit: plan.submit)
        wait.onEnd = { [weak self, weak wait] in
            guard let self, let wait, self.agentLogin === wait else { return }
            self.agentLogin = nil
        }
        agentLogin = wait
        state.pending.set(fill)
        wait.schedule(after: agentFillLifetime) { [weak self] in self?.agentLoginExpired(token) }
        poke(browser, link: plan.target.link)
        return await withTaskCancellationHandler {
            await wait.wait()
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdrawAgentLogin(token) }
        }
    }

    /// The agent hung up: the fill is withdrawn, so no tab takes it after nobody waits for the answer.
    func withdrawAgentLogin(_ token: UUID) {
        guard let wait = agentLogin, wait.token == token else { return }
        state.pending.withdrawAgentFill(token)
        wait.finish(.finished(.timedOut, code: nil, detail: "The request was withdrawn."))
    }

    private func agentLoginExpired(_ token: UUID) {
        guard let wait = agentLogin, wait.token == token else { return }
        if !wait.taken {
            state.pending.withdrawAgentFill(token)
            wait.finish(.finished(.timedOut, code: nil, detail: nil))
        } else if let result = wait.result {
            // The form was sent and no code field asked within the code's 30 s.
            wait.finish(.finished(AgentLoginWait.outcome(result), code: .notFilled, detail: nil))
        } else {
            // An extension from before `login-result` fills and says nothing more.
            state.pending.withdrawAgentFill(token)
            let code: AgentLoginCode? = wait.code == .needsPremium ? .premiumRequired : wait.code == .none ? AgentLoginCode.none : nil
            wait.finish(.finished(.filled, code: code, detail: "The extension did not say how it went; update PasswordPie's extension."))
        }
    }

    /// What `BridgeState` saw of the agent's fill while answering the extension.
    func agentFillEvent(_ event: AgentFillEvent) {
        guard let wait = agentLogin else { return }
        switch event {
        case .taken(let token):
            guard token == wait.token else { return }
            wait.markTaken()
            wait.schedule(after: agentResultLifetime) { [weak self] in self?.agentLoginExpired(token) }
        case .otherSite(let token, let site):
            guard token == wait.token else { return }
            wait.finish(.finished(.noMatchingTab, code: nil, detail: site.map { "The tab in front is on \($0)." } ?? "The tab in front is not a website."))
        case .result(let token, let raw):
            guard token == wait.token, let result = AgentFillResult(rawValue: raw) else { return }
            if let end = wait.received(result) {
                wait.finish(end)
            } else {
                wait.schedule(after: agentCodeLifetime) { [weak self] in self?.agentLoginExpired(token) }
            }
        case .code(let token, let filled):
            guard token == wait.token, let end = wait.receivedCode(filled: filled) else { return }
            wait.finish(end)
        }
    }
}

/// The browser side of `login` for the broker: the open database's items as the extension fills them, and the bridge.
@MainActor
final class AgentLoginBridge: AgentBrowserLogins {
    private unowned let session: VaultSession
    private unowned let bridge: BrowserBridge

    init(session: VaultSession, bridge: BrowserBridge) {
        self.session = session
        self.bridge = bridge
    }

    func loginTarget(_ browser: AgentBrowserName?) async -> AgentLoginTarget? {
        await bridge.agentLoginTarget(browser)
    }

    func loginOverview(_ item: AgentItem) -> AgentLoginOverview? {
        guard let entry = session.agentEntry(item) else { return nil }
        return AgentLoginOverview(title: entry.title, username: entry.username, websites: entryWebsites(entry))
    }

    func loginWebsite(of item: AgentItem, for page: String?) -> String? {
        guard let entry = session.agentEntry(item) else { return nil }
        if let page { return SiteSuggestions.matchingWebsite(of: entry, pageURL: page) }
        return entryWebsites(entry).first { webURL($0) != nil }
    }

    func loginSite(_ address: String) -> String? {
        BrowserSite(url: address)?.key
    }

    func loginAllows(website: String, on page: String) -> Bool {
        BrowserSite.allowsFill(entryWebsite: website, pageURL: page)
    }

    func loginCodePlan(_ item: AgentItem) -> AgentLoginCodePlan {
        guard let entry = session.agentEntry(item), OneTimeCodes.hasCode(entry) else { return .none }
        // The bridge's own check, the one the page's code request meets: this Mac's Premium, as for people.
        return bridge.codeAllowed() ? .fill : .needsPremium
    }

    func login(_ plan: AgentLoginPlan) async -> AgentLoginEnd {
        guard let listID = session.agentListID(plan.item) else {
            return session.agentVaultLocked ? .locked : .finished(.timedOut, code: nil, detail: "The item is no longer there.")
        }
        return await bridge.agentLogin(plan, entryID: listID)
    }
}
#endif
