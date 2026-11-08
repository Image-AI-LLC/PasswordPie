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

## Chrome

Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose `.output/chrome-mv3`. The
`key` in `wxt.config.ts` pins the unpacked ID to `pbbiimlkojflhpopeplkbfeecanbbdoj`, which the native host manifest
written by PasswordPie allows. PasswordPie must be running (direct-download build) for the extension to connect.

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
