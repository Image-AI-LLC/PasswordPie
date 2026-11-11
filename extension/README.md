# PasswordPie browser extension

Fills the account picked in the PasswordPie panel into the page, in Chrome and Safari, and with Premium the two-step code
too. It also carries your passwordpie.com account: you sign in on the site (the popup only opens its connect page), and
since the PasswordPie app has no sign-in, the extension hands it the account's Premium. The design (messages, security rules) is in [docs/BROWSER_EXTENSION.md](../docs/BROWSER_EXTENSION.md), the account
and Premium in [docs/ACCOUNTS.md](../docs/ACCOUNTS.md); what the user sees is "Fill in the browser" and "Premium in the
browser" in [docs/UX.md](../docs/UX.md).

Laid out like [mkext](https://mkext.dev) (Apache-2.0): [WXT](https://wxt.dev), a React 19 + Tailwind + TanStack Query
popup, and a Better Auth bearer session that passwordpie.com hands over after you sign in there (plain `fetch`, no auth
client). The content script stays plain TypeScript with no
framework, because it runs on every page. One source, two builds.

## Build

    pnpm install
    pnpm test            # vitest + jsdom: field finding, filling, background logic
    pnpm typecheck
    pnpm build:chrome    # → .output/chrome-mv3
    pnpm build:safari    # → .output/safari-mv3
    pnpm zip:chrome-store  # → .output/passwordpie-extension-<version>-chrome-store.zip, for the Chrome Web Store

Build settings (environment variables at build time):

| Variable | Default | |
|---|---|---|
| `WXT_PP_SITE_URL` | `https://passwordpie.com` | The site for sign-in and Premium. `http://localhost:8787` for the mock. |
| `WXT_PP_STORE` | unset | `mas`: the Safari build inside the App Store app, with no account, no request to the site, no upgrade link, no key field and no `storage` permission (`make mas-dev`). |

## Testing against the mock site

    node dev/mock-site.mjs                                   # http://localhost:8787, see the comment at its top
    WXT_PP_SITE_URL=http://localhost:8787 pnpm build:chrome

Click **Sign in on localhost:8787** in the popup: the mock's sign-in page takes any email with the password `password`,
then its `/extension/connect` page hands the extension a session. `PPIE-TEST-TEST-TEST` redeems once. Tokens are signed with the test key
in `dev/test-key.json`, which only debug and `make install` builds of the app trust. The demo script is in docs/UX.md,
"Premium in the browser".

## Chrome

Users install it from the Chrome Web Store
([ebgkjnfglbkeckkknmeakpkbdpjndjhk](https://chromewebstore.google.com/detail/ebgkjnfglbkeckkknmeakpkbdpjndjhk)). To run
your own build, open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose
`.output/chrome-mv3`. `CHROME_KEY` in `manifest.ts` is the store item's public key, so the unpacked build has the store
ID, which the native host manifest written by PasswordPie allows. Remove the store copy first: Chrome keeps one
extension per ID. PasswordPie must be running (direct-download build) for the extension to connect.

The store package leaves `key` out, which the store requires, and it is the only difference from `pnpm build:chrome`.
It builds into `.output/chrome-mv3-store`, so it never replaces the unpacked `.output/chrome-mv3`.
Releasing, and the listing text, screenshots and privacy answers, are in
[docs/BROWSER_EXTENSION.md](../docs/BROWSER_EXTENSION.md) ("Releasing the Chrome extension") and
[store/LISTING.md](store/LISTING.md).

## Safari

The Safari build is embedded into the app's `PasswordPieSafari.appex` by `make install`; turn it on in Safari's
Extensions settings (or from the panel's "Enable Safari Extension…" line).

## Icon

`icon.svg` is the brand mark (`art/source/mark.svg`) in orange `#EE8C32`, cropped to the pie so it fills the canvas, on a
transparent background with a see-through keyhole. Regenerate the PNGs after changing it:

    for s in 16 32 48 128; do rsvg-convert -w $s -h $s icon.svg -o public/icon/$s.png; done

## Layout

- `src/app/background.ts`: wires browser events, the popup's messages, the panel shortcut, the daily entitlement
  refresh and the storage changes that drive `PassRelay` to `FillController`, and takes the session the connect page
  hands over (`acceptSiteSession`).
- `src/app/content.ts`: wires fill and code messages and focus events to `PageFiller` and `CodeFiller`, and on the
  site's connect page starts `startSiteConnect`. No React.
- `src/lib/toolbar.ts`: what a click on the toolbar button does (the popup, or PasswordPie directly once the account
  has Premium), and the right-click menus: scan, the website and the account on the button, scan on the page.
- `src/app/popup/`: the toolbar popup page; `src/components/popup.tsx` is the UI, driven through `PopupApi`.
- `src/lib/controller.ts`: tab reports, the in-memory fill (30 s, per tab and origin), frame targeting, and the code flow
  (watch for a code field, ask the app with the entitlement token, fill or hint).
- `src/lib/pass-relay.ts`: hands the account's pass to the app (`premium`) on sign-in, renewal and connect, and takes it
  back on sign-out, 401 or `premium: false`. Not in the App Store build.
- `src/lib/account.ts`, `src/lib/auth.ts`, `src/lib/config.ts`: the passwordpie.com session, entitlement and keys.
- `src/lib/site-connect.ts`, `src/lib/site-session.ts`: signing in on passwordpie.com. The content script's half of the
  connect page's `postMessage` protocol, and the background's check of the token before it keeps it. Not in the App
  Store build (`tests/store-build.test.ts`).
- `src/lib/code-fields.ts`, `src/lib/code-filler.ts`: finding and filling two-step code fields, and the page note.
- `src/lib/native-channel.ts`: `ChromeNativeChannel` (one port, ids, timeout, reconnect) and `SafariNativeChannel`.
- `src/lib/fields.ts`, `src/lib/page-filler.ts`: finding and filling sign-in fields, waiting for two-step sign-in.
