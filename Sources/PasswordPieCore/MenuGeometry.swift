import CoreGraphics
import Foundation

/// Window placement for the panel and its cascading submenus. All frames use AppKit screen coordinates (origin bottom-left),
/// and every window hangs down from its top-left anchor.
public enum MenuGeometry {
    public static let rootWidth: CGFloat = 300
    public static let screenMargin: CGFloat = 8
    /// Distance from the centered origin inside which a dropped panel snaps back and forgets its position.
    public static let snapDistance: CGFloat = 300
    public static let submenuInset: CGFloat = 5

    /// Visible frame inset 8 pt on the left, right and bottom, 0 at the top.
    public static func confinement(visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.minX + screenMargin,
            y: visibleFrame.minY + screenMargin,
            width: max(visibleFrame.width - 2 * screenMargin, 0),
            height: max(visibleFrame.height - screenMargin, 0)
        )
    }

    /// Frame for a window of `size` hanging from `topLeft`: x is clamped into the confinement, the top stays put
    /// until the bottom would cross the bottom margin, then the window moves up.
    public static func frame(topLeft: CGPoint, size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let x = min(max(topLeft.x, area.minX), area.maxX - width)
        var top = min(topLeft.y, area.maxY)
        if top - height < area.minY { top = area.minY + height }
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// Top-left of the panel when opened by the hotkey without a saved position: 20 % down from the top of the screen.
    public static func centeredTopLeft(screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: screenFrame.minX + floor((screenFrame.width - rootWidth) / 2),
            y: screenFrame.minY + floor(screenFrame.height * 0.8)
        )
    }

    public static func shouldSnapToCenter(topLeft: CGPoint, centered: CGPoint) -> Bool {
        hypot(topLeft.x - centered.x, topLeft.y - centered.y) < snapDistance
    }

    /// Frame of a submenu opened from a row: to the right of the parent, its top `submenuInset` above the row,
    /// flipped to the left when it does not fit.
    public static func childFrame(parent: CGRect, rowTop: CGFloat, size: CGSize, in area: CGRect) -> CGRect {
        var x = parent.maxX
        if x + size.width > area.maxX {
            x = parent.minX - size.width
        }
        return frame(topLeft: CGPoint(x: x, y: rowTop + submenuInset), size: size, in: area)
    }

    /// Menu width: the widest row, at least `minimum`, at most a quarter of the screen.
    public static func width(widestRow: CGFloat, minimum: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(max(minimum, widestRow), max(floor(screenWidth / 4), minimum))
    }
}
