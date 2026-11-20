import AppKit
import PasswordPieBridge

/// The question asked once per browser built on Chromium, the first time its extension connects (docs/UX.md, "Other
/// browsers built on Chrome"). Return is Don't Allow: a key pressed by accident never lets a browser in.
enum BrowserApprovalPrompt {
    static func title(_ identity: ChromiumBrowserIdentity) -> String {
        "Allow “\(identity.name)” to fill passwords?"
    }

    static func message(_ identity: ChromiumBrowserIdentity) -> String {
        var text = "The PasswordPie extension in \(identity.name) wants to connect. Once allowed, \(identity.name) gets an "
            + "account's username and password when you pick it in PasswordPie, as Chrome does."
        let signer = identity.signer.map { "Signed by \($0). " } ?? ""
        text += "\n\n\(signer)Allow it only if you added the PasswordPie extension to \(identity.name) yourself. "
            + "You can change this in Preferences > Browsers."
        return text
    }

    static let denyTitle = "Don't Allow"
    static let allowTitle = "Allow"

    @MainActor
    static func ask(_ identity: ChromiumBrowserIdentity, answer: @escaping @MainActor (Bool) -> Void) {
        // After the current event: the question must not run inside the caller's work.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = title(identity)
                alert.informativeText = message(identity)
                alert.icon = NSWorkspace.shared.icon(forFile: identity.bundleURL.path)
                alert.addButton(withTitle: denyTitle)
                alert.addButton(withTitle: allowTitle)
                NSApp.activate(ignoringOtherApps: true)
                answer(alert.runModal() == .alertSecondButtonReturn)
            }
        }
    }
}
