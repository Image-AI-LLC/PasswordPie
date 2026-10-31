#if DEBUG
import AppKit
import Foundation

/// Debug builds write the panel's state to `PASSWORDPIE_STATUS_FILE` ten times a second, so tests can read it without a screenshot.
/// Secrets never appear: only the length of the master-password field.
@MainActor
final class StatusReporter {
    private let path: String
    private var timer: Timer?
    private let snapshot: () -> [String: Any]

    init?(snapshot: @escaping () -> [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["PASSWORDPIE_STATUS_FILE"] else { return nil }
        self.path = path
        self.snapshot = snapshot
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        write()
    }

    private func write() {
        var state = snapshot()
        state["time"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
