import AppKit
import PasswordPieCore
import SwiftUI

/// How long the bubble has left. The pointer on it stops the clock, and leaving starts it again where it stopped.
struct BubbleCountdown: Equatable {
    static let stay: TimeInterval = 6

    private(set) var remaining = BubbleCountdown.stay
    private var runningSince: Date?

    var isRunning: Bool { runningSince != nil }

    mutating func start(at now: Date) {
        remaining = Self.stay
        runningSince = now
    }

    mutating func pause(at now: Date) {
        guard let runningSince else { return }
        remaining = max(0, remaining - max(0, now.timeIntervalSince(runningSince)))
        self.runningSince = nil
    }

    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    func timeLeft(at now: Date) -> TimeInterval {
        guard let runningSince else { return remaining }
        return max(0, remaining - max(0, now.timeIntervalSince(runningSince)))
    }
}

/// Where the bubble sits: centred, 48 pt above the bottom of the screen's visible frame (so above the Dock).
func appLinkBubbleOrigin(visibleFrame: CGRect, size: CGSize) -> CGPoint {
    CGPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: visibleFrame.minY + 48)
}

/// Minimum click-guard interval when one bubble swaps directly into another in place, preventing a stray double-click
/// on Undo from accidentally pressing Turn Back On.
func appLinkSwapGuardInterval(systemDoubleClick: TimeInterval = NSEvent.doubleClickInterval) -> TimeInterval {
    max(systemDoubleClick, 0.5)
}

/// The bubble's window. It never takes the keyboard: the user is about to paste into the app underneath.
final class AppLinkBubblePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // isFloatingPanel turns hidesOnDeactivate back on and resets the level. Set both after.
        level = pinnedWindowLevel()
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Leading icon style for the bottom-of-screen bubble. Both variants occupy the exact same width (28 pt) when an
/// app badge is present so swapping from an account Undo bubble to an app-level notice never shifts the text.
enum BubbleIconKind {
    /// An account's icon, optionally carrying an app's icon as its bottom-right badge.
    case account(title: String, siteHost: String?, appIcon: NSImage?)
    /// An app's own icon carrying a quiet prohibit mark (app-level automatic adding stopped).
    case appStopped(appIcon: NSImage)
}

/// One line and one button: what changed, and the way back. See "An account remembers its app" in docs/UX.md.
struct AppLinkBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    var message: String
    var action: String
    var icon: BubbleIconKind
    var onAct: () -> Void
    var onHover: (Bool) -> Void

    static let height: CGFloat = 44
    static let maxWidth: CGFloat = 560

    init(
        message: String,
        action: String,
        title: String,
        siteHost: String?,
        appIcon: NSImage?,
        onAct: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) {
        self.message = message
        self.action = action
        self.icon = .account(title: title, siteHost: siteHost, appIcon: appIcon)
        self.onAct = onAct
        self.onHover = onHover
    }

    init(
        message: String,
        action: String,
        icon: BubbleIconKind,
        onAct: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) {
        self.message = message
        self.action = action
        self.icon = icon
        self.onAct = onAct
        self.onHover = onHover
    }

    var body: some View {
        let dark = colorScheme == .dark
        HStack(spacing: 10) {
            leadingIcon(dark: dark)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text(dark: dark))
                .lineLimit(1)
                .truncationMode(.middle)
            SplitActionButton(title: action, action: onAct)
                .padding(.leading, 6)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .frame(maxWidth: Self.maxWidth)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface(dark: dark)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border(dark: dark), lineWidth: 1))
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func leadingIcon(dark: Bool) -> some View {
        switch icon {
        case .account(let title, let siteHost, let appIcon):
            SiteIconView(host: siteHost, title: title, side: 24)
                .overlay(alignment: .bottomTrailing) {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 13, height: 13)
                            .padding(1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.surface(dark: dark)))
                            .offset(x: 6, y: 6)
                    }
                }
                .padding(.trailing, appIcon == nil ? 0 : 4)
        case .appStopped(let appIcon):
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "nosign")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondaryText(dark: dark))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Palette.surface(dark: dark)))
                        .offset(x: 5, y: 5)
                }
                .padding(.trailing, 4)
        }
    }
}

/// Shows one bubble at a time at the bottom of the screen and takes it away after 6 seconds.
@MainActor
final class AppLinkBubbleController {
    private var panel: AppLinkBubblePanel?
    private var countdown = BubbleCountdown()
    private var timer: Timer?
    /// Action clicks before this instant are ignored (prevents an accidental double-click after an in-place swap).
    private var ignoreActionUntil: Date?

    var isShowing: Bool { panel != nil }

    func show(_ notice: AppLinkNotice, title: String?, siteHost: String?, act: @escaping () -> Void) {
        let icon: BubbleIconKind
        let guardSwap: Bool
        switch notice {
        case .linked, .unlinked:
            icon = .account(title: title ?? "", siteHost: siteHost, appIcon: AppIdentity.icon(for: notice.app))
            guardSwap = false
        case .autoStopped(let app):
            icon = .appStopped(appIcon: AppIdentity.icon(for: app))
            guardSwap = panel != nil
        }
        show(message: notice.message, action: notice.action, icon: icon, guardSwap: guardSwap, act: act)
    }

    /// A site was added to an account: the same bubble, with no app's mark on the account's icon.
    func show(_ notice: SiteNotice, title: String, siteHost: String?, act: @escaping () -> Void) {
        show(message: notice.message, action: notice.action, icon: .account(title: title, siteHost: siteHost, appIcon: nil), guardSwap: false, act: act)
    }

    private func show(message: String, action: String, icon: BubbleIconKind, guardSwap: Bool, act: @escaping () -> Void) {
        dismiss(animated: false)
        ignoreActionUntil = guardSwap ? Date().addingTimeInterval(appLinkSwapGuardInterval()) : nil
        // A test process can have no screens: there is nowhere to show it.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = AppLinkBubblePanel(contentRect: .zero)
        let view = AppLinkBubbleView(
            message: message,
            action: action,
            icon: icon,
            onAct: { [weak self, weak panel] in
                guard let self else { return }
                if let guardUntil = self.ignoreActionUntil, Date() < guardUntil { return }
                self.ignoreActionUntil = nil
                act()
                // Only dismiss if `act()` did not already swap in a newer bubble (e.g. 3rd Undo -> autoStopped).
                if let panel, self.panel === panel {
                    self.dismiss(animated: true)
                }
            },
            onHover: { [weak self] inside in self?.hover(inside) }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        let origin = appLinkBubbleOrigin(visibleFrame: screen.visibleFrame, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        countdown.start(at: Date())
        schedule()
    }

    func dismiss(animated: Bool) {
        timer?.invalidate()
        timer = nil
        ignoreActionUntil = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.close() }
        })
    }

    private func hover(_ inside: Bool) {
        guard panel != nil else { return }
        if inside {
            countdown.pause(at: Date())
            timer?.invalidate()
            timer = nil
        } else {
            countdown.resume(at: Date())
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: countdown.timeLeft(at: Date()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
    }
}
