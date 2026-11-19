import Foundation

// Website login for agents (`passwordpie login`): the app fills an item's sign-in form in the owner's browser, through the
// browser extension, after the owner approves. The agent hears how it went and the item's overview, never the password or
// the code. See docs/AGENTS.md, "Website login".

/// The browsers the extension fills in. Which one a login goes to is the app's to find out; the agent may only name one.
public enum AgentBrowserName: String, Codable, Sendable, CaseIterable {
    case chrome
    case safari

    /// "Google Chrome", "Safari".
    public var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        }
    }
}

/// How a login ended. `filled` and `submitted` are success; the others say why nothing was signed in.
public enum AgentLoginOutcome: String, Codable, Sendable, CaseIterable {
    /// The username and password went into the page; the form was not sent.
    case filled
    /// Filled, and the form's own button was pressed.
    case submitted
    /// The tab in front of that browser is not on the site (the agent's tab is in the background, or another page is
    /// open), or no extension speaks for the browser. PasswordPie never switches tabs.
    case noMatchingTab = "no-matching-tab"
    /// The site asked for is not one of the item's websites. Nothing was filled and nobody was asked.
    case siteMismatch = "site-mismatch"
    /// No tab of that browser took the fill within 30 seconds.
    case timedOut = "timed-out"
    /// The tab took the fill, but no password field appeared within 30 seconds.
    case noFields = "no-fields"

    public var succeeded: Bool { self == .filled || self == .submitted }

    /// The tool's exit code: 0 for success, else one past PasswordPie's refusals (docs/AGENTS.md, "Exit codes").
    public var exitCode: Int32 {
        switch self {
        case .filled, .submitted: return 0
        case .noMatchingTab: return 74
        case .siteMismatch: return 75
        case .timedOut: return 76
        case .noFields: return 77
        }
    }

    /// As the activity log shows it.
    public var activityOutcome: AgentOutcome {
        switch self {
        case .filled: return .filled
        case .submitted: return .submitted
        case .noMatchingTab: return .noMatchingTab
        case .siteMismatch: return .siteMismatch
        case .timedOut: return .fillTimedOut
        case .noFields: return .noFields
        }
    }
}

/// What became of the item's two-step code.
public enum AgentLoginCode: String, Codable, Sendable {
    /// The item has none.
    case none
    /// The code went into the site's code field.
    case filled
    /// It will go in if the site shows a code field within 30 seconds of the fill: the form was not sent, or the request
    /// ended before the site asked.
    case waiting
    /// No code field appeared in time.
    case notFilled = "not-filled"
    /// The item has a code, and this Mac has no PasswordPie Premium: it is not filled, as for people.
    case premiumRequired = "premium-required"
}

/// The item as the agent may know it after a login: never the password, never the code.
public struct AgentLoginOverview: Codable, Equatable, Sendable {
    public var title: String
    public var username: String
    public var websites: [String]

    public init(title: String, username: String, websites: [String]) {
        self.title = title
        self.username = username
        self.websites = websites
    }
}

/// The `login` answer.
public struct AgentLoginAnswer: Codable, Equatable, Sendable {
    public var outcome: AgentLoginOutcome
    public var item: AgentLoginOverview?
    /// The site the login was for: its registrable domain, as "github.com".
    public var site: String?
    /// "Google Chrome", "Safari".
    public var browser: String?
    public var code: AgentLoginCode?
    /// More about a failure, from the app ("The tab in front is on another site.").
    public var detail: String?

    public init(outcome: AgentLoginOutcome, item: AgentLoginOverview?, site: String?, browser: String?, code: AgentLoginCode?, detail: String? = nil) {
        self.outcome = outcome
        self.item = item
        self.site = site
        self.browser = browser
        self.code = code
        self.detail = detail
    }

    /// The `detail` of a `no-matching-tab` answered because no extension speaks for the browser. The tool's line reads
    /// it back (`noExtensionStart`): the app and the tool are one bundle, built from this file.
    public static func noExtension(in browser: String?) -> String {
        "\(noExtensionStart) in \(browser ?? "Google Chrome or Safari")."
    }

    static let noExtensionStart = "PasswordPie's extension is not connected"

    /// The tool's one line. Success goes to standard output; anything else to standard error, saying what to do, and
    /// ending, as every refusal does, with `AgentConstants.pasteWarning`.
    public var line: String { line(mcp: false) }

