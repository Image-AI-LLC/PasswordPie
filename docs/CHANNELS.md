# Release channels

One source tree, two channels. The channel is chosen at build time, not by a runtime switch, so
App Store builds do not contain direct-only code.

| | Direct (default) | App Store |
|---|---|---|
| Build | `swift build` / `make install` / `make dist-direct` | `PP_MAS=1 swift build` / `make mas-dev` |
| Swift flag | `PP_DIRECT` defined | not defined |
| Sandbox | no (hardened runtime, notarized) | yes (`Entitlements/mas.entitlements`) |
| Import CSV from Chrome / Apple Passwords | yes | yes |
| Live read of Chrome's password store | yes (Preferences > Chrome) | **not compiled in** |
| Two-step codes (Premium) | always on, no paywall (`directChannelPremiumStatus()`) | needs Premium: StoreKit 2 only, Apple is the source of truth |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

Check no debug preview can grant Premium in a release store build, and that the direct binary does not link StoreKit:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c PASSWORDPIE_PREMIUM_PREVIEW   # expect 0
    otool -L "$(swift build -c release --show-bin-path)/PasswordPie" | grep -c StoreKit                     # expect 0

## Releasing the direct download

    NOTARY_ENV=<file with APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID> Scripts/release-direct.sh

It runs `make dist-direct`, notarizes and staples the app, then wraps it in `build/direct/PasswordPie-<version>.dmg`
(with an Applications shortcut), signs, notarizes and staples the DMG, and checks both with `spctl`. Attach the DMG and
its `.sha256` to a GitHub release tagged `v<version>`; passwordpie.com links to
`releases/latest/download/PasswordPie.dmg`, so upload a copy under that name too.

The build is Apple Silicon only: `libargon2.a` comes from Homebrew, which ships it for one architecture. An Intel or
universal build needs an x86_64 argon2 first.

The AutoFill extension's restricted entitlement is stripped unless `APP_PROFILE` and `APPEX_PROFILE` are passed, as with
every other target here.

## Direct-only code

Everything is behind `#if PP_DIRECT`: `ChromeLogins.swift`, `VaultSession+Chrome.swift` (store build has no-op stubs),
the Chrome section of Preferences, and the Chrome tests. Live Chrome logins are held in `VaultSession.liveEntries`,
separate from `entries`, so `save()` can never write them into the KeePass file. They are read-only; the user
either edits them in Chrome or uses "Save to KeePass" on a single login.

## What was verified for the App Store channel (dev-signed, `make mas-dev`)

- Builds, signs with the sandbox entitlement, launches, and creates its container data folder. No sandbox denials in the log.
- Reading Chrome's folder is denied in the sandbox (this is why live read is direct-only).
- The legacy keychain (what Touch ID unlock uses today) works inside the sandbox: add, read, delete.

## Open items before an App Store submission

These could not be verified without a Distribution certificate and provisioning profile, or need design work:

1. **Remember the database across launches.** `databasePath` is a plain path in UserDefaults. Sandbox needs a
   security-scoped bookmark (`files.bookmarks.app-scope` is already in the entitlements, the code is not written).
2. **Import of non-KDBX databases writes a sibling `.kdbx`** next to the source file. The sandbox only grants the chosen
   file, not its folder, so this needs a save panel.
3. **Auto-fill / auto-type** uses `AXIsProcessTrusted` and `CGEventPost`. It was not confirmed that a sandboxed app can
   be granted Accessibility; test with a real store-signed build, and decide whether the store channel ships without it.
4. **Touch ID keychain.** The data-protection keychain (`kSecUseDataProtectionKeychain`) returns -34018 without a
   provisioning profile. With a profile the store channel can use the biometric access control the comment in
   `TouchIDSecretStore.swift` describes.
5. **In-app purchase.** Built: see "Premium" below. What is left is in App Store Connect, under "Before Premium can be sold".
6. **Site-ranking data licence.** See `Scripts/gen_domain_ranks.py` and the note in the delivery report.

## Premium

Two-step codes need Premium on the App Store channel. Everything else is free on both channels. The behavior is in
"Premium: two-step codes" in [UX.md](UX.md).

| Product ID | Type | Price |
|---|---|---|
| `com.oldcai.passwordpie.premium.lifetime` | Non-consumable | US$29, set in App Store Connect |
| `com.oldcai.passwordpie.premium.yearly` | Auto-renewable subscription, 1 year | US$10, set in App Store Connect |

**App Store channel.** `StoreKitPremiumBackend` is the only code that imports StoreKit, and the whole file is outside
`PP_DIRECT`. Premium comes only from `.verified` transactions in `Transaction.currentEntitlements`, kept current by
`Transaction.updates`, honoring `revocationDate` and `expirationDate`. It also asks again when the menu opens and when the
app comes forward, because the stream does not always fire for a refund. Nothing is cached, so no flag on disk can grant it.
A purchase result never grants Premium by itself: the entitlement can lag it by a moment, so the store keeps asking for a
few seconds, then says it is on its way and unlocks when it arrives.
The prices shown are `Product.displayPrice`. The UI links only to the terms, the privacy policy and Apple's own
subscription page, and says nothing about buying elsewhere. `AppStore.showManageSubscriptions` does not exist on macOS,
so Manage Subscription opens `https://apps.apple.com/account/subscriptions`.

**Direct channel.** StoreKit cannot sell outside the App Store and there is no license system, so Premium is on and no
paywall code path is compiled in. `directChannelPremiumStatus()` in `PremiumChannel.swift` is the one seam: a license
check goes there, and the binary keeps working if it is never written.

**The gate.** `OneTimeCodes.access(for:hasPremium:)` is the only code in the app target that may call `TOTP.code`.
`PremiumGateTests` fails if a call appears anywhere else. `Search.swift` and the menu never read a code. The gate changes
nothing on disk: the `otp` field stays in the KeePass file, and saving keeps it.

**Signing.** No entitlement is added. In-App Purchase is an App ID capability that Apple turns on for explicit App IDs,
and StoreKit needs only the sandbox's existing `network.client`.

**Local testing.** `Configuration/PasswordPie.storekit` holds both products. It works only through Xcode's Run action: open
`Package.swift` in Xcode, run with `PP_MAS=1` in the scheme's environment, and pick the file under Scheme > Run > Options >
StoreKit Configuration. Launching the built `.app` directly talks to the real store. Debug builds can also draw any state
with made-up prices, using `PASSWORDPIE_PREMIUM_PREVIEW` in `PremiumPreview.swift`, which release builds do not compile.

### Before Premium can be sold

These are in App Store Connect and cannot be done from this repo.

1. Check that In-App Purchase is on for the App ID `com.oldcai.passwordpie`.
2. Sign the Paid Apps agreement, and fill in the bank and tax details. Until they are active, products do not load.
3. Create the non-consumable `com.oldcai.passwordpie.premium.lifetime`. Base price US$29 in the United States storefront.
4. Create a subscription group, such as "PasswordPie Premium". Add the auto-renewable subscription
   `com.oldcai.passwordpie.premium.yearly` with a 1 year duration and a base price of US$10.
5. For both, add a display name, a description and a review screenshot of the Premium window.
6. Leave Billing Grace Period off. Codes lock at `expirationDate`, so a grace period would charge people for days they
   cannot use. Turning it on needs a code change first.
7. Create a sandbox tester under Users and Access > Sandbox, and sign in with it under System Settings > App Store on the test Mac.
8. Upload a build, then attach both products to the app version for review. A product's first review has to go with a version.
9. Put the terms link in the app description or the EULA field, as guideline 3.1.2 asks. The privacy policy URL goes in the App Privacy section.
