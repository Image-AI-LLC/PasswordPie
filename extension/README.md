# PasswordPie browser extension

Fills the account picked in the PasswordPie panel into the page, in Chrome and Safari. The design (messages, security
rules) is in [docs/BROWSER_EXTENSION.md](../docs/BROWSER_EXTENSION.md); what the user sees is "Fill in the browser" in
[docs/UX.md](../docs/UX.md).

Built with [WXT](https://wxt.dev) and TypeScript, no UI framework. One source, two builds.

## Build

    pnpm install
    pnpm test            # vitest + jsdom: field finding, filling, background logic
    pnpm typecheck
    pnpm build:chrome    # → .output/chrome-mv3
    pnpm build:safari    # → .output/safari-mv3
    pnpm zip:chrome-store  # → .output/passwordpie-extension-<version>-chrome-store.zip, for the Chrome Web Store

## Chrome

Users install it from the Chrome Web Store
([ebgkjnfglbkeckkknmeakpkbdpjndjhk](https://chromewebstore.google.com/detail/ebgkjnfglbkeckkknmeakpkbdpjndjhk)). To run
your own build, open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose
`.output/chrome-mv3`. `CHROME_KEY` in `manifest.ts` is the store item's public key, so the unpacked build has the store
ID, which the native host manifest written by PasswordPie allows. Remove the store copy first: Chrome keeps one extension per ID. PasswordPie must be running (direct-download
build) for the extension to connect.

The store package leaves `key` out, which the store requires, and it is the only difference from `pnpm build:chrome`.
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

- `src/entrypoints/background.ts`: wires browser events to `FillController`.
- `src/entrypoints/content.ts`: wires fill messages and focus events to `PageFiller`.
- `src/lib/controller.ts`: tab reports, the in-memory fill (30 s, per tab and origin), frame targeting.
- `src/lib/native-channel.ts`: `ChromeNativeChannel` (one port, ids, timeout, reconnect) and `SafariNativeChannel`.
- `src/lib/fields.ts`, `src/lib/page-filler.ts`: finding and filling sign-in fields, waiting for two-step sign-in.
