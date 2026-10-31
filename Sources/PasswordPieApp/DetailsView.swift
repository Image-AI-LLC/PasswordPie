import AppKit
import PasswordPieCore
import SwiftUI

struct DetailField: Identifiable, Equatable {
    enum Kind: Equatable {
        case username, password, url, oneTimePassword, notes, custom(String)
    }

    let id: String
    var kind: Kind
    var label: String
    var value: String
    var secret: Bool
}

/// The word "copy" always copies. A menu exists only when the field has something besides copy.
enum FieldCopyItem: Equatable {
    case reveal, conceal, largeType, openAndFill, open

    var title: String {
        switch self {
        case .reveal: "reveal"
        case .conceal: "conceal"
        case .largeType: "large type"
        case .openAndFill: "open and fill"
        case .open: "open"
        }
    }
}

func fieldCopyMenu(_ field: DetailField, revealed: Bool) -> [FieldCopyItem]? {
    switch field.kind {
    case .password:
        return [revealed ? .conceal : .reveal, .largeType]
    case .url:
        return [.openAndFill, .open]
    default:
        return nil
    }
}

/// State of the details popover. The search field keeps keyboard focus, so the controller drives this model with up, down and return.
@MainActor
final class DetailsModel: ObservableObject {
    let entryID: UUID
    let title: String
    let fields: [DetailField]
    let tags: [String]
    @Published var focused = 0
    @Published var revealed: Set<String> = []
    @Published var optionHeld = NSEvent.modifierFlags.contains(.option)
    @Published var flashing = false
    @Published var favorite: Bool
    unowned let session: VaultSession
    private let done: () -> Void
    private var monitor: Any?

    init(entry: VaultEntry, session: VaultSession, done: @escaping () -> Void) {
        entryID = entry.id
        title = entry.title.isEmpty ? "Untitled" : entry.title
        favorite = entry.favorite
        tags = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }
        self.session = session
        self.done = done
        var fields: [DetailField] = []
        if !entry.username.isEmpty { fields.append(DetailField(id: "username", kind: .username, label: "username", value: entry.username, secret: false)) }
        if !entry.password.isEmpty { fields.append(DetailField(id: "password", kind: .password, label: "password", value: entry.password, secret: true)) }
        if !entry.url.isEmpty { fields.append(DetailField(id: "url", kind: .url, label: "website", value: entry.url, secret: false)) }
        if TOTP.parse(entry: entry) != nil { fields.append(DetailField(id: "otp", kind: .oneTimePassword, label: "one-time password", value: "", secret: false)) }
        let handled: Set<String> = ["title", "username", "password", "url", "notes", "otp"]
        for field in entry.fields where !handled.contains(field.key.lowercased()) && !field.value.isEmpty && !field.key.lowercased().hasPrefix("timeotp") {
            fields.append(DetailField(id: "custom:" + field.key, kind: .custom(field.key), label: field.key, value: field.value, secret: field.protected))
        }
        if !entry.notes.isEmpty { fields.append(DetailField(id: "notes", kind: .notes, label: "notes", value: entry.notes, secret: false)) }
        self.fields = fields
        focused = fields.firstIndex { $0.kind == .password } ?? 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionHeld = event.modifierFlags.contains(.option)
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Up and down move between copyable fields and stop at the ends.
    func move(_ delta: Int) {
        guard !fields.isEmpty else { return }
        focused = min(max(focused + delta, 0), fields.count - 1)
    }

    func isShown(_ field: DetailField) -> Bool {
        !field.secret || revealed.contains(field.id) || optionHeld
    }

    func toggleReveal(_ field: DetailField) {
        if revealed.contains(field.id) { revealed.remove(field.id) } else { revealed.insert(field.id) }
    }

    func toggleFavorite() {
        session.toggleFavorite(entryID)
        favorite.toggle()
    }

