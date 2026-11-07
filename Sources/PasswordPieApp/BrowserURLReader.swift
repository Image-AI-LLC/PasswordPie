import ApplicationServices
import Foundation
import PasswordPieCore

/// Reads the front tab's address from a browser window with the Accessibility API, for when its extension is not
/// connected. Used only to list the site's accounts; it never asks for Accessibility and never logs what it read.
/// Every attribute read is a blocking call into the browser, so the walk is bounded by a node budget and a deadline
/// and must run off the main thread.
enum BrowserURLReader {
    static let messagingTimeout: Float = 0.25
    static let nodeBudget = 300
    static let deadline: TimeInterval = 0.3

    /// The `AXURL` of the focused window's web area, or for Chrome the address field's text. Nil without Accessibility.
    static func read(pid: pid_t, browser: BridgeBrowser) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        let end = Date().addingTimeInterval(deadline)
        var queue: [AXUIElement] = [window]
        var visited = 0
        var address: String?
        while !queue.isEmpty, visited < nodeBudget, Date() < end {
            let element = queue.removeFirst()
            visited += 1
            let role: String? = attribute(element, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url: URL = attribute(element, "AXURL"), BrowserSite(url: url.absoluteString) != nil {
                    return url.absoluteString
                }
                // A page's own tree is large and holds no address; do not walk into it.
                continue
            }
            if browser == .chrome, address == nil, role == (kAXTextFieldRole as String),
               let value: String = attribute(element, kAXValueAttribute) {
                address = addressFieldURL(value)
            }
            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                queue += children
            }
        }
        return address
    }

    /// Chrome's address field shows `github.com/login` without the scheme. Text that is not an address gives nil.
    static func addressFieldURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let site = BrowserSite(url: candidate), site.host.contains(".") || site.host == "localhost" else { return nil }
        return candidate
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == [AXUIElement].self {
            return value as? [AXUIElement] as? T
        }
        return value as? T
    }
}
