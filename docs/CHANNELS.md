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
| Two-step codes (Premium) | a pass from the PasswordPie browser extension (signed in to an account with Premium), or an activation from passwordpie.com. **No account, no sign-in in the app** | a StoreKit 2 purchase on this Apple Account, or an activation from passwordpie.com. **No account, no sign-in** |
| Two-step codes in the browser (Premium) | the app has Premium, or the extension's passwordpie.com token checks ([ACCOUNTS.md](ACCOUNTS.md)) | the app has Premium |
| Network from the app | **none** of its own (see "Network" below) | **none**: no `URLSession`, no `network.client` entitlement |
| Extension popup | Open PasswordPie, Scan QR code on this page, account, Upgrade (pricing page) and "Have a key?"; it hands the account's pass to the app | Safari build with `WXT_PP_STORE=mas` (`make mas-dev`): Open PasswordPie and Scan QR code on this page only. No account, no Upgrade, no key field, no request to the site |
| Browser extension | Safari and Chrome (the Chrome Web Store extension; an unpacked build has the same ID) | Safari only; Chrome's native host is **not compiled in**. See [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md) |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

Check no debug preview or mock site can reach a release store build, and that the direct binary does not link StoreKit:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e PASSWORDPIE_PREMIUM_PREVIEW -e PASSWORDPIE_SITE_URL   # expect 0
    otool -L "$(swift build -c release --show-bin-path)/PasswordPie" | grep -c StoreKit                     # expect 0

Check neither build has an account or a way to reach the site:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api/premium -e app/sign-in -e api/auth   # expect 0
    strings -a build/direct/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api/premium -e app/sign-in -e api/auth   # expect 0
    otool -L build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c AuthenticationServices.*Web   # informational: AutoFill links the framework
    codesign -d --entitlements :- build/mas/PasswordPie.app | grep -c network.client                      # expect 0
    grep -rlE 'api/premium|api/auth' build/mas/PasswordPie.app/Contents/PlugIns/*Safari*/Contents/Resources   # expect nothing

## Releasing the direct download

    NOTARY_ENV=<file with APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID> Scripts/release-direct.sh

It runs `make dist-direct`, notarizes and staples the app, then wraps it in `build/direct/PasswordPie-<version>.dmg`
(with an Applications shortcut), signs, notarizes and staples the DMG, and checks both with `spctl`. Attach the DMG and
its `.sha256` to a GitHub release tagged `v<version>`; passwordpie.com links to
`releases/latest/download/PasswordPie.dmg`, so upload a copy under that name too.

Direct builds trust the Chrome Web Store extension's ID (`BridgeConstants.chromeExtensionID`). Releases made before it
was added cannot connect to the store extension. The Chrome extension itself ships through the Chrome Web Store: see
"Releasing the Chrome extension" in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

The build is Apple Silicon only: `libargon2.a` comes from Homebrew, which ships it for one architecture. An Intel or
universal build needs an x86_64 argon2 first.

The AutoFill extension's restricted entitlement is stripped unless `APP_PROFILE` and `APPEX_PROFILE` are passed, as with
every other target here.

## Network

Neither channel's app opens a network connection of its own. `NetworkSourceTests` fails if any file under `Sources/`
(the app, its core, the bridge, the Chrome host, the Safari and AutoFill extensions) names `URLSession`, `URLRequest`,
`ASWebAuthenticationSession`, `NWConnection` or another networking API (`Network`, `WebKit`, BSD inet sockets), except
files on its allow-list, and the allow-list is empty. No entitlement file asks for `network.client`. Every
`Data(contentsOf:)` in the sources reads a file URL (checked by reading them; the test does not prove it).

What remains, none of it a connection the app makes:

- **Pages it opens in your browser.** Get Premium, Redeem a Key and Open Account Settings (passwordpie.com), Add Chrome
  Extension… (the Chrome Web Store), a database entry's website, the links in About. The browser loads them, not the app.
- **The browser extensions.** The app talks to them over a Unix socket in its App Group container, on this Mac. The
  Chrome host and the Safari extension relay frames to that socket and nothing else. The extension itself talks to
  passwordpie.com (sign-in, Premium, keys); that is the extension's network use, listed on its store page.
- **macOS.** The system may check the app's signature and notarization, and Safari, Chrome and Passwords do their own
  networking. None of it is PasswordPie's code.

Site icons come bundled or from the extension (BROWSER_EXTENSION.md, "Site icons"); there is no update check.

