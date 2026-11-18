#if PP_DIRECT
import Darwin
import Foundation
import PasswordPieAgent

/// Agent access in the app: the switch, `agent.sock` (only while the switch is on), the broker, the approval windows and
/// the activity log. See docs/AGENTS.md and "Agents" in docs/UX.md.
@MainActor
final class AgentAccess: ObservableObject {
    @Published private(set) var enabled: Bool
    /// Why the socket could not be opened, for the Agents pane.
    @Published private(set) var problem: String?
    /// The newest activity first.
    @Published private(set) var activity: [AgentActivityRecord] = []
    /// What the command-line link button last did.
    @Published private(set) var linkStatus: String?
    /// The standing permissions in force on this Mac, for the Agents pane. Empty while locked.
    @Published private(set) var standing: [AgentGrant] = []
    /// The database holds standing permissions of any Mac: Revoke All has something to remove.
    @Published private(set) var anyGrants = false

    let session: VaultSession
    let broker: VaultBroker
    let approver: AgentApprovalController
    let grants: StandingPermissions
    /// A request was let through by a standing permission: the menu-bar pie shows its dot.
    var onSilentUse: (() -> Void)?
    private let log: AgentActivityLog
    private let server: AgentServer
    private let defaults: UserDefaults
    private let socketPath: String?
    /// Where `passwordpie` is linked on the PATH.
    let linkFolder: URL

    /// Called when a request waits for an unlock: the app shows its lock screen.
    var onNeedsUnlock: (() -> Void)? {
        get { broker.onNeedsUnlock }
        set { broker.onNeedsUnlock = newValue }
    }

    /// Tests pass a socket under /tmp, a log in a temporary folder, their own defaults, approver, Premium check and server
    /// peer check.
    init(
        session: VaultSession,
        defaults: UserDefaults = .standard,
        socketPath: String? = nil,
        logURL: URL = AgentActivityLog.defaultURL,
        approver: AgentApprovalController? = nil,
        hasPremium: @escaping @MainActor () -> Bool = appHasPremium,
        mac: String = AgentMacIdentity.current,
        peerCheck: (@Sendable (Int32) -> Bool)? = nil,
        linkFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    ) {
        self.session = session
        self.defaults = defaults
        self.socketPath = socketPath
        self.linkFolder = linkFolder
        enabled = defaults.bool(forKey: AgentConstants.enabledKey)
        let log = AgentActivityLog(url: logURL)
        self.log = log
        let approver = approver ?? Self.debugApprover() ?? AgentApprovalController()
        self.approver = approver
        let relay = ActivityRelay(log: log)
        // Kept in the database's custom data; Premium is this app's own check, never anything in a request.
        let grants = StandingPermissions(
            mac: mac,
            hasPremium: { hasPremium() },
            read: { [weak session] in session?.agentGrants },
            write: { [weak session] edit, done in
                guard let session else { return done(false) }
                session.changeAgentGrants(edit, then: done)
            }
        )
        self.grants = grants
        let broker = VaultBroker(vault: session, approver: approver, grants: grants, activity: relay) { false }
        self.broker = broker
        server = AgentServer(
            handler: { request, caller in await broker.handle(request, from: caller) },
            peerCheck: peerCheck ?? AgentServer.isPasswordPieCLI
        )
        broker.isEnabled = { [weak self] in self?.enabled ?? false }
        broker.onWaitingChanged = { [weak session] waiting in session?.agentWaitingLine = AgentWaiting.lockScreenLine(waiting) }
        relay.appended = { [weak self] record in
            self?.activity.insert(record, at: 0)
            if record.outcome == .allowedByGrant { self?.onSilentUse?() }
        }
        grants.onChange = { [weak self] in self?.refreshStanding() }
        activity = log.records().reversed()
        session.agentAccessOn = enabled
        refreshStanding()
    }

