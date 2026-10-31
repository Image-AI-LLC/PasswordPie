import AppKit
import PasswordPieCore
import SwiftUI

enum PinnedWindowCloseReason: Equatable {
    case closeButton, resignKey, escape, commandW
}

/// A pinned account stays up while its fields are copied into another app.
/// Losing focus, pressing Escape, or Command-W must not dismiss it. Only the close button does.
func pinnedWindowShouldClose(_ reason: PinnedWindowCloseReason) -> Bool {
    reason == .closeButton
}

/// Command-W reaches `performClose` as a key-down. The close button is a mouse event, so it still closes.
func pinnedEventIsCommandW(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
    return event.charactersIgnoringModifiers?.lowercased() == "w"
}

enum PinnedWindowPlacement: Equatable {
    case orderFront
    case openNew(index: Int)
}

/// One window per account. Pinning an account that is already open brings that window forward.
func pinnedWindowPlacement(openIDs: [UUID], id: UUID) -> PinnedWindowPlacement {
    openIDs.contains(id) ? .orderFront : .openNew(index: openIDs.count)
}

/// New windows start at the top-right and step down-left so they do not stack on the same origin.
func pinnedWindowOrigin(visibleMaxX: CGFloat, visibleMaxY: CGFloat, size: CGSize, index: Int) -> CGPoint {
    let step = 28 * CGFloat(index)
    return CGPoint(x: visibleMaxX - size.width - 24 - step, y: visibleMaxY - size.height - 24 - step)
}

/// Detached 1Password mini (`OPHelperWindow.setDetached:` in 6.8.9) uses the main-menu level minus 2.
/// The attached mini, and PasswordPie's own menu, sit one level higher.
func pinnedWindowLevel() -> NSWindow.Level {
    NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 2)
}

/// The entry still shown in the pinned window. Trash and deletion both return nil, so the window closes.
func activePinnedEntry(_ entries: [VaultEntry], id: UUID) -> VaultEntry? {
    entries.first { $0.id == id && !$0.trashed }
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
        // isFloatingPanel turns hidesOnDeactivate back on and resets the level. Set both after.
        level = pinnedWindowLevel()
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        let commandW = NSApp.currentEvent.map(pinnedEventIsCommandW) ?? false
        guard pinnedWindowShouldClose(commandW ? .commandW : .closeButton) else { return }
        super.performClose(sender)
    }

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
