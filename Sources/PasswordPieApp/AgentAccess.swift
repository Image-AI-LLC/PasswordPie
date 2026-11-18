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

    let session: VaultSession
    let broker: VaultBroker
    let approver: AgentApprovalController
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

    /// Tests pass a socket under /tmp, a log in a temporary folder, their own defaults, approver and server peer check.
    init(
        session: VaultSession,
        defaults: UserDefaults = .standard,
        socketPath: String? = nil,
        logURL: URL = AgentActivityLog.defaultURL,
        approver: AgentApprovalController? = nil,
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
        // Item B replaces `NoAgentGrants` with the standing permissions.
        let broker = VaultBroker(vault: session, approver: approver, grants: NoAgentGrants(), activity: relay) { false }
        self.broker = broker
        server = AgentServer(
            handler: { request, caller in await broker.handle(request, from: caller) },
            peerCheck: peerCheck ?? AgentServer.isPasswordPieCLI
        )
        broker.isEnabled = { [weak self] in self?.enabled ?? false }
        broker.onWaitingChanged = { [weak session] waiting in session?.agentWaitingLine = AgentWaiting.lockScreenLine(waiting) }
        relay.appended = { [weak self] record in self?.activity.insert(record, at: 0) }
        activity = log.records().reversed()
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

    /// At launch: open the socket when the switch is on.
    func start() {
        if enabled { openSocket() }
    }

    /// The switch in Preferences > Agents. Off closes the socket at once.
    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: AgentConstants.enabledKey)
        if on {
            openSocket()
        } else {
            server.stop()
            approver.withdrawAll()
            problem = nil
        }
    }

    var isListening: Bool { server.isRunning }

    /// The vault locked or unlocked. Locking withdraws every prompt: nothing is handed out while locked.
    func vaultStateChanged(locked: Bool) {
        if locked { approver.withdrawAll() }
        broker.vaultStateChanged()
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

    /// The exact command the button runs, shown beside it.
    var linkCommand: String {
        let tool = toolURL?.path ?? "/Applications/PasswordPie.app/\(AgentConstants.toolPathInBundle)"
        return "mkdir -p \(Self.tilde(linkFolder.path)) && ln -sf '\(tool)' \(Self.tilde(linkURL.path))"
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
