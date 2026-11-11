# Premium in the browser

How a two-step code gets from the app to a page, and who decides whether it may. The browser extension has **no
account**: it signs in nowhere, asks passwordpie.com nothing and stores nothing. It is a bridge between the browser and
the app. Whether this Mac has Premium is the app's business alone ([CHANNELS.md](CHANNELS.md)). What the user sees is in
"Premium in the browser" in [UX.md](UX.md); the messages are in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

Until 2026-11-11 the extension had an account of its own (it was signed in on passwordpie.com, kept a session and a
week-long pass, and handed the pass to the direct app). That is gone: it put a sign-in between a click on the toolbar
button and the user's passwords, and it made the extension a second place that knew about Premium. No released app and
no extension in the Chrome Web Store ever had it (the store has 0.1.0, from before).

## What is free and what is Premium

| Free | Premium |
|---|---|
| Fill the username and password from the panel, on this site or a new tab | Fill the two-step code (TOTP) into the page, including on the next step after the password |
| The accounts for this site at the top of the panel | Later Premium features in the browser, such as saving new passwords |
| The toolbar button, its right-click menu, and scanning a two-step QR code | |

Premium is bought where the app came from: through Apple in the App Store app, on passwordpie.com for the downloaded
app, which then takes it as an activation (`passwordpie://activate`). Both are in [CHANNELS.md](CHANNELS.md).

## Who decides

The extension's source is public, so anything it decided could be patched out. It decides nothing. The **app** decides
whether a code may go to the browser, and it reads nothing from the request to do so (`browserCodeAllowed` in
`PremiumChannel.swift`):

- A code goes to the browser when this Mac has Premium of its own (`appHasPremium()`): a purchase or an activation in the
  App Store channel, an activation in the direct channel.
- Nothing else counts: not the direct channel's free-codes switch (`directChannelCodesAreFree`), and nothing an extension
  sends. A `code` request has no field for a proof of Premium, and the app knows no message that hands one over
  (`BridgeUpgradeTests`, `BridgePremiumTests`, `BrowserCodeAccessTests`).

## Codes over the bridge

The full messages are in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md), "`code`". In short:

1. The pick works as before. When the `tab` answer fills an account that has a two-step code, it says so
   (`"otp": true`) and the app keeps a **pending code** for that browser and the page's site, for 30 seconds. No code
   is computed yet.
2. The extension watches that tab's frames of that origin for a code field, on this page and on the next one.
3. When one appears, the extension sends `code` with the tab's origin, and nothing else.
4. The app checks, in order: unlocked, a pending code for that browser and site, not expired, Premium ("Who
   decides"). Then it computes the current code and answers it with the seconds left in its 30-second step, and drops the
   pending code. Without Premium it answers `"premium": false`.

Codes are never logged and never written to disk, in the app, the host, the appex or the extension.

## Without Premium: the note and Upgrade

On `"premium": false` the extension shows a quiet note in the corner of the frame that has the code field, for 8
seconds: "PasswordPie Premium fills two-step codes for you." and an **Upgrade** button. The button is not a link. A click
sends the app `upgrade`, and the app opens its Premium window, the one a locked code's row opens: the plans through Apple
in the App Store channel, Get Premium on passwordpie.com in the direct channel. So the extension links to no shop, knows
nothing about prices or channels, and is the same build in both.

The background sends `upgrade` only for a click that comes from the frame the note was sent to, within 10 seconds of
sending it, and once per note (`FillController.upgrade`). A page cannot reach the button (a closed shadow root) or send
the message (content scripts take runtime messages from the extension only). The worst a forged one could do is open the
Premium window.

## The activation token

What passwordpie.com signs for an account with Premium, and the only proof either app accepts. A compact JWS (JWT),
signed with Ed25519 (`alg: EdDSA`, RFC 8037):

    header  {"alg":"EdDSA","typ":"JWT","kid":"pp-1"}
    claims  {"iss":"https://passwordpie.com","aud":"passwordpie-activation","sub":"<user id>","premium":true,
             "plan":"lifetime","iat":1762560000,"exp":1794096000}

- Issued only while the account has Premium, when the person presses Activate. `exp` is the earlier of a year from now
  and the end of the entitlement.
- The private key is a Cloudflare secret of passwordpie.com only. The public key (32 bytes) is
  `EntitlementToken.publicKey` in `PasswordPieCore`.

The app accepts a token only when all of these hold (`EntitlementToken.verifyActivation`, tested in `EntitlementTests`):

1. Three base64url parts, at most 4 KiB in all. The header says `alg: EdDSA`.
2. The Ed25519 signature over `<header>.<claims>` (the ASCII bytes as sent) checks against a trusted key.
3. `iss` is `https://passwordpie.com`; `aud` is `passwordpie-activation` or an array that holds it. A token with
   `aud: passwordpie-app`, the week-long pass the extension used to carry, is not an activation and unlocks nothing.
4. `exp` is in the future; `iat`, if present, is not more than 5 minutes in the future; `nbf`, if present, has passed.
5. `premium` is `true`.

### Keys

| `kid` | Trusted by | Private key |
|---|---|---|
| `pp-1` | every build (`EntitlementToken.publicKey`, `h2YWSwg8b--b6tXhehQ6Ccav0CdLqFR0HLeWj9F6dM0`) | passwordpie.com's Cloudflare secret |
| `pp-test` | debug builds and `make install` (`PP_DEV_EXTENSION`) only (`EntitlementToken.testPublicKey`) | `extension/dev/test-key.json`, public on purpose, for `Scripts/mint-activation-link.mjs` and tests |

A test key that release builds trusted would let anyone mint Premium, so `pp-test` is compiled only into debug builds
and `make install` (which already trusts the public unpacked Chrome extension), never into `make dist-direct` or
`make mas-dev`. `EntitlementToken.verifyActivation` tries each trusted key; the `kid` is informational.

## Keys to redeem

Admins on passwordpie.com make keys in batches, each for "lifetime" or "N days", and export them as CSV. A key works
once, has an expiry date, and redeeming is rate limited. Format: `PPIE-` and 12 characters from
`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, O, 1, I), shown in groups of four. Keys are redeemed on passwordpie.com/redeem,
signed in there. The page then offers Activate.

## App Store rules

The Safari extension ships inside the App Store app, so what it does counts as the app's on the App Privacy label, and it
may not point anywhere else to buy (guideline 3.1.1). It does neither: it has no account, makes no request to any site,
and its Upgrade opens the app's own Premium window, which sells through In-App Purchase. There is no separate App Store
build of the extension any more: `make mas-dev` embeds the same Safari build as `make install`
(`extension/tests/store-build.test.ts` checks the bundle).

## Testing without the site

- `node Scripts/mint-activation-link.mjs [days] [plan] [audience]` prints a `passwordpie://activate` link signed with the
  test key. Open it to give a debug or `make install` build Premium.
- `node extension/dev/mock-site.mjs` serves a two-step sign-in page at `http://localhost:8787/demo/login` (username and
  password, then a six-box code page), for the code fill and the note. It has no account and no API.
