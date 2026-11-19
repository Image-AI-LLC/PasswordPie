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
    /// The items whose rows are shown one by one (`Group.id`). An item with several secrets is one row that opens.
    @Published private(set) var opened: Set<Int> = []
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
        // A login fills one account: with several to choose from, the owner picks one; nothing is picked for them.
        ticked = prompt.kind == .login && prompt.rows.count > 1 ? [] : Set(prompt.rows.indices)
        length = prompt.lasting == .sessionOnly ? .session : lasting.lastLength()
        // A few secrets are all in view. Many are a list of items, each closed until the owner opens it.
        if prompt.rows.count <= Self.rowsShownOpen { opened = Set(groups.map(\.id)) }
    }

    // MARK: Rows by item

    /// The rows of one item, in the order asked. `id` is its first row's index.
    struct Group: Identifiable, Equatable {
        let id: Int
        let title: String
        let folder: String
        let rows: [Int]
    }

    enum Tick: Equatable {
        case all, some, none
    }

    /// Up to this many secrets, every row is shown. Above it, an item with several secrets starts closed.
    static let rowsShownOpen = 6

    /// The request's rows, those of one item together where the item was first asked for. A login's rows are accounts
    /// to choose from, never grouped; a row that names no item stands alone.
    var groups: [Group] {
        var groups: [Group] = []
        var place: [UUID: Int] = [:]
        for (index, row) in prompt.rows.enumerated() {
            if !isLogin, let item = row.item, let at = place[item] {
                groups[at] = Group(id: groups[at].id, title: groups[at].title, folder: groups[at].folder, rows: groups[at].rows + [index])
            } else {
                if !isLogin, let item = row.item { place[item] = groups.count }
                groups.append(Group(id: index, title: row.title, folder: row.folder, rows: [index]))
            }
        }
        return groups
    }

    func isOpen(_ group: Group) -> Bool { group.rows.count == 1 || opened.contains(group.id) }

    func toggleOpen(_ group: Group) {
        if opened.contains(group.id) { opened.remove(group.id) } else { opened.insert(group.id) }
    }

    func tick(of group: Group) -> Tick {
        let on = group.rows.filter(ticked.contains).count
        return on == 0 ? .none : on == group.rows.count ? .all : .some
    }

    /// The item's checkbox: everything of it, or nothing. Ticking a part-ticked item ticks the rest.
    func toggle(group: Group) {
        guard !confirming, !isLogin else { return }
        if tick(of: group) == .all {
            ticked.subtract(group.rows)
        } else {
            ticked.formUnion(group.rows)
        }
    }

    /// The closed row's second line: "12 secrets · 11 environment variables, 1 file for the command", then how many are
    /// left out when some are unticked.
    func groupLine(_ group: Group) -> String {
        let rows = group.rows.map { prompt.rows[$0] }
        func count(_ delivery: AgentDelivery, _ one: String, _ many: String) -> String? {
            let found = rows.filter { $0.delivery == delivery }.count
            return found == 0 ? nil : found == 1 ? "1 \(one)" : "\(found) \(many)"
        }
        let ways = [
            count(.env, "environment variable", "environment variables"),
            count(.file, "file for the command", "files for the command"),
            count(.stdin, "on the command's standard input", "on the command's standard input"),
            count(.shown, "shown to the agent", "shown to the agent"),
            count(.compare, "compared with the files", "compared with the files"),
        ].compactMap { $0 }
        var line = "\(rows.count) secrets · " + ways.joined(separator: ", ")
        let off = group.rows.filter { !ticked.contains($0) }.count
        if off > 0, off < rows.count { line += " · \(off) left out" }
        if off == rows.count { line += " · all left out" }
        return line
    }

    /// How many of the item's secrets are too short to hide in the command's output: said on the closed row too.
    func tooShortCount(_ group: Group) -> Int {
        group.rows.filter { prompt.rows[$0].tooShortToMask }.count
    }

    var isLogin: Bool { prompt.kind == .login }

    /// `passwordpie check-import`: values are compared inside PasswordPie, and nothing is handed out.
    var isCheck: Bool { prompt.kind == .check }

    var answered: Bool { finish == nil }

    /// "Claude Code wants to use 2 secrets" / "… wants to see 1 secret".
    var title: String {
        if isLogin { return "\(prompt.agent) wants to log in to \(prompt.site ?? "a website")" }
        let count = prompt.rows.count == 1 ? "1 secret" : "\(prompt.rows.count) secrets"
        if isCheck { return "\(prompt.agent) wants to compare \(count) with files" }
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

    /// The lengths the menu offers: only "this agent session" when no agent was found.
    var lengths: [AgentGrantLength] { prompt.lasting == .sessionOnly ? [.session] : AgentGrantLength.allCases }

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

    var canAllow: Bool { (isLogin ? ticked.count == 1 : !ticked.isEmpty) && !confirming }

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
        case .fill: return prompt.submit ? "filled in, then the form is sent" : "filled in"
        case .compare: return "compared with \(row.name ?? "the file") in the folder"
        }
    }

    /// What a check tells the agent, said in the window: an answer about each value, never the value.
    static let checkNote = "PasswordPie compares each one with the file and tells the agent only “same”, “differs” or “missing”. No value leaves PasswordPie, but the agent learns whether the file holds the same value."

    /// "password · environment variable T"; for a login "octocat · username and password, filled in, then the form is sent".
    func rowLine(_ row: AgentApprovalRow) -> String {
        guard isLogin else { return "\(row.field) · \(deliveryText(row))" }
        let who = row.username.flatMap { $0.isEmpty ? nil : $0 + " · " } ?? ""
        return "\(who)\(row.field), \(deliveryText(row))"
    }

    static let rawWarning = "The agent will see the value. It stays in the conversation, and in the model provider's records if the model is hosted."

    func toggle(_ index: Int) {
        guard !confirming else { return }
        if isLogin {
            ticked = [index]
            return
        }
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }

    func deny() {
        resolve(.deny)
    }

    /// Asks for Touch ID (or the login password) first. Nothing is allowed without it.
    func allow() {
        guard canAllow else { return }
        let rows = ticked
        let counted = rows.count == 1 ? "1 secret" : "\(rows.count) secrets"
        let reason = isLogin ? "let \(prompt.agent) log in to \(prompt.site ?? "a website")"
            : isCheck ? "let \(prompt.agent) compare \(counted) with files"
            : prompt.raw ? "show a secret to \(prompt.agent)" : "let \(prompt.agent) use \(counted)"
        confirm(reason) { .allow(rows) }
    }

    /// "Allow for 7 days" or one of its menu's lengths. Without Premium this opens the Premium window and approves
    /// nothing: the window stays for Allow Once or Deny. With Premium, Touch ID as for Allow Once.
    func allow(for choice: AgentGrantLength) {
        guard canAllowLasting, lengths.contains(choice) else { return }
        guard lasting.hasPremium() else {
            lasting.showPremium()
            return
        }
        length = choice
        // Only a choice among several is remembered: "this agent session" alone says nothing about the owner's habit.
        if lengths.count > 1 { lasting.rememberLength(choice) }
        let rows = ticked
        let count = rows.count == 1 ? "1 secret" : "\(rows.count) secrets"
        let span = choice == .session ? "until it quits" : "for \(choice.label)"
        let reason = isLogin
            ? "let \(prompt.agent) log in to \(prompt.site ?? "a website") \(span)"
            : "let \(prompt.agent) use \(count) \(span) in this project"
        confirm(reason) { .allowLasting(rows, choice) }
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

    #if DEBUG
    /// The window's words, for the debug status file. No value is in a prompt, so none is here.
    var debugSummary: [String: Any] {
        [
            "title": title,
            "rows": prompt.rows.map { "\($0.title) (\($0.folder)): \(rowLine($0))" },
            "allow": allowTitle,
            "lasting": offersLasting ? lastingTitle : NSNull(),
            "lastingMenu": offersLasting ? lengths.map(lengthTitle) : [],
            "lastingUnavailable": lastingUnavailable ?? NSNull(),
            "agent": agentLine,
            "via": prompt.via ?? NSNull(),
            "command": prompt.command ?? NSNull(),
            "project": prompt.project,
            "site": prompt.site ?? NSNull(),
            "browser": prompt.browser ?? NSNull(),
            "reason": prompt.reason ?? NSNull(),
            "raw": prompt.raw,
            "folder": prompt.folder ?? NSNull(),
        ]
    }
    #endif
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

/// A checkbox that can also say "some": AppKit's, since SwiftUI's has no mixed state.
private struct MixedCheckbox: NSViewRepresentable {
    let state: AgentApprovalModel.Tick
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.pressed))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.shown = state == .all ? .on : state == .none ? .off : .mixed
        button.state = context.coordinator.shown
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var shown: NSControl.StateValue = .off
        init(action: @escaping () -> Void) { self.action = action }

        /// A click moves the button to its own next state. The model decides instead: the button goes back to what
        /// the model said, and the model's answer is drawn when it changes.
        @objc func pressed(_ sender: NSButton) {
            sender.state = shown
            action()
        }
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
            // Many secrets are a list of items, so the list scrolls instead of pushing the buttons off the screen.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.groups) { group in
                        if group.rows.count == 1 {
                            secretRow(group.rows[0], model.prompt.rows[group.rows[0]])
                        } else {
                            groupRow(group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The bar stays in view, so a list that goes on below is seen to go on.
            .scrollIndicators(.visible)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            if model.isCheck {
                Text(AgentApprovalModel.checkNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText(dark: dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.prompt.raw {
                Text(AgentApprovalModel.rawWarning)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.error(dark: dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                if model.isLogin {
                    detail("Site", model.prompt.site ?? "", full: model.prompt.site ?? "")
                    if let browser = model.prompt.browser { detail("Browser", browser, full: browser) }
                }
                if let command = model.prompt.command {
                    detail("Command", command, full: [command, model.prompt.program].compactMap { $0 }.joined(separator: "\n"))
                }
                if let folder = model.prompt.folder { detail("Folder", abbreviated(folder), full: folder) }
                if !model.isLogin { detail("Project", abbreviated(model.prompt.project), full: model.prompt.project) }
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
            ForEach(model.lengths, id: \.self) { choice in
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

    /// An item with several secrets: one row with the item's checkbox, opening to a checkbox for each secret.
    private func groupRow(_ group: AgentApprovalModel.Group) -> some View {
        let open = model.isOpen(group)
        let short = model.tooShortCount(group)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // AppKit's checkbox has no text baseline to line up with: a fixed box, at the height of the title's line.
                MixedCheckbox(state: model.tick(of: group)) { model.toggle(group: group) }
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("All secrets of \(group.title)")
                Button {
                    model.toggleOpen(group)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(group.title).font(.system(size: 13, weight: .medium))
                                if !group.folder.isEmpty { Text("(\(group.folder))").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            // Closed, the row says what is in it. Open, the rows under it do.
                            if !open {
                                Text(model.groupLine(group)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if short > 0 {
                                    Text("\(short == 1 ? "1 is" : "\(short) are") shorter than 6 characters: not hidden in the command's output.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Hides its secrets" : "Shows its secrets, each with a checkbox")
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.rows, id: \.self) { index in
                        fieldRow(index, model.prompt.rows[index])
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    /// One secret of an opened item: its checkbox and what happens to it. The item is named on the row above.
    private func fieldRow(_ index: Int, _ row: AgentApprovalRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { model.ticked.contains(index) }, set: { _ in model.toggle(index) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.rowLine(row)).font(.system(size: 12))
                if row.tooShortToMask {
                    Text("Shorter than 6 characters: not hidden in the command's output.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func secretRow(_ index: Int, _ row: AgentApprovalRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.isLogin {
                // One account per login: a radio, not a checkbox.
                Image(systemName: model.ticked.contains(index) ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.ticked.contains(index) ? Palette.accentText(dark: dark) : Palette.secondaryText(dark: dark))
                    .onTapGesture { model.toggle(index) }
                    .accessibilityAddTraits(model.ticked.contains(index) ? [.isButton, .isSelected] : .isButton)
            } else {
            Toggle("", isOn: Binding(get: { model.ticked.contains(index) }, set: { _ in model.toggle(index) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.prompt.rows.count == 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    if !row.folder.isEmpty { Text("(\(row.folder))").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Text(model.rowLine(row)).font(.system(size: 11)).foregroundStyle(.secondary)
                if let note = row.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
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
