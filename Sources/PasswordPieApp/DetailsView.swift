import AppKit
import Combine
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
        case .upgrade: "Upgrade to unlock"
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

/// Return on the username or password fills, as Return on the account's row does. Other fields keep their button's action.
func returnFillsAccount(_ field: DetailField) -> Bool {
    field.kind == .username || field.kind == .password
}

/// Which row of the details the keyboard is on. Rows come and go when Chrome or Restore changes the list, so this is never an index.
enum DetailFocus: Hashable {
    case field(String)
    case previousHeader
    case previous(UUID)
}

/// `updated 2 days ago`. Rough on purpose: this is a label, not a record.
func chromeUpdatedText(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(now.timeIntervalSince(date), 0)
    func count(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return count(Int(seconds / 60), "minute") }
    if seconds < 86_400 { return count(Int(seconds / 3_600), "hour") }
    return count(Int(seconds / 86_400), "day")
}

/// The top line of a previous password: `updated Oct 20` or `date unknown`, then `not used yet` for a value never saved.
func previousPasswordCaption(_ item: PreviousPasswords.Item, now: Date = Date()) -> String {
    var caption = "date unknown"
    if let date = item.date {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMd" : "yMMMd")
        caption = "updated " + formatter.string(from: date)
    }
    return item.used ? caption : caption + " · not used yet"
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
    /// Website host for the site icon. Nil when the entry has no website.
    let siteHost: String?
    @Published private(set) var fields: [DetailField] = []
    let tags: [String]
    @Published var focusedRow: DetailFocus = .field("")
    /// Older values of the password, kept with the account.
    @Published private(set) var previous: [PreviousPasswords.Item] = []
    @Published var previousOpen = false
    /// Which rows say Restore could not be written.
    @Published private(set) var restoreFailures: Set<UUID> = []
    @Published var confirmingClear = false
    @Published private(set) var clearFailed = false
    /// The last Chrome update for this account could not be written.
    @Published private(set) var updateFailed = false
    /// When Chrome updated the saved password, for the label. Nil means it stays plain.
    @Published private(set) var chromeUpdatedAt: Date?
    @Published private(set) var fromChrome = false
    /// Days until the password should be changed (negative once overdue). Nil without a reminder.
    @Published private(set) var changeInDays: Int?
    @Published var revealed: Set<String> = []
    @Published var optionHeld = false
    @Published var flashing = false
    @Published var favorite: Bool
    let presentation: DetailsPresentation
    unowned let session: VaultSession
    fileprivate let done: () -> Void
    /// The account's Return action from the row (fill, or open and fill). Nil when the account has none or the window is pinned.
    private let fill: (() -> Void)?
    private var monitor: Any?
    private var activationObservers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []

    /// An index into `fields`, for what only moves among fields. Off the end while a previous password is focused.
    var focused: Int {
        get {
            if case .field(let id) = focusedRow, let index = fields.firstIndex(where: { $0.id == id }) { return index }
            return fields.count
        }
        set {
            if fields.indices.contains(newValue) { focusedRow = .field(fields[newValue].id) }
        }
    }

    init(entry: VaultEntry, session: VaultSession, presentation: DetailsPresentation = .popover, done: @escaping () -> Void, fill: (() -> Void)? = nil) {
        entryID = entry.id
        title = entry.title.isEmpty ? "Untitled" : entry.title
        siteHost = websiteHost(of: entry)
        favorite = entry.favorite
        tags = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }
        self.presentation = presentation
        self.session = session
        self.done = done
        self.fill = fill
        apply(entry)
        focusedRow = .field(fields.first { $0.kind == .password }?.id ?? fields.first?.id ?? "")
        let optionDown = NSEvent.modifierFlags.contains(.option)
        optionHeld = optionRevealHeld(after: .opened(presentation: presentation, optionDown: optionDown))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionHeld = optionRevealHeld(after: .flagsChanged(optionDown: event.modifierFlags.contains(.option)))
            return event
        }
        // A background Chrome write, or a Restore, changes what this row shows while it is open.
        // These publish before the property changes, so each takes the new value it is handed.
        let id = entry.id
        updateFailed = session.chromeUpdateFailures.contains(id)
        fromChrome = session.chromeBadgeIDs.contains(id)
        subscriptions = [
            session.$allEntries.sink { [weak self] all in
                guard let self, let current = all.first(where: { $0.id == id && !$0.trashed }) else { return }
                self.apply(current)
            },
            session.$chromeUpdateFailures.sink { [weak self] failures in
                guard let self else { return }
                self.updateFailed = failures.contains(id)
                self.refreshUpdateLabel()
            },
            session.$chromeBadgeIDs.sink { [weak self] ids in self?.fromChrome = ids.contains(id) }
        ]
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

    private func apply(_ entry: VaultEntry) {
        favorite = entry.favorite
        fields = Self.detailFields(of: entry)
        changeInDays = PasswordRotation.daysLeft(of: entry, now: Date())
        #if PP_DIRECT
        previous = PreviousPasswords.items(of: entry, now: Date())
        #endif
        current = entry
        refreshUpdateLabel()
        repairFocus()
    }

    private var current: VaultEntry?

    private func refreshUpdateLabel() {
        #if PP_DIRECT
        chromeUpdatedAt = updateFailed ? nil : current.flatMap { PreviousPasswords.chromeUpdateDate(of: $0, now: Date()) }
        #endif
    }

    /// The row the keyboard was on left, because the list folded or Restore took it. The header is the nearest thing left.
    private func repairFocus() {
        guard !rowOrder.contains(focusedRow) else { return }
        if case .previous = focusedRow, !previous.isEmpty {
            focusedRow = .previousHeader
        } else {
            focusedRow = .field(fields.first { $0.kind == .password }?.id ?? fields.first?.id ?? "")
        }
    }

    /// The order up and down walk: previous passwords sit right after the password's row.
    var rowOrder: [DetailFocus] {
        var order: [DetailFocus] = []
        for field in fields {
            order.append(.field(field.id))
            if field.kind == .password, !previous.isEmpty {
                order.append(.previousHeader)
                if previousOpen { order += previous.map { .previous($0.id) } }
            }
        }
        return order
    }

    static func detailFields(of entry: VaultEntry) -> [DetailField] {
        var fields: [DetailField] = []
        if !entry.username.isEmpty { fields.append(DetailField(id: "username", kind: .username, label: "username", value: entry.username, secret: false)) }
        if !entry.password.isEmpty { fields.append(DetailField(id: "password", kind: .password, label: "password", value: entry.password, secret: true)) }
        // Right under the password (and its strength), before the websites.
        if OneTimeCodes.hasCode(entry) { fields.append(DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)) }
        if !entry.url.isEmpty { fields.append(DetailField(id: "url", kind: .url, label: "website", value: entry.url, secret: false)) }
        let otherWebsites = EntryMerge.otherWebsites(entry)
        for website in otherWebsites {
            fields.append(DetailField(id: "custom:" + website.key, kind: .otherWebsite(website.key), label: "website", value: website.value, secret: false))
        }
        let handled: Set<String> = ["title", "username", "password", "url", "notes", "otp"]
        for field in entry.fields where !handled.contains(field.key.lowercased()) && !otherWebsites.contains(field) && !field.value.isEmpty && !field.key.lowercased().hasPrefix("timeotp") && !EntryMerge.isReservedKey(field.key) {
            fields.append(DetailField(id: "custom:" + field.key, kind: .custom(field.key), label: field.key, value: field.value, secret: field.protected))
        }
        if !entry.notes.isEmpty { fields.append(DetailField(id: "notes", kind: .notes, label: "notes", value: entry.notes, secret: false)) }
        return fields
    }

    /// Up and down move between rows and stop at the ends.
    func move(_ delta: Int) {
        let order = rowOrder
        guard !order.isEmpty else { return }
        let position = order.firstIndex(of: focusedRow) ?? 0
        focusedRow = order[min(max(position + delta, 0), order.count - 1)]
    }

    func isFocused(_ row: DetailFocus) -> Bool {
        focusedRow == row
    }

    func togglePrevious() {
        previousOpen.toggle()
        confirmingClear = false
        if !previousOpen { repairFocus() }
    }

    func previousKey(_ item: PreviousPasswords.Item) -> String {
        "previous:" + item.id.uuidString
    }

    func isShown(_ item: PreviousPasswords.Item) -> Bool {
        revealed.contains(previousKey(item)) || optionHeld
    }

    func toggleReveal(_ item: PreviousPasswords.Item) {
        let key = previousKey(item)
        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
    }

    /// Copy never fills, unlike Return on the password. The popover goes away as it does for any copy.
    func copyPrevious(_ item: PreviousPasswords.Item) {
        session.copy(item.value)
        if fieldActionClosesDetails(.copy, presentation: presentation) { done() }
    }

    func restore(_ item: PreviousPasswords.Item) {
        guard session.restorePreviousPassword(item.id, of: entryID) else {
            restoreFailures.insert(item.id)
            return
        }
        restoreFailures.remove(item.id)
        revealed.removeAll()
        focusedRow = .previousHeader
        announce("Password restored. The website and Chrome aren't changed.")
    }

    /// ⌘Return. Only a previous password takes it.
    func restoreFocused() -> Bool {
        guard case .previous(let id) = focusedRow, let item = previous.first(where: { $0.id == id }) else { return false }
        restore(item)
        return true
    }

    func clearPrevious() {
        confirmingClear = false
        if session.clearPreviousPasswords(of: entryID) {
            clearFailed = false
            previousOpen = false
            repairFocus()
            announce("Previous passwords cleared.")
        } else {
            clearFailed = true
        }
    }

    func retryUpdate() {
        session.retryChromeUpdates()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    /// What the debug status reports as focused.
    var focusedLabel: String? {
        switch focusedRow {
        case .field(let id): fields.first { $0.id == id }?.label
        case .previousHeader: "previous passwords"
        case .previous: "previous password"
        }
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
    /// Opens the reset link, or the account's website when it has none.
    func resetPassword() {
        guard let entry = session.entry(entryID) else { return }
        session.openURL(of: entryID, website: PasswordRotation.resetAddress(of: entry))
    }

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
        switch focusedRow {
        case .previousHeader:
            togglePrevious()
            return
        case .previous(let id):
            guard !flashing, let item = previous.first(where: { $0.id == id }) else { return }
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.flashing = false
                guard self.focusedRow == .previous(id) else { return }
                self.copyPrevious(item)
            }
            return
        case .field:
            break
        }
        guard fields.indices.contains(focused), !flashing else { return }
        let field = fields[focused]
        let action = fieldControl(field, revealed: revealed.contains(field.id), codeLocked: codeIsLocked).primary
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.flashing = false
            // Focus may have moved during the flash; act only on the field Return was pressed on.
            guard self.fields.indices.contains(self.focused), self.fields[self.focused].id == field.id else { return }
            // The fill hides the panel itself, like Return on the row.
            if let fill = self.fill, returnFillsAccount(field) {
                fill()
                return
            }
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

/// The site icon, or the letter tile when none is bundled or cached.
struct SiteIconView: View {
    var host: String?
    var title: String
    var side: CGFloat
    /// Redraws when the browser extension hands over an icon.
    @ObservedObject private var icons = SiteIconStore.shared

    var body: some View {
        Image(nsImage: icons.image(forHost: host) ?? MenuIcons.tile(title))
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

struct DetailsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DetailsModel
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                ForEach(Array(model.fields.enumerated()), id: \.element.id) { index, field in
                    DetailRow(model: model, premium: model.session.premium, field: field, focused: model.isFocused(.field(field.id)))
                    if field.kind == .password {
                        StrengthRow(password: field.value)
                        if let days = model.changeInDays { PasswordReminderRow(model: model, days: days) }
                        if model.updateFailed { UpdateFailedRow(model: model) }
                        if !model.previous.isEmpty { PreviousPasswordsSection(model: model) }
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

    @ViewBuilder
    private var headerBadge: some View {
        if iconMark(favorite: model.favorite, fromChrome: model.fromChrome) == .chrome {
            let side = 32 * ChromeBadge.detailsRatio
            ChromeGlyph(side: side)
                .padding(ChromeBadge.detailsRing)
                .background(Circle().fill(Palette.surface(dark: colorScheme == .dark)))
                .offset(x: ChromeBadge.detailsRing * 2, y: ChromeBadge.detailsRing * 2)
                .help(ChromeBadge.tooltip)
                .accessibilityLabel(ChromeBadge.tooltip)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SiteIconView(host: model.siteHost, title: model.title, side: 32)
                .overlay(alignment: .bottomTrailing) { headerBadge }
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
    /// A fill under the row when it has no keyboard focus: the locked one-time code's.
    var tint: Color? = nil
    /// After the label: where this value came from.
    var labelDetail: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                if let labelDetail { labelDetail }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(highlighted ? Palette.brandAccent.opacity(0.2) : tint ?? Color.clear)
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
        let locked = control.primary == .upgrade
        let actionShown = fieldActionsStayVisible(model.presentation) || locked || hovering || (focused && model.flashing)
        DetailChrome(
            label: field.label,
            highlighted: focused,
            tint: locked ? Palette.fieldSurface(dark: colorScheme == .dark).opacity(0.55) : nil,
            labelDetail: locked ? lockMark : updateLabel
        ) { value }
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

    /// The small lock after "one-time password" without Premium. The dots say it in words for VoiceOver.
    private var lockMark: AnyView {
        // A 9 pt font draws the glyph about 8 pt tall, as in the approved mockup.
        AnyView(Image(systemName: "lock.fill")
            .font(.system(size: 9))
            .foregroundStyle(Palette.accentText(dark: colorScheme == .dark).opacity(0.85))
            .accessibilityHidden(true))
    }

    /// `· [Chrome] updated 2 days ago`, only on the password and only for a Chrome update.
    private var updateLabel: AnyView? {
        guard field.kind == .password, let date = model.chromeUpdatedAt else { return nil }
        return AnyView(HStack(spacing: 4) {
            Text("·").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            ChromeGlyph(side: 10)
            Text("updated " + chromeUpdatedText(date)).font(.system(size: 10)).foregroundStyle(.secondary)
        })
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
            weight: control.primary == .upgrade ? .semibold : .regular,
            items: control.menu.map { item in
                SplitActionButton.Item(title: item.title) { model.perform(item, on: field) }
            }
        ) {
            model.perform(control.primary, on: field)
        }
    }
}

/// `[Chrome] Couldn't update. Using the saved password.` with Try Again. Silent when the update worked.
private struct UpdateFailedRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DetailsModel

    var body: some View {
        HStack(spacing: 6) {
            ChromeGlyph()
            Text("Couldn't update. Using the saved password.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.error(dark: colorScheme == .dark))
                .lineLimit(2)
            Spacer(minLength: 8)
            SplitActionButton(title: "Try Again", prominence: .quiet, items: []) { model.retryUpdate() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }
}

/// `▸ previous passwords (2)` and, when open, one two-line row per value.
private struct PreviousPasswordsSection: View {
    @ObservedObject var model: DetailsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.previousOpen {
                ForEach(model.previous) { item in
                    PreviousPasswordRow(model: model, item: item)
                }
            }
            if model.confirmingClear { confirmation }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.previousOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text("previous passwords (\(model.previous.count))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.previousOpen {
                Menu {
                    Button("Clear Previous Passwords") { model.confirmingClear = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePrevious() }
        .background(model.isFocused(.previousHeader) ? Palette.brandAccent.opacity(0.2) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Previous passwords, \(model.previous.count)")
        .accessibilityHint(model.previousOpen ? "Collapse the list" : "Expand the list")
    }

    private var confirmation: some View {
        HStack(spacing: 8) {
            Text("Clear all previous passwords? This can't be undone.")
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 8)
            SplitActionButton(title: "Cancel", prominence: .quiet, items: []) { model.confirmingClear = false }
            SplitActionButton(title: "Clear", prominence: .quiet, items: []) { model.clearPrevious() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }
}

/// Time on top, the value below, Restore and Copy on the right. Both buttons are neutral: neither one is the default.
private struct PreviousPasswordRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DetailsModel
    var item: PreviousPasswords.Item

    private var focused: Bool { model.isFocused(.previous(item.id)) }
    private var restoreTitle: String { item.used ? "Restore" : "Use" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if item.source == .chrome { ChromeGlyph(side: 10) }
                Text(previousPasswordCaption(item)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Group {
                if model.isShown(item) {
                    Text(item.value).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(String(repeating: "•", count: min(max(item.value.count, 8), 16))).font(.system(size: 13))
                }
            }
            .padding(.trailing, focused ? 170 : 140)
            if model.restoreFailures.contains(item.id) {
                Text("Couldn't restore. Nothing changed.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.error(dark: colorScheme == .dark))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(focused ? Palette.brandAccent.opacity(0.2) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                SplitActionButton(title: focused ? restoreTitle + " ⌘↩" : restoreTitle, prominence: .quiet, items: []) { model.restore(item) }
                    .help("The website and Chrome aren't changed.")
                SplitActionButton(
                    title: focused ? "Copy ↩" : "Copy",
                    prominence: .quiet,
                    items: [
                        SplitActionButton.Item(title: model.isShown(item) ? "Conceal" : "Reveal") { model.toggleReveal(item) },
                        SplitActionButton.Item(title: "Large Type") { model.session.showLargeType(item.value) }
                    ]
                ) { model.copyPrevious(item) }
                .opacity(focused && model.flashing ? 0.4 : 1)
            }
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(previousPasswordCaption(item))
    }
}

/// When the password should be changed, and the button that opens the page to change it.
private struct PasswordReminderRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DetailsModel
    var days: Int

    var body: some View {
        DetailChrome(label: "change password") {
            HStack {
                Text(PasswordRotation.phrase(daysLeft: days))
                    .font(.system(size: 13))
                    .foregroundStyle(days <= 0 ? Palette.error(dark: colorScheme == .dark) : Color.primary)
                Spacer()
                Button("Reset Password") { model.resetPassword() }
                    .controlSize(.small)
                    .help("Opens the page where this password is changed.")
            }
        }
        .frame(minHeight: 30)
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
    var entryID: UUID
    @ObservedObject var session: VaultSession
    @ObservedObject var premium: PremiumStore

    var body: some View {
        if let entry = session.entry(entryID) {
            OneTimeCodeView(access: session.oneTimeCodeAccess(for: entry))
        }
    }
}

/// The current code with its countdown, or the locked row without Premium. The details row, the item editor and the
/// Add Two-Step Code window all draw it, so codes are made in this file and `VaultSession` only (`PremiumGateTests`).
struct OneTimeCodeView: View {
    @Environment(\.colorScheme) private var colorScheme
    var access: OneTimeCodeAccess

    var body: some View {
        switch access {
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
            LockedOneTimeCode()
        case .noCode:
            EmptyView()
        }
    }
}

/// Six dots where the code would be, without Premium. It is given nothing about the code, so it cannot make one.
/// An invisible code sizes it, so a row is exactly as tall as with a live code and does not jump when Premium arrives.
struct LockedOneTimeCode: View {
    static let accessibilityText = "Locked. Included with Premium."
    static let diameter: CGFloat = 7
    static let gap: CGFloat = 4.7

    /// From the dots' centre down to the bottom of the code's line. A details row has 5 pt of padding under that line, so
    /// the centre is 15.5 pt above the row's bottom edge: 29.5 pt down a 45 pt row, halfway between the label's baseline
    /// and the bottom edge, and lower than the middle of a live code's digits.
    static let centreAboveLineBottom: CGFloat = 10.5

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = Palette.accentText(dark: colorScheme == .dark).opacity(0.5)
        ZStack(alignment: .bottomLeading) {
            Text(verbatim: "000 000").font(.system(size: 17, weight: .medium, design: .monospaced)).fixedSize().hidden()
            HStack(spacing: Self.gap) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(ink).frame(width: Self.diameter, height: Self.diameter) }
                Color.clear.frame(width: Self.diameter, height: Self.diameter)
                ForEach(3..<6, id: \.self) { _ in Circle().fill(ink).frame(width: Self.diameter, height: Self.diameter) }
            }
            .padding(.bottom, Self.centreAboveLineBottom - Self.diameter / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText)
        .accessibilityAddTraits(.isStaticText)
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
