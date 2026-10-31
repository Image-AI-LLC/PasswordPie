import AppKit
import SwiftUI

enum PinnedWindowCloseReason: Equatable {
    case closeButton, resignKey, escape
}

/// A pinned account stays up while its fields are copied into another app.
/// Losing focus or pressing Escape must not dismiss it. Only the close button does.
func pinnedWindowShouldClose(_ reason: PinnedWindowCloseReason) -> Bool {
    reason == .closeButton
}

/// Always-on-top panel for one opened account. Clicking it can focus PasswordPie, so the field
/// menu can open. It stays visible after PasswordPie deactivates, so the user can paste into the form underneath.
final class PinnedEntryPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // isFloatingPanel turns hidesOnDeactivate back on. Set it after, or clicking the form hides the account.
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if pinnedWindowShouldClose(.resignKey) { close() }
    }

    override func cancelOperation(_ sender: Any?) {
        if pinnedWindowShouldClose(.escape) { close() }
    }
}

/// The first click both focuses the panel and hits the field, so copy does not take a second click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
