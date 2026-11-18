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

/// What the window needs to offer a standing permission: the app's own Premium check, the Premium window, and the length
/// chosen last time. Nothing in the request says anything about Premium.
@MainActor
struct AgentLastingOptions {
    var hasPremium: () -> Bool
    /// Opens the Premium window over the approval window.
    var showPremium: () -> Void
    var lastLength: () -> AgentGrantLength
    var rememberLength: (AgentGrantLength) -> Void

    static let lastLengthKey = "agentGrantLength"

    /// The app's: `appHasPremium()`, the Premium window, and the last length in the preferences. A forged preference only
    /// changes which length the button names; the owner still chooses it and touches the sensor.
    static func live(defaults: UserDefaults = .standard) -> AgentLastingOptions {
        AgentLastingOptions(
            hasPremium: { appHasPremium() },
            showPremium: { AppDelegate.shared?.showPaywall(overApproval: true) },
            lastLength: { defaults.string(forKey: lastLengthKey).flatMap(AgentGrantLength.init(rawValue:)) ?? .default },
            rememberLength: { defaults.set($0.rawValue, forKey: lastLengthKey) }
        )
    }
}

/// One prompt: what the agent asks for, which rows the owner keeps ticked, and the answer. See "The approval window" and
/// "Do not ask me every time" in docs/UX.md.
@MainActor
final class AgentApprovalModel: ObservableObject {
    let prompt: AgentApprovalPrompt
    @Published var ticked: Set<Int>
    @Published private(set) var confirming = false
    @Published private(set) var notConfirmed = false
    /// The length "Allow for … ▾" names: the last one chosen.
    @Published private(set) var length: AgentGrantLength
    private let confirmation: OwnerConfirmation
    private let lasting: AgentLastingOptions
    private var finish: ((AgentApprovalDecision) -> Void)?

    var id: UUID { prompt.id }

    init(
        prompt: AgentApprovalPrompt, confirmation: OwnerConfirmation, lasting: AgentLastingOptions? = nil,
        finish: @escaping (AgentApprovalDecision) -> Void
    ) {
        self.prompt = prompt
        self.confirmation = confirmation
        let lasting = lasting ?? .live()
        self.lasting = lasting
        self.finish = finish
        ticked = Set(prompt.rows.indices)
        length = lasting.lastLength()
    }

    var answered: Bool { finish == nil }

    /// "Claude Code wants to use 2 secrets" / "… wants to see 1 secret".
    var title: String {
        let count = prompt.rows.count == 1 ? "1 secret" : "\(prompt.rows.count) secrets"
        return "\(prompt.agent) wants to \(prompt.raw ? "see" : "use") \(count)"
    }

    var allowTitle: String { prompt.raw ? "Show to Agent" : "Allow Once" }

    /// Shown beside Allow Once, greyed when the request cannot have one (`lastingUnavailable`).
    var offersLasting: Bool {
        guard !prompt.raw else { return false }
        return prompt.lasting != .notOffered
    }

    /// Why this request asks every time (inline code, an unknown launcher…), when it does.
    var lastingUnavailable: String? {
        if case .unavailable(let why) = prompt.lasting { return why }
        return nil
    }

    var isPremium: Bool { lasting.hasPremium() }

    /// "Allow for 7 days", "Allow for This Agent Session"; without Premium, with "· Premium".
    var lastingTitle: String {
        let title = "Allow for \(length == .session ? "This Agent Session" : length.label)"
        return isPremium ? title : title + " · Premium"
    }

    /// A length's line in the menu: "8 hours", and without Premium "8 hours — Premium".
    func lengthTitle(_ choice: AgentGrantLength) -> String {
        isPremium ? choice.menuTitle : "\(choice.menuTitle) — Premium"
    }

    var canAllowLasting: Bool { canAllow && offersLasting && lastingUnavailable == nil }

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
        let rows = ticked
        let reason = prompt.raw ? "show a secret to \(prompt.agent)" : "let \(prompt.agent) use \(rows.count == 1 ? "1 secret" : "\(rows.count) secrets")"
        confirm(reason) { .allow(rows) }
    }

    /// "Allow for 7 days" or one of its menu's lengths. Without Premium this opens the Premium window and approves
    /// nothing: the window stays for Allow Once or Deny. With Premium, Touch ID as for Allow Once.
    func allow(for choice: AgentGrantLength) {
        guard canAllowLasting else { return }
        guard lasting.hasPremium() else {
            lasting.showPremium()
            return
        }
        length = choice
        lasting.rememberLength(choice)
        let rows = ticked
        let count = rows.count == 1 ? "1 secret" : "\(rows.count) secrets"
        let span = choice == .session ? "until it quits" : "for \(choice.label)"
        confirm("let \(prompt.agent) use \(count) \(span) in this project") { .allowLasting(rows, choice) }
    }

    private func confirm(_ reason: String, then decision: @escaping () -> AgentApprovalDecision) {
        confirming = true
        notConfirmed = false
        Task { @MainActor in
            let confirmed = await confirmation.confirm(reason: reason)
            confirming = false
            guard !answered else { return }
            if confirmed {
                resolve(decision())
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
    private let lasting: AgentLastingOptions?
    /// Puts a model on screen and returns how to take it away. Tests pass one that shows nothing.
    private let show: (AgentApprovalModel) -> () -> Void
    private(set) var open: [UUID: (model: AgentApprovalModel, close: () -> Void)] = [:]
    /// The newest prompt, for tests and the debug status file.
    var onPresent: ((AgentApprovalModel) -> Void)?

    init(confirmation: OwnerConfirmation? = nil, lasting: AgentLastingOptions? = nil, show: ((AgentApprovalModel) -> () -> Void)? = nil) {
        makeConfirmation = { confirmation ?? SystemOwnerConfirmation() }
        self.lasting = lasting
        self.show = show ?? AgentApprovalController.window(for:)
    }

    func present(_ prompt: AgentApprovalPrompt) async -> AgentApprovalDecision {
        await withCheckedContinuation { continuation in
            // Each prompt its own confirmation, so withdrawing one closes only its own Touch ID sheet.
            let model = AgentApprovalModel(prompt: prompt, confirmation: makeConfirmation(), lasting: lasting) { [weak self] decision in
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
                if model.offersLasting { lastingButton }
            }
            if let why = model.lastingUnavailable {
                Text("No standing permission for this one: \(why)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: model.offersLasting ? 520 : 460, alignment: .leading)
        .background(Palette.windowSurface(dark: dark))
    }

    /// "Allow for 7 days ▾": the button allows for the length it names, the arrow offers the others.
    private var lastingButton: some View {
        Menu {
            ForEach(AgentGrantLength.allCases, id: \.self) { choice in
                Button(model.lengthTitle(choice)) { model.allow(for: choice) }
            }
        } label: {
            Text(model.lastingTitle)
        } primaryAction: {
            model.allow(for: model.length)
        }
        .fixedSize()
        .disabled(!model.canAllowLasting)
        .help(model.lastingUnavailable ?? (model.isPremium
            ? "Allow, and do not ask again for the same request until the time is up. Confirm with Touch ID."
            : "Standing permissions need Premium. Allow Once is free."))
        .accessibilityIdentifier("agents.allowLasting")
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
