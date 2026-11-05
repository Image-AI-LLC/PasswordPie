import AppKit
import PasswordPieCore
import SwiftUI

enum PinnedWindowPlacement: Equatable {
    case orderFront
    case openNew(index: Int)
}

/// One window per account. Pinning an account that is already open brings that window forward.
func pinnedWindowPlacement(openIDs: [UUID], id: UUID) -> PinnedWindowPlacement {
    openIDs.contains(id) ? .orderFront : .openNew(index: openIDs.count)
}

/// The order of open windows, back to front, after `id` comes to the top.
func pinnedOrderRaising(_ id: UUID, in order: [UUID]) -> [UUID] {
    order.filter { $0 != id } + [id]
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

/// Always-on-top panel for one opened account. It never takes focus, so the form underneath keeps the
/// caret while a field is clicked here or copied with a global shortcut. Only its close button dismisses it.
final class PinnedEntryPanel: NSPanel {
    var onMouseDown: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // isFloatingPanel turns hidesOnDeactivate back on and resets the level. Set both after.
        level = pinnedWindowLevel()
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }
}

/// The panel is never key, so every click has to count as a first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
