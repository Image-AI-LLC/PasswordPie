import AppKit
import PasswordPieCore
import SwiftUI

// MARK: Editor (detached window)

struct EditorView: View {
    @ObservedObject var session: VaultSession
    @State private var showPassword = false
    @State private var otpInput = ""
    @State private var tagsInput = ""
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
                TextField("One-time password", text: $otpInput, prompt: Text("Base32 secret or otpauth:// URL"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: binding(\.notes))
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
                }
                TextField("Tags (comma separated)", text: $tagsInput)
                Toggle("Favorite", isOn: favoriteBinding)
            }
            .formStyle(.grouped)
            HStack {
                if !session.editingIsNew {
                    Button("Move to Trash", role: .destructive) { session.deleteEditing() }
                }
                Spacer()
                Button("Cancel") { session.cancelEditing() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 450, height: 560)
        .onAppear {
            guard !loaded, let entry = session.editing else { return }
            otpInput = entry.otp
            tagsInput = entry.tagList.filter { $0.caseInsensitiveCompare("Favorite") != .orderedSame }.joined(separator: ", ")
            loaded = true
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
        let trimmed = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            entry.otp = ""
        } else if trimmed.lowercased().hasPrefix("otpauth://") {
            entry.otp = trimmed
        } else {
            entry.otp = TOTP.otpAuthURL(secretBase32: trimmed, title: entry.title, username: entry.username)
        }
        let favorite = entry.favorite
        var tags = tagsInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        tags.removeAll { $0.caseInsensitiveCompare("Favorite") == .orderedSame }
        entry.tags = tags.joined(separator: ",")
        entry.favorite = favorite
        session.saveEditing(entry)
    }
}
