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
| Two-step codes (Premium) | need a PasswordPie account with Premium (Get Premium and keys on passwordpie.com) | a StoreKit 2 purchase on this Apple Account, or an activation from passwordpie.com. **No account, no sign-in** |
| Two-step codes in the browser (Premium) | the app's own account has Premium, or the extension's passwordpie.com token checks ([ACCOUNTS.md](ACCOUNTS.md)) | the app has Premium |
| Network from the app | passwordpie.com, for the account only | **none**: no `URLSession`, no `network.client` entitlement |
| Extension popup | account, Upgrade (pricing page) and "Have a key?" | Safari build with `WXT_PP_STORE=mas` (`make mas-dev`): Open PasswordPie only. No account, no Upgrade, no key field, no request to the site |
| Browser extension | Safari and Chrome (the Chrome Web Store extension; an unpacked build has the same ID) | Safari only; Chrome's native host is **not compiled in**. See [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md) |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

Check no debug preview or mock site can reach a release store build, and that the direct binary does not link StoreKit:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e PASSWORDPIE_PREMIUM_PREVIEW -e PASSWORDPIE_SITE_URL   # expect 0
    otool -L "$(swift build -c release --show-bin-path)/PasswordPie" | grep -c StoreKit                     # expect 0

Check the store build has no account and no way to reach the site:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api/premium -e app/sign-in -e api/auth   # expect 0
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
5. **In-app purchase.** Built: see "Premium" below. What is left is in App Store Connect, under "Before Premium can be
   sold".
6. **Site-ranking data licence.** See `Scripts/gen_domain_ranks.py` and the note in the delivery report.

## Premium

Two-step codes need Premium, on both channels. Everything else is free. The behavior is in "Premium: two-step codes"
in [UX.md](UX.md).

