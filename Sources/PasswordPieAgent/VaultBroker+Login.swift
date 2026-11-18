import Foundation

// `login`: fill an item's sign-in form in the owner's browser. The broker resolves the item among shared ones, binds the fill
// to one of the item's websites, refuses before anyone is asked when the site or the tab in front does not match, asks the
// owner (Allow Once, Touch ID), then hands the fill to the browser side and waits for how it went. The answer is the
// outcome and the item's overview; no value ever goes back. See docs/AGENTS.md, "Website login".

extension VaultBroker {
    func login(_ request: AgentRequest, caller: AgentCaller) async -> AgentResponse {
        let asked = request.secrets ?? []
        let typed = asked.first?.ref ?? request.url ?? ""
        func usage(_ detail: String) -> AgentResponse {
            log(request, caller: caller, outcome: .usage, items: typed.isEmpty ? [] : [typed], delivery: [])
            var refusal = AgentResponse.error(.usage, id: request.id, ref: asked.first?.ref)
            refusal.detail = detail
            return refusal
        }
        func refuse(_ code: AgentErrorCode, outcome: AgentOutcome, items: [String], refs: [String]? = nil) -> AgentResponse {
            log(request, caller: caller, outcome: outcome, items: items, delivery: [])
            return .error(code, id: request.id, ref: code == .notAvailable && asked.isEmpty ? request.url : asked.first?.ref, refs: refs)
        }

        guard let logins else { return usage("This copy of PasswordPie cannot fill a browser.") }
        guard asked.count <= 1, asked.allSatisfy({ $0.delivery == .fill }) else { return usage("login takes one item.") }
        var reference: AgentReference?
        if let ref = asked.first?.ref {
            guard let parsed = try? AgentReference(ref) else { return usage("\(ref) is not a reference (pp://folder/item).") }
            reference = parsed
        }
        let url = request.url.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard reference != nil || url != nil else { return usage("login needs an item reference, or --url to be offered the items for a site.") }
        if let url, logins.loginSite(url) == nil { return usage("\(url) is not a web address.") }
        var browser: AgentBrowserName?
        if let name = request.browser {
            guard let named = AgentBrowserName(rawValue: name) else { return usage("--browser takes chrome or safari.") }
            browser = named
        }
        if limiter.isBlocked(caller.sessionKey, now: clock()) { return refuse(.tooManyRequests, outcome: .tooManyRequests, items: [typed]) }
        guard await waitForUnlock(request, caller: caller, count: 1) else { return refuse(.locked, outcome: .locked, items: [typed]) }

        // Which shared items: the one named, or every one with a website on the page's site.
        let shared = vault.agentSharedItems()
        var candidates: [AgentItem]
        if let reference {
            switch AgentResolver.resolve(reference, in: shared) {
            case .found(let item, .password):
                candidates = [item]
            case .found:
                return usage("login takes an item, not one of its fields: pp://folder/item.")
            case .notAvailable:
                return refuse(.notAvailable, outcome: .notAvailable, items: [typed])
            case .ambiguous(let refs):
                return refuse(.ambiguous, outcome: .ambiguous, items: [typed], refs: refs)
            }
        } else {
            candidates = shared.filter { logins.loginWebsite(of: $0, for: url) != nil }
            guard !candidates.isEmpty else { return refuse(.notAvailable, outcome: .notAvailable, items: [typed]) }
        }
        let labels = candidates.map { Self.loginLabel($0) }

        // Where it would go. Nothing is asked when no extension can fill there, or when the site or the tab in front is
        // already known not to match. Such an answer carries no overview (the username and websites come only with an
        // approval) and never names the site of the owner's tab: without a prompt it must not become a way to watch
        // what the owner browses. `site` is only ever the one the agent itself asked for.
        func early(_ outcome: AgentLoginOutcome, site: String?, browser: String?, detail: String? = nil) -> AgentResponse {
            log(request, caller: caller, outcome: outcome.activityOutcome, items: labels, delivery: [])
            return loginAnswer(request, AgentLoginAnswer(
                outcome: outcome,
                item: nil,
                site: site,
                browser: browser,
                code: nil,
                detail: detail
            ))
        }
        guard let target = await logins.loginTarget(browser) else {
            let which = browser?.displayName ?? "Google Chrome or Safari"
            return early(.noMatchingTab, site: url.flatMap(logins.loginSite), browser: browser?.displayName,
                         detail: "PasswordPie's extension is not connected in \(which).")
        }
        guard !vault.agentVaultLocked else { return refuse(.locked, outcome: .locked, items: labels) }
        let pageNotAWebsite = "The tab in front is not a website."
        let pageElsewhere = "The tab in front is on another site."
        var websites: [String] = []
        if let url {
            for candidate in candidates {
                guard let website = logins.loginWebsite(of: candidate, for: url) else {
                    return early(.siteMismatch, site: logins.loginSite(url), browser: target.browser.displayName)
                }
                websites.append(website)
            }
            switch target.page {
            case .unknown:
                break
            case .notAWebsite:
                return early(.noMatchingTab, site: logins.loginSite(url), browser: target.browser.displayName, detail: pageNotAWebsite)
            case .url(let page):
                if !websites.contains(where: { logins.loginAllows(website: $0, on: page) }) {
                    return early(.noMatchingTab, site: logins.loginSite(url), browser: target.browser.displayName, detail: pageElsewhere)
                }
            }
        } else {
            let item = candidates[0]
            switch target.page {
            case .unknown:
                guard let website = logins.loginWebsite(of: item, for: nil) else {
                    return early(.siteMismatch, site: nil, browser: target.browser.displayName, detail: "The item lists no website.")
                }
                websites = [website]
            case .notAWebsite:
                return early(.noMatchingTab, site: nil, browser: target.browser.displayName, detail: pageNotAWebsite)
            case .url(let page):
                guard let website = logins.loginWebsite(of: item, for: page) else {
                    return early(.siteMismatch, site: nil, browser: target.browser.displayName, detail: pageElsewhere)
                }
                websites = [website]
            }
        }
        let site = logins.loginSite(websites[0]) ?? websites[0]
        let codes = candidates.map { logins.loginCodePlan($0) }

        // One prompt at a time per agent session; a second request waits behind it.
        await acquire(caller.sessionKey)
        defer { release(caller.sessionKey) }
        if Task.isCancelled { return refuse(.timeout, outcome: .timedOut, items: labels) }
        if limiter.isBlocked(caller.sessionKey, now: clock()) { return refuse(.tooManyRequests, outcome: .tooManyRequests, items: labels) }
        guard !vault.agentVaultLocked else { return refuse(.locked, outcome: .locked, items: labels) }
        let rows = candidates.indices.map { index in
            AgentApprovalRow(
                title: candidates[index].title,
                folder: candidates[index].folderText,
                field: "username and password",
                delivery: .fill,
                name: nil,
                tooShortToMask: false,
                username: logins.loginOverview(candidates[index])?.username,
                note: Self.codeNote(codes[index])
            )
        }
        let prompt = AgentApprovalPrompt(
            id: UUID(),
            kind: .login,
            raw: false,
            agent: caller.agentName,
            signature: caller.signatureText,
            agentPID: caller.agent?.pid,
            startedIn: Self.startedIn(caller),
            command: nil,
            program: nil,
            project: caller.project,
            reason: request.reason.flatMap { $0.isEmpty ? nil : $0 },
            rows: rows,
            site: site,
            browser: target.text,
            submit: request.submit == true,
            via: Self.viaText(request)
        )
        let delivery = ["fill \(target.browser.displayName) \(site)"]
        switch await ask(prompt) {
        case .allow(let selected) where selected.count == 1 && candidates.indices.contains(selected.first ?? -1):
            let index = selected.first ?? 0
            let item = candidates[index]
            guard !vault.agentVaultLocked else { return refuse(.locked, outcome: .locked, items: [labels[index]]) }
            // Still shared, and still listing that website, after the wait.
            guard vault.agentSharedItems().contains(where: { $0.id == item.id }), logins.loginWebsite(of: item, for: websites[index]) != nil else {
                return refuse(.notAvailable, outcome: .notAvailable, items: [labels[index]])
            }
            // Agent access turned off while the window was up: nothing is filled.
            guard isEnabled() else { return refuse(.accessOff, outcome: .accessOff, items: [labels[index]]) }
            let plan = AgentLoginPlan(item: item, website: websites[index], target: target, submit: request.submit == true, code: codes[index])
            let end = await logins.login(plan)
            // Withdrawn because access was turned off before any tab took it. A fill a tab took keeps its outcome.
            if case .finished(.timedOut, _, _) = end, !isEnabled() {
                return refuse(.accessOff, outcome: .accessOff, items: [labels[index]])
            }
            switch end {
            case .locked:
                return refuse(.locked, outcome: .locked, items: [labels[index]])
            case .finished(let outcome, let code, let detail):
                log(request, caller: caller, outcome: outcome.activityOutcome, items: [labels[index]], delivery: delivery)
                var answer = loginAnswer(request, AgentLoginAnswer(
                    outcome: outcome,
                    item: logins.loginOverview(item),
                    site: site,
                    browser: target.browser.displayName,
                    code: code,
                    detail: detail
                ))
                answer.by = "once"
                return answer
            }
        case .allow, .deny:
            limiter.recordDenial(caller.sessionKey, now: clock())
            log(request, caller: caller, outcome: .denied, items: labels, delivery: delivery)
            return .error(.denied, id: request.id)
        case .dismissed:
            let locked = vault.agentVaultLocked
            log(request, caller: caller, outcome: locked ? .locked : .timedOut, items: labels, delivery: delivery)
            return .error(locked ? .locked : .timeout, id: request.id)
        }
    }

    private func loginAnswer(_ request: AgentRequest, _ login: AgentLoginAnswer) -> AgentResponse {
        var answer = AgentResponse(type: AgentRequestKind.login.rawValue, id: request.id)
        answer.login = login
        return answer
    }

    /// For the activity log: "Web/GitHub › login".
    static func loginLabel(_ item: AgentItem) -> String {
        (item.folder.isEmpty ? item.title : item.folderText + "/" + item.title) + " › login"
    }

    /// The prompt's line about the two-step code, when the item has one.
    static func codeNote(_ plan: AgentLoginCodePlan) -> String? {
        switch plan {
        case .none: return nil
        case .fill: return "The two-step code is filled too, when the site asks for it."
        case .needsPremium: return "Two-step code not filled: needs PasswordPie Premium."
        }
    }
}
