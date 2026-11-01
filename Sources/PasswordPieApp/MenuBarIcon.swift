import AppKit

/// The selected B-keyhole pie, traced from `art/source/mark.svg` (24 units, y down).
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// The keyhole stays transparent; macOS supplies light/dark/highlighted tinting.
    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            path().fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func path() -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        appendRim(to: path)
        appendKeyhole(to: path)
        return scaled(path)
    }

    /// The scalloped outer pie alone, filled solid. It turns while a database decrypts.
    static func rimPath() -> NSBezierPath {
        let path = NSBezierPath()
        appendRim(to: path)
        return scaled(path)
    }

    /// The keyhole alone, so a turning rim can keep it still.
    static func keyholePath() -> NSBezierPath {
        let path = NSBezierPath()
        appendKeyhole(to: path)
        return scaled(path)
    }

    private static func scaled(_ path: NSBezierPath) -> NSBezierPath {
        path.transform(using: AffineTransform(scale: size.width / 24))
        return path
    }

    private static func appendRim(to path: NSBezierPath) {
        // The SVG's first 30 polygon vertices; exact quarter-turn copies give all 120.
        let quarter: [NSPoint] = [
            .init(x: 12.0000, y: 1.9000), .init(x: 12.5236, y: 2.0092),
            .init(x: 13.0196, y: 2.2989), .init(x: 13.4776, y: 2.6708),
            .init(x: 13.9119, y: 3.0055), .init(x: 14.3553, y: 3.2101),
            .init(x: 14.8416, y: 3.2546), .init(x: 15.3850, y: 3.1819),
            .init(x: 15.9675, y: 3.0888), .init(x: 16.5420, y: 3.0859),
            .init(x: 17.0500, y: 3.2531), .init(x: 17.4488, y: 3.6095),
            .init(x: 17.7336, y: 4.1084), .init(x: 17.9442, y: 4.6595),
            .init(x: 18.1530, y: 5.1664), .init(x: 18.4347, y: 5.5653),
            .init(x: 18.8336, y: 5.8470), .init(x: 19.3405, y: 6.0558),
            .init(x: 19.8916, y: 6.2664), .init(x: 20.3905, y: 6.5512),
            .init(x: 20.7469, y: 6.9500), .init(x: 20.9141, y: 7.4580),
            .init(x: 20.9112, y: 8.0325), .init(x: 20.8181, y: 8.6150),
            .init(x: 20.7454, y: 9.1584), .init(x: 20.7899, y: 9.6447),
            .init(x: 20.9945, y: 10.0881), .init(x: 21.3292, y: 10.5224),
            .init(x: 21.7011, y: 10.9804), .init(x: 21.9908, y: 11.4764)
        ]
        for turn in 0..<4 {
            for (index, vertex) in quarter.enumerated() {
                var point = vertex
                for _ in 0..<turn { point = NSPoint(x: 24 - point.y, y: point.x) }
                if turn == 0 && index == 0 { path.move(to: point) }
                else { path.line(to: point) }
            }
        }
        path.close()
    }

    private static func appendKeyhole(to path: NSBezierPath) {
        // M10.65 11.6 A3 3 0 1 1 13.35 11.6: the long, positive-sweep circle arc.
        // Cubics of at most 15 degrees keep radial error below 2e-8 SVG units.
        let radius: CGFloat = 3
        let center = NSPoint(x: 12, y: 11.6 - sqrt(radius * radius - 1.35 * 1.35))
        let start = atan2(11.6 - center.y, -1.35)
        let end = atan2(11.6 - center.y, 1.35) + 2 * .pi
        let segments = Int(ceil((end - start) / (.pi / 12)))
        let step = (end - start) / CGFloat(segments)
        let tangent = 4.0 / 3 * tan(step / 4) * radius
        path.move(to: NSPoint(x: 10.65, y: 11.6))
        for index in 0..<segments {
            let a = start + CGFloat(index) * step
            let b = a + step
            let p0 = NSPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            let p1 = NSPoint(x: center.x + radius * cos(b), y: center.y + radius * sin(b))
            path.curve(to: p1,
                       controlPoint1: NSPoint(x: p0.x - tangent * sin(a), y: p0.y + tangent * cos(a)),
                       controlPoint2: NSPoint(x: p1.x + tangent * sin(b), y: p1.y - tangent * cos(b)))
        }
        path.line(to: NSPoint(x: 14.4, y: 16.6))
        // Q14.5 17 14 17, exactly converted from quadratic to cubic.
        path.curve(to: NSPoint(x: 14, y: 17),
                   controlPoint1: NSPoint(x: 14.4 + 0.1 * 2 / 3, y: 16.6 + 0.4 * 2 / 3),
                   controlPoint2: NSPoint(x: 14 + 0.5 * 2 / 3, y: 17))
        path.line(to: NSPoint(x: 10, y: 17))
        // Q9.5 17 9.6 16.6, exactly converted from quadratic to cubic.
        path.curve(to: NSPoint(x: 9.6, y: 16.6),
                   controlPoint1: NSPoint(x: 10 - 0.5 * 2 / 3, y: 17),
                   controlPoint2: NSPoint(x: 9.6 - 0.1 * 2 / 3, y: 16.6 + 0.4 * 2 / 3))
        path.close()
    }
}
