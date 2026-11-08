import Foundation
import PasswordPieBridge
import SafariServices

/// The native side of the PasswordPie Safari extension. Each `browser.runtime.sendNativeMessage` arrives here; it is sent
/// to the PasswordPie app over the bridge socket and the app's answer goes back to the extension. Nothing is kept, and a
/// message's contents are never logged. See docs/BROWSER_EXTENSION.md.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        let box = ContextBox(context)
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Self.relay(message)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: answer]
            box.context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    static func relay(_ message: Any?) -> Any {
        let id = (message as? [String: Any])?["id"] as? Int
        guard let message, JSONSerialization.isValidJSONObject(message),
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            return error("bad-request", id: id)
        }
        if AppLaunch.isShowRequest(payload) { return show(payload, id: id) }
        do {
            // The sandbox cannot read the app's bundle, so the app's signature cannot be checked from here (securityd
            // answers EPERM). The app checks this extension's signature; the socket is in the team's group container.
            let data = try BridgeClient.request(payload, verifyServer: false)
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            // The error only: never the message, which can carry a URL.
            NSLog("PasswordPie Safari extension: no answer from the app (%@)", String(describing: error))
            return Self.error("app-unavailable", id: id)
        }
    }

    /// The toolbar button. Short timeouts keep the whole of it under 10 s, inside the extension's 12: the first try, then,
    /// when that failed, a start of the app this extension is inside if it is not running, and tries until it answers.
    private static func show(_ payload: Data, id: Int?) -> Any {
        func attempt() -> Any? {
            guard let data = try? BridgeClient.request(payload, timeout: 1, verifyServer: false) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        if let answer = attempt() { return answer }
        let running = AppLaunch.isAppRunning()
        if AppLaunch.fallback(for: payload, appRunning: running) == .launch,
           let app = Bundle.main.executableURL.flatMap(AppLaunch.containingApp(of:)) {
            AppLaunch.open(app)
        }
        var answer: Any?
        _ = AppLaunch.retry(for: running ? AppLaunch.runningWaitSeconds : AppLaunch.showWaitSeconds, interval: 0.25) {
            answer = attempt()
            return answer != nil
        }
        return answer ?? error(AppLaunch.failureCode(appRunning: AppLaunch.isAppRunning()), id: id)
    }

    private static func error(_ code: String, id: Int?) -> [String: Any] {
        var answer: [String: Any] = ["type": "error", "code": code]
        if let id { answer["id"] = id }
        return answer
    }
}

/// `NSExtensionContext` is not Sendable; it is only used again to complete the request.
private final class ContextBox: @unchecked Sendable {
    let context: NSExtensionContext
    init(_ context: NSExtensionContext) { self.context = context }
}
