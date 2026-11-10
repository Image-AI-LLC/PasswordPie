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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: binding(\.title))
                TextField("Username", text: binding(\.username))
                HStack(spacing: 6) {
                    if showPassword {
                        TextField("Password", text: binding(\.password)).font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("Password", text: binding(\.password))
                    }
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                    Button("Generate") { session.editing?.password = PasswordGenerator.generate(CharacterRecipe()) }
                }
                TextField("Website", text: binding(\.url))
                oneTimePasswordRow
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: binding(\.notes))
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
                }
                TextField("Tags (comma separated)", text: $tagsInput)
                Toggle("Favorite", isOn: favoriteBinding)
                Toggle("Don't auto-merge", isOn: $keepSeparate)
                if let entry = session.editing, EntryMerge.partCount(entry) >= 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Merged from \(EntryMerge.partCount(entry)) accounts. Split restores them and keeps them separate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        let extras = EntryMerge.extraFields(entry)
                        if !extras.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(extras.enumerated()), id: \.offset) { _, field in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(field.key).font(.caption).foregroundStyle(.secondary)
                                            if field.protected {
                                                Text(mergedExtraFieldText(field))
                                                    .font(.system(.caption, design: .monospaced))
                                                    .fixedSize(horizontal: false, vertical: true)
                                            } else {
                                                Text(field.value)
                                                    .font(.system(.caption))
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                if !session.editingIsNew {
                    Button("Move to Trash", role: .destructive) { session.deleteEditing() }
                }
                if let entry = session.editing, EntryMerge.partCount(entry) >= 2 {
                    Button("Split") { confirmSplit = true }
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
        .onAppear {
            guard !loaded, let entry = session.editing else { return }
            otpInput = entry.otp
            tagsInput = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }.joined(separator: ", ")
            keepSeparate = EntryMerge.keepsSeparate(entry)
            loaded = true
        }
    }

    // MARK: One-time password

    /// The field, its QR button, what went wrong with the last scan, and the current code once there is one.
    private var oneTimePasswordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("One-time password") {
                HStack(spacing: 6) {
                    OTPInputField(text: $otpInput, placeholder: "Base32 secret or otpauth:// URL") { pasteboard in
                        guard OTPInputScanner.holdsOnlyAnImage(pasteboard) else { return false }
                        apply(OTPInputScanner.scan(pasteboard: pasteboard))
                        return true
                    }
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
            }
            if !otpScanError.isEmpty {
                Text(otpScanError)
                    .font(.caption)
                    .foregroundStyle(Palette.error(dark: colorScheme == .dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let draft = otpDraft {
                let access = session.oneTimeCodeAccess(for: draft)
                if access != .noCode {
                    HStack(spacing: 8) {
                        OneTimeCodeView(access: access)
                        if access == .locked {
                            Button("Upgrade") { session.requestPremium() }.controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
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
        session.saveEditing(entry)
    }
}

/// Protected merge extras stay masked, the same way the details view hides a secret.
func mergedExtraFieldText(_ field: VaultField) -> String {
    guard field.protected else { return field.value }
    return String(repeating: "•", count: min(max(field.value.count, 8), 16))
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
        field.bezelStyle = .roundedBezel
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
