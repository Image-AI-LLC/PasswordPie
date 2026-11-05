import AppKit
import PasswordPieCore
import SwiftUI

struct DetailField: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `otherWebsite` is one more site of the account, stored under a numbered name such as `URL (2)`.
        case username, password, url, otherWebsite(String), oneTimePassword, notes, custom(String)
    }

    let id: String
    var kind: Kind
    var label: String
    var value: String
    var secret: Bool

    /// The address this field opens. Nil when it is not a website.
    var website: String? {
        switch kind {
        case .url, .otherWebsite: value
        default: nil
        }
    }
}

/// One thing a details field can do. The button shows `primary`; the arrow lists `menu`.
enum FieldAction: Equatable, Hashable {
    case copy, reveal, conceal, largeType, openAndFill, open, upgrade

    var title: String {
        switch self {
        case .copy: "Copy"
        case .reveal: "Reveal"
        case .conceal: "Conceal"
        case .largeType: "Large Type"
        case .openAndFill: "Open and Fill"
        case .open: "Open"
        case .upgrade: "Upgrade"
        }
    }
}

struct FieldControl: Equatable {
    var primary: FieldAction
    var menu: [FieldAction]
}

/// A website opens. Copy is in the arrow, with open-and-fill. Every other field copies, and only a secret has a menu.
/// A one-time code the user does not have Premium for offers Upgrade instead.
func fieldControl(_ field: DetailField, revealed: Bool, codeLocked: Bool = false) -> FieldControl {
    if field.kind == .oneTimePassword, codeLocked {
        return FieldControl(primary: .upgrade, menu: [])
    }
    if field.website != nil {
        return FieldControl(primary: .open, menu: [.copy, .openAndFill])
    }
    return FieldControl(primary: .copy, menu: field.secret ? [revealed ? .conceal : .reveal, .largeType] : [])
}

enum DetailsPresentation: Equatable {
    /// The menu popover. Copying or opening leaves, because the menu would cover the place being filled.
    case popover
    /// A floating window the user pinned. Field actions never dismiss it.
    case pinned
}

/// Copying, opening, and open-and-fill close the popover. A pinned window stays until its close button.
func fieldActionClosesDetails(_ action: FieldAction, presentation: DetailsPresentation) -> Bool {
    guard presentation == .popover else { return false }
    switch action {
    case .copy, .open, .openAndFill, .upgrade: return true
    case .reveal, .conceal, .largeType: return false
    }
}

func showsPinButton(_ presentation: DetailsPresentation) -> Bool {
    presentation == .popover
}

/// Field actions show on hover in the popover and in a pinned window.
func fieldActionsStayVisible(_ presentation: DetailsPresentation) -> Bool {
    switch presentation {
    case .popover, .pinned:
        return false
    }
}

/// Why the Option-to-reveal flag changed. A local monitor never sees the key-up after another app is front.
enum OptionRevealChange: Equatable {
    case opened(presentation: DetailsPresentation, optionDown: Bool)
    case flagsChanged(optionDown: Bool)
    case appResignedActive
    case appBecameActive(optionDown: Bool)
}

/// Option reveals a secret only while this app can see the key. The pinned window stays on screen
/// after PasswordPie deactivates, so it must not inherit a held Option or keep one after resign.
/// An explicit Reveal stays in `revealed` and is not cleared here.
func optionRevealHeld(after change: OptionRevealChange) -> Bool {
    switch change {
    case .opened(let presentation, let optionDown):
        return presentation == .popover && optionDown
    case .flagsChanged(let optionDown), .appBecameActive(let optionDown):
        return optionDown
    case .appResignedActive:
        return false
    }
}

