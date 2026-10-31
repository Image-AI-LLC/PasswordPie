import AppKit

/// The menu bar mark: a shield with a keyhole cut through it, matching the app icon.
/// Traced from `art/source/menubar.svg` (18×18, y pointing down).
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// Template image, so the system tints it for light, dark and highlighted menu bars.
    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            path().fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shield outline plus the keyhole; the even-odd rule punches the keyhole out of the shield.
    static func path() -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // Shield
        path.move(to: NSPoint(x: 9, y: 1))
        path.curve(to: NSPoint(x: 15.5, y: 3.5), controlPoint1: NSPoint(x: 9.5, y: 1), controlPoint2: NSPoint(x: 12, y: 2.5))
        path.curve(to: NSPoint(x: 16.5, y: 5), controlPoint1: NSPoint(x: 16.1667, y: 3.8333), controlPoint2: NSPoint(x: 16.5, y: 4.3333))
        path.curve(to: NSPoint(x: 9, y: 17), controlPoint1: NSPoint(x: 16.5, y: 10.5), controlPoint2: NSPoint(x: 14.5, y: 14.5))
        path.curve(to: NSPoint(x: 1.5, y: 5), controlPoint1: NSPoint(x: 3.5, y: 14.5), controlPoint2: NSPoint(x: 1.5, y: 10.5))
        path.curve(to: NSPoint(x: 2.5, y: 3.5), controlPoint1: NSPoint(x: 1.5, y: 4.3333), controlPoint2: NSPoint(x: 1.8333, y: 3.8333))
        path.curve(to: NSPoint(x: 9, y: 1), controlPoint1: NSPoint(x: 6, y: 2.5), controlPoint2: NSPoint(x: 8.5, y: 1))
        path.close()

        // Keyhole: round head over a flared slot
        path.move(to: NSPoint(x: 8, y: 8.5))
        path.curve(to: NSPoint(x: 6.5, y: 6.5), controlPoint1: NSPoint(x: 7, y: 8), controlPoint2: NSPoint(x: 6.5, y: 7.5))
        path.curve(to: NSPoint(x: 9, y: 4), controlPoint1: NSPoint(x: 6.5, y: 5), controlPoint2: NSPoint(x: 7.5, y: 4))
        path.curve(to: NSPoint(x: 11.5, y: 6.5), controlPoint1: NSPoint(x: 10.5, y: 4), controlPoint2: NSPoint(x: 11.5, y: 5))
        path.curve(to: NSPoint(x: 10, y: 8.5), controlPoint1: NSPoint(x: 11.5, y: 7.5), controlPoint2: NSPoint(x: 11, y: 8))
        path.line(to: NSPoint(x: 11.5, y: 12.5))
        path.line(to: NSPoint(x: 6.5, y: 12.5))
        path.close()
        return path
    }
}
