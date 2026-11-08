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
| Two-step codes (Premium) | need a PasswordPie account with Premium (Get Premium and keys on passwordpie.com) | need a PasswordPie account with Premium; sold here with StoreKit 2 and put onto the account |
| Two-step codes in the browser (Premium) | the app's own account has Premium, or the extension's passwordpie.com token checks ([ACCOUNTS.md](ACCOUNTS.md)) | the same |
| Extension popup | account, Upgrade (pricing page) and "Have a key?" | Safari build with `WXT_PP_STORE=mas` (`make mas-dev`): account only, no Upgrade, no key field |
| Browser extension | Safari and Chrome (the Chrome Web Store extension; an unpacked build has the same ID) | Safari only; Chrome's native host is **not compiled in**. See [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md) |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

Check no debug preview or mock site can reach a release store build, and that the direct binary does not link StoreKit:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e PASSWORDPIE_PREMIUM_PREVIEW -e PASSWORDPIE_SITE_URL   # expect 0
    otool -L "$(swift build -c release --show-bin-path)/PasswordPie" | grep -c StoreKit                     # expect 0

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
5. **In-app purchase and the account.** Built: see "Premium" below. What is left is in App Store Connect and on
   passwordpie.com, under "Before Premium can be sold".
6. **Site-ranking data licence.** See `Scripts/gen_domain_ranks.py` and the note in the delivery report.

## Premium

Two-step codes need Premium, on both channels. Everything else is free. The behavior is in "Premium: two-step codes"
in [UX.md](UX.md).

**Premium is the PasswordPie account's** (user decision, 2026-11-08). An account gets it from a Stripe purchase on
passwordpie.com, a redeemed key, or an App Store purchase put onto the account. The app, the direct download and the
browser extension all read the same account.

> **This replaces the decision of 2026-11-05** that the direct download's codes were free for everyone. The direct app
> now needs a signed-in account with Premium too. To go back, set `directChannelCodesAreFree = true` in
> `PremiumChannel.swift`: codes in the app are free again, and the browser extension still needs the account
> (`appAccountHasPremium()` ignores the switch).

| Product ID | Type | Price |
|---|---|---|
| `com.oldcai.passwordpie.premium.lifetime` | Non-consumable | US$29, set in App Store Connect |
| `com.oldcai.passwordpie.premium.yearly` | Auto-renewable subscription, 1 year | US$10, set in App Store Connect |

### Who has Premium

