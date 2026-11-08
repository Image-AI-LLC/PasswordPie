import AppKit
import Foundation

/// The extension's toolbar button asks the app to show its panel. When the app is not running, the Chrome host or the
/// Safari extension handler, both inside PasswordPie.app, start it and send the request again. See docs/BROWSER_EXTENSION.md, "show".
public enum AppLaunch {
    /// How long a `show` waits for a just-started app to open its socket. With the first try, a Safari `show` stays
    /// under 10 s, and the extension waits 12 (`SHOW_TIMEOUT_MS`).
    public static let showWaitSeconds: Double = 7
    /// How long a `show` waits for an app that is already running: the host may be between reconnects.
    public static let runningWaitSeconds: Double = 2
    /// The error for a `show` when the app runs but did not answer. The extension does not send this user to the website.
    public static let notRespondingCode = "app-not-responding"

    /// What a `show` the app did not get does next.
    public enum Fallback: Equatable {
        /// The app is not running: start it and wait `showWaitSeconds`.
        case launch
        /// The app is running: do not start it again, wait `runningWaitSeconds` for its socket.
        case wait
        /// Not a `show`: answer `app-unavailable` now.
        case none
    }

    public static func fallback(for frame: Data, appRunning: Bool) -> Fallback {
        guard isShowRequest(frame) else { return .none }
        return appRunning ? .wait : .launch
    }

    /// The error code for a `show` that got no answer after its fallback.
    public static func failureCode(appRunning: Bool) -> String {
        appRunning ? notRespondingCode : "app-unavailable"
    }

    /// True when PasswordPie is running for this user. By bundle identifier: the sandboxed Safari extension cannot read the app's bundle.
    public static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: BridgeConstants.appIdentifier).isEmpty
    }

    /// True when the frame is a `show` request. Only that request starts the app: tab reports never do.
    public static func isShowRequest(_ frame: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return false }
        return object["type"] as? String == "show"
    }

    /// The `.app` bundle that holds `executable`: the host in `Contents/MacOS`, or an extension in `Contents/PlugIns`.
    public static func containingApp(of executable: URL) -> URL? {
        var url = executable.standardizedFileURL
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// Starts the app. Returns at once; the caller waits for its socket with `retry`.
    public static func open(_ app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { NSLog("PasswordPie: could not start the app (%@)", String(describing: error)) }
        }
    }

    /// Calls `attempt` every `interval` seconds until it returns true. No attempt starts after `seconds`; one in progress
    /// then may still run to its own timeout.
    public static func retry(for seconds: Double, interval: Double = 0.1, _ attempt: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if attempt() { return true }
            guard Date().addingTimeInterval(interval) < deadline else { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