    /// For the MCP tool: what to do in the tools' terms, and a failure ends with `AgentConstants.mcpGuidance`.
    public func line(mcp: Bool) -> String {
        let listHint = mcp ? "passwordpie_list" : "`passwordpie list`"
        let offerHint = mcp ? "passwordpie_login with url" : "`passwordpie login --url URL`"
        let account = item.map { $0.username.isEmpty ? $0.title : "\($0.title) (\($0.username))" } ?? "the account"
        let place = [site.map { " on \($0)" }, browser.map { " in \($0)" }].compactMap { $0 }.joined()
        var text: String
        switch outcome {
        case .submitted: text = "PasswordPie: filled \(account)\(place) and pressed the form's sign-in button. Check the page to see whether the site accepted it."
        case .filled: text = "PasswordPie: filled \(account)\(place). The form was not sent; press the site's sign-in button."
        case .noMatchingTab where detail?.hasPrefix(Self.noExtensionStart) == true:
            // No extension speaks for the browser: there is no tab to bring forward, and only the owner can turn it on.
            return AgentRefusal.oneLine("PasswordPie: nothing was filled. \(detail ?? "") Ask the owner to turn it on (PasswordPie > Preferences > Browsers), then try again. "
                + (mcp ? AgentConstants.mcpGuidance : AgentConstants.pasteWarning))
        case .noMatchingTab:
            text = "PasswordPie: the tab in front\(browser.map { " in \($0)" } ?? "") is not on \(site ?? "the site"); nothing was filled. Bring the sign-in page's tab to the front (PasswordPie does not switch tabs), then try again."
        case .siteMismatch:
            text = "PasswordPie: \(account) is not for \(site ?? "the site of the tab in front"); nothing was filled. Use an item whose website is this site (\(listHint)), or \(offerHint) to be offered one."
        case .timedOut:
            text = "PasswordPie: no tab\(browser.map { " of \($0)" } ?? "") took the fill within 30 seconds. Check that PasswordPie's extension is on in that browser and profile, then try again."
        case .noFields:
            text = "PasswordPie: the page\(place) showed no password field within 30 seconds; nothing was signed in. Open the site's sign-in page, then try again."
        }
        if let detail, !detail.isEmpty { text += " " + detail }
        switch code {
        case .premiumRequired?: text += " Two-step code not filled: needs PasswordPie Premium."
        case .filled?: text += " The two-step code was filled too."
        case .waiting?: text += " The two-step code goes in if the site asks for it within 30 seconds."
        case .notFilled?: text += " No two-step code field appeared, so the code was not filled."
        case .none?, nil: break
        }
        return AgentRefusal.oneLine(outcome.succeeded ? text : text + " " + (mcp ? AgentConstants.mcpGuidance : AgentConstants.pasteWarning))
    }
}

/// What the app's browser side tells the broker about where a login would go.
public struct AgentLoginTarget: Equatable, Sendable {
    public enum Page: Equatable, Sendable {
        /// No report from the tab in front just now (the extension may be asleep).
        case unknown
        /// The tab in front shows something that is not a website (a new tab page, settings).
        case notAWebsite
        /// The origin of the tab in front.
        case url(String)
    }

    public var browser: AgentBrowserName
    /// "the profile in use", for the prompt. Chrome's profile names are not known to the extension.
    public var profile: String?
    /// The bridge connection the fill is for: in Chrome, one per profile. Nil when any may take it.
    public var link: Int?
    public var page: Page

    public init(browser: AgentBrowserName, profile: String?, link: Int?, page: Page) {
        self.browser = browser
        self.profile = profile
        self.link = link
        self.page = page
    }

    /// "Google Chrome, the profile in use".
    public var text: String {
        [browser.displayName, profile].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the app will do with the item's two-step code, decided before the prompt.
public enum AgentLoginCodePlan: Equatable, Sendable {
    case none
    /// The item has a code and this Mac has Premium.
    case fill
    /// The item has a code; without Premium it is not filled.
    case needsPremium
}

/// An approved login, for the browser side to carry out.
public struct AgentLoginPlan: Equatable, Sendable {
    public var item: AgentItem
    /// The item's website the fill is bound to. The tab must be on its site.
    public var website: String
    public var target: AgentLoginTarget
    public var submit: Bool
    public var code: AgentLoginCodePlan

    public init(item: AgentItem, website: String, target: AgentLoginTarget, submit: Bool, code: AgentLoginCodePlan) {
        self.item = item
        self.website = website
        self.target = target
        self.submit = submit
        self.code = code
    }
}

public enum AgentLoginEnd: Equatable, Sendable {
    case finished(AgentLoginOutcome, code: AgentLoginCode?, detail: String?)
    /// The vault locked before the login was done: nothing more is handed out.
    case locked
}

/// The app's browser side, as the broker sees it. The app implements it with the browser bridge and the open database;
/// tests stand in a fake. Site rules (registrable domain, no downgrade) live behind it, with the extension's.
@MainActor
public protocol AgentBrowserLogins: AnyObject {
    /// Where a login would go now: the browser named, else the one whose extension is connected, its profile in use, and
    /// the page its tab in front shows (asked for afresh). Nil when no extension can fill there.
    func loginTarget(_ browser: AgentBrowserName?) async -> AgentLoginTarget?
    /// The item's title, username and websites. Nil when it is no longer there.
    func loginOverview(_ item: AgentItem) -> AgentLoginOverview?
    /// The item's website that may fill `page` (same site, no downgrade), or with no page its main website. Nil when none.
    func loginWebsite(of item: AgentItem, for page: String?) -> String?
    /// The registrable domain of a web address ("github.com"), nil when it is not one.
    func loginSite(_ address: String) -> String?
    /// True when `website` may fill `page`: the same site, no downgrade.
    func loginAllows(website: String, on page: String) -> Bool
    func loginCodePlan(_ item: AgentItem) -> AgentLoginCodePlan
    /// Hands the approved fill to the extension and waits for how it went. Cancelling the task withdraws the fill.
    func login(_ plan: AgentLoginPlan) async -> AgentLoginEnd
}
