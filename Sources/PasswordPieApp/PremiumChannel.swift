import Foundation
import PasswordPieCore

#if PP_DIRECT
/// **The direct channel's switch.** False: two-step codes need a signed-in PasswordPie account with Premium, as in the App
/// Store app (the user's decision of 2026-11-08, replacing "codes are free in the direct app" of 2026-11-05). Set it to
/// true to make codes in the app free again for everyone; the account still decides for the browser extension.
let directChannelCodesAreFree = false
#endif

#if PP_DIRECT
typealias PremiumStore = AccountPremiumStore
#else
typealias PremiumStore = AppStorePremiumStore
#endif

/// Which `PremiumStore` this build's channel uses. Chosen at compile time, like everything else in docs/CHANNELS.md.
enum PremiumChannel {
    /// The store the app runs on, for `appAccountHasPremium()`.
    @MainActor private(set) static weak var live: PremiumStore?

    #if PP_DIRECT
    @MainActor
    static func makeStore(services: AccountServices? = nil) -> PremiumStore {
        let store = PremiumStore(services: services ?? .live(), freeCodes: directChannelCodesAreFree)
        if live == nil { live = store }
        return store
    }
    #else
    @MainActor
    static func makeStore(secrets: AccountSecretStore? = nil) -> PremiumStore {
        var backend: PremiumBackend = StoreKitPremiumBackend()
        var service = "com.oldcai.passwordpie.account"
        #if DEBUG
        if let preview = PremiumPreviewBackend.fromEnvironment() { backend = preview }
        service += ".dev"
        #endif
        let store = PremiumStore(
            backend: backend,
            secrets: secrets ?? KeychainAccountSecrets(service: service),
            verify: { EntitlementToken.verifyActivation($0, now: $1) }
        )
        if live == nil { live = store }
        return store
    }
    #endif
}

/// **The seam the browser bridge asks:** true when this app has Premium for the browser. App Store channel: the app has
/// Premium. Direct channel: the PasswordPie account signed in inside the app has it; the free-codes switch does not count.
@MainActor
func appAccountHasPremium() -> Bool {
    #if PP_DIRECT
    PremiumChannel.live?.accountHasPremium ?? false
    #else
    PremiumChannel.live?.hasPremium ?? false
    #endif
}

/// Whether a two-step code may go to the browser for a `code` request carrying `entitlement` (docs/ACCOUNTS.md,
/// "Who decides"). Direct channel: the app's own account has Premium, or the extension's token from passwordpie.com is
/// good; `directChannelCodesAreFree` does not count. App Store channel: the app has Premium, and the Safari extension has no
/// token to carry. The token is never logged or kept.
@MainActor
func browserCodeAllowed(entitlement: String?, now: Date, appAccount: @MainActor () -> Bool = appAccountHasPremium) -> Bool {
    #if PP_DIRECT
    appAccount() || EntitlementToken.verifyTrusted(entitlement, now: now) != nil
    #else
    appAccount()
    #endif
}