`PremiumStore.hasPremium` is true only while the keychain holds a **pass** (the `token` from
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

### App Store purchases go onto the account

`StoreKitPremiumBackend` is the only code that imports StoreKit, and the whole file is outside `PP_DIRECT`. It hands
over each verified transaction with its JWS (`VerificationResult.jwsRepresentation`).

    POST /api/premium/apple/bind {"signedTransaction": "<JWS>", "restore": false|true}
    ← 200 entitlement + {"rebound": bool, "previousAccountEmailMasked": string|null}
    ← 409 {"error": "bound-elsewhere", "previousAccountEmailMasked": "j•••@gmail.com"}   (restore: false only)
    ← 409 {"error": "rebind-limited", "nextAllowedAt": ISO 8601}
    ← 400 {"error": "invalid-transaction"}

- **Buy.** Signed out, the window asks for sign-in first, then the purchase carries on. The JWS goes to `bind` with
  `restore: false`. If the site cannot be reached, the purchase stays on this Mac and goes on at the next refresh.
- **A purchase that arrives while signed out** (Ask to Buy, another Mac) stays in StoreKit and is sent with
  `restore: false` after sign-in. Automatic sends never use `restore: true`.
- **Restore Purchases** runs `AppStore.sync()`, then sends each active purchase with `restore: false`. One that answers
  `bound-elsewhere` is moved only after the confirmation ("a purchase can move once a year, the other account loses
  Premium"), with `restore: true`. A move answers `rebound: true`, and the app names the other account, which lost it.
  `rebind-limited` shows `nextAllowedAt`. Any other 409 is treated as `bound-elsewhere`, so nothing moves without asking.

The prices shown are `Product.displayPrice`. The UI links only to the terms, the privacy policy and Apple's own
subscription page, and the App Store build says nothing about buying elsewhere (`PremiumGateTests`). Only
`PremiumDirectViews.swift`, wholly `#if PP_DIRECT`, sends people to passwordpie.com to buy or redeem a key.

**Direct channel.** No StoreKit. The Premium window offers Get Premium (passwordpie.com/pricing), Redeem a Key
(passwordpie.com/redeem) and Check Again.

**Codes in the browser.** `browserCodeAllowed` in `PremiumChannel.swift` decides, the same in both channels: the account
signed in inside the app has Premium (`appAccountHasPremium()`), or the `code` request carries a good passwordpie.com
token from the extension ([ACCOUNTS.md](ACCOUNTS.md)). `directChannelCodesAreFree` does not count there.

**The gate.** `OneTimeCodes.access(for:hasPremium:)` is the only code in the app target that may call `TOTP.code`.
`PremiumGateTests` fails if a call appears anywhere else. `Search.swift` and the menu never read a code. The gate changes
nothing on disk: the `otp` field stays in the KeePass file, and saving keeps it.

**Signing.** No entitlement is added for In-App Purchase or the sign-in sheet. In-App Purchase is an App ID capability,
and StoreKit and `ASWebAuthenticationSession` need only the sandbox's existing `network.client`. The custom scheme is
caught by the session itself, so Info.plist registers no URL type.

### App Store review risk

Apple dislikes requiring an account to buy (guideline 5.1.1(v)). The case for it here: Premium is an account feature
used across platforms (the browser extension in Chrome, other Macs), which 5.1.1(v) allows, and 3.1.3(b) lets an app
unlock what was bought on the web as long as the same is sold in the app, which it is. It can still be rejected. What
lowers the risk:

- Sign in with Apple, first and one click.
- A purchase is never lost: one made or approved while signed out stays on the Mac and goes onto the account at sign-in.
- No mention of buying elsewhere in the App Store build.
- Review notes should say why the account exists and give a demo account (see the checklist).

If review rejects it anyway, the fallback is to let a StoreKit purchase unlock codes on this Mac while signed out and
add it to the account at sign-in; that is a change to `PremiumStore.hasPremium` only.

### Testing the account without the site

`Scripts/mock-account-site.mjs` serves all of the above on `http://localhost:8788`, signing passes with the public test
key (`extension/dev/test-key.json`, `kid: pp-test`), which only debug and `make install` builds trust:

    MOCK_AUTO_APPLE=1 node Scripts/mock-account-site.mjs           # Apple sign-in completes at once
    PASSWORDPIE_SITE_URL=http://localhost:8788 .build/debug/PasswordPie …
    curl localhost:8788/mock/redeem-latest                          # PPIE-TEST-TEST-TEST for the last account
    curl -X POST localhost:8788/mock/bind  -d '{"originalTransactionId":"preview-lifetime","email":"jane@gmail.com"}'
    curl -X POST localhost:8788/mock/moved -d '{"originalTransactionId":"preview-lifetime"}'

`PASSWORDPIE_SITE_URL` is read by debug builds only. On the App Store channel, `PASSWORDPIE_PREMIUM_PREVIEW` (debug only)
fakes StoreKit with JWS-shaped transactions the mock accepts and the real site refuses, and `PASSWORDPIE_PREMIUM_SCRIPT`
(debug only) runs `sign-in-apple,buy-lifetime,restore,confirm-move,sign-out,refresh` for screenshots.

**Local StoreKit testing.** `Configuration/PasswordPie.storekit` holds both products. It works only through Xcode's Run
action: open `Package.swift` in Xcode, run with `PP_MAS=1` in the scheme's environment, and pick the file under Scheme >
Run > Options > StoreKit Configuration. Launching the built `.app` directly talks to the real store. The JWS from the
local StoreKit environment is signed by Xcode's local certificate, so the real site refuses it; the mock accepts it.

### Before Premium can be sold

These are in App Store Connect, the Apple Developer site and passwordpie.com's settings, and cannot be done from this repo.

1. Check that In-App Purchase is on for the App ID `com.oldcai.passwordpie`.
2. Sign the Paid Apps agreement, and fill in the bank and tax details. Until they are active, products do not load.
3. Create the non-consumable `com.oldcai.passwordpie.premium.lifetime`. Base price US$29 in the United States storefront.
4. Create a subscription group, such as "PasswordPie Premium". Add the auto-renewable subscription
   `com.oldcai.passwordpie.premium.yearly` with a 1 year duration and a base price of US$10.
5. For both, add a display name, a description and a review screenshot of the Premium window.
6. Leave Billing Grace Period off. Codes lock at `expirationDate`, so a grace period would charge people for days they
   cannot use. Turning it on needs a code change first.
7. **App Store Server API key:** Users and Access > Integrations > In-App Purchase: generate a key, and give
   passwordpie.com the Issuer ID, the Key ID and the `.p8` (Cloudflare secrets).
8. **App Store Server Notifications V2:** in the app's App Information, set the production and sandbox URLs to
   `https://passwordpie.com/api/apple/notifications`.
9. **Sign in with Apple:** turn on the capability for the App ID; create a Services ID (such as
   `com.oldcai.passwordpie.web`) with `passwordpie.com` as a domain and Better Auth's Apple callback as the return URL;
   create a Sign in with Apple key, and give passwordpie.com the Services ID, Team ID, Key ID and `.p8`.
10. `EntitlementToken.publicKey` holds passwordpie.com's production public key (`kid: pp-1`, from passwordpie.com#8).
    Before a release, check the site signs with its private half (a token from `/api/premium/entitlement` verifies).
11. Create a sandbox tester under Users and Access > Sandbox, and sign in with it under System Settings > App Store on the test Mac.
12. Upload a build, then attach both products to the app version for review. A product's first review has to go with a version.
13. Review notes: Premium is a PasswordPie account feature used in the browser extension and on other Macs; Sign in with
    Apple is offered first; give a demo PasswordPie account.
14. Put the terms link in the app description or the EULA field, as guideline 3.1.2 asks. The privacy policy URL goes in the App Privacy section.