/// State of the details popover. The search field keeps keyboard focus, so the controller drives this model with up, down and return.
@MainActor
final class DetailsModel: ObservableObject {
    let entryID: UUID
    let title: String
    /// Website host for the favicon. Nil when the entry has no website.
    let siteHost: String?
    let fields: [DetailField]
    let tags: [String]
    @Published var focused = 0
    @Published var revealed: Set<String> = []
    @Published var optionHeld = false
    @Published var flashing = false
    @Published var favorite: Bool
    let presentation: DetailsPresentation
    unowned let session: VaultSession
    private let done: () -> Void
    private var monitor: Any?
    private var activationObservers: [NSObjectProtocol] = []

    init(entry: VaultEntry, session: VaultSession, presentation: DetailsPresentation = .popover, done: @escaping () -> Void) {
        entryID = entry.id
        title = entry.title.isEmpty ? "Untitled" : entry.title
        siteHost = websiteHost(of: entry)
        favorite = entry.favorite
        tags = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }
        self.presentation = presentation
        self.session = session
        self.done = done
        var fields: [DetailField] = []
        if !entry.username.isEmpty { fields.append(DetailField(id: "username", kind: .username, label: "username", value: entry.username, secret: false)) }
        if !entry.password.isEmpty { fields.append(DetailField(id: "password", kind: .password, label: "password", value: entry.password, secret: true)) }
        if !entry.url.isEmpty { fields.append(DetailField(id: "url", kind: .url, label: "website", value: entry.url, secret: false)) }
        let otherWebsites = EntryMerge.otherWebsites(entry)
        for website in otherWebsites {
            fields.append(DetailField(id: "custom:" + website.key, kind: .otherWebsite(website.key), label: "website", value: website.value, secret: false))
        }
        if OneTimeCodes.access(for: entry, hasPremium: false) != .noCode { fields.append(DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)) }
        let handled: Set<String> = ["title", "username", "password", "url", "notes", "otp"]
        for field in entry.fields where !handled.contains(field.key.lowercased()) && !otherWebsites.contains(field) && !field.value.isEmpty && !field.key.lowercased().hasPrefix("timeotp") && !EntryMerge.isReservedKey(field.key) {
            fields.append(DetailField(id: "custom:" + field.key, kind: .custom(field.key), label: field.key, value: field.value, secret: field.protected))
        }
        if !entry.notes.isEmpty { fields.append(DetailField(id: "notes", kind: .notes, label: "notes", value: entry.notes, secret: false)) }
        self.fields = fields
        focused = fields.firstIndex { $0.kind == .password } ?? 0
        let optionDown = NSEvent.modifierFlags.contains(.option)
        optionHeld = optionRevealHeld(after: .opened(presentation: presentation, optionDown: optionDown))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionHeld = optionRevealHeld(after: .flagsChanged(optionDown: event.modifierFlags.contains(.option)))
            return event
        }
        // The pinned window stays visible over the form. A local monitor misses the key-up
        // in the other app, so resign hides the Option reveal and the next activation samples the key again.
        // `revealed` is an explicit click and is left alone.
        guard presentation == .pinned else { return }
        activationObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.optionHeld = optionRevealHeld(after: .appResignedActive)
                }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let optionDown = NSEvent.modifierFlags.contains(.option)
                    self?.optionHeld = optionRevealHeld(after: .appBecameActive(optionDown: optionDown))
                }
            },
        ]
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Up and down move between copyable fields and stop at the ends.
    func move(_ delta: Int) {
        guard !fields.isEmpty else { return }
        focused = min(max(focused + delta, 0), fields.count - 1)
    }

    /// True while a one-time code here needs Premium. Read fresh, so an open row unlocks the moment Premium arrives.
    var codeIsLocked: Bool { !session.premium.hasPremium }

    func isShown(_ field: DetailField) -> Bool {
        !field.secret || revealed.contains(field.id) || optionHeld
    }

    func toggleReveal(_ field: DetailField) {
        if revealed.contains(field.id) { revealed.remove(field.id) } else { revealed.insert(field.id) }
    }

    func toggleFavorite() {
        session.toggleFavorite(entryID)
        favorite = session.entry(entryID)?.favorite ?? favorite
    }

    /// Runs the field's action. The popover then hides for copy and open; a pinned window never does.
    func perform(_ action: FieldAction, on field: DetailField) {
        switch action {
        case .copy:
            copyValue(field)
        case .reveal, .conceal:
            toggleReveal(field)
        case .largeType:
            session.showLargeType(field.value)
        case .openAndFill:
            session.fill(entryID, .openAndFill, website: field.website)
        case .open:
            session.openURL(of: entryID, website: field.website)
        case .upgrade:
            session.requestPremium()
        }
        if fieldActionClosesDetails(action, presentation: presentation) {
            done()
        }
    }

    /// Opens this account in a floating window and puts the menu away.
    func pin() {
        session.pinEntry(entryID)
    }

    /// Editing happens in a detached window; the panel hides first.
    func edit() {
        done()
        session.edit(entryID)
    }

    /// Return: flash the field's button (0.3 s), then run its primary action.
    func activateFocused() {
        guard fields.indices.contains(focused), !flashing else { return }
        let field = fields[focused]
        let action = fieldControl(field, revealed: revealed.contains(field.id), codeLocked: codeIsLocked).primary
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.flashing = false
            // Focus may have moved during the flash; act only on the field Return was pressed on.
            guard self.fields.indices.contains(self.focused), self.fields[self.focused].id == field.id else { return }
            self.perform(action, on: field)
        }
    }

    private func copyValue(_ field: DetailField) {
        switch field.kind {
        case .username: session.copy(.username, of: entryID)
        case .password: session.copy(.password, of: entryID)
        case .url: session.copy(.url, of: entryID)
        case .otherWebsite(let key): session.copy(.custom(key), of: entryID)
        case .notes: session.copy(.notes, of: entryID)
        case .oneTimePassword: session.copy(.oneTimePassword, of: entryID)
        case .custom(let key): session.copy(.custom(key), of: entryID)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The site favicon, or the letter tile when Google has none.
private struct SiteIconView: View {
    var host: String?
    var title: String
    var side: CGFloat
    @State private var logo: NSImage?

    var body: some View {
        Image(nsImage: logo ?? SiteIconStore.shared.image(forHost: host) ?? MenuIcons.tile(title))
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
            .task(id: host ?? "") {
                logo = SiteIconStore.shared.image(forHost: host)
                let image = await SiteIconStore.shared.load(host)
                if !Task.isCancelled { logo = image }
            }
    }
}

struct DetailsView: View {
    @ObservedObject var model: DetailsModel
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                ForEach(Array(model.fields.enumerated()), id: \.element.id) { index, field in
                    DetailRow(model: model, premium: model.session.premium, field: field, focused: index == model.focused)
                    if field.kind == .password {
                        StrengthRow(password: field.value)
                    }
                }
                if !model.tags.isEmpty {
                    DetailChrome(label: "tags") {
                        Text(model.tags.joined(separator: ", ")).font(.system(size: 13))
                    }
                }
            }
            .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
        }
        .frame(width: 400, height: min(contentHeight, 500))
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            let fitted = min(height, 500)
            DispatchQueue.main.async { onHeight?(fitted) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SiteIconView(host: model.siteHost, title: model.title, side: 32)
            Text(model.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Button { model.edit() } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit (⌘E)")
            if showsPinButton(model.presentation) {
                Button { model.pin() } label: {
                    Image(systemName: "pin").font(.system(size: 13)).foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Pin window (⌘O)")
            }
            Button { model.toggleFavorite() } label: {
                Image(systemName: model.favorite ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(model.favorite ? Palette.favorite : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Label above a value with a hairline under it; the shell shared by every details row.
private struct DetailChrome<Content: View>: View {
    var label: String
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(highlighted ? Palette.brandAccent.opacity(0.2) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }
}

private struct DetailRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DetailsModel
    /// Observed so that an open row changes the moment Premium arrives or ends.
    @ObservedObject var premium: PremiumStore
    var field: DetailField
    var focused: Bool
    @State private var hovering = false

    var body: some View {
        let control = fieldControl(field, revealed: model.revealed.contains(field.id), codeLocked: !premium.hasPremium)
        // Upgrade is how a locked row says what to do, so it does not wait for a hover.
        let actionShown = fieldActionsStayVisible(model.presentation) || control.primary == .upgrade || hovering || (focused && model.flashing)
        DetailChrome(label: field.label, highlighted: focused) { value }
            .contentShape(Rectangle())
            .onTapGesture { model.perform(control.primary, on: field) }
            .padding(.trailing, fieldActionsStayVisible(model.presentation) ? (control.menu.isEmpty ? 60 : 92) : 0)
            .overlay(alignment: .trailing) {
                if actionShown {
                    actions(control)
                        .padding(.trailing, 10)
                        .opacity(focused && model.flashing ? 0.4 : 1)
                }
            }
            .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var value: some View {
        switch field.kind {
        case .oneTimePassword:
            OneTimePasswordValue(entryID: model.entryID, session: model.session, premium: premium)
        case .url, .otherWebsite:
            Text(field.value).font(.system(size: 13)).foregroundStyle(Palette.accentText(dark: colorScheme == .dark)).lineLimit(1).truncationMode(.middle)
        case .notes:
            Text(field.value).font(.system(size: 13)).lineLimit(8)
        default:
            if model.isShown(field) {
                Text(field.value).font(.system(size: 13, design: field.secret ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
            } else {
                Text(String(repeating: "•", count: min(max(field.value.count, 8), 16))).font(.system(size: 13))
            }
        }
    }

    private func actions(_ control: FieldControl) -> some View {
        SplitActionButton(
            title: control.primary.title,
            prominence: control.primary == .upgrade ? .primary : .quiet,
            items: control.menu.map { item in
                SplitActionButton.Item(title: item.title) { model.perform(item, on: field) }
            }
        ) {
            model.perform(control.primary, on: field)
        }
    }
}

private struct StrengthRow: View {
    var password: String

    var body: some View {
        let strength = PasswordGenerator.strength(of: password)
        DetailChrome(label: "strength") {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color(strength)).frame(width: max(geo.size.width * strength, 6))
                }
            }
            .frame(height: 5)
            .padding(.vertical, 4)
        }
        .frame(minHeight: 30)
    }

    private func color(_ strength: Double) -> Color {
        strength < 0.4 ? Palette.strengthWeak : strength < 0.7 ? Palette.strengthMedium : Palette.strengthStrong
    }
}

private struct OneTimePasswordValue: View {
    @Environment(\.colorScheme) private var colorScheme
    var entryID: UUID
    @ObservedObject var session: VaultSession
    @ObservedObject var premium: PremiumStore

    var body: some View {
        if let entry = session.entry(entryID) {
            switch session.oneTimeCodeAccess(for: entry) {
            case .available(let settings):
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let period = Double(settings.period)
                    let remaining = period - context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
                    let urgent = remaining <= 5
                    HStack(spacing: 8) {
                        Text(groupedCode(OneTimeCodes.code(settings: settings, at: context.date)))
                            .font(.system(size: 17, weight: .medium, design: .monospaced))
                            .foregroundStyle(urgent ? Palette.error(dark: colorScheme == .dark) : Palette.accentText(dark: colorScheme == .dark))
                        CountdownPie(fraction: remaining / period, color: urgent ? Palette.error(dark: colorScheme == .dark) : Palette.accentText(dark: colorScheme == .dark)).frame(width: 14, height: 14)
                    }
                }
            case .locked:
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).accessibilityHidden(true)
                    Text("Included with Premium").font(.system(size: 13))
                }
                .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
            case .noCode:
                EmptyView()
            }
        }
    }
}

struct CountdownPie: View {
    var fraction: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.35), lineWidth: 1)
            PieSlice(fraction: fraction).fill(color)
        }
    }
}

struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: rect.width / 2 - 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
