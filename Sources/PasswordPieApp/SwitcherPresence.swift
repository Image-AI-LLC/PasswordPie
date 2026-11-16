import AppKit

/// Whether PasswordPie is in the ⌘Tab switcher and the Dock (docs/UX.md, "Preferences is in the app switcher").
/// macOS lists an app there only while its activation policy is `.regular`, and the policy belongs to the whole app,
/// so it follows the one window a user has to find again. The menu and the pinned windows never ask for it.
@MainActor
final class SwitcherPresence {
    static func policy(preferencesOpen: Bool) -> NSApplication.ActivationPolicy {
        preferencesOpen ? .regular : .accessory
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
    func sync(preferencesOpen: Bool) {
        let wanted = Self.policy(preferencesOpen: preferencesOpen)
        if current() != wanted { apply(wanted) }
    }
}