    /// Debug builds only: `PASSWORDPIE_AGENT_APPROVE=allow|deny` shows the window, then answers it after 2 seconds without
    /// Touch ID, so the whole path can be run and screenshotted on a Mac nobody is sitting at. Release builds ignore it.
    private static func debugApprover() -> AgentApprovalController? {
        #if DEBUG
        guard let answer = ProcessInfo.processInfo.environment["PASSWORDPIE_AGENT_APPROVE"] else { return nil }
        return AgentApprovalController(confirmation: DebugConfirmation(), show: { model in
            let close = AgentApprovalController.window(for: model)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if answer == "allow" { model.allow() } else { model.deny() } }
            return close
        })
        #else
        return nil
        #endif
    }

    /// The browser bridge an approved login waits in; turning access off withdraws it there.
    private weak var bridge: BrowserBridge?

    /// `passwordpie login`: fills through the browser extension (docs/AGENTS.md, "Website login").
    func attachBrowser(_ bridge: BrowserBridge) {
        self.bridge = bridge
        broker.logins = AgentLoginBridge(session: session, bridge: bridge)
    }

    /// At launch: open the socket when the switch is on.
    func start() {
        if enabled { openSocket() }
    }

    /// The switch in Preferences > Agents. Off closes the socket at once.
    func setEnabled(_ on: Bool) {
        enabled = on
        session.agentAccessOn = on
        defaults.set(on, forKey: AgentConstants.enabledKey)
        if on {
            openSocket()
        } else {
            server.stop()
            approver.withdrawAll()
            bridge?.withdrawAgentLoginForAccessOff()
            problem = nil
            // "This agent session" permissions end; the others stay and do nothing until it is on again.
            grants.endSessions()
        }
    }

    var isListening: Bool { server.isRunning }

    /// The vault locked or unlocked. Locking withdraws every prompt: nothing is handed out while locked.
    func vaultStateChanged(locked: Bool) {
        if locked { approver.withdrawAll() } else { grants.unlocked() }
        broker.vaultStateChanged()
        refreshStanding()
    }

    // MARK: Standing permissions

    /// Reads the standing permissions in force again, for the pane.
    func refreshStanding() {
        standing = grants.inForce.sorted { $0.created > $1.created }
        anyGrants = !(session.agentGrants?.isEmpty ?? true)
    }

    /// Premium is here, so the standing permissions count.
    var premiumForStanding: Bool { grants.hasPremium() }

    func revoke(_ grant: AgentGrant) {
        grants.revoke(grant.id)
    }

    /// Preferences > Agents > Revoke All, and the gear menu's Revoke Agent Permissions.
    func revokeAll() {
        grants.revokeAll()
    }

    /// "until 26 Nov, 16:02", or "until Claude Code quits" for a session permission.
    static func endText(_ grant: AgentGrant) -> String {
        if grant.session != nil { return "until \(grant.agentName) quits (at most 12 hours)" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM, HH:mm")
        return "until \(formatter.string(from: grant.ends))"
    }

    func stop() {
        server.stop()
    }

    private func openSocket() {
        guard !server.isRunning else { return }
        do {
            try server.start(path: socketPath)
            problem = nil
        } catch {
            problem = "Agents cannot reach PasswordPie: another copy of PasswordPie may be running."
        }
    }

    // MARK: The command-line tool

    /// `PasswordPie.app/Contents/Helpers/passwordpie`, when this is an app bundle that has it.
    var toolURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(AgentConstants.toolPathInBundle)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var linkURL: URL { linkFolder.appendingPathComponent(AgentConstants.toolName) }

    /// The lines to paste into Claude Code, Codex and Cursor to add `passwordpie mcp`. The app never edits their files.
    var mcpHosts: [AgentMCPSetup.Host] {
        AgentMCPSetup.hosts(tool: toolURL?.path ?? "/Applications/PasswordPie.app/\(AgentConstants.toolPathInBundle)")
    }

    /// The exact command the button runs, shown beside it, each path quoted for the shell.
    var linkCommand: String {
        let tool = toolURL?.path ?? "/Applications/PasswordPie.app/\(AgentConstants.toolPathInBundle)"
        return "mkdir -p \(Self.shellQuoted(linkFolder.path)) && ln -sf \(Self.shellQuoted(tool)) \(Self.shellQuoted(linkURL.path))"
    }

    /// `~/rest` stays expandable; anything that needs it is single-quoted, with a quote in it written as `'\''`.
    static func shellQuoted(_ path: String) -> String {
        let short = tilde(path)
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+,:@~")
        if short.unicodeScalars.allSatisfy(safe.contains) { return short }
        var prefix = ""
        var rest = short
        if short.hasPrefix("~/") {
            prefix = "~/"
            rest = String(short.dropFirst(2))
        }
        return prefix + "'" + rest.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when the link exists and points at this app's tool.
    var linkIsCurrent: Bool {
        guard let tool = toolURL, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else { return false }
        return URL(fileURLWithPath: target).standardizedFileURL.path == tool.standardizedFileURL.path
    }

    /// Links `passwordpie` into `~/.local/bin`: a folder of this user, so no administrator password. An existing file that
    /// is not a link is left alone.
    func createLink() {
        guard let tool = toolURL else {
            linkStatus = "This copy of PasswordPie has no command-line tool."
            return
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: linkFolder, withIntermediateDirectories: true)
            if (try? manager.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
                try manager.removeItem(at: linkURL)
            } else if manager.fileExists(atPath: linkURL.path) {
                linkStatus = "\(Self.tilde(linkURL.path)) already exists and is not a link. Remove it first."
                return
            }
            try manager.createSymbolicLink(at: linkURL, withDestinationURL: tool)
            linkStatus = "Linked. If `passwordpie` is not found, add \(Self.tilde(linkFolder.path)) to your PATH."
        } catch {
            linkStatus = "Could not create the link in \(Self.tilde(linkFolder.path))."
        }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Activity

    /// The records whose agent, project, command or items contain `filter`, ignoring case.
    func activity(matching filter: String) -> [AgentActivityRecord] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return activity }
        return activity.filter { record in
            ([record.agent, record.project, record.command ?? ""] + record.items).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
}

#if DEBUG
@MainActor
private final class DebugConfirmation: OwnerConfirmation {
    func confirm(reason: String) async -> Bool { true }
    func cancel() {}
}
#endif

/// Writes to the activity log and tells the Agents pane.
private final class ActivityRelay: AgentActivityLogging {
    let log: AgentActivityLog
    var appended: ((AgentActivityRecord) -> Void)?

    init(log: AgentActivityLog) {
        self.log = log
    }

    func append(_ record: AgentActivityRecord) {
        log.append(record)
        appended?(record)
    }
}
#endif
