import AppKit
import SwiftUI
import XCTest
@testable import PasswordPie

@MainActor
final class LockScreenTests: XCTestCase {
    func testCompactPanelReservesRoomForIndependentUnlockAndCreateFields() {
        XCTAssertEqual(Metrics.width, 300)
        XCTAssertEqual(Metrics.lockedHeight, 360)
        XCTAssertEqual(Metrics.createHeight, 410)
    }

    func testFieldRegistrationDoesNotUnregisterAReplacement() {
        let fields = LockFields()
        let primary = NSSecureTextField()
        let replacement = NSSecureTextField()
        let confirm = NSSecureTextField()
        fields.register(primary, isConfirm: false)
        fields.register(confirm, isConfirm: true)
        fields.register(replacement, isConfirm: false)
        fields.unregister(primary)
        XCTAssertTrue(fields.primary === replacement)
        XCTAssertTrue(fields.confirm === confirm)
        fields.unregister(confirm)
        XCTAssertNil(fields.confirm)
        fields.unregister(replacement)
        XCTAssertNil(fields.primary)
    }

    func testNativeReturnSubmitsButOtherCommandsStayNative() {
        var submissions = 0
        let field = PasswordField(placeholder: "Master password", text: .constant(""), fields: LockFields(), isConfirm: false) {
            submissions += 1
        }
        let coordinator = field.makeCoordinator()
        let control = NSSecureTextField()
        let editor = NSTextView()
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, 1)
    }

    func testTypingUpdatesBindingAndClearsErrorWithoutGlobalAppState() {
        var password = ""
        var error = "Incorrect password. Please try again."
        let field = PasswordField(placeholder: "Master password",
                                  text: Binding(get: { password }, set: { password = $0 }),
                                  fields: LockFields(), isConfirm: false,
                                  onEdit: { error = "" }, submit: {})
        let control = NSSecureTextField()
        control.stringValue = "not-a-real-secret"
        field.makeCoordinator().controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
        XCTAssertEqual(password, "not-a-real-secret")
        XCTAssertEqual(error, "")
    }

    func testFocusChangesDoNotEditOrSubmitAndOlderBlurCannotClearNewFocus() {
        var password = "unchanged"
        var edits = 0
        var submissions = 0
        var focus: LockFieldFocus?
        func field(_ role: LockFieldFocus) -> PasswordField {
            PasswordField(placeholder: "Password",
                          text: Binding(get: { password }, set: { password = $0 }),
                          fields: LockFields(), isConfirm: role == .confirmation,
                          onEdit: { edits += 1 },
                          onFocusChange: { focus = LockFieldFocus.updated(focus, field: role, focused: $0) },
                          submit: { submissions += 1 })
        }
        let primary = field(.primary).makeCoordinator()
        let confirm = field(.confirmation).makeCoordinator()
        let primaryControl = NSSecureTextField()
        let confirmControl = NSSecureTextField()
        primary.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: primaryControl))
        XCTAssertEqual(focus, .primary)
        confirm.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: confirmControl))
        primary.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: primaryControl))
        XCTAssertEqual(focus, .confirmation)
        XCTAssertEqual(password, "unchanged")
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(confirm.control(confirmControl, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(focus, .confirmation)
        confirm.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: confirmControl))
        XCTAssertNil(focus)
    }

    func testRealCreateFormRegistersFieldsAndReturnMovesThenSubmits() throws {
        let fields = LockFields()
        var submissions = 0
        let content = makeContent(LockScreenPresentation(databaseName: "Example.kdbx", creating: true),
                                  fields: fields, unlock: { submissions += 1 })
        let host = NSHostingView(rootView: content)
        let window = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 410),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let primary = try XCTUnwrap(fields.primary)
        let confirm = try XCTUnwrap(fields.confirm)
        XCTAssertTrue(window.makeFirstResponder(primary))
        let primaryDelegate = try XCTUnwrap(primary.delegate as? PasswordField.Coordinator)
        XCTAssertTrue(primaryDelegate.control(primary, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(window.firstResponder === confirm.currentEditor())
        let confirmDelegate = try XCTUnwrap(confirm.delegate as? PasswordField.Coordinator)
        XCTAssertTrue(confirmDelegate.control(confirm, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, 1)
        window.contentView = nil
    }

    func testEmptyNativeFieldsReportInitialFocusAndTabWithoutTyping() async throws {
        let fields = LockFields()
        var focus: LockFieldFocus?
        let host = NSHostingView(rootView: VStack {
            PasswordField(placeholder: "Master password", text: .constant(""), fields: fields, isConfirm: false,
                          onFocusChange: { focus = LockFieldFocus.updated(focus, field: .primary, focused: $0) }, submit: {})
            PasswordField(placeholder: "Repeat password", text: .constant(""), fields: fields, isConfirm: true,
                          onFocusChange: { focus = LockFieldFocus.updated(focus, field: .confirmation, focused: $0) }, submit: {})
        })
        let window = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let primary = try XCTUnwrap(fields.primary)
        let confirm = try XCTUnwrap(fields.confirm)
        window.recalculateKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(primary))
        await nextMainQueueTurn()
        XCTAssertEqual(focus, .primary)
        XCTAssertEqual(primary.stringValue, "")
        // Deliver the native Tab command through the shared field editor.
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertTab(nil)
        await nextMainQueueTurn()
        XCTAssertTrue(window.firstResponder === confirm.currentEditor())
        XCTAssertEqual(focus, .confirmation)
        XCTAssertEqual(confirm.stringValue, "")
        XCTAssertTrue(window.makeFirstResponder(nil))
        await nextMainQueueTurn()
        XCTAssertNil(focus)
        window.contentView = nil
    }

    func testNativeColorsUpdateWhenSwiftUIColorSchemeChanges() async throws {
        let fields = LockFields()
        let field = PasswordField(placeholder: "Master password", text: .constant(""), fields: fields, isConfirm: false, submit: {})
        let host = NSHostingView(rootView: field.environment(\.colorScheme, .light))
        // Deliberately oppose the environment: colors must not follow AppKit defaults.
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 38)
        host.layoutSubtreeIfNeeded()
        let native = try XCTUnwrap(fields.primary)
        XCTAssertEqual(native.textColor, NSColor(Palette.text(dark: false)))
        host.rootView = field.environment(\.colorScheme, .dark)
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(fields.primary === native)
        XCTAssertEqual(native.textColor, NSColor(Palette.text(dark: true)))
        let placeholder = try XCTUnwrap(native.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(placeholder, NSColor(Palette.secondaryText(dark: true)))
    }

    func testLightDarkAndLongErrorLayoutsFitAndRenderNativeFields() throws {
        for dark in [false, true] {
            for mode in ["locked", "create", "options"] {
                let creating = mode == "create"
                let options = mode == "options"
                let height = creating ? Metrics.createHeight : Metrics.lockedHeight
                let fields = LockFields()
                let state = LockScreenPresentation(
                    databaseName: "A very long example database filename.kdbx", creating: creating,
                    message: options ? String(repeating: "Something went wrong. ", count: 12) : "",
                    showsKeyFile: options, keyFileName: "a-very-long-key-file-name-that-must-truncate.key",
                    touchIDAvailable: options)
                let content = makeContent(state, fields: fields)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(x: 0, y: 0, width: Metrics.width, height: height)
                host.layoutSubtreeIfNeeded()
                let primary = try XCTUnwrap(fields.primary)
                let placeholderColor = try XCTUnwrap(primary.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                XCTAssertEqual(placeholderColor, NSColor(Palette.secondaryText(dark: dark)))
                XCTAssertEqual(primary.textColor, NSColor(Palette.text(dark: dark)))
                XCTAssertTrue(host.bounds.contains(host.convert(primary.bounds, from: primary)))
                XCTAssertEqual(fields.confirm != nil, creating)
                if let confirm = fields.confirm {
                    XCTAssertTrue(host.bounds.contains(host.convert(confirm.bounds, from: confirm)))
                }
                XCTAssertLessThanOrEqual(host.fittingSize.height, height + 1)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/passwordpie-lock-\(mode)-\(dark ? "dark" : "light").png"))
                let background = try XCTUnwrap(rep.colorAt(x: 5, y: 5))
                XCTAssertEqual(background.alphaComponent, 1)
                XCTAssertEqual(background.redComponent < 0.5, dark)
            }
        }
    }

    private func makeContent(_ presentation: LockScreenPresentation, fields: LockFields,
                             unlock: @escaping () -> Void = {}) -> LockScreenContent {
        LockScreenContent(presentation: presentation, password: .constant(""), confirmation: .constant(""),
                          fields: fields, actions: LockScreenActions(unlock: unlock, touchID: {}, open: {},
                                                                    create: {}, keyFile: {}, edit: {}))
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
