import Foundation
import PasswordPieCore

#if PP_DIRECT
/// **The direct channel's switch.** False: two-step codes need Premium, as in the App Store app (the user's decision of
/// 2026-11-08, replacing "codes are free in the direct app" of 2026-11-05). Set it to true to make codes in the app free
/// again for everyone; the browser extension still needs Premium (`appHasPremium()` ignores the switch).
let directChannelCodesAreFree = false
#endif

#if PP_DIRECT
typealias PremiumStore = DirectPremiumStore
#else
typealias PremiumStore = AppStorePremiumStore
#endif

/// Which `PremiumStore` this build's channel uses. Chosen at compile time, like everything else in docs/CHANNELS.md.
enum PremiumChannel {
    /// The store the app runs on, for `appHasPremium()` and the bridge's `premium` request.
    @MainActor static weak var live: PremiumStore?

    /// Where Premium's tokens are kept. A debug build keeps its own, apart from the installed app's.
    static var keychainService: String {
        #if DEBUG
        "com.oldcai.passwordpie.account.dev"
        #else
        "com.oldcai.passwordpie.account"
        #endif
    }

    #if PP_DIRECT
    @MainActor
    static func makeStore(secrets: SecretStore? = nil) -> PremiumStore {
        let store = PremiumStore(
            secrets: secrets ?? KeychainSecrets(service: keychainService),
            verifyPass: { EntitlementToken.verifyTrusted($0, now: $1) },
            verifyActivation: { EntitlementToken.verifyActivation($0, now: $1) },
            freeCodes: directChannelCodesAreFree
        )
        if live == nil { live = store }
        return store
    }

    /// The bridge's `premium` request from `browser`'s extension: its pass, or taking it back.
    @MainActor
    static func passRelay(from browser: BridgeBrowser) -> ((PassRelay) -> Bool)? {
        { relay in live?.receive(relay, from: PassSource(browser)) ?? false }
    }
    #else
    @MainActor
    static func makeStore(secrets: SecretStore? = nil) -> PremiumStore {
        var backend: PremiumBackend = StoreKitPremiumBackend()
        #if DEBUG
        if let preview = PremiumPreviewBackend.fromEnvironment() { backend = preview }
        #endif
        let store = PremiumStore(
            backend: backend,
            secrets: secrets ?? KeychainSecrets(service: keychainService),
            verify: { EntitlementToken.verifyActivation($0, now: $1) }
        )
        if live == nil { live = store }
        return store
    }

    /// The App Store app takes Premium only from StoreKit or an activation. Its Safari extension has no account and sends
    /// no pass; one that arrives anyway is answered as an unknown message and changes nothing.
    @MainActor
    static func passRelay(from browser: BridgeBrowser) -> ((PassRelay) -> Bool)? {
        nil
    }
    #endif
}

/// **The seam the browser bridge asks:** true when this Mac has Premium of its own. App Store channel: a purchase or an
/// activation. Direct channel: a pass from a browser extension or an activation; the free-codes switch does not count.
@MainActor
func appHasPremium() -> Bool {
    #if PP_DIRECT
    PremiumChannel.live?.ownPremium ?? false
    #else
    PremiumChannel.live?.hasPremium ?? false
    #endif
}

/// Whether a two-step code may go to the browser for a `code` request carrying `entitlement` (docs/ACCOUNTS.md,
/// "Who decides"). Direct channel: this Mac has Premium, or the extension's token from passwordpie.com is good;
/// `directChannelCodesAreFree` does not count. App Store channel: the app has Premium, and the Safari extension has no
/// token to carry. The token is never logged or kept.
@MainActor
func browserCodeAllowed(entitlement: String?, now: Date, appPremium: @MainActor () -> Bool = appHasPremium) -> Bool {
    #if PP_DIRECT
    appPremium() || EntitlementToken.verifyTrusted(entitlement, now: now) != nil
    #else
    appPremium()
    #endif
}
