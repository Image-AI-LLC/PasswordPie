import AppKit
import Combine

/// Owns the temporary event monitor, independently of SwiftUI view re-creation.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var needsModifier = false
    private var monitor: Any?
    private weak var window: NSWindow?
    private var commit: ((HotKeyConfig) -> Void)?
    private var finish: (() -> Void)?

    func start(in window: NSWindow?, suspend: () -> Void,
               commit: @escaping (HotKeyConfig) -> Void, finish: @escaping () -> Void) {
        guard !isRecording, let window else { return }
        self.window = window
        self.commit = commit
        self.finish = finish
        needsModifier = false
        isRecording = true
        suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Returns true for events consumed by recording, false for ordinary navigation.
    func consume(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        guard event.window === window else { stop(); return false }
        if event.keyCode == 53 { stop(); return true }
        // Tab stays navigation rather than trapping keyboard users inside the recorder.
        if event.keyCode == 48 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            stop()
            return false
        }
        guard let config = HotKeyConfig(event: event) else {
            needsModifier = true
            return true
        }
        commit?(config)
        stop()
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        needsModifier = false
        window = nil
        commit = nil
        let completion = finish
        finish = nil
        completion?()
    }
}
