# Accounts and Premium in the browser

How a PasswordPie account unlocks Premium in the browser extension, how the extension hands it to the app, and how the
app checks it before a two-step code leaves the Mac. This is the direct channel and the Chrome Web Store extension. Neither
app has an account (2026-11-10, [CHANNELS.md](CHANNELS.md)): people sign in only in the extension and on passwordpie.com.
The App Store app and its Safari extension have no account at all. What the user sees is in
"Premium in the browser" in [UX.md](UX.md); the messages are in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

## What is free and what is Premium

| Free | Premium |
|---|---|
| Fill the username and password from the panel, on this site or a new tab | Fill the two-step code (TOTP) into the page, including on the next step after the password |
| The accounts for this site at the top of the panel | Later Premium features in the browser, such as saving new passwords |
| The toolbar button and its popup | |

One PasswordPie account holds one Premium entitlement, and passwordpie.com is the only judge of it. It comes from
Stripe on passwordpie.com (US$29 once, or US$10 a year, the App Store prices) or from a redeemed key. The extension reads
the account and hands its pass to the direct app ("Handing Premium to the app" below); the app's rules are "Who has
Premium: the direct channel" in [CHANNELS.md](CHANNELS.md).

## Who decides

The extension's source is public, so anything it decides can be patched out. The **app** decides whether a code may go
to the browser, and the extension only carries proof:

A code goes to the browser, in the direct channel, when either holds (`browserCodeAllowed` in `PremiumChannel.swift`):

1. This Mac has Premium (`appHasPremium()`): a pass an extension handed over, or an activation, that still checks.
2. The `code` request carries an entitlement token whose Ed25519 signature checks against a public key built into the
   app, with the right `iss`, `aud` and an `exp` in the future (`EntitlementToken`). An app from before the `premium`
   request, or an extension from before it, still fills codes this way.

Nothing else counts, and not the direct channel's free-codes switch (`directChannelCodesAreFree`). In the App Store
channel a code goes to Safari when the app has Premium, and the extension carries no proof.

## Signing in (extension)

The extension has no sign-in form. People sign in on passwordpie.com, which has email, Google and whatever comes later,
and finishes a new account's email verification; the site then hands the extension a session of its own. The popup's
**Sign in on passwordpie.com** only opens `${SITE_URL}/extension/connect`. passwordpie.com runs Better Auth with the
`bearer` plugin, and the extension never sends cookies (`credentials: "omit"`): every call carries
`Authorization: Bearer <token>`, kept in `browser.storage.local` (`local:session-token`).

The connect page, `/extension/connect` (with a language prefix too, such as `/zh/extension/connect`):

- Signed out: it goes to `/sign-in?callbackUrl=/extension/connect`. Email, Google and sign-up with email verification
  all come back to it.
- Signed in: it talks to the extension's content script with `window.postMessage`. Every message is a plain object and
  every `targetOrigin` is `window.location.origin`:

      page → ext  { source: 'passwordpie-site', type: 'hello' }                  after mount, again every 250 ms until ready or 3 s
      ext → page  { source: 'passwordpie-extension', type: 'ready' }             once when the content script starts there, then once per hello
      page → ext  { source: 'passwordpie-site', type: 'session', token }         once, after the first ready; token from POST /api/auth/extension/session
      ext → page  { source: 'passwordpie-extension', type: 'connected', email }  or  { source: 'passwordpie-extension', type: 'failed' }

- `POST /api/auth/extension/session` takes only a same-origin request with the site's cookie session (401 otherwise),
  creates a **new** Better Auth session for that user and returns `{"token": "…"}`, usable as `Authorization: Bearer`
  (`GET /api/auth/get-session` and `GET /api/premium/entitlement` answer 200 with it). `Cache-Control: no-store`, rate
  limited. The page asks for it only after a `ready`, so nothing is issued in a browser without the extension. It is not
  the cookie session, so signing out of the extension leaves the website signed in, and the other way round.
