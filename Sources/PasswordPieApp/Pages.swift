import AppKit
import PasswordPieCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Editor (detached window)

struct EditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: VaultSession
    @State private var showPassword = false
    @State private var otpInput = ""
    /// Why the last scan did not give a code, under the one-time password row.
    @State private var otpScanError = ""
    @State private var tagsInput = ""
    @State private var keepSeparate = false
    @State private var confirmSplit = false
    @State private var loaded = false
    /// The websites after the main one, and the fields with no row of their own, as rows. They go into the item on Save.
    @State private var websites: [EditableField] = []
    @State private var fields: [EditableField] = []
    /// Form inputs an import saved without a name. Listed apart and folded, so they can be removed together.
    @State private var unnamed: [EditableField] = []
    @State private var unnamedOpen = false
    @State private var revealed: Set<UUID> = []
    @State private var confirmRemoveAll = false
    /// Days between password changes: 0 is Never, -1 is Custom with `customDays`.
    @State private var changeEvery = 0
    @State private var customDays = ""
    @State private var resetLink = ""
    /// The row Add Website or Add Field just made, which takes the keyboard.
    @State private var added: UUID?

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    mainCard
                    reminderCard
                    otherFieldsCard
                    if !unnamed.isEmpty { unnamedFieldsCard }
                    notesCard
                    EditorCard {
                        EditorRow(label: "Tags") { EditorField(placeholder: "Comma separated", text: $tagsInput) }
                    }
                    mergeCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            Divider()
            HStack {
                if !session.editingIsNew {
                    Button("Move to Trash", role: .destructive) { session.deleteEditing() }
                }
                Spacer()
                Button("Cancel") { session.cancelEditing() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(BrandPrimaryButtonStyle())
            }
            .padding(12)
        }
        .frame(width: 450, height: 640)
        .tint(Palette.brandAccent)
        .alert("Split these accounts?", isPresented: $confirmSplit) {
            Button("Split") { session.splitEditing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the accounts from before the merge. They will not auto-merge again.")
        }
        .alert("Remove all \(unnamed.count) unnamed form fields?", isPresented: $confirmRemoveAll) {
            Button("Remove All", role: .destructive) { unnamed = [] }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed when you save.")
        }
        .onAppear {
            guard !loaded, let entry = session.editing else { return }
            otpInput = entry.otp
            tagsInput = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }.joined(separator: ", ")
            keepSeparate = EntryMerge.keepsSeparate(entry)
            websites = EntryFields.websites(of: entry)
            let custom = EntryFields.custom(of: entry)
            fields = custom.filter { !EntryFields.isUnnamed($0.name) }
            unnamed = custom.filter { EntryFields.isUnnamed($0.name) }
            let days = PasswordRotation.period(of: entry) ?? 0
            changeEvery = days == 0 || PasswordRotation.presets.contains(days) ? days : -1
            customDays = changeEvery == -1 ? String(days) : ""
            resetLink = PasswordRotation.resetLink(of: entry)
            loaded = true
        }
    }

    // MARK: Sections

    /// The site icon, the title, and the favorite star.
    private var identity: some View {
        HStack(spacing: 4) {
            SiteIconView(host: websiteHost(forWebsite: session.editing?.url ?? ""), title: session.editing?.title ?? "", side: 28)
            EditorField(placeholder: "Title", text: binding(\.title), size: 16, weight: .semibold)
            Button { session.editing?.favorite.toggle() } label: {
                Image(systemName: favoriteBinding.wrappedValue ? "star.fill" : "star")
                    .foregroundStyle(favoriteBinding.wrappedValue ? Palette.favorite : Palette.secondaryText(dark: dark))
            }
            .buttonStyle(.borderless)
            .frame(width: EditorMetrics.action)
            .help(favoriteBinding.wrappedValue ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel("Favorite")
            .accessibilityAddTraits(favoriteBinding.wrappedValue ? .isSelected : [])
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
    }

    private var mainCard: some View {
        EditorCard {
            EditorRow(label: "Username") { EditorField(placeholder: "", text: binding(\.username)) }
            EditorDivider()
            EditorRow(label: "Password") {
                EditorField(placeholder: "", text: binding(\.password), secure: !showPassword, mono: showPassword)
                EditorIconButton(symbol: showPassword ? "eye.slash" : "eye", label: showPassword ? "Hide Password" : "Show Password") {
                    showPassword.toggle()
                }
                Button("Generate") { session.editing?.password = PasswordGenerator.generate(CharacterRecipe()) }
                    .controlSize(.small)
                    .padding(.leading, 6)
            }
            EditorDivider()
            oneTimePasswordRow
            EditorDivider()
            EditorRow(label: "Website") {
                EditorField(placeholder: "https://", text: binding(\.url))
                if !websites.isEmpty {
                    EditorIconButton(symbol: "minus.circle", label: "Remove Website") {
                        session.editing?.url = websites.removeFirst().value
                    }
                }
            }
            ForEach($websites) { $website in
                EditorRow(label: "") {
                    EditorField(placeholder: "https://", text: $website.value, takesKeyboard: added == website.id)
                    EditorIconButton(symbol: "minus.circle", label: "Remove Website") {
                        websites.removeAll { $0.id == website.id }
                    }
                }
            }
            EditorDivider()
            EditorAddRow(title: "Add Website") {
                let row = EditableField()
                added = row.id
                websites.append(row)
            }
        }
    }

    /// How often this password has to change, and where. docs/UX.md, "A reminder to change a password".
    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionLabel(title: "Password reminder")
            EditorCard {
                EditorRow(label: "Change every") {
                    Picker("Change every", selection: $changeEvery) {
                        Text("Never").tag(0)
                        ForEach(PasswordRotation.presets, id: \.self) { days in
                            Text(days == 365 ? "1 year" : "\(days) days").tag(days)
                        }
                        Text("Custom…").tag(-1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 2)
                    if changeEvery == -1 {
                        EditorField(placeholder: "90", text: $customDays).frame(width: 56)
                        Text("days").font(.system(size: 12)).foregroundStyle(Palette.secondaryText(dark: dark))
                    }
                    Spacer(minLength: 0)
                }
                if changeEvery != 0 {
                    EditorDivider()
                    EditorRow(label: "Reset link") {
                        EditorField(placeholder: "The page where you change it", text: $resetLink)
                    }
                }
            }
        }
    }

    /// The period the rows say: nil for Never, or for a Custom that is not a number of days.
    private var chosenPeriod: Int? {
        switch changeEvery {
        case 0: return nil
        case -1: return Int(customDays.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        default: return changeEvery
        }
    }

    /// Every field with no row above, except the unnamed form fields.
    private var otherFieldsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionLabel(title: "Other fields")
            EditorCard {
                ForEach($fields) { $field in
                    fieldRow($field) { fields.removeAll { $0.id == field.id } }
                    EditorDivider()
                }
                EditorAddRow(title: "Add Field") {
                    let row = EditableField()
                    added = row.id
                    fields.append(row)
                }
            }
        }
    }

    /// What an import left behind. One line until opened; Remove All is inside, with the rows it removes.
    private var unnamedFieldsCard: some View {
        EditorCard {
            HStack(spacing: 6) {
                Button { unnamedOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: unnamedOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.secondaryText(dark: dark))
                            .frame(width: 12)
                        Text("Unnamed form fields").font(.system(size: 13))
                        Text("\(unnamed.count)").font(.system(size: 13)).foregroundStyle(Palette.secondaryText(dark: dark).opacity(0.75))
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Form inputs that had no name when an import saved them.")
                .accessibilityLabel("Unnamed form fields, \(unnamed.count)")
                .accessibilityValue(unnamedOpen ? "Open" : "Closed")
                if unnamedOpen {
                    Button("Remove All…") { confirmRemoveAll = true }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: EditorMetrics.row)
            if unnamedOpen {
                ForEach($unnamed) { $field in
                    EditorDivider()
                    fieldRow($field) { unnamed.removeAll { $0.id == field.id } }
                }
            }
        }
    }

    /// A field's name, its value, the eye of a protected one, and its remove button.
    private func fieldRow(_ field: Binding<EditableField>, remove: @escaping () -> Void) -> some View {
        let id = field.wrappedValue.id
        let protected = field.wrappedValue.protected
        let name = field.wrappedValue.name
        return HStack(spacing: 0) {
            EditorField(placeholder: "Name", text: field.name, size: 12, secondary: true, takesKeyboard: added == id)
                .frame(width: EditorMetrics.label + 6)
            EditorField(placeholder: "Value", text: field.value, secure: protected && !revealed.contains(id), mono: protected)
            if protected {
                EditorIconButton(symbol: revealed.contains(id) ? "eye.slash" : "eye", label: "Show \(name)") {
                    revealed.formSymmetricDifference([id])
                }
            }
            EditorIconButton(symbol: "minus.circle", label: "Remove \(name)", action: remove)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: EditorMetrics.row)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorSectionLabel(title: "Notes")
            EditorCard {
                TextEditor(text: binding(\.notes))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 58)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Notes")
            }
        }
    }

    /// Where a merged item is split, and whether this item may be merged at all.
    private var mergeCard: some View {
        EditorCard {
            if let entry = session.editing, EntryMerge.partCount(entry) >= 2 {
                EditorRow(label: nil) {
                    Text("Merged from \(EntryMerge.partCount(entry)) accounts")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText(dark: dark))
                    Spacer()
                    Button("Split…") { confirmSplit = true }
                        .controlSize(.small)
                        .help("Restores the accounts from before the merge and keeps them separate.")
                }
                EditorDivider()
            }
            EditorRow(label: nil) {
                Toggle(isOn: Binding(get: { !keepSeparate }, set: { keepSeparate = !$0 })) {
                    Text("Merge with matching accounts")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText(dark: dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Accounts with the same website, username and password become one item.")
            }
        }
    }

    // MARK: One-time password

    /// The field, its QR button, what went wrong with the last scan, and the current code once there is one.
    private var oneTimePasswordRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorRow(label: "One-time password") {
                OTPInputField(text: $otpInput, placeholder: "Secret or otpauth:// link") { pasteboard in
                    guard OTPInputScanner.holdsOnlyAnImage(pasteboard) else { return false }
                    apply(OTPInputScanner.scan(pasteboard: pasteboard))
                    return true
                }
                .padding(.horizontal, 6)
                Menu {
                    Button("Scan Clipboard") { apply(OTPInputScanner.scan(pasteboard: .general)) }
                    Button("Choose Image…") { chooseQRImage() }
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                } primaryAction: {
                    apply(OTPInputScanner.scan(pasteboard: .general))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Scan a QR code from the clipboard. Take a screenshot of it with ⌃⇧⌘4 first.")
                .accessibilityLabel("Scan QR Code")
            }
            if !otpScanError.isEmpty {
                Text(otpScanError)
                    .font(.caption)
                    .foregroundStyle(Palette.error(dark: colorScheme == .dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let draft = otpDraft {
                OneTimeCodePreview(session: session, premium: session.premium, draft: draft)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            readDrop(providers)
            return true
        }
        .onChange(of: otpInput) { _, _ in otpScanError = "" }
    }

    /// The item as it would be saved with what the field holds now, for the code preview.
    private var otpDraft: VaultEntry? {
        guard var entry = session.editing else { return nil }
        entry.otp = editorOTPValue(otpInput, title: entry.title, username: entry.username)
        return entry
    }

    /// A scan fills the field, and an empty title or username from the QR code. A failure says why under the row.
    private func apply(_ outcome: OTPScanOutcome) {
        switch outcome {
        case .scanned(let scan):
            otpInput = scan.uri
            if session.editing?.title.isEmpty == true, !scan.issuer.isEmpty { session.editing?.title = scan.issuer }
            if session.editing?.username.isEmpty == true, !scan.account.isEmpty { session.editing?.username = scan.account }
            // After `otpInput` changed, which clears the message.
            DispatchQueue.main.async { otpScanError = "" }
        case .failed(let text):
            DispatchQueue.main.async { otpScanError = text }
        }
    }

    private func chooseQRImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture of the QR code"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(OTPInputScanner.scan(fileURL: url))
    }

    /// An image file from Finder, or an image dragged from another app.
    private func readDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { apply(url.map(OTPInputScanner.scan(fileURL:)) ?? .failed(OTPInputScanner.unreadableImage)) }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                let image = image as? NSImage
                DispatchQueue.main.async { apply(image.map(OTPInputScanner.scan(image:)) ?? .failed(OTPInputScanner.unreadableImage)) }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<VaultEntry, String>) -> Binding<String> {
        Binding(
            get: { session.editing?[keyPath: keyPath] ?? "" },
            set: { session.editing?[keyPath: keyPath] = $0 }
        )
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(get: { session.editing?.favorite ?? false }, set: { session.editing?.favorite = $0 })
    }

    /// A bare Base32 secret becomes an otpauth URL, the form KeePassXC stores in the `otp` field.
    private func commit() {
        guard var entry = session.editing else { return }
        entry.otp = editorOTPValue(otpInput, title: entry.title, username: entry.username)
        let favorite = entry.favorite
        var tags = tagsInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        tags.removeAll { $0.caseInsensitiveCompare("Favorite") == .orderedSame }
        entry.tags = tags.joined(separator: ",")
        entry.favorite = favorite
        EntryMerge.setKeepSeparate(keepSeparate, on: &entry)
        EntryFields.apply(websites: websites, custom: fields + unnamed, to: &entry)
        PasswordRotation.setPeriod(chosenPeriod, on: &entry)
        PasswordRotation.setResetLink(chosenPeriod == nil ? "" : resetLink, on: &entry)
        session.saveEditing(entry)
    }
}

// MARK: Editor rows (DESIGN.md, "Item editor")

enum EditorMetrics {
    static let row: CGFloat = 30
    /// The label column. A value's text starts 6 pt after it, inside its field.
    static let label: CGFloat = 122
    /// One slot of the action column at the end of a row.
    static let action: CGFloat = 20
}

/// The small name over a card that has no label column of its own.
struct EditorSectionLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
            .padding(.leading, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EditorCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card(dark: colorScheme == .dark)))
    }
}

