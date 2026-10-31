import AppKit
import SwiftUI

/// Existing controller timing drives a gentle mark pulse and content fade.
@MainActor
final class LockModel: ObservableObject {
    @Published var turned = false
    @Published var open = false
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
struct LockScreenPresentation {
    var databaseName: String
    /// Menu titles when more than one database is open. Empty keeps the plain name.
    var databaseChoices: [String] = []
    var creating = false
    var message = ""
    var showsKeyFile = false
    var keyFileName = ""
    var touchIDAvailable = false
}

struct LockScreenActions {
    var unlock: () -> Void
    var touchID: () -> Void
    var open: () -> Void
    var create: () -> Void
    var keyFile: () -> Void
    var edit: () -> Void
    var selectDatabase: (Int) -> Void = { _ in }
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
            presentation: LockScreenPresentation(
                databaseName: session.databaseURL.lastPathComponent,
                databaseChoices: session.databasePaths.count > 1 ? session.databaseMenuTitles : [],
                creating: session.creating, message: session.message,
                showsKeyFile: session.showsKeyFile, keyFileName: session.keyFileName,
                touchIDAvailable: session.touchIDAvailable),
            password: $session.passwordDraft, confirmation: $session.confirmDraft,
            fields: lock.fields, turned: lock.turned,
            actions: LockScreenActions(
                unlock: session.unlock, touchID: session.unlockWithTouchID,
                open: session.chooseDatabase, create: session.newDatabase,
                keyFile: session.chooseKeyFile,
                edit: { if !session.message.isEmpty { session.message = "" } },
                selectDatabase: { index in
                    let paths = session.databasePaths
                    guard paths.indices.contains(index) else { return }
                    session.selectDatabase(paths[index])
                }))
            .scaleEffect(lock.open ? 0.97 : 1)
            .opacity(lock.open ? 0 : 1)
            .animation(.easeInOut(duration: 0.3), value: lock.open)
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

    /// One database shows its name. Several databases open a menu. Each file keeps its own keychain secret.
    @ViewBuilder private var databaseTitle: some View {
        if presentation.databaseChoices.count > 1 {
            Menu {
                ForEach(Array(presentation.databaseChoices.enumerated()), id: \.offset) { index, title in
                    Button(title) { actions.selectDatabase(index) }
                }
            } label: {
                databaseNameLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.top, 4)
        } else {
            databaseNameLabel
                .padding(.top, 4)
        }
    }

    private var databaseNameLabel: some View {
        Text(presentation.databaseName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(presentation.databaseName)
    }

    var body: some View {
        VStack(spacing: 0) {
            PasswordPieMark(size: 64, turn: turned ? 1 : 0)
            Text("Password Pie")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(foreground)
                .padding(.top, 4)
            databaseTitle
            Text(presentation.creating ? "Choose a password for your new database." : "Your passwords, kept safe.")
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 3)

            VStack(spacing: 8) {
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
                Button(action: actions.unlock) {
                    Text(presentation.creating ? "Create Database" : "Unlock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Palette.brandAccent, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lock.unlock")
                // Empty passwords remain actionable for key-file-only databases.
            }
            .padding(.top, 12)

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
                Button(action: actions.keyFile) {
                    Label(presentation.keyFileName.isEmpty ? "Choose Key File…" : presentation.keyFileName,
                          systemImage: "key")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondary)
                .help(presentation.keyFileName.isEmpty ? "Choose a key file" : presentation.keyFileName)
                .accessibilityIdentifier("lock.keyFile")
                .padding(.top, 4)
            }

            Text(presentation.message.isEmpty ? " " : presentation.message)
                .font(.system(size: 10))
                .foregroundStyle(Palette.error(dark: dark))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity)
                .frame(height: 36, alignment: .top)
                .help(presentation.message)
                .accessibilityIdentifier("lock.error")
                .padding(.top, 6)
            Spacer(minLength: 0)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface(dark: dark))
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
        fields.register(field, isConfirm: isConfirm)
        return field
    }

    func updateNSView(_ field: FocusAwareSecureTextField, context: Context) {
        context.coordinator.parent = self
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
