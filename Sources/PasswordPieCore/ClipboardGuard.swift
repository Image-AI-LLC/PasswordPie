import Foundation

/// The slice of NSPasteboard the clipboard policy needs, so the policy runs without AppKit.
public protocol PasteboardLike: AnyObject {
    var changeCount: Int { get }
    /// Replaces the contents with `string`, flagged as concealed so clipboard managers skip it. Returns the new change count.
    func write(_ string: String) -> Int
    func clear()
}

/// A scheduled action that can be cancelled.
public protocol Cancellable: AnyObject {
    func cancel()
}

/// Copy policy: clear after max(timeout, 5) seconds, only if nothing else was copied in between; a new copy cancels the old timer.
public final class ClipboardGuard {
    public static let minimumTimeout: TimeInterval = 5
    public static let defaultTimeout: TimeInterval = 90

    public var timeout: TimeInterval
    private let pasteboard: PasteboardLike
    private let schedule: (TimeInterval, @escaping () -> Void) -> Cancellable
    private var pending: Cancellable?
    private var lastWrite: Int?

    public init(
        pasteboard: PasteboardLike,
        timeout: TimeInterval = ClipboardGuard.defaultTimeout,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable
    ) {
        self.pasteboard = pasteboard
        self.timeout = timeout
        self.schedule = schedule
    }

    public var delay: TimeInterval { max(timeout, ClipboardGuard.minimumTimeout) }

    public func copy(_ string: String) {
        pending?.cancel()
        let ours = pasteboard.write(string)
        lastWrite = ours
        pending = schedule(delay) { [weak self] in self?.clearIfUnchanged() }
    }

    /// Clears right now (app quit) if the clipboard still holds our copy.
    public func flush() {
        pending?.cancel()
        clearIfUnchanged()
    }

    private func clearIfUnchanged() {
        pending = nil
        guard let ours = lastWrite else { return }
        lastWrite = nil
        if pasteboard.changeCount == ours {
            pasteboard.clear()
        }
    }
}
