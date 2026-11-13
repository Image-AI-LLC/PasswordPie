import AppKit
import PasswordPieCore
import SwiftUI

#if PP_DIRECT
/// The question after a change-password page took an account's new password: did the website accept it?
/// PasswordPie never decides that by itself, so nothing changes until the person answers
/// (docs/UX.md, "Reset Password makes the new password for you").
@MainActor
final class PasswordChangeModel: ObservableObject {
    struct Question: Equatable {
        var entryID: UUID
        /// The account's title, for the window's title.
        var title: String
        /// The page that reported, as the person knows it.
        var host: String
    }

    @Published private(set) var question: Question?
    /// Use New Password could not be written. The question stays, so it can be tried again.
    @Published private(set) var failed = false

    private unowned let session: VaultSession
    /// Shows the window. Wired by the app delegate.
    var present: (() -> Void)?
    /// Closes it.
    var dismiss: (() -> Void)?

    init(session: VaultSession) {
        self.session = session
    }

    /// The browser extension says the page's form was sent. Asked only while the account still has a new password
    /// waiting; a locked vault drops it, because the question would name an account on the lock screen.
    func receive(_ entryID: UUID, host: String) {
        guard !session.locked, let entry = session.storedEntry(entryID),
              PreviousPasswords.candidate(of: entry, now: session.chromeClock()) != nil else { return }
        failed = false
        question = Question(entryID: entryID, title: entry.title, host: host)
        present?()
    }

    /// Use New Password: it becomes the saved password, and the old one goes to previous passwords. When the new password
    /// is gone by now (used from the details, or changed in the editor) there is nothing left to do.
    func useNewPassword() {
        guard let question else { return }
        guard !session.locked, let entry = session.storedEntry(question.entryID),
              PreviousPasswords.candidate(of: entry, now: session.chromeClock()) != nil else {
            finish()
            return
        }
        guard session.usePasswordCandidate(of: question.entryID) else {
            failed = true
            return
        }
        finish()
    }

    /// Not Yet, the close button, and locking. Nothing changes: the new password keeps waiting in previous passwords.
    func cancel() {
        question = nil
        failed = false
    }

    private func finish() {
        cancel()
        dismiss?()
    }
}

/// The window over the browser: one question, Use New Password and Not Yet.
struct PasswordChangeConfirmView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: PasswordChangeModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.brandAccent)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Did \(model.question?.host ?? "the website") accept the new password?")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use New Password makes it the saved password. The old one goes to previous passwords.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.failed {
                Text("Couldn't save. Nothing changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.error(dark: colorScheme == .dark))
            }
            HStack {
                Spacer()
                Button("Not Yet") {
                    model.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Use New Password") { model.useNewPassword() }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    // No Return shortcut: the window comes up as the form is sent, and a Return still on its way must not answer it.
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
    }
}
#endif
