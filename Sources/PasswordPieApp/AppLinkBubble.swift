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

/// One line and one button: what changed, and the way back. See "An account remembers its app" in docs/UX.md.
struct AppLinkBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    var message: String
    var action: String
    var title: String
    var siteHost: String?
    /// The app the notice is about, as the mark on the account's icon. Nil for a notice about a website.
    var appIcon: NSImage?
    var onAct: () -> Void
    var onHover: (Bool) -> Void

    static let height: CGFloat = 44
    static let maxWidth: CGFloat = 560

    var body: some View {
        let dark = colorScheme == .dark
        HStack(spacing: 10) {
            // The account's icon carries the app's as its mark, as an account from Chrome carries Chrome's.
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
}

/// Shows one bubble at a time at the bottom of the screen and takes it away after 6 seconds.
@MainActor
final class AppLinkBubbleController {
    private var panel: AppLinkBubblePanel?
    private var countdown = BubbleCountdown()
    private var timer: Timer?

    var isShowing: Bool { panel != nil }

    func show(_ notice: AppLinkNotice, title: String, siteHost: String?, act: @escaping () -> Void) {
        show(message: notice.message, action: notice.action, title: title, siteHost: siteHost, appIcon: AppIdentity.icon(for: notice.app), act: act)
    }

    /// A site was added to an account: the same bubble, with no app's mark on the account's icon.
    func show(_ notice: SiteNotice, title: String, siteHost: String?, act: @escaping () -> Void) {
        show(message: notice.message, action: notice.action, title: title, siteHost: siteHost, appIcon: nil, act: act)
    }

    private func show(message: String, action: String, title: String, siteHost: String?, appIcon: NSImage?, act: @escaping () -> Void) {
        dismiss(animated: false)
        let view = AppLinkBubbleView(
            message: message, action: action, title: title, siteHost: siteHost,
            appIcon: appIcon,
            onAct: { [weak self] in
                act()
                self?.dismiss(animated: true)
            },
            onHover: { [weak self] inside in self?.hover(inside) }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        // A test process can have no screens: there is nowhere to show it.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let origin = appLinkBubbleOrigin(visibleFrame: screen.visibleFrame, size: size)
        let panel = AppLinkBubblePanel(contentRect: NSRect(origin: origin, size: size))
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
