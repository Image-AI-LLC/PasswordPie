import AppKit
import PasswordPieCore
import SwiftUI

/// The Password Generator child window: a new password every time it opens, Characters and Words tabs.
@MainActor
final class GeneratorModel: ObservableObject {
    enum Mode: String { case characters = "Characters", words = "Words" }

    @Published var mode: Mode = .characters { didSet { regenerate() } }
    @Published var characters = CharacterRecipe() { didSet { regenerate() } }
    @Published var passphrase = PassphraseRecipe() { didSet { regenerate() } }
    @Published var password = ""
    private unowned let session: VaultSession

    init(session: VaultSession) {
        self.session = session
        regenerate()
    }

    func regenerate() {
        password = mode == .characters ? PasswordGenerator.generate(characters) : PasswordGenerator.generate(passphrase)
    }

    var strength: Double {
        mode == .words ? min(PasswordGenerator.entropyBits(passphrase) / 100, 1) : PasswordGenerator.strength(of: password)
    }

    /// Copy, then the whole popup hides.
    func copyAndHide() {
        session.copy(password)
        session.hidePanel?()
    }

    /// Saved only when the user chooses it; nothing is written silently.
    func saveAsPasswordItem() {
        session.saveGenerated(password)
        session.hidePanel?()
    }
}

struct GeneratorView: View {
    @ObservedObject var model: GeneratorModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(model.password)
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.card(dark: colorScheme == .dark)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                SplitActionButton(
                    title: "Copy",
                    size: .regular,
                    prominence: .primary,
                    items: [.init(title: "Save as Password Item") { model.saveAsPasswordItem() }]
                ) {
                    model.copyAndHide()
                }
            }
            Picker("", selection: $model.mode) {
                Text("Characters").tag(GeneratorModel.Mode.characters)
                Text("Words").tag(GeneratorModel.Mode.words)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.mode == .characters {
                stepperRow("Length", value: $model.characters.length, range: CharacterRecipe.lengthRange)
                stepperRow("Digits", value: $model.characters.digits, range: CharacterRecipe.countRange)
                stepperRow("Symbols", value: $model.characters.symbols, range: CharacterRecipe.countRange)
                Toggle("Avoid ambiguous characters", isOn: $model.characters.avoidAmbiguous)
            } else {
                stepperRow("Words", value: $model.passphrase.words, range: PassphraseRecipe.wordRange)
                HStack {
                    Text("Separator").frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.passphrase.separator) {
                        ForEach(["-", " ", ".", "_", ","], id: \.self) { Text($0 == " " ? "space" : $0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
            HStack {
                Button("Regenerate Password") { model.regenerate() }
                Spacer()
                ProgressView(value: model.strength).frame(width: 90)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 412, height: 300, alignment: .topLeading)
        .tint(Palette.brandAccent)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)").frame(width: 24, alignment: .trailing).monospacedDigit()
        }
    }
}