- The page shows: connecting; connected ("PasswordPie in this browser is signed in as {email}. You can close this
  tab."); no `ready` within 3 s (not installed, or too old: a link to the Chrome Web Store item and Try again); failed.

The extension's side (`extension/src/lib/site-connect.ts`, `site-session.ts`):

- The content script listens only in the top frame, only when `location.origin` is the build's site (`SITE_URL`), and
  acts only while the path, after an optional language prefix, is `/extension/connect`. The path is read for each
  message rather than once, because the site's sign-in may come back to the connect page by in-page navigation after
  the script started on `/sign-in`. It takes only messages with `event.source === window` and
  `event.origin === SITE_URL`, and hands one `session` at a time to the background.
- The background takes the token only from its own content script in the top frame of that page (`sender.id`,
  `frameId`, `url`). It asks `GET /api/auth/get-session` with it first: an unknown token, or no answer, keeps nothing and
  answers `failed`. A good one is kept with its user, replacing any other account (whose entitlement is dropped and whose pass
  the app gives back before the new account is kept, and whose session is ended on the site without waiting), and the entitlement is refreshed, which hands Premium to the app
  through `PassRelay`. Then it answers `connected` with the email, even if only the entitlement could not be read.
- **Sign out:** `POST /api/auth/sign-out` with the bearer token (given up after 5 s), then the session token, user and
  entitlement are removed, even offline. Only this browser's session ends; the website stays signed in.
- A 401 from any call drops the stored tokens: the session is gone. A 403, a 200 that is not JSON (a challenge or
  captive-portal page) or no answer within 10 s is not a sign-out: the popup keeps the last user it saw.
- Safari: the content script runs on passwordpie.com only once the user lets the extension access that site.

There is no `identity` permission and no `oauth2` key: Google sign-in is the site's.

## Handing Premium to the app

The app has no sign-in, so the extension gives it the pass the site issued (`PassRelay`, `extension/src/lib/pass-relay.ts`).
Every sign-in, sign-out, renewal and 401 lands in `browser.storage.local`; the background watches those keys and tells the
app each time, and also when its connection to the app comes up and, if its last try found no app, on the app's next
poke (the app may have started later; Chrome's host keeps the port open meanwhile). The message is
`premium` in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

| In the extension | Sent to the app |
|---|---|
| Signed in, the site says Premium with a token | `{"type":"premium","pass":"<token>"}` |
| Signed out, or a 401 | `{"type":"premium","drop":"signed-out"}`, if the app took a pass from here |
| The site says `premium: false` | `{"type":"premium","drop":"no-premium"}`, if the app took a pass from here |
| Signed in, no answer from the site yet; or never had Premium | nothing |

`local:app-has-pass` remembers that the app took a pass from this browser, so taking it back reaches the app even if it
was not running at the sign-out: the next connection or poke sends it. An app that answers without knowing the message
never held a pass from here, so that also clears it. Requests run one at a time, so a sign-out never overtakes
the pass before it. The App Store build of the Safari extension has no account and no relay, and sends nothing.

The popup asks the background whether the app took the pass. With Premium and the app holding it, the popup says nothing
more. If the app did not answer, or answered without knowing the message (an older app), the popup says so in one
line. If the app understood and did not take the pass (it did not check, for example it ran out), the popup shows no line.
It never claims the Mac app has Premium.

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
  `EntitlementToken.publicKey` in `PasswordPieCore`. The same key signs activations (`aud: passwordpie-activation`).

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

Codes and tokens are never logged and never written to disk, in the app, the host, the appex or the extension, except
that the extension keeps the token in its storage and the direct app keeps a handed-over pass in its keychain, both
because the site issued it for that purpose. It unlocks nothing but Premium.

## Keys to redeem

Admins on passwordpie.com make keys in batches, each for "lifetime" or "N days", and export them as CSV. A key works
once, has an expiry date, and redeeming is rate limited. Format: `PPIE-` and 12 characters from
`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, O, 1, I), shown in groups of four. The popup accepts lowercase and missing
dashes, and sends the normalized form. Keys are redeemed on passwordpie.com/redeem (signed in) or in the popup.

## App Store rules

The Safari extension ships inside the App Store app, so what it does counts as the app's on the App Privacy label. A
Safari build made for the App Store (`make mas-dev`, `WXT_PP_STORE=mas`) has no account, makes no request to the site, and
has no upgrade link or key field (guideline 3.1.1). The page hint says the code needs Premium without saying where to get
it. Buying there is the app's In-App Purchase.

## Testing without the site

`extension/dev/mock-site.mjs` serves the API above on `http://localhost:8787`, signs tokens with the test key, signs in
any email with the password `password` on its own `/sign-in` page, serves `/extension/connect` and
`POST /api/auth/extension/session` as described in "Signing in (extension)", redeems `PPIE-TEST-TEST-TEST` once (`PPIE-USED-USED-USED` answers `used`), and
serves a two-step sign-in page at `/demo/login` (username and password, then a six-box code page). Build the extension
against it with `WXT_PP_SITE_URL=http://localhost:8787 pnpm build:chrome`.
