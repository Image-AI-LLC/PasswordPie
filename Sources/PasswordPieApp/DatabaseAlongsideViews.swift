import PasswordPieCore
import SwiftUI

/// A database of the list that is not open, while another one is: its master password, and Unlock, which opens it
/// beside the open one without locking anything (`VaultSession.unlockAlongside`). Used by Preferences > Database and by
/// Preferences > Agents for the agents database. See "Two databases at once, and a Mac nobody sits at" in docs/UX.md.
struct DatabaseUnlockField: View {
    @ObservedObject var session: VaultSession
    let path: String
    /// Starts with the field showing, as Preferences > Agents does for a request that waits.
    var startOpen = false
    @State private var showing = false
    @State private var password = ""
    @State private var problem = ""
    @State private var busy = false

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        if showing || startOpen {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SecureField("Master password of \(name)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(unlock)
                        .disabled(busy)
                        .accessibilityIdentifier("database.unlock.password")
                    Button(busy ? "Unlocking…" : "Unlock", action: unlock)
                        .disabled(busy || password.isEmpty)
                    if !startOpen {
                        Button("Cancel") { showing = false; password = ""; problem = "" }
                            .disabled(busy)
                    }
                }
                if !problem.isEmpty {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Button("Unlock…") { showing = true }
                .help("Open \(name) beside the database that is open, with its own master password")
        }
    }

    private func unlock() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        problem = ""
        session.unlockAlongside(path, password: password) { failure in
            busy = false
            password = ""
            if let failure {
                problem = failure
            } else {
                showing = false
            }
        }
    }
}
