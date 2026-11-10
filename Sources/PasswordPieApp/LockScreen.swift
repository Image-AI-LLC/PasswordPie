import AppKit
import SwiftUI

/// Existing controller timing drives a gentle mark pulse and content fade.
@MainActor
final class LockModel: ObservableObject {
    @Published var turned = false
    @Published var open = false
    /// The lock scene plays: the locked card replaces the form.
    @Published var locking = false
    let fields = LockFields()
}

/// Native password fields behind the lock screen, so the panel can focus them directly.
@MainActor
final class LockFields {
    private(set) var primary: NSSecureTextField?
    private(set) var confirm: NSSecureTextField?

    func register(_ field: NSSecureTextField, isConfirm: Bool) {
        if isConfirm { confirm = field } else { primary = field }
    }

    func unregister(_ field: NSSecureTextField) {
        if primary === field { primary = nil }
        if confirm === field { confirm = nil }
    }
}

/// Values needed to present the lock form, without owning vault or credential state.
struct LockScreenPresentation: Equatable {
    var databaseName: String
    var creating = false
    var message = ""
    var showsKeyFile = false
    var keyFileName = ""
    var touchIDAvailable = false
    /// The database is decrypting: the logo's rim turns.
    var unlocking = false
    /// Decrypting or just opened: the form stays where it is, dimmed, and takes no input.
    var busy = false
    /// Just locked by ⌘L: the locked card replaces the form until the panel fades out.
    var locking = false
}

extension LockScreenPresentation {
    @MainActor
    init(session: VaultSession, locking: Bool) {
        self.init(databaseName: session.databaseURL.lastPathComponent,
                  creating: session.creating, message: session.message,
                  showsKeyFile: session.showsKeyFile, keyFileName: session.keyFileName,
                  touchIDAvailable: session.touchIDAvailable,
                  unlocking: session.unlocking, busy: session.unlocking || !session.locked,
                  locking: locking)
    }
}

struct LockScreenActions {
    static let inert = LockScreenActions(unlock: {}, touchID: {}, open: {}, create: {}, keyFile: {}, edit: {})

    var unlock: () -> Void
    var touchID: () -> Void
    var open: () -> Void
    var create: () -> Void
    var keyFile: () -> Void
    var edit: () -> Void
    /// The × beside a chosen or remembered key file: Forget Key File.
    var forgetKeyFile: () -> Void = {}
}

enum LockFieldFocus: Equatable {
    case primary
    case confirmation

    static func updated(_ current: Self?, field: Self, focused: Bool) -> Self? {
        if focused { return field }
        // Native editing notifications can overlap when moving between fields.
        return current == field ? nil : current
    }
}

/// Retains the controller-facing interface while replacing the old split metal doors.
struct DoorsView: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var lock: LockModel

    var body: some View {
        LockScreenContent(
            presentation: LockScreenPresentation(session: session, locking: lock.locking),
            password: $session.passwordDraft, confirmation: $session.confirmDraft,
            fields: lock.fields, turned: lock.turned,
            actions: LockScreenActions(
                unlock: session.unlock, touchID: session.unlockWithTouchID,
                open: session.chooseDatabase, create: session.newDatabase,
                keyFile: session.chooseKeyFile,
                edit: { if !session.message.isEmpty { session.message = "" } },
                forgetKeyFile: { session.forgetKeyFile() }))
            .scaleEffect(lock.open ? 0.97 : 1)
            .opacity(lock.open ? 0 : 1)
            // The lock scene covers the menu quickly; the unlock fade is slower.
            .animation(.easeInOut(duration: lock.locking ? 0.15 : 0.3), value: lock.open)
    }
}

struct LockScreenContent: View {
    var presentation: LockScreenPresentation
    @Binding var password: String
    @Binding var confirmation: String
    var fields: LockFields
    var turned = false
    var actions: LockScreenActions
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusedField: LockFieldFocus?

    private var dark: Bool { colorScheme == .dark }
    private var foreground: Color { Palette.text(dark: dark) }
    private var secondary: Color { Palette.secondaryText(dark: dark) }

    private var databaseTitle: some View {
        databaseNameLabel
            .padding(.top, 4)
    }

