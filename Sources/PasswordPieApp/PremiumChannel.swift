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
    /// The store the app runs on, for `appHasPremium()`.
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
            verifyActivation: { EntitlementToken.verifyActivation($0, now: $1) },
            freeCodes: directChannelCodesAreFree
        )
        if live == nil { live = store }
        return store
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
    #endif
}

/// **The seam the browser bridge asks:** true when this Mac has Premium of its own. App Store channel: a purchase or an
/// activation. Direct channel: an activation; the free-codes switch does not count.
@MainActor
func appHasPremium() -> Bool {
    #if PP_DIRECT
    PremiumChannel.live?.ownPremium ?? false
    #else
    PremiumChannel.live?.hasPremium ?? false
    #endif
}

/// Whether a two-step code may go to the browser (docs/ACCOUNTS.md, "Who decides"): only when this Mac has Premium of its
/// own. The browser extension has no account and carries no proof, so nothing it sends can change the answer.
/// `directChannelCodesAreFree` does not count.
@MainActor
func browserCodeAllowed(appPremium: @MainActor () -> Bool = appHasPremium) -> Bool {
    appPremium()
}
