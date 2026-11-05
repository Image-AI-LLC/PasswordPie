import PasswordPieCore

#if PP_DIRECT
/// **The seam for the direct channel.** Who has Premium on a Developer ID build. StoreKit cannot sell there and there is
/// no license system yet, so everyone does, and no paywall code path runs. A license check goes here: return `.free` or
/// `.directChannel` from it, and wire `presentPaywall` to whatever sells the license.
func directChannelPremiumStatus() -> PremiumStatus {
    .directChannel
}
#endif

/// Which `PremiumStore` this build's channel uses. Chosen at compile time, like everything else in docs/CHANNELS.md.
enum PremiumChannel {
    @MainActor
    static func makeStore() -> PremiumStore {
        #if PP_DIRECT
        return PremiumStore(fixedStatus: directChannelPremiumStatus())
        #else
        #if DEBUG
        if let preview = PremiumPreviewBackend.fromEnvironment() {
            return PremiumStore(backend: preview)
        }
        #endif
        return PremiumStore(backend: StoreKitPremiumBackend())
        #endif
    }
}
