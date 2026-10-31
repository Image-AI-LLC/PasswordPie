// Render the app's real menu bar icon (Sources/PasswordPieApp/MenuBarIcon.swift) to PNGs for offline checks.
// Usage: swiftc -parse-as-library art/tools/render_menubar.swift Sources/PasswordPieApp/MenuBarIcon.swift -o /tmp/render_menubar
//        /tmp/render_menubar <out dir>
import AppKit

@main
enum RenderMenuBar {
    static func main() throws {
        let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let image = MenuBarIcon.image()

        for scale in [1, 2] {
            let pixels = Int(MenuBarIcon.size.width) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { fatalError("cannot allocate bitmap") }
            rep.size = MenuBarIcon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: MenuBarIcon.size))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode png") }
            let url = outDir.appendingPathComponent("menubar_app_\(scale)x.png")
            try png.write(to: url)
            print("Wrote \(url.path)")
        }
    }
}