struct EditorDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
    }
}

/// A label in the label column, then the value and the row's actions. An empty label keeps the column; nil gives it up.
struct EditorRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                    .lineLimit(1)
                    .frame(width: EditorMetrics.label, alignment: .leading)
            }
            content
        }
        .padding(.leading, 12)
        .padding(.trailing, label == nil ? 12 : 8)
        .frame(minHeight: EditorMetrics.row)
    }
}

/// A plain text field that shows the focus outline only while it has the keyboard.
struct EditorField: View {
    @Environment(\.colorScheme) private var colorScheme
    var placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var secondary = false
    /// True for a row that was just added: it takes the keyboard when it appears.
    var takesKeyboard = false
    @FocusState private var focused: Bool

    var body: some View {
        let dark = colorScheme == .dark
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: size, weight: weight, design: mono ? .monospaced : .default))
        .foregroundStyle(secondary ? Palette.secondaryText(dark: dark) : Palette.text(dark: dark))
        .focused($focused)
        .padding(.horizontal, 6)
        .frame(height: size > 13 ? 26 : 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(focused ? Palette.surface(dark: dark) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.focus(dark: dark), lineWidth: 1.5).opacity(focused ? 1 : 0))
        .onAppear { if takesKeyboard { focused = true } }
    }
}

