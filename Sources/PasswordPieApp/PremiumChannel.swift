import Foundation
import PasswordPieCore

#if PP_DIRECT
/// **The direct channel's switch.** False: two-step codes need a signed-in PasswordPie account with Premium, as in the App
/// Store app (the user's decision of 2026-11-08, replacing "codes are free in the direct app" of 2026-11-05). Set it to
/// true to make codes in the app free again for everyone; the account still decides for the browser extension.
let directChannelCodesAreFree = false
#endif

/// Which `PremiumStore` this build's channel uses. Chosen at compile time, like everything else in docs/CHANNELS.md.
enum PremiumChannel {
    /// The store the app runs on, for `appAccountHasPremium()`.
    @MainActor private(set) static weak var live: PremiumStore?

    @MainActor
    static func makeStore(services: AccountServices? = nil) -> PremiumStore {
        let services = services ?? .live()
        #if PP_DIRECT
        let store = PremiumStore(backend: nil, services: services, freeCodes: directChannelCodesAreFree)
        #else
        var backend: PremiumBackend = StoreKitPremiumBackend()
        #if DEBUG
        if let preview = PremiumPreviewBackend.fromEnvironment() { backend = preview }
        #endif
        let store = PremiumStore(backend: backend, services: services)
        #endif
        if live == nil { live = store }
        return store
    }
}

/// **The seam for the app's own account** (shared with the browser bridge, worktree `extension-premium`): true when
/// the PasswordPie account signed in inside the app has Premium now. The direct channel's free-codes switch does not count.
@MainActor
func appAccountHasPremium() -> Bool {
    PremiumChannel.live?.accountHasPremium ?? false
}
