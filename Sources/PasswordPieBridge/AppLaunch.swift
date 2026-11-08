import AppKit
import Foundation

/// The extension's toolbar button asks the app to show its panel. When the app is not running, the Chrome host or the
/// Safari extension handler, both inside PasswordPie.app, start it and send the request again. See docs/BROWSER_EXTENSION.md, "show".
public enum AppLaunch {
    /// How long a `show` waits for a just-started app to open its socket. The extension waits longer (`SHOW_TIMEOUT_MS`).
    public static let showWaitSeconds: Double = 8

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

    /// Calls `attempt` every `interval` seconds until it returns true, for at most `seconds`.
    public static func retry(for seconds: Double, interval: Double = 0.1, _ attempt: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if attempt() { return true }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return attempt()
    }
}
