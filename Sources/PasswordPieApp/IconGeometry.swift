import Foundation

/// Preserves native icon proportions while keeping existing layout slots unchanged.
enum IconGeometry {
    static func aspectFit(_ imageSize: CGSize, in slot: CGRect) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              slot.origin.x.isFinite, slot.origin.y.isFinite,
              slot.size.width.isFinite, slot.size.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              slot.size.width > 0, slot.size.height > 0 else { return .zero }
        let scale = min(slot.width / imageSize.width, slot.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: slot.minX + (slot.width - width) / 2,
                      y: slot.minY + (slot.height - height) / 2,
                      width: width, height: height)
    }
}