## Direct-only code

Everything is behind `#if PP_DIRECT`: `ChromeLogins.swift`, `ChromeUpdates.swift`, `VaultSession+Chrome.swift` and
`VaultSession+ChromeUpdates.swift` (store build has no-op stubs), the Chrome section of Preferences, and the Chrome tests.
Live Chrome logins are held in `VaultSession.liveEntries`, separate from `entries`, so `save()` can never write them
into the KeePass file. Chrome itself is read-only. A newer Chrome password on the same account replaces the saved one,
and older ones move to the protected `PasswordPie.PreviousPasswords` field; see "The newest password wins" in
[UX.md](UX.md). The store build leaves that field alone and hides it, as it does the other reserved fields.

## What was verified for the App Store channel (dev-signed, `make mas-dev`)

- Builds, signs with the sandbox entitlement, launches, and creates its container data folder. No sandbox denials in the log.
- Reading Chrome's folder is denied in the sandbox (this is why live read is direct-only).
- The legacy keychain (what Touch ID unlock and remembered key files use) works inside the sandbox: add, read, delete.

## Key files in the sandbox

A key file is read once, when it is chosen in an open panel (Choose Key File…, Use Existing Key File…) or written to
the place chosen in a save panel (Add Key File…). Both are user-selected files, which
`com.apple.security.files.user-selected.read-write` covers. After the first unlock with it, PasswordPie keeps the
file's **contents** in the login keychain (generic password, service `com.oldcai.passwordpie.keyfile`, account = the
database path, the same legacy keychain as the Touch ID secret, which works in the sandbox). Later unlocks read the
keychain, never the original path, so neither channel needs a security-scoped bookmark to the key file. Forget Key File
deletes the item; Remove Key File deletes it too, and so does removing the database from the list in Preferences. The Touch ID secret (`com.oldcai.passwordpie`) holds only the master
password; a KeePass 1 key file that older builds put inside it is still read, and removed on Forget Key File.

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
5. **In-app purchase.** Built: see "Premium" below. What is left is in App Store Connect, under "Before Premium can be
   sold".
6. **Site-ranking data licence.** See `Scripts/gen_domain_ranks.py` and the note in the delivery report.

## Premium

Two-step codes need Premium, on both channels. Everything else is free. The behavior is in "Premium: two-step codes"
in [UX.md](UX.md).

