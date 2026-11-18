#if PP_DIRECT
import AppKit
import LocalAuthentication
import PasswordPieAgent
import SwiftUI

/// Confirms an Allow at the Mac: Touch ID, or the login password where there is none. Software can click a button in
/// another app's window; it cannot touch the sensor. A protocol so tests stand in an answer.
@MainActor
protocol OwnerConfirmation: AnyObject {
    func confirm(reason: String) async -> Bool
    /// The prompt went away: a Touch ID sheet still up for it closes.
    func cancel()
}

@MainActor
final class SystemOwnerConfirmation: OwnerConfirmation {
    private var context: LAContext?

    func confirm(reason: String) async -> Bool {
        let context = LAContext()
        self.context = context
        context.localizedFallbackTitle = "Use Password…"
        // Separate from unlocking the vault with Touch ID, and from its 7-day rule.
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

/// One prompt: what the agent asks for, which rows the owner keeps ticked, and the answer. See "Approving an agent's
/// request" in docs/UX.md.
@MainActor
final class AgentApprovalModel: ObservableObject {
    let prompt: AgentApprovalPrompt
    @Published var ticked: Set<Int>
    @Published private(set) var confirming = false
    @Published private(set) var notConfirmed = false
    private let confirmation: OwnerConfirmation
    private var finish: ((AgentApprovalDecision) -> Void)?

    var id: UUID { prompt.id }

    init(prompt: AgentApprovalPrompt, confirmation: OwnerConfirmation, finish: @escaping (AgentApprovalDecision) -> Void) {
        self.prompt = prompt
        self.confirmation = confirmation
        self.finish = finish
        ticked = Set(prompt.rows.indices)
    }

    var answered: Bool { finish == nil }

    /// "Claude Code wants to use 2 secrets" / "… wants to see 1 secret".
    var title: String {
        let count = prompt.rows.count == 1 ? "1 secret" : "\(prompt.rows.count) secrets"
        return "\(prompt.agent) wants to \(prompt.raw ? "see" : "use") \(count)"
    }

    var allowTitle: String { prompt.raw ? "Show to Agent" : "Allow Once" }

    var canAllow: Bool { !ticked.isEmpty && !confirming }

    /// "Claude Code, signed by Anthropic PBC, started in Terminal (pid 4182)".
    var agentLine: String {
        var line = "\(prompt.agent), \(prompt.signature)"
        if let startedIn = prompt.startedIn { line += ", started in \(startedIn)" }
        if let pid = prompt.agentPID { line += "   (pid \(pid))" }
        return line
    }

    func deliveryText(_ row: AgentApprovalRow) -> String {
        switch row.delivery {
        case .env: return "environment variable \(row.name ?? "")"
        case .file: return "a file for the command, path in $\(row.name ?? "")"
        case .stdin: return "the command's standard input"
        case .shown: return "shown to the agent"
        }
    }

    static let rawWarning = "The agent will see the value. It stays in the conversation, and in the model provider's records if the model is hosted."

    func toggle(_ index: Int) {
        guard !confirming else { return }
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }

    func deny() {
        resolve(.deny)
    }

    /// Asks for Touch ID (or the login password) first. Nothing is allowed without it.
    func allow() {
        guard canAllow else { return }
        confirming = true
        notConfirmed = false
        let rows = ticked
        let reason = prompt.raw ? "show a secret to \(prompt.agent)" : "let \(prompt.agent) use \(rows.count == 1 ? "1 secret" : "\(rows.count) secrets")"
        Task { @MainActor in
            let confirmed = await confirmation.confirm(reason: reason)
            confirming = false
            guard !answered else { return }
            if confirmed {
                resolve(.allow(rows))
            } else {
                notConfirmed = true
            }
        }
    }

    /// The broker withdrew it, or the vault locked.
    func dismiss() {
        if confirming { confirmation.cancel() }
        resolve(.dismissed)
    }

    private func resolve(_ decision: AgentApprovalDecision) {
        guard let finish else { return }
        self.finish = nil
        finish(decision)
    }
}

/// Shows approval windows over whatever is in front, one per prompt, drawn by PasswordPie itself.
@MainActor
final class AgentApprovalController: AgentApprover {
    private let makeConfirmation: () -> OwnerConfirmation
    /// Puts a model on screen and returns how to take it away. Tests pass one that shows nothing.
    private let show: (AgentApprovalModel) -> () -> Void
    private(set) var open: [UUID: (model: AgentApprovalModel, close: () -> Void)] = [:]
    /// The newest prompt, for tests and the debug status file.
    var onPresent: ((AgentApprovalModel) -> Void)?

    init(confirmation: OwnerConfirmation? = nil, show: ((AgentApprovalModel) -> () -> Void)? = nil) {
        makeConfirmation = { confirmation ?? SystemOwnerConfirmation() }
        self.show = show ?? AgentApprovalController.window(for:)
    }

    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        await withCheckedContinuation { continuation in
            // Each prompt its own confirmation, so withdrawing one closes only its own Touch ID sheet.
        let model = AgentApprovalModel(prompt: prompt, confirmation: makeConfirmation()) { [weak self] decision in
                self?.open.removeValue(forKey: prompt.id)?.close()
                continuation.resume(returning: decision)
            }
            open[prompt.id] = (model, show(model))
            onPresent?(model)
        }
    }

    func withdraw(_ id: UUID) {
        open[id]?.model.dismiss()
    }

    /// The vault locked: nothing is handed out, so no prompt stays.
    func withdrawAll() {
        for entry in open.values { entry.model.dismiss() }
    }

    static func window(for model: AgentApprovalModel) -> () -> Void {
        let host = NSHostingController(rootView: AgentApprovalView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return { panel.close() }
    }
}

struct AgentApprovalView: View {
    @ObservedObject var model: AgentApprovalModel
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PasswordPieMark(size: 30)
                Text(model.title).font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.prompt.rows.enumerated()), id: \.offset) { index, row in
                    secretRow(index, row)
                }
            }
            if model.prompt.raw {
                Text(AgentApprovalModel.rawWarning)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.error(dark: dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                if let command = model.prompt.command {
                    detail("Command", command, full: [command, model.prompt.program].compactMap { $0 }.joined(separator: "\n"))
                }
                detail("Project", abbreviated(model.prompt.project), full: model.prompt.project)
                detail("Agent", model.agentLine, full: model.agentLine)
                // How the request came, and what the MCP client says it is: its claim, under the agent the app found.
                if let via = model.prompt.via {
                    GridRow {
                        Text("")
                        Text(via).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let reason = model.prompt.reason {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The agent says:").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("“\(reason)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText(dark: dark))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.notConfirmed {
                Text("Not confirmed. Nothing was allowed.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Deny") { model.deny() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.allow()
                } label: {
                    Label(model.allowTitle, systemImage: "touchid")
                }
                .disabled(!model.canAllow)
                .help("Confirm with Touch ID or your login password")
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .background(Palette.windowSurface(dark: dark))
    }

    private func secretRow(_ index: Int, _ row: AgentApprovalRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { model.ticked.contains(index) }, set: { _ in model.toggle(index) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.prompt.rows.count == 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    if !row.folder.isEmpty { Text("(\(row.folder))").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Text("\(row.field) · \(model.deliveryText(row))").font(.system(size: 11)).foregroundStyle(.secondary)
                if row.tooShortToMask {
                    Text("Shorter than 6 characters: not hidden in the command's output.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, _ value: String, full: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: label == "Command" ? .monospaced : .default))
                // Only the command is cut (in the middle, full text on hover): who signed the agent is never hidden.
                .lineLimit(label == "Command" ? 1 : 3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(full)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
#endif
