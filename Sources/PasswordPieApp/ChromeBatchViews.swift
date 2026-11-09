import AppKit
import PasswordPieCore
import SwiftUI

/// `12 passwords changed in Chrome   Review   ×`, laid out like a menu row under the search field.
final class ChromeBatchRowView: NSView {
    static let height: CGFloat = 26
    private static let dismissWidth: CGFloat = 26
    private static let reviewPadding: CGFloat = 10
    private static let reviewTitle = "Review"
    private static let dismissTitle = "×"

    var onReview: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var summary: String?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// The panel moves by its background; without this a press here starts a drag and the click never arrives.
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ summary: String?) {
        guard summary != self.summary else { return }
        self.summary = summary
        setAccessibilityElement(summary != nil)
        setAccessibilityRole(.group)
        setAccessibilityLabel(summary)
        needsDisplay = true
    }

    private var font: NSFont { NSFont.menuFont(ofSize: 12) }

    private var dismissRect: NSRect {
        NSRect(x: bounds.width - Self.dismissWidth, y: 0, width: Self.dismissWidth, height: bounds.height)
    }

    private var reviewRect: NSRect {
        let width = ceil(MenuListView.textWidth(Self.reviewTitle, font)) + Self.reviewPadding
        return NSRect(x: dismissRect.minX - width, y: 0, width: width, height: bounds.height)
    }

    /// Runs when released over the same control, like a menu item.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let target = reviewRect.contains(start) ? reviewRect : dismissRect.contains(start) ? dismissRect : nil
        guard let target else { return }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            guard next.type == .leftMouseUp else { continue }
            if target.contains(convert(next.locationInWindow, from: nil)) {
                if target == reviewRect { onReview?() } else { onDismiss?() }
            }
            return
        }
    }

    override func accessibilityChildren() -> [Any]? {
        [
            element(Self.reviewTitle, rect: reviewRect) { [weak self] in self?.onReview?() },
            element("Dismiss", rect: dismissRect) { [weak self] in self?.onDismiss?() }
        ]
    }

    private func element(_ title: String, rect: NSRect, press: @escaping () -> Void) -> NSAccessibilityElement {
        let element = PressableElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityFrame(window?.convertToScreen(convert(rect, to: nil)) ?? rect)
        element.setAccessibilityLabel(title)
        element.setAccessibilityParent(self)
        element.press = press
        return element
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let summary else { return }
        menuInk(0.03).setFill()
        bounds.fill()
        menuInk(0.25).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let row = bounds
        func draw(_ text: String, x: CGFloat, width: CGFloat, color: NSColor, weight: NSFont? = nil) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let usedFont = weight ?? font
            let lineHeight = ceil(usedFont.ascender - usedFont.descender + usedFont.leading)
            let rect = NSRect(x: x, y: row.midY - lineHeight / 2, width: max(width, 0), height: lineHeight)
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: usedFont, .foregroundColor: color, .paragraphStyle: style])
        }
        let review = reviewRect
        draw(summary, x: 12, width: review.minX - 16, color: MenuPalette.text)
        draw(Self.reviewTitle, x: review.minX + Self.reviewPadding / 2, width: review.width, color: MenuPalette.caret)
        draw(Self.dismissTitle, x: dismissRect.minX + 9, width: dismissRect.width - 9, color: MenuPalette.secondaryText, weight: NSFont.menuFont(ofSize: 14))
    }
}

private final class PressableElement: NSAccessibilityElement {
    var press: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        press?()
        return true
    }
}

/// Which accounts a batch would change. Read-only: passwords never appear here.
struct ChromeBatchReviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: VaultSession
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let batch = session.chromeBatch {
                Text(batch.summary).font(.system(size: 13, weight: .semibold))
                Text("These accounts have a newer password in Chrome. Your saved passwords move to previous passwords. Chrome isn't changed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(batch.accounts) { account in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.title).font(.system(size: 13)).lineLimit(1)
                                if !account.username.isEmpty {
                                    Text(account.username).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
                        }
                    }
                }
                .frame(height: min(CGFloat(batch.accounts.count) * 42, 280))
                if !session.chromeBatchError.isEmpty {
                    Text(session.chromeBatchError).font(.system(size: 11)).foregroundStyle(Palette.error(dark: colorScheme == .dark))
                }
                HStack {
                    Spacer()
                    Button(batch.applyTitle) { session.applyChromeBatch() }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .onChange(of: session.chromeBatch) { _, batch in
            if batch == nil { close() }
        }
    }
}
