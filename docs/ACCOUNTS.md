# Accounts and Premium in the browser

How a PasswordPie account unlocks Premium in the browser extension, and how the app checks it before a two-step code
leaves the Mac. Product decisions of 2026-11-08, including the later one that Premium always belongs to the account. What the user sees is in
"Premium in the browser" in [UX.md](UX.md); the messages are in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

## What is free and what is Premium

| Free | Premium |
|---|---|
| Fill the username and password from the panel, on this site or a new tab | Fill the two-step code (TOTP) into the page, including on the next step after the password |
| The accounts for this site at the top of the panel | Later Premium features in the browser, such as saving new passwords |
| The toolbar button and its popup | |

One PasswordPie account holds one Premium entitlement, and passwordpie.com is the only judge of it. It comes from
Stripe on passwordpie.com (US$29 once, or US$10 a year, the App Store prices), from a redeemed key, or from an App Store
purchase that the App Store app binds to the signed-in account (`POST /api/premium/apple/bind`; one account per
purchase at a time, rebinding at most once a year). The extension, the direct app and the App Store app all read the
same account. Signing in inside the app, its token and the StoreKit binding are in "Accounts" in
[CHANNELS.md](CHANNELS.md); this document is the browser side.

## Who decides

The extension's source is public, so anything it decides can be patched out. The **app** decides whether a code may go
to the browser, and the extension only carries proof:

A code goes to the browser, in both channels, when either holds (`browserCodeAllowed` in `PremiumChannel.swift`):

1. The account signed in inside the app has Premium (`appAccountHasPremium()`).
2. The `code` request carries an entitlement token whose Ed25519 signature checks against a public key built into the
   app, with the right `iss`, `aud` and an `exp` in the future (`EntitlementToken`).

Nothing else counts: not StoreKit on its own, and not the direct channel's free-codes switch
(`directChannelCodesAreFree`).

## Signing in (extension)

passwordpie.com runs Better Auth with the `bearer` plugin. The extension never uses cookies (`credentials: "omit"`):

- **Email and password:** `authClient.signIn.email` → the session token comes back in the `set-auth-token` header and
  is kept in `browser.storage.local` (`local:session-token`). Every call sends `Authorization: Bearer <token>`.
- **Google (Chrome only):** mkext's flow. `chrome.identity.getAuthToken({interactive: true})` gives a Google *access*
  token (that API never returns an ID token); `POST /api/auth/extension/google` with `{"accessToken": "…"}` returns
  `{"token": "<session token>"}`. The site checks the access token with Google's tokeninfo/userinfo endpoint and that its
  `aud` is the extension's OAuth client. The
  button only shows when the build has a Google OAuth client ID (`WXT_GOOGLE_CLIENT_ID`). Safari has no
  `identity.getAuthToken`, so Safari signs in with email only.
- **Sign out:** `authClient.signOut()`, then the session token and the entitlement token are removed, even offline.
- A 401 from any call drops the stored tokens: the session is gone.

## Entitlement API (passwordpie.com)

All calls carry `Authorization: Bearer <session token>`.

    GET  https://passwordpie.com/api/premium/entitlement
    ← {"premium": true, "plan": "lifetime" | "yearly" | "key" | null, "expiresAt": "2027-11-08T00:00:00Z" | null, "token": "<JWT>" | null}

    POST https://passwordpie.com/api/premium/redeem   {"code": "PPIE-XXXX-XXXX-XXXX"}
    ← 200 with the same body as above
    ← 4xx {"error": "invalid" | "used" | "expired" | "rate-limited"}

The extension asks for the entitlement each time the popup opens and once a day (`alarms`), and keeps the answer in
`browser.storage.local` (`local:entitlement`). A network failure keeps the last answer; a 401 clears it.

## The entitlement token

A compact JWS (JWT), signed with Ed25519 (`alg: EdDSA`, RFC 8037):

    header  {"alg":"EdDSA","typ":"JWT","kid":"pp-1"}
    claims  {"iss":"https://passwordpie.com","aud":"passwordpie-app","sub":"<user id>","premium":true,
             "plan":"lifetime","iat":1762560000,"exp":1763164800}