    private var databaseNameLabel: some View {
        Text(presentation.databaseName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(presentation.databaseName)
    }

    /// The height the panel needs for this presentation at the given width: the form's content, or the locked card.
    static func fittedHeight(_ presentation: LockScreenPresentation, width: CGFloat = Metrics.width) -> CGFloat {
        let content = LockScreenContent(presentation: presentation, password: .constant(""),
                                        confirmation: .constant(""), fields: LockFields(), actions: .inert)
        let sizing = NSHostingController(rootView: content.fixedSize(horizontal: false, vertical: true))
        return ceil(sizing.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }

    var body: some View {
        Group {
            if presentation.locking {
                lockedCard
            } else {
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface(dark: dark))
        .animation(.easeInOut(duration: 0.2), value: presentation.locking)
    }

    /// Shown while ⌘L locks the open menu. It sits at the top, so it does not move while the panel folds around it.
    private var lockedCard: some View {
        VStack(spacing: 0) {
            PasswordPieMark(size: 46, turn: turned ? 1 : 0)
            Text("Locked")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(foreground)
                .padding(.top, 14)
                .accessibilityIdentifier("lock.locked")
            databaseNameLabel
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.lockCardHeight)
    }

    private var form: some View {
        VStack(spacing: 0) {
            PasswordPieMark(size: 64, turn: turned ? 1 : 0, spinning: presentation.unlocking)
            Text("Password Pie")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(foreground)
                .padding(.top, 4)
            databaseTitle
            guidance
                .padding(.top, 3)
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// One line of guidance. An error takes its place, so no blank space is kept for one.
    @ViewBuilder
    private var guidance: some View {
        if presentation.message.isEmpty {
            Text(presentation.creating ? "Choose a password for your new database." : "Your passwords, kept safe.")
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else {
            Text(presentation.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.error(dark: dark))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .help(presentation.message)
                .accessibilityIdentifier("lock.error")
        }
    }

    /// Everything below the guidance line: the fields, buttons and database links. While the database opens they stay
    /// where they are, dimmed, and take no input.
    private var controls: some View {
        let busy = presentation.busy
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Group {
                    secureEntry(placeholder: "Master password", text: $password, isConfirm: false) {
                        if presentation.creating {
                            fields.confirm?.window?.makeFirstResponder(fields.confirm)
                        } else {
                            actions.unlock()
                        }
                    }
                    if presentation.creating {
                        secureEntry(placeholder: "Repeat password", text: $confirmation, isConfirm: true,
                                    submit: actions.unlock)
                    }
                }
                .opacity(busy ? 0.55 : 1)
                .disabled(busy)
                Button(action: actions.unlock) {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Palette.brandAccent, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!busy)
                .accessibilityIdentifier("lock.unlock")
                // Empty passwords remain actionable for key-file-only databases.
            }
            .padding(.top, 12)

            VStack(spacing: 0) {
                if presentation.touchIDAvailable && !presentation.creating {
                    Button(action: actions.touchID) {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("lock.touchID")
                    .padding(.top, 4)
                }
                if presentation.showsKeyFile {
                    keyFileRow
                }
                HStack(spacing: 12) {
                    Button("Open Database…", action: actions.open)
                        .accessibilityIdentifier("lock.open")
                    Rectangle().fill(Palette.border(dark: dark)).frame(width: 1, height: 12)
                    Button("New Database…", action: actions.create)
                        .accessibilityIdentifier("lock.new")
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(secondary)
                .frame(height: 18)
                .padding(.top, 14)
            }
            .opacity(busy ? 0.4 : 1)
            .disabled(busy)
        }
        .animation(.easeInOut(duration: 0.2), value: busy)
    }

    /// The key file's name, or a button to choose one. A name has a × that forgets it on this Mac.
    private var keyFileRow: some View {
        let name = presentation.keyFileName
        let title = name.isEmpty ? (presentation.creating ? "Add Key File…" : "Choose Key File…") : name
        return HStack(spacing: 4) {
            Spacer(minLength: 0)
            Button(action: actions.keyFile) {
                Label(title, systemImage: "key")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name.isEmpty ? (presentation.creating ? "Add a key file to the new database" : "Choose this database's key file") : name)
            .accessibilityIdentifier("lock.keyFile")
            if !name.isEmpty {
                Button(action: actions.forgetKeyFile) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Forget Key File")
                .accessibilityLabel("Forget Key File")
                .accessibilityIdentifier("lock.forgetKeyFile")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var buttonTitle: String {
        if presentation.busy { return presentation.creating ? "Creating…" : "Unlocking…" }
        return presentation.creating ? "Create Database" : "Unlock"
    }

    private func secureEntry(placeholder: String, text: Binding<String>, isConfirm: Bool,
                             submit: @escaping () -> Void) -> some View {
        let role: LockFieldFocus = isConfirm ? .confirmation : .primary
        let focused = focusedField == role
        return PasswordField(placeholder: placeholder, text: text, fields: fields,
                      isConfirm: isConfirm, onEdit: actions.edit,
                      onFocusChange: { focusedField = LockFieldFocus.updated(focusedField, field: role, focused: $0) },
                      submit: submit)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Palette.fieldSurface(dark: dark), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(focused ? Palette.focus(dark: dark) : Palette.border(dark: dark),
                        lineWidth: focused ? 1.5 : 1))
    }
}

/// Reports native focus even before an empty field receives its first keystroke.
final class FocusAwareSecureTextField: NSSecureTextField {
    var focusChanged: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { reportFocusAfterResponderChange() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { reportFocusAfterResponderChange() }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        reportFocusAfterResponderChange()
    }

    private func reportFocusAfterResponderChange() {
        // AppKit transfers actual first-responder status to a shared field editor.
        // Defer until that handoff completes; never report a stale focus request.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let editor = self.currentEditor()
            let focused = self.window?.firstResponder === self ||
                (editor != nil && self.window?.firstResponder === editor)
            self.focusChanged(focused)
        }
    }
}

/// A native secure field. Typing clears a pending error, Return submits, and the panel focuses it directly.
struct PasswordField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var fields: LockFields
    var isConfirm: Bool
    var onEdit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    var submit: () -> Void

    func makeNSView(context: Context) -> FocusAwareSecureTextField {
        let field = FocusAwareSecureTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        applyColors(to: field, scheme: context.environment.colorScheme)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        field.cell?.usesSingleLineMode = true
        field.isEnabled = context.environment.isEnabled
        fields.register(field, isConfirm: isConfirm)
        return field
    }

    func updateNSView(_ field: FocusAwareSecureTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        applyColors(to: field, scheme: context.environment.colorScheme)
        if field.stringValue != text { field.stringValue = text }
    }

    private func applyColors(to field: NSSecureTextField, scheme: ColorScheme) {
        let dark = scheme == .dark
        field.textColor = NSColor(Palette.text(dark: dark))
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(Palette.secondaryText(dark: dark)),
            .font: NSFont.systemFont(ofSize: 13)
        ])
    }

    static func dismantleNSView(_ field: FocusAwareSecureTextField, coordinator: Coordinator) {
        field.focusChanged = { _ in }
        coordinator.parent.fields.unregister(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasswordField

        init(_ parent: PasswordField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
            parent.onEdit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }
    }
}
