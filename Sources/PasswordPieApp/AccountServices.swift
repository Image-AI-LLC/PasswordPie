#if PP_DIRECT
import AppKit
import AuthenticationServices
import Foundation
import PasswordPieCore

// The direct channel's PasswordPie account, as `AccountPremiumStore` reaches it. Not in the App Store binary, which has no
// account and no network code. As `AccountPremiumStore` reaches it: the site, the keychain, and the sign-in sheet. Each is a
// protocol so tests can script it. What the replies mean is decided in PasswordPieCore (`Account.swift`).

/// passwordpie.com's account and Premium endpoints. Every call that takes `session` sends it as a bearer token.
@MainActor
protocol AccountClient: AnyObject {
    /// The session token for a sign-in callback's one-time code. Nil when the code is refused or the site is unreachable.
    func exchange(code: String) async -> String?
    func email(session: String) async -> String?
    func entitlement(session: String) async -> AccountReply
    func signOut(session: String) async
}

@MainActor
final class URLSessionAccountClient: AccountClient {
    private let site: AccountSite
    private let urlSession: URLSession

    init(site: AccountSite, urlSession: URLSession = .shared) {
        self.site = site
        self.urlSession = urlSession
    }

    private func send(_ url: URL, method: String = "GET", session: String? = nil, body: [String: Any]? = nil) async -> (Int, Data)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Bearer only: the site's cookies never come along, so a browser session cannot stand in for this one.
        request.httpShouldHandleCookies = false
        if let session { request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await urlSession.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    func exchange(code: String) async -> String? {
        guard let (status, data) = await send(site.exchangeURL, method: "POST", body: ["code": code]), status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    func email(session: String) async -> String? {
        guard let (status, data) = await send(site.sessionURL, session: session), status == 200 else { return nil }
        return AccountSessionInfo.email(from: data) ?? nil
    }

    func entitlement(session: String) async -> AccountReply {
        guard let (status, data) = await send(site.entitlementURL, session: session) else { return .unreachable }
        return AccountReply.parse(status: status, body: data)
    }

    func signOut(session: String) async {
        _ = await send(site.signOutURL, method: "POST", session: session, body: [:])
    }
}

/// The sign-in sheet. Ends with the `passwordpie://auth?…` URL the site sent the browser to.
@MainActor
protocol AccountSignInDriver: AnyObject {
    /// Throws `AccountSignInCancelled` when the user closes the sheet.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

struct AccountSignInCancelled: Error {}

/// `ASWebAuthenticationSession`: passwordpie.com in a sheet that belongs to the app, sharing Safari's cookies so a
/// remembered Apple Account or Google sign-in is one click.
@MainActor
final class WebAuthenticationSignIn: NSObject, AccountSignInDriver, ASWebAuthenticationPresentationContextProviding {
    private var current: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        current?.cancel()
        return try await withCheckedThrowingContinuation { continuation in
            // The completion runs on a background queue.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                DispatchQueue.main.async { self?.current = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AccountSignInCancelled())
                } else {
                    continuation.resume(throwing: error ?? AccountSignInCancelled())
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            current = session
            NSApp.activate(ignoringOtherApps: true)
            if !session.start() {
                current = nil
                continuation.resume(throwing: AccountSignInCancelled())
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let anchor = {
            MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? NSWindow() }
        }
        return Thread.isMainThread ? anchor() : DispatchQueue.main.sync(execute: anchor)
    }
}

/// Everything `AccountPremiumStore` needs for the account.
@MainActor
struct AccountServices {
    var site: AccountSite
    var client: AccountClient
    var secrets: AccountSecretStore
    var signIn: AccountSignInDriver
    /// Checks a pass. The real one trusts `EntitlementToken.trustedKeys`.
    var verify: (String, Date) -> Entitlement?

    /// The real site, keychain and sheet. A debug build can point at a mock site with `PASSWORDPIE_SITE_URL`: the pass
    /// still has to check against a trusted key, and its keychain items are kept apart from the installed app's.
    static func live() -> AccountServices {
        var site = AccountSite.production
        var service = "com.oldcai.passwordpie.account"
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PASSWORDPIE_SITE_URL"], let url = URL(string: override) {
            site = AccountSite(base: url)
            service += ".dev"
        }
        #endif
        return AccountServices(
            site: site,
            client: URLSessionAccountClient(site: site),
            secrets: KeychainAccountSecrets(service: service),
            signIn: WebAuthenticationSignIn(),
            verify: { EntitlementToken.verifyTrusted($0, now: $1) }
        )
    }
}
#endif