- Issued only while the account has Premium. `exp` is the earlier of now + 7 days and the end of the entitlement, so a
  refund or a lapsed year stops working within a week at most even if the extension never asks again.
- The private key is a Cloudflare secret of passwordpie.com only. The public key (32 bytes) is
  `EntitlementToken.publicKey` in `PasswordPieCore`, shared with the app's own account sign-in.

The app accepts a token only when all of these hold (`EntitlementToken.verify`, tested in `EntitlementTests`):

1. Three base64url parts, at most 4 KiB in all. The header says `alg: EdDSA`.
2. The Ed25519 signature over `<header>.<claims>` (the ASCII bytes as sent) checks against a trusted key.
3. `iss` is `https://passwordpie.com`; `aud` is `passwordpie-app` or an array that holds it.
4. `exp` is in the future; `iat`, if present, is not more than 5 minutes in the future; `nbf`, if present, has passed.
5. `premium` is `true`.

### Keys

| `kid` | Trusted by | Private key |
|---|---|---|
| `pp-1` | every build (`EntitlementToken.publicKey`, `h2YWSwg8b--b6tXhehQ6Ccav0CdLqFR0HLeWj9F6dM0`) | passwordpie.com's Cloudflare secret |
| `pp-test` | debug builds and `make install` (`PP_DEV_EXTENSION`) only (`EntitlementToken.testPublicKey`) | `extension/dev/test-key.json`, public on purpose, for the mock site and tests |

A test key that release builds trusted would let anyone mint Premium, so `pp-test` is compiled only into debug builds
and `make install` (which already trusts the public unpacked Chrome extension), never into `make dist-direct` or
`make mas-dev`. `EntitlementToken.verifyTrusted` tries each trusted key; the `kid` is
informational.

## Codes over the bridge

The full messages are in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md), "`code`". In short:

1. The pick works as before. When the `tab` answer fills an account that has a two-step code, it says so
   (`"otp": true`) and the app keeps a **pending code** for that browser and the page's site, for 30 seconds. No code
   is computed yet.
2. The extension watches that tab's frames of that origin for a code field, on this page and on the next one.
3. When one appears, the extension sends `code` with the tab's origin and its entitlement token (or none).
4. The app checks, in order: unlocked, a pending code for that browser and site, not expired, Premium ("Who
   decides"). Then it computes the current code and answers it with the seconds left in its 30-second step, and drops the
   pending code. Without Premium it answers `"premium": false` and the extension shows a quiet upgrade hint.

Codes and tokens are never logged and never written to disk, in the app, the host, the appex or the extension. The
token is kept in extension storage because the site issued it for that purpose; it unlocks nothing but this check.

## Keys to redeem

Admins on passwordpie.com make keys in batches, each for "lifetime" or "N days", and export them as CSV. A key works
once, has an expiry date, and redeeming is rate limited. Format: `PPIE-` and 12 characters from
`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, O, 1, I), shown in groups of four. The popup accepts lowercase and missing
dashes, and sends the normalized form. Keys are redeemed on passwordpie.com/redeem (signed in) or in the popup.

## App Store rules

The Safari extension ships inside the App Store app too. A Safari build made for the App Store (`make mas-dev`,
`WXT_PP_STORE=mas`) signs in to the account and shows its plan, but has no upgrade link and no key field (guideline
3.1.1: no buying or unlocking outside In-App Purchase), and the page hint says the code needs Premium without saying
where to get it. Buying there is the app's In-App Purchase, bound to the account.

## Testing without the site

`extension/dev/mock-site.mjs` serves the API above on `http://localhost:8787`, signs tokens with the test key, accepts
any email with the password `password`, redeems `PPIE-TEST-TEST-TEST` once (`PPIE-USED-USED-USED` answers `used`), and
serves a two-step sign-in page at `/demo/login` (username and password, then a six-box code page). Build the extension
against it with `WXT_PP_SITE_URL=http://localhost:8787 pnpm build:chrome`.