**Neither app has an account** (user decision, 2026-11-10, replacing 2026-11-08's "the direct app signs in"). People sign in
in two places only: the PasswordPie browser extension and passwordpie.com. The direct app has no sign-in, no session and
no call to passwordpie.com; it has Premium while it holds a **pass** the extension handed over, or an **activation** from
the website. The two channels now differ only in how Premium is bought: Apple's In-App Purchase in the App Store app,
passwordpie.com for the direct one.

> **2026-11-09** (still in force for the App Store app): it has no account, no sign-in and no network code, for two
> reasons: guideline 5.1.1(v) asks that an app without significant account-based features be usable without a login, and
> any account data the app sends would have to appear on its App Privacy label. Optional sign-in would not avoid that, so
> the code is not in the binary.

> **The direct app's codes need Premium** (2026-11-08), replacing the decision of 2026-11-05 that they were free for
> everyone. To go back, set `directChannelCodesAreFree = true` in `PremiumChannel.swift`: codes in the app are free again,
> and the browser extension still needs Premium (`appHasPremium()` ignores the switch).

| Product ID | Type | Price |
|---|---|---|
| `com.oldcai.passwordpie.premium.lifetime` | Non-consumable | US$29, set in App Store Connect |
| `com.oldcai.passwordpie.premium.yearly` | Auto-renewable subscription, 1 year | US$10, set in App Store Connect |

### Who has Premium: the App Store channel

`AppStorePremiumStore.hasPremium` is true while StoreKit reports a verified, unrevoked, unexpired purchase
(`PremiumStatus`), or while the keychain holds an **activation** that still checks. Nothing is sent anywhere.

An activation is a `passwordpie://activate?token=<JWT>` link opened from passwordpie.com. The token is the same Ed25519
JWS as the pass below, with `aud: passwordpie-activation`, so neither kind of token works as the other. `exp` is the earlier of
one year and the end of the account's Premium. It cannot be revoked, because the app never talks to the site, so a refund
on the site stops counting only at `exp`. The app keeps whichever valid activation runs out latest, and never logs the
token. Both channels register the `passwordpie` URL scheme (`CFBundleURLTypes` in the shared `Info.plist`) and share
`ActivationVault`; any other `passwordpie://` URL does nothing. An activation lasts a year for every plan, lifetime included:
pressing Activate again renews it, and no longer token is issued.

Guideline 3.1.3(b) allows access to what was acquired on your website as long as the same is sold in the app, which it
is. Guideline 3.1.1 forbids an app's own unlock mechanisms such as license keys, so activation has no UI in the app and no
field to type into, and the review notes must describe it, or guideline 2.3.1 (no hidden features) applies. If review
objects, removing `application(_:open:)` and the URL type drops activation and leaves purchases untouched.

### Who has Premium: the direct channel

`DirectPremiumStore.hasPremium` is true while the keychain holds a **pass** or an **activation** that checks: its Ed25519
signature against a key built into the app (`EntitlementToken.trustedKeys`), `iss`, `aud`, and an `exp` in the future. A
pass is checked against `aud: passwordpie-app` and an activation against `aud: passwordpie-activation`, so neither stands
in for the other. The rules are `DirectPremium` in `PasswordPieCore/DirectPremium.swift` (tested in `DirectPremiumTests`).
The app trusts the signature, never the sender.

- **A pass** is the 7-day token passwordpie.com already issues to a signed-in extension (`token` in
  `GET /api/premium/entitlement`). The extension hands it over the bridge with a `premium` request
  ([BROWSER_EXTENSION.md](BROWSER_EXTENSION.md)) after it signs in, each time it renews it (popup, daily alarm), and when
  its connection to the app comes up. Each browser's pass is kept apart.
- **An activation** is the `passwordpie://activate` link above, exactly as in the App Store app.

| What happened | Premium |
|---|---|
| A browser hands over a pass that checks | Yes, until its `exp`; nothing on the window shows that date |
| A browser hands over a pass that does not check | Nothing changes, and nothing stored changes |
| That browser signs out, gets a 401, or the site answers `premium: false` | That browser's pass is deleted. Another browser's pass, or an activation, still counts |
| No browser renews the pass for 7 days | No, from its `exp`; the window says the extension has not renewed it |
| An activation link that checks | Yes, until its `exp` (the latest one held wins) |
| An activation link that ran out, or a pass sent as an activation | Refused, with a plain message. Nothing changes |
| Neither | No |

The app re-evaluates when a token arrives, at launch, when the menu opens, and when the earliest `exp` passes. No timer
talks to a site, because nothing does.

**Migration.** A direct build from before this decision signed in inside the app and kept `session`, `pass` and `email`.
The released v0.1.0 never did (it had no account and no bridge); only builds made from `main` between #37 and this change
did. A `pass` left by one counts until its `exp` and is never renewed; `session` and `email` are deleted at every launch.

**Keychain.** The legacy login keychain, service `com.oldcai.passwordpie.account` (`.dev` in any debug build), accounts
`pass.chrome`, `pass.safari`, `activation`, and the old `pass`. It works in the sandbox without a profile (see above).
None of them is ever logged, echoed over the bridge or written anywhere else. Nothing is read from it before
`PremiumStore.start()` or a token arriving.

**The browser.** `appHasPremium()` (the seam the browser bridge shares with the extension) is this Mac's own Premium:
a pass or an activation, not the free-codes switch.

**What a shared pass allows.** A pass is a bearer proof. Whoever copies one from a Premium extension and hands it to
another Mac's bridge gives that Mac Premium until its `exp`, at most 7 days, with no further renewal unless that Mac's
own extension signs in. An activation link works the same way for up to a year. The site could limit how many it issues
per account; nothing in the app limits it.

### App Store purchases

`StoreKitPremiumBackend` is the only code that imports StoreKit, and the whole file is outside `PP_DIRECT`.

- **Buy.** Apple's sheet; the verified transaction unlocks the codes.
- **Restore Purchases** runs `AppStore.sync()` and reads the entitlements again. No account is involved.
- **A purchase from elsewhere** (Ask to Buy, another Mac) arrives through `Transaction.updates`.

The prices shown are `Product.displayPrice`. The UI links only to the terms, the privacy policy and Apple's own
subscription page, and the App Store build says nothing about buying elsewhere (`PremiumGateTests`). Only
`PremiumDirectViews.swift`, wholly `#if PP_DIRECT`, sends people to passwordpie.com to buy or redeem a key.

**Direct channel.** No StoreKit. The Premium window offers Get Premium (passwordpie.com/pricing), Redeem a Key
(passwordpie.com/redeem) and Open Account Settings (passwordpie.com/settings/premium, where Activate is).

**Codes in the browser.** `browserCodeAllowed` in `PremiumChannel.swift` decides. App Store channel: the app has Premium.
Direct channel: this Mac has Premium (`appHasPremium()`: a pass or an activation), or the `code` request carries a good
passwordpie.com token from the extension ([ACCOUNTS.md](ACCOUNTS.md)). `directChannelCodesAreFree` does not count there.

**The gate.** `OneTimeCodes.access(for:hasPremium:)` is the only code in the app target that may call `TOTP.code`.
`PremiumGateTests` fails if a call appears anywhere else. `Search.swift` and the menu never read a code. The gate changes
nothing on disk: the `otp` field stays in the KeePass file, and saving keeps it.

**Signing.** In-App Purchase is an App ID capability and needs no entitlement. The store build has dropped
`network.client`, because nothing in the app opens a connection and StoreKit runs in Apple's own process. This has not been
tested against the real store: do it at step 8 of the checklist. If the products do not load without it, put that one key
back in `Entitlements/mas.entitlements`; it changes nothing on the App Privacy label.

### App Store privacy label

Answer **Data Not Collected** in App Store Connect. Data processed only on the device is not collected, the app has no
network code, and Apple handles the purchase itself. Keep it true: any new request from the store build, or from the Safari
extension inside it, needs this answer checked first.

### Testing without the site

**Direct channel.** A pass comes from the extension built against the mock site (`extension/dev/mock-site.mjs`, see
[ACCOUNTS.md](ACCOUNTS.md), "Testing without the site"), which signs with the public test key
(`extension/dev/test-key.json`, `kid: pp-test`) that only debug and `make install` builds trust.

**Both channels.** `node Scripts/mint-activation-link.mjs [days] [plan] [audience]` prints an activation link signed with
the test key: a negative `days` for one that has run out, `passwordpie-app` as the audience for a pass dressed as an
activation. Open it with `open -a <the debug .app> '<link>'`.

**App Store channel.** `PASSWORDPIE_PREMIUM_PREVIEW` (debug only) fakes StoreKit, and `PASSWORDPIE_PREMIUM_SCRIPT` (debug
only) runs `buy-lifetime,buy-yearly,restore,refresh` for screenshots.

**Local StoreKit testing.** `Configuration/PasswordPie.storekit` holds both products. It works only through Xcode's Run
action: open `Package.swift` in Xcode, run with `PP_MAS=1` in the scheme's environment, and pick the file under Scheme >
Run > Options > StoreKit Configuration. Launching the built `.app` directly talks to the real store.

### Before Premium can be sold

These are in App Store Connect and the Apple Developer site, and cannot be done from this repo.

1. Check that In-App Purchase is on for the App ID `com.oldcai.passwordpie`.
2. Sign the Paid Apps agreement, and fill in the bank and tax details. Until they are active, products do not load.
3. Create the non-consumable `com.oldcai.passwordpie.premium.lifetime`. Base price US$29 in the United States storefront.
4. Create a subscription group, such as "PasswordPie Premium". Add the auto-renewable subscription
   `com.oldcai.passwordpie.premium.yearly` with a 1 year duration and a base price of US$10.
5. For both, add a display name, a description and a review screenshot of the Premium window.
6. Leave Billing Grace Period off. Codes lock at `expirationDate`, so a grace period would charge people for days they
   cannot use. Turning it on needs a code change first.
7. `EntitlementToken.publicKey` holds passwordpie.com's production public key (`kid: pp-1`, from passwordpie.com#8).
   Before a release, check the site signs with its private half (a token from `/api/premium/entitlement` verifies).
8. Create a sandbox tester under Users and Access > Sandbox, and sign in with it under System Settings > App Store on the test Mac. **Buy and restore with it on a `make mas-dev` build, to prove StoreKit works without `network.client`** (see Signing).
9. Upload a build, then attach both products to the app version for review. A product's first review has to go with a version.
10. Review notes: the app has no account and needs no login. Say that a customer who bought Premium on passwordpie.com can
   activate it from the website through the `passwordpie://activate` link (guideline 3.1.3(b); the same plans are sold
   here), and include a working activation link for the reviewer.
11. Answer **Data Not Collected** in App Privacy.
12. Put the terms link in the app description or the EULA field, as guideline 3.1.2 asks. The privacy policy URL goes in the App Privacy section.
