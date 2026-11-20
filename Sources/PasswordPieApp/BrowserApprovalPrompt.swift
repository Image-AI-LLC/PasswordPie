import AppKit
import PasswordPieBridge
import SwiftUI

/// The question asked once per browser built on Chromium, the first time its extension connects (docs/UX.md, "Other
/// browsers built on Chrome"; DESIGN.md, "Browser question window"). Neither button is the default and no key presses
/// either: a key pressed by accident neither lets a browser in nor shuts it out.
enum BrowserApprovalPrompt {
    static let width: CGFloat = 480

    /// A browser's name with non-breaking spaces, so a line never ends inside it.
    static func unbroken(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func title(_ identity: ChromiumBrowserIdentity) -> String {
        "Allow “\(unbroken(identity.name))” to fill passwords?"
    }

    /// Who signed the browser. Nil when the certificate names no organization.
    static func signerLine(_ identity: ChromiumBrowserIdentity) -> String? {
        identity.signer.map { "Signed by \($0)" }
    }

    static let effect = "It gets the username and password of each account you pick."

    static func condition(_ identity: ChromiumBrowserIdentity) -> String {
        "Only allow it if you added the PasswordPie extension to \(unbroken(identity.name)) yourself."
    }

    static let changeNote = "You can change this in Preferences > Browsers."
    static let denyTitle = "Don't Allow"
    static let allowTitle = "Allow"

    /// The questions on screen now, so their windows stay alive until answered.
    @MainActor private(set) static var open: [BrowserApprovalModel] = []

    @MainActor
    static func ask(_ identity: ChromiumBrowserIdentity, answer: @escaping @MainActor (Bool) -> Void) {
        // After the current event: the question must not open inside the caller's work.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let model = BrowserApprovalModel(identity: identity, answer: answer)
                let panel = panel(for: model)
                model.onAnswered = { [weak model] in
                    panel.close()
                    open.removeAll { $0 === model }
                }
                open.append(model)
                panel.center()
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                #if DEBUG
                model.runDebugScript()
                #endif
            }
        }
    }

    /// The window, not yet on screen: the approval window's panel, with no title and no close button.
    @MainActor
    static func panel(for model: BrowserApprovalModel) -> NSPanel {
        // The title bar is hidden and the content runs under it, so the view is laid out without the bar's safe area and
        // the window takes the view's own size.
        let view = NSHostingView(rootView: BrowserApprovalView(model: model))
        view.safeAreaRegions = []
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: view.fittingSize),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true
        )
        panel.contentView = view
        panel.title = "PasswordPie"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// One open question: which browser, and the answer given at most once.
@MainActor
final class BrowserApprovalModel: ObservableObject {
    let identity: ChromiumBrowserIdentity
    private var answer: (@MainActor (Bool) -> Void)?
    /// Closes the window.
    var onAnswered: (() -> Void)?

    init(identity: ChromiumBrowserIdentity, answer: @escaping @MainActor (Bool) -> Void) {
        self.identity = identity
        self.answer = answer
    }

    func allow() { finish(true) }
    func deny() { finish(false) }

    private func finish(_ allowed: Bool) {
        guard let answer else { return }
        self.answer = nil
        answer(allowed)
        onAnswered?()
        // The closure holds the panel, and the panel holds this model through its view: break the cycle once answered.
        onAnswered = nil
    }

    /// The window's words, for the status file a debug build writes.
    var debugSummary: [String: Any] {
        [
            "title": BrowserApprovalPrompt.title(identity),
            "browser": identity.name,
            "signer": BrowserApprovalPrompt.signerLine(identity) ?? NSNull(),
            "effect": BrowserApprovalPrompt.effect,
            "condition": BrowserApprovalPrompt.condition(identity),
            "note": BrowserApprovalPrompt.changeNote,
            "buttons": [BrowserApprovalPrompt.denyTitle, BrowserApprovalPrompt.allowTitle]
        ]
    }

    #if DEBUG
    /// Debug builds only: `PASSWORDPIE_BROWSER_APPROVE` (`allow` or `deny`) answers the window two seconds after it
    /// opens, so the question can be tried on a Mac nobody sits at. `hold`, or any other word, leaves it open: a
    /// misspelt word must not write an answer into the preferences the debug build shares with the installed app.
    func runDebugScript() {
        guard let step = ProcessInfo.processInfo.environment["PASSWORDPIE_BROWSER_APPROVE"], ["allow", "deny"].contains(step) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                if step == "allow" { self?.allow() } else { self?.deny() }
            }
        }
    }
    #endif
}

struct BrowserApprovalView: View {
    @ObservedObject var model: BrowserApprovalModel
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    /// The two icons share a column this wide; every line beside them starts at one edge.
    private let iconColumn: CGFloat = 32

    var body: some View {
        let identity = model.identity
        VStack(alignment: .leading, spacing: 0) {
            // Who asks.
            HStack(spacing: 12) {
                PasswordPieMark(size: 30)
                    .frame(width: iconColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PasswordPie")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondaryText(dark: dark))
                    Text(BrowserApprovalPrompt.title(identity))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.text(dark: dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            // Who is asked about: the browser's own icon, its name and who signed it.
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: identity.bundleURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconColumn, height: iconColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrowserApprovalPrompt.unbroken(identity.name))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.text(dark: dark))
                        .fixedSize(horizontal: false, vertical: true)
                    if let signer = BrowserApprovalPrompt.signerLine(identity) {
                        Text(signer)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText(dark: dark))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 16)
            .help(identity.bundleURL.path)
            // What allowing does, then when to allow: the full width, from the buttons' left edge.
            Text(BrowserApprovalPrompt.effect)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Text(BrowserApprovalPrompt.condition(identity))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Text(BrowserApprovalPrompt.changeNote)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText(dark: dark))
                .padding(.top, 8)
            // Equal width, equal weight, no default: neither answer is pushed.
            HStack(spacing: 10) {
                Button { model.deny() } label: {
                    Text(BrowserApprovalPrompt.denyTitle).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("browserApproval.deny")
                Button { model.allow() } label: {
                    Text(BrowserApprovalPrompt.allowTitle).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("browserApproval.allow")
            }
            .controlSize(.large)
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: BrowserApprovalPrompt.width, alignment: .leading)
        .background(Palette.windowSurface(dark: dark))
    }
}
