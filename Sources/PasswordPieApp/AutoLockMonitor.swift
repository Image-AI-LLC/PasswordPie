import AppKit
import IOKit
import PasswordPieCore

/// Seconds since the last keyboard or mouse input.
enum SystemIdle {
    static func seconds() -> TimeInterval {
        if let hid = hidIdleTime() { return hid }
        // kCGAnyInputEventType. `.null` is not "any": it reports the time since the last *null* event (about 1.4 million seconds).
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// IOHIDSystem's `HIDIdleTime`, in nanoseconds.
    static func hidIdleTime() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = (dictionary["HIDIdleTime"] as? NSNumber)?.doubleValue else { return nil }
        return nanoseconds / 1_000_000_000
    }
}

/// Feeds system events to the pure `AutoLockPolicy` and locks when it says so.
/// Hiding the panel or losing focus never locks; only idleness, sleep, the screen saver, a user switch or power off do.
@MainActor
final class AutoLockMonitor {
    private var policy: AutoLockPolicy
    private var timer: Timer?
    private let lock: () -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: AutoLockSettings, lock: @escaping () -> Void) {
        policy = AutoLockPolicy(settings: settings, systemIdle: { SystemIdle.seconds() })
        self.lock = lock
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.policy.shouldLockForIdle() { self.lock() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleep() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.sleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.wake() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.wake() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { if $0.policy.sessionDidResignActive() { $0.lock() } }
        observe(workspace, NSWorkspace.willPowerOffNotification) { if $0.policy.willPowerOff() { $0.lock() } }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.policy.registerActivity() }
        observe(workspace, NSWorkspace.didDeactivateApplicationNotification) { $0.policy.registerActivity() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { if $0.policy.screenSaverDidStart() { $0.lock() } }
    }

    func registerActivity() { policy.registerActivity() }

    func update(_ settings: AutoLockSettings) { policy.settings = settings }

    /// Seconds the system reports idle; shown in the DEBUG status file.
    var systemIdle: TimeInterval { SystemIdle.seconds() }

    private func sleep() { if policy.willSleep() { lock() } }
    private func wake() { if policy.didWake() { lock() } }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AutoLockMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        tokens.append((center, token))
    }
}