    /// Copies the field, then the whole popup hides.
    func copy(_ field: DetailField) {
        switch field.kind {
        case .username: session.copy(.username, of: entryID)
        case .password: session.copy(.password, of: entryID)
        case .url: session.copy(.url, of: entryID)
        case .notes: session.copy(.notes, of: entryID)
        case .oneTimePassword: session.copy(.oneTimePassword, of: entryID)
        case .custom(let key): session.copy(.custom(key), of: entryID)
        }
        done()
    }

    /// Editing happens in a detached window; the panel hides first.
    func edit() {
        done()
        session.edit(entryID)
    }

    func largeType(_ field: DetailField) {
        session.showLargeType(field.value)
    }

    func openURL(fill: Bool) {
        if fill { session.fill(entryID, .openAndFill) } else { session.openURL(of: entryID); done() }
    }

    /// Return: flash the field's button twice (2 x 0.15 s), copy it, hide.
    func activateFocused() {
        guard fields.indices.contains(focused), !flashing else { return }
        let field = fields[focused]
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.flashing = false
            // Focus may have moved during the flash; copy only the field Return was pressed on.
            guard self.fields.indices.contains(self.focused), self.fields[self.focused].id == field.id else { return }
            self.copy(field)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DetailsView: View {
    @ObservedObject var model: DetailsModel
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                ForEach(Array(model.fields.enumerated()), id: \.element.id) { index, field in
                    DetailRow(model: model, field: field, focused: index == model.focused)
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
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuIcons.tile(model.title)).resizable().scaledToFit().frame(width: 32, height: 32)
            Text(model.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Button { model.edit() } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit (⌘E)")
            Button { model.toggleFavorite() } label: {
                Image(systemName: model.favorite ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(model.favorite ? Color(red: 0.96, green: 0.72, blue: 0.2) : Color.secondary)
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
        .background(highlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }
}

private struct DetailRow: View {
    @ObservedObject var model: DetailsModel
    var field: DetailField
    var focused: Bool
    @State private var hovering = false

    var body: some View {
        DetailChrome(label: field.label, highlighted: focused) { value }
            .contentShape(Rectangle())
            .onTapGesture { model.copy(field) }
            .overlay(alignment: .trailing) {
                if hovering || (focused && model.flashing) {
                    actions
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
            OneTimePasswordValue(entryID: model.entryID, session: model.session)
        case .url:
            Text(field.value).font(.system(size: 13)).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
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

    private var actions: some View {
        FieldCopyButton(items: fieldCopyMenu(field, revealed: model.revealed.contains(field.id)) ?? []) {
            model.copy(field)
        } onItem: { item in
            switch item {
            case .reveal, .conceal: model.toggleReveal(field)
            case .largeType: model.largeType(field)
            case .openAndFill: model.openURL(fill: true)
            case .open: model.openURL(fill: false)
            }
        }
    }
}

/// One control. The word copies. The arrow, present only when `items` is not empty, opens the menu.
struct FieldCopyButton: View {
    var items: [FieldCopyItem]
    var onCopy: () -> Void
    var onItem: (FieldCopyItem) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onCopy) {
                Text("copy")
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FieldCopyPressStyle())
            .help("Copy")
            if !items.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.28)).frame(width: 0.5, height: 12)
                Menu {
                    ForEach(items, id: \.self) { item in
                        Button(item.title) { onItem(item) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.28), lineWidth: 0.5))
        .fixedSize()
    }
}

private struct FieldCopyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.14) : Color.clear)
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
        strength < 0.4 ? .red : strength < 0.7 ? .orange : .green
    }
}

private struct OneTimePasswordValue: View {
    var entryID: UUID
    @ObservedObject var session: VaultSession

    var body: some View {
        if let entry = session.entry(entryID), let settings = TOTP.parse(entry: entry) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let period = Double(settings.period)
                let remaining = period - context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
                let urgent = remaining <= 5
                HStack(spacing: 8) {
                    Text(groupedCode(TOTP.code(settings: settings, at: context.date)))
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(urgent ? Color.red : Color.accentColor)
                    CountdownPie(fraction: remaining / period, color: urgent ? .red : .accentColor).frame(width: 14, height: 14)
                }
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