/// One slot of a row's action column: show, remove.
struct EditorIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                .frame(width: EditorMetrics.action, height: EditorMetrics.action)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The quiet last row of a list: a plus and what it adds, in the value column.
struct EditorAddRow: View {
    @Environment(\.colorScheme) private var colorScheme
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
            .padding(.leading, 12 + EditorMetrics.label + 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The one-time password field. A text field cannot paste a picture, so ⌘V with only an image on the clipboard goes to
/// `pasteImage` instead, while this field is being edited. True from it means the paste was handled.
struct OTPInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var pasteImage: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        // Drawn like the editor's other fields: no bezel, no background.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("One-time password")
        context.coordinator.field = field
        context.coordinator.install()
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OTPInputField
        weak var field: NSTextField?
        private var monitor: Any?

        init(_ parent: OTPInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let field = self.field, field.currentEditor() != nil, event.window === field.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                return self.parent.pasteImage(.general) ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The code the editor's field would give, under it. Observes Premium, so it unlocks the moment Premium arrives.
private struct OneTimeCodePreview: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var premium: PremiumStore
    var draft: VaultEntry

    var body: some View {
        let access = session.oneTimeCodeAccess(for: draft)
        if access != .noCode {
            HStack(spacing: 8) {
                OneTimeCodeView(access: access)
                if access == .locked {
                    SplitActionButton(title: FieldAction.upgrade.title, prominence: .primary, weight: .semibold, items: []) { session.requestPremium() }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