**Each channel decides Premium its own way** (user decision, 2026-11-09, replacing 2026-11-08's "Premium is the account's
on both channels"). The App Store app has no account, no sign-in and no network code, for two reasons: guideline 5.1.1(v)
asks that an app without significant account-based features be usable without a login, and any account data the app sends
would have to appear on its App Privacy label. Optional sign-in would not avoid that, so the code is not in the binary.
The direct download and the browser extension read the PasswordPie account on passwordpie.com.

> **The direct app's codes need the account** (2026-11-08), replacing the decision of 2026-11-05 that they were free for
> everyone. To go back, set `directChannelCodesAreFree = true` in `PremiumChannel.swift`: codes in the app are free again,
> and the browser extension still needs the account (`appAccountHasPremium()` ignores the switch).

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
token. Only the App Store build registers the URL scheme (`make mas-dev` adds `CFBundleURLTypes`).

Guideline 3.1.3(b) allows access to what was acquired on your website as long as the same is sold in the app, which it
is. Guideline 3.1.1 forbids an app's own unlock mechanisms such as license keys, so activation has no UI in the app and no
field to type into, and the review notes must describe it, or guideline 2.3.1 (no hidden features) applies. If review
objects, removing `application(_:open:)` and the URL type drops activation and leaves purchases untouched.

### Who has Premium: the direct channel

`AccountPremiumStore.hasPremium` is true only while the keychain holds a **pass** (the `token` from
`GET /api/premium/entitlement`) whose Ed25519 signature checks against a key built into the app
(`EntitlementToken.trustedKeys`), with the right `iss` and `aud`, and an `exp` in the future. The site's `premium: true`
alone grants nothing. The decision is `AccountPremiumDecision.evaluate` in `PasswordPieCore/Account.swift`.

| What happened | Premium |
|---|---|
| Signed out | No, whatever is left in the keychain |
| The site answers with a good pass | Yes, until the pass's `exp` (at most 7 days) |
| The site answers `premium: false` | No; the cached pass is deleted |
| The site answers `premium: true` with a pass that does not check | No ("Not confirmed") |
| The site cannot be reached, cached pass still good | Yes |
| The site cannot be reached, cached pass ran out | No, and the app says it could not renew |
| 401 | Signed out: session, pass and email are deleted |

The app asks the site at launch, when it comes forward, when the menu opens (at most every 5 minutes), when the pass
runs out, and at least once a day; every 15 minutes while it cannot reach it.

**Keychain.** The legacy login keychain, service `com.oldcai.passwordpie.account` (`.dev` for a debug build pointed at
a mock site), accounts `session`, `pass` and `email`. It works in the sandbox without a profile (see above). None of them
is ever logged. Nothing is read from it before `PremiumStore.start()`.

**The browser.** `appAccountHasPremium()` (the seam the browser bridge shares with the extension) is the signed-in
account's Premium, the same check.

### Signing in

`ASWebAuthenticationSession` (`AccountServices.swift`) opens passwordpie.com, sharing Safari's cookies, so a remembered
Apple Account or Google sign-in is one click. Sign in with Apple is the first button (guideline 4.8: the app offers
Google, so it must offer Sign in with Apple).

    GET  https://passwordpie.com/app/sign-in?state=<random>&provider=apple|google&callback=passwordpie://auth
         (no provider: every way to sign in, Apple first)
    →    302 passwordpie://auth?code=<one-time, 60 s>&state=<as sent>      (or &error=<code>)
    POST /api/auth/app/exchange {"code"} → {"token": "<Better Auth bearer session token>"}   400 {"error":"invalid-code"}

The app refuses a callback whose `state` it did not send. A callback may carry `token=` instead of `code=`; the code is
preferred, so the session token never sits in a URL. The email comes from Better Auth's `GET /api/auth/get-session`,
and Sign Out calls `POST /api/auth/sign-out`; every call is `Authorization: Bearer`, never cookies.

### App Store purchases

`StoreKitPremiumBackend` is the only code that imports StoreKit, and the whole file is outside `PP_DIRECT`.

- **Buy.** Apple's sheet; the verified transaction unlocks the codes.
- **Restore Purchases** runs `AppStore.sync()` and reads the entitlements again. No account is involved.
- **A purchase from elsewhere** (Ask to Buy, another Mac) arrives through `Transaction.updates`.

The prices shown are `Product.displayPrice`. The UI links only to the terms, the privacy policy and Apple's own
subscription page, and the App Store build says nothing about buying elsewhere (`PremiumGateTests`). Only
`PremiumDirectViews.swift`, wholly `#if PP_DIRECT`, sends people to passwordpie.com to buy or redeem a key.

**Direct channel.** No StoreKit. The Premium window offers Get Premium (passwordpie.com/pricing), Redeem a Key
(passwordpie.com/redeem) and Check Again.

**Codes in the browser.** `browserCodeAllowed` in `PremiumChannel.swift` decides. App Store channel: the app has Premium.
Direct channel: the account signed in inside the app has Premium (`appAccountHasPremium()`), or the `code` request carries
a good passwordpie.com token from the extension ([ACCOUNTS.md](ACCOUNTS.md)). `directChannelCodesAreFree` does not count
there.

**The gate.** `OneTimeCodes.access(for:hasPremium:)` is the only code in the app target that may call `TOTP.code`.
`PremiumGateTests` fails if a call appears anywhere else. `Search.swift` and the menu never read a code. The gate changes
nothing on disk: the `otp` field stays in the KeePass file, and saving keeps it.

**Signing.** In-App Purchase is an App ID capability and needs no entitlement. The store build has dropped
`network.client`, because nothing in the app opens a connection and StoreKit runs in Apple's own process. This has not been
tested against the real store: do it at step 8 of the checklist. If the products do not load without it, put that one key
back in `Entitlements/mas.entitlements`; it changes nothing on the App Privacy label. The direct build's sign-in sheet
catches its own custom scheme, so the shared Info.plist registers no URL type.

### App Store privacy label

Answer **Data Not Collected** in App Store Connect. Data processed only on the device is not collected, the app has no
network code, and Apple handles the purchase itself. Keep it true: any new request from the store build, or from the Safari
extension inside it, needs this answer checked first.

### Testing without the site

**Direct channel.** `Scripts/mock-account-site.mjs` serves the account on `http://localhost:8788`, signing passes with the
public test key (`extension/dev/test-key.json`, `kid: pp-test`), which only debug and `make install` builds trust:

    MOCK_AUTO_APPLE=1 node Scripts/mock-account-site.mjs           # Apple sign-in completes at once
    PASSWORDPIE_SITE_URL=http://localhost:8788 .build/debug/PasswordPie …
    curl localhost:8788/mock/redeem-latest                          # PPIE-TEST-TEST-TEST for the last account

`PASSWORDPIE_SITE_URL` is read by debug builds only.

**App Store channel.** `PASSWORDPIE_PREMIUM_PREVIEW` (debug only) fakes StoreKit, and `PASSWORDPIE_PREMIUM_SCRIPT` (debug
only) runs `buy-lifetime,buy-yearly,restore,refresh` for screenshots. `node Scripts/mint-activation-link.mjs` prints an
activation link signed with the test key, for a debug build.

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
