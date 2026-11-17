import AppKit

/// Whether PasswordPie is in the ⌘Tab switcher and the Dock (docs/UX.md, "Preferences is in the app switcher").
/// macOS lists an app there only while its activation policy is `.regular`, and the policy belongs to the whole app,
/// so it follows the one window a user has to find again. The menu and the pinned windows never ask for it.
@MainActor
final class SwitcherPresence {
    /// `otherWindowOpen`: the item editor, About, Premium or the Chrome review window. None of them puts the app in the
    /// switcher, but one still open when Preferences closes keeps it there: leaving the switcher gives the keyboard to
    /// the app behind, and that window would drop behind it with no way back.
    static func policy(
        preferencesOpen: Bool,
        otherWindowOpen: Bool,
        current: NSApplication.ActivationPolicy
    ) -> NSApplication.ActivationPolicy {
        if preferencesOpen { return .regular }
        return current == .regular && otherWindowOpen ? .regular : .accessory
    }

    private let current: () -> NSApplication.ActivationPolicy
    private let apply: (NSApplication.ActivationPolicy) -> Void

    init(
        current: @escaping () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
        apply: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }
    ) {
        self.current = current
        self.apply = apply
    }

    /// Setting the policy it already has still makes the Dock redraw, so it is set only on a change.
    func sync(preferencesOpen: Bool, otherWindowOpen: Bool) {
        let now = current()
        let wanted = Self.policy(preferencesOpen: preferencesOpen, otherWindowOpen: otherWindowOpen, current: now)
        if now != wanted { apply(wanted) }
    }
}
