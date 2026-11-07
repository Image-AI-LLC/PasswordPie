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
        guard let data = try? BridgeClient.request(payload),
              let answer = try? JSONSerialization.jsonObject(with: data) else {
            return error("app-unavailable", id: id)
        }
        return answer
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
