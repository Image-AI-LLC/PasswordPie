import AppKit
import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// docs/UX.md, "The whole field is the button": the pointer on a field draws a dashed outline round all of it, and a
/// click anywhere inside runs the field's button.
@MainActor
final class DetailFieldHoverTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    private func login() -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.username = "ann"
        entry.password = "secret"
        entry.url = "https://github.com/login"
        return entry
    }

    private func hosted(_ model: DetailsModel, dark: Bool = false) async throws -> NSHostingView<DetailsView> {
        let host = NSHostingView(rootView: DetailsView(model: model))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        try await settle(host)
        return host
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func draw(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func differs(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let one = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let two = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return abs(one.redComponent - two.redComponent) + abs(one.greenComponent - two.greenComponent) + abs(one.blueComponent - two.blueComponent) > 0.12
    }

    /// Where two drawings of the same view differ, in points from the top left, and the pixel rows it covers.
    private struct Change {
        var rect: CGRect
        var pixels: (x: ClosedRange<Int>, y: ClosedRange<Int>)
    }

    private func change(from before: NSBitmapImageRep, to after: NSBitmapImageRep) -> Change? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for x in 0..<before.pixelsWide {
            for y in 0..<before.pixelsHigh where differs(before, after, x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        let scale = CGFloat(before.pixelsWide) / size.width
        let rect = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return Change(rect: rect, pixels: (minX...maxX, minY...maxY))
    }

    /// What the pointer on `kind` adds to the drawing.
    private func hoverChange(on kind: DetailField.Kind, dark: Bool = false) async throws -> (change: Change, before: NSBitmapImageRep, after: NSBitmapImageRep) {
        let session = VaultSession(writes: .inline)
        let model = DetailsModel(entry: login(), session: session, done: {})
        let host = try await hosted(model, dark: dark)
        let before = try draw(host)
        model.pointer(true, on: try XCTUnwrap(model.fields.first { $0.kind == kind }))
        try await settle(host)
        let after = try draw(host)
        if let dir = ProcessInfo.processInfo.environment["PP_TEST_DUMP"] {
            try after.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("field-hover-\(kind)-\(dark ? "dark" : "light").png"))
        }
        let change = try XCTUnwrap(change(from: before, to: after), "the pointer on a field changes how it is drawn")
        return withExtendedLifetime(session) { (change, before, after) }
    }

    func testThePointerOnAFieldOutlinesTheWholeRow() async throws {
        for dark in [false, true] {
            let (change, _, _) = try await hoverChange(on: .username, dark: dark)
            XCTAssertLessThanOrEqual(change.rect.minX, 6, "the outline starts at the row's leading edge, not at the button; dark: \(dark)")
            XCTAssertGreaterThanOrEqual(change.rect.maxX, size.width - 6, "dark: \(dark)")
            XCTAssertGreaterThanOrEqual(change.rect.height, 28, "it surrounds the label and the value; dark: \(dark)")
            XCTAssertLessThanOrEqual(change.rect.height, 46, "and no other row; dark: \(dark)")
        }
    }

    func testTheOutlineIsDashed() async throws {
        let (change, before, after) = try await hoverChange(on: .username)
        // Along the outline's top line, drawn stretches alternate with gaps.
        let y = change.pixels.y.lowerBound
        var runs = 0
        var drawing = false
        for x in change.pixels.x {
            let drawn = differs(before, after, x, y) || differs(before, after, x, y + 1)
            if drawn, !drawing { runs += 1 }
            drawing = drawn
        }
        XCTAssertGreaterThan(runs, 20, "a solid line would be one stretch")
    }

    func testTheOutlineFollowsThePointerToAnotherField() async throws {
        let username = try await hoverChange(on: .username).change
        let password = try await hoverChange(on: .password).change
        XCTAssertGreaterThanOrEqual(password.rect.minY, username.rect.maxY - 1, "one field is outlined at a time")
    }

    func testLeavingAFieldClearsItsOutlineButNotAnotherFields() throws {
        let session = VaultSession(writes: .inline)
        let model = DetailsModel(entry: login(), session: session, done: {})
        let username = try XCTUnwrap(model.fields.first { $0.kind == .username })
        let password = try XCTUnwrap(model.fields.first { $0.kind == .password })
        XCTAssertNil(model.hoveredField)
        model.pointer(true, on: username)
        XCTAssertEqual(model.hoveredField, username.id)
        // The pointer enters the next row before the last one reports that it left.
        model.pointer(true, on: password)
        model.pointer(false, on: username)
        XCTAssertEqual(model.hoveredField, password.id)
        model.pointer(false, on: password)
        XCTAssertNil(model.hoveredField)
        withExtendedLifetime(session) {}
    }

    /// The click lands on the value's side of the row, far from the Copy button.
    func testAClickAnywhereInTheFieldRunsItsButton() async throws {
        let row = try await hoverChange(on: .username).change.rect
        var closed = 0
        let session = VaultSession(writes: .inline)
        let model = DetailsModel(entry: login(), session: session, done: { closed += 1 })
        let host = try await hosted(model)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Off every screen, but ordered in: SwiftUI takes no gestures in a window that is not shown.
        window.orderFrontRegardless()
        try await settle(host)
        // A third of the way along, between the text and the button.
        let inHost = CGPoint(x: size.width / 3, y: host.isFlipped ? row.midY : size.height - row.midY)
        let point = host.convert(inHost, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            NSApp.sendEvent(event)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let copied = await waitUntil(timeout: 2) { closed == 1 }
        XCTAssertTrue(copied, "copying closes the popover, so the click reached the row")
        window.close()
        withExtendedLifetime(session) {}
    }
}
