# PasswordPie browser extension

Fills the account picked in the PasswordPie panel into the page, in Chrome and Safari, and the two-step code too when
the app has Premium. It is a bridge between the browser and the PasswordPie app on the same Mac, and nothing more: it has
no account, signs in nowhere, asks passwordpie.com nothing and stores nothing. A click on its toolbar button opens
PasswordPie; its right-click menus scan a two-step QR code. The design (messages, security rules) is in
[docs/BROWSER_EXTENSION.md](../docs/BROWSER_EXTENSION.md), who decides about Premium in
[docs/ACCOUNTS.md](../docs/ACCOUNTS.md); what the user sees is "Fill in the browser", "Premium in the browser" and "Scan
a two-step QR code" in [docs/UX.md](../docs/UX.md).

[WXT](https://wxt.dev) and plain TypeScript: a background service worker and a content script, with no extension pages
and no UI framework. The content script runs on every page, so it stays small. One source, two builds, and the Safari
build is the same in the direct download and in the App Store app.

## Build

    pnpm install
    pnpm test            # vitest + jsdom: field finding, filling, background logic
    pnpm typecheck
    pnpm build:chrome    # → .output/chrome-mv3
    pnpm build:safari    # → .output/safari-mv3
    pnpm zip:chrome-store  # → .output/passwordpie-extension-<version>-chrome-store.zip, for the Chrome Web Store

There are no build settings: the extension knows one address, the download page the toolbar button opens when the app is
not installed.

## Demo pages

    node dev/mock-site.mjs    # http://localhost:8787/login (or /demo/login): a sign-in, then a page with six code boxes
                              # http://localhost:8787/change-password: current, new and confirm boxes, for Reset Password

For Premium in the app, open an activation link (`node ../Scripts/mint-activation-link.mjs`), signed with the test key in
`dev/test-key.json`, which only debug and `make install` builds of the app trust. The demo script is in docs/UX.md,
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

- `src/app/background.ts`: wires browser events, the toolbar button, the panel shortcut and the right-click menus to
  `FillController` and `Toolbar`.
- `src/app/content.ts`: wires fill and code messages and focus events to `PageFiller` and `CodeFiller`, and shows the
  note for a scan that found nothing.
- `src/lib/controller.ts`: tab reports, the in-memory fill (30 s, per tab and origin), frame targeting, the code flow
  (watch for a code field, ask the app, fill or hint), and Upgrade in the hint (asks the app for its Premium window).
- `src/lib/toolbar.ts`: the right-click menus: scan and the website on the button, scan on the page, and what a scan
  that handed nothing over says.
- `src/lib/qr-page.ts`, `src/lib/qr-scan.ts`, `src/lib/scan-outcome.ts`: reading a two-step QR code from the page.
- `src/lib/page-note.ts`: the small note in the corner of a page.
- `src/lib/code-fields.ts`, `src/lib/code-filler.ts`: finding and filling two-step code fields, and the note about Premium.
- `src/lib/native-channel.ts`: `ChromeNativeChannel` (one port, ids, timeout, reconnect) and `SafariNativeChannel`.
- `src/lib/fields.ts`, `src/lib/page-filler.ts`: finding and filling sign-in fields, waiting for two-step sign-in.
