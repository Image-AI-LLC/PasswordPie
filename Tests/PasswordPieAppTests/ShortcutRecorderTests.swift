import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PasswordPie

@MainActor
private final class RecorderFixture {
    let recorder = ShortcutRecorder()
    let window: NSWindow
    var suspensions = 0
    var completions = 0
    var commits: [HotKeyConfig] = []

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    func start(in target: NSWindow? = nil, withoutWindow: Bool = false) {
        recorder.start(in: withoutWindow ? nil : (target ?? window),
                       suspend: { self.suspensions += 1 },
                       commit: { self.commits.append($0) },
                       finish: { self.completions += 1 })
    }

    func event(keyCode: Int = kVK_ANSI_A, modifiers: NSEvent.ModifierFlags = [],
               in target: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                      modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: (target ?? window).windowNumber,
                                      context: nil, characters: "a",
                                      charactersIgnoringModifiers: "a",
                                      isARepeat: false, keyCode: UInt16(keyCode)))
    }

    func cleanUp() {
        recorder.stop()
        window.close()
    }
}

final class ShortcutRecorderTests: XCTestCase {
    func testKeycapOrderAndDefaultDisplay() {
        XCTAssertEqual(HotKeyConfig.default.keyCode, UInt32(kVK_ANSI_Backslash))
        XCTAssertEqual(HotKeyConfig.default.modifiers, UInt32(cmdKey))
        XCTAssertEqual(HotKeyConfig.default.keycaps, ["⌘", "\\"])
        XCTAssertEqual(HotKeyConfig.default.display, "⌘\\")
        let config = HotKeyConfig(keyCode: UInt32(kVK_ANSI_A),
                                  modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(config.keycaps, ["⌃", "⌥", "⇧", "⌘", "A"])
        XCTAssertEqual(config.display, "⌃⌥⇧⌘A")
    }

    func testBareAndShiftOnlyKeysAreRejected() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            XCTAssertNil(HotKeyConfig(event: try fixture.event()))
            XCTAssertNil(HotKeyConfig(event: try fixture.event(modifiers: .shift)))
        }
    }

    func testCommandOptionAndControlAreAccepted() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            let cases: [(NSEvent.ModifierFlags, UInt32)] = [
                (.command, UInt32(cmdKey)), (.option, UInt32(optionKey)), (.control, UInt32(controlKey)),
                ([.command, .shift], UInt32(cmdKey | shiftKey))
            ]
            for (flags, mask) in cases {
                XCTAssertEqual(HotKeyConfig(event: try fixture.event(modifiers: flags)),
                               HotKeyConfig(keyCode: UInt32(kVK_ANSI_A), modifiers: mask))
            }
        }
    }

    func testStartWithoutWindowDoesNotRecordOrSuspend() async {
        await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.start(withoutWindow: true)
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertEqual(fixture.suspensions, 0)
            fixture.recorder.stop()
            XCTAssertEqual(fixture.completions, 0)
        }
    }

    func testRepeatedStartSuspendsOnlyOnce() async {
        await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.start()
            fixture.start()
            XCTAssertTrue(fixture.recorder.isRecording)
            XCTAssertEqual(fixture.suspensions, 1)
            fixture.recorder.stop()
            XCTAssertEqual(fixture.completions, 1)
        }
    }

    func testEscapeCancelsAndFinishesOnceWithoutCommit() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.start()
            XCTAssertTrue(fixture.recorder.consume(try fixture.event(keyCode: kVK_Escape)))
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertTrue(fixture.commits.isEmpty)
            XCTAssertEqual(fixture.completions, 1)
            fixture.recorder.stop()
            XCTAssertEqual(fixture.completions, 1)
        }
    }

    func testTabAndShiftTabCancelWithoutConsumingNavigation() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            for flags: NSEvent.ModifierFlags in [[], .shift] {
                fixture.start()
                XCTAssertFalse(fixture.recorder.consume(try fixture.event(keyCode: kVK_Tab, modifiers: flags)))
                XCTAssertFalse(fixture.recorder.isRecording)
            }
            XCTAssertTrue(fixture.commits.isEmpty)
            XCTAssertEqual(fixture.completions, 2)
        }
    }

    func testValidCombinationCommitsAndFinishesExactlyOnce() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.start()
            let event = try fixture.event(modifiers: [.command, .shift])
            XCTAssertTrue(fixture.recorder.consume(event))
            XCTAssertEqual(fixture.commits, [HotKeyConfig(keyCode: UInt32(kVK_ANSI_A),
                                                         modifiers: UInt32(cmdKey | shiftKey))])
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertEqual(fixture.completions, 1)
            XCTAssertFalse(fixture.recorder.consume(event))
            fixture.recorder.stop()
            XCTAssertEqual(fixture.commits.count, 1)
            XCTAssertEqual(fixture.completions, 1)
        }
    }

    func testBareKeyKeepsRecordingAndRequestsModifier() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.start()
            XCTAssertTrue(fixture.recorder.consume(try fixture.event()))
            XCTAssertTrue(fixture.recorder.isRecording)
            XCTAssertTrue(fixture.recorder.needsModifier)
            XCTAssertTrue(fixture.commits.isEmpty)
            XCTAssertEqual(fixture.completions, 0)
            fixture.recorder.stop()
            XCTAssertFalse(fixture.recorder.needsModifier)
        }
    }

    func testOtherWindowEventStopsRecordingAndPassesThrough() async throws {
        try await MainActor.run {
            let fixture = RecorderFixture()
            let other = RecorderFixture()
            defer { fixture.cleanUp(); other.cleanUp() }
            fixture.start()
            let event = try fixture.event(modifiers: .command, in: other.window)
            XCTAssertTrue(event.window === other.window)
            XCTAssertFalse(fixture.recorder.consume(event))
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertTrue(fixture.commits.isEmpty)
            XCTAssertEqual(fixture.completions, 1)
        }
    }

    func testStopIsIdempotentAndAllowsAnotherRecording() async {
        await MainActor.run {
            let fixture = RecorderFixture()
            defer { fixture.cleanUp() }
            fixture.recorder.stop()
            XCTAssertEqual(fixture.completions, 0)
            fixture.start()
            fixture.recorder.stop()
            fixture.recorder.stop()
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertEqual(fixture.completions, 1)
            fixture.start()
            XCTAssertTrue(fixture.recorder.isRecording)
            XCTAssertFalse(fixture.recorder.needsModifier)
            fixture.recorder.stop()
            XCTAssertEqual(fixture.suspensions, 2)
            XCTAssertEqual(fixture.completions, 2)
        }
    }
}
