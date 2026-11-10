# Browser extension (v1)

The PasswordPie extension fills the account chosen in the PasswordPie panel into the page in Chrome or Safari. The panel
does all the choosing and matching; the extension only reports the active tab, finds the sign-in form and fills it.
What the user sees is in "Fill in the browser" in [UX.md](UX.md).

Filling the username and password is free. Filling the two-step code (TOTP) is Premium: the extension signed in to a
PasswordPie account with Premium, or Premium in the app. The extension also hands that Premium to the direct app, which has
no sign-in of its own: see [ACCOUNTS.md](ACCOUNTS.md). Not yet: an icon or menu inside page fields, saving new passwords,
Firefox.

## Pieces

| Piece | Where | Channel |
|---|---|---|
| Extension (WXT + TypeScript, laid out like [mkext](https://mkext.dev): a React + Tailwind + TanStack Query popup, Better Auth bearer sign-in; the content script has no framework) | `extension/` | Chrome build and Safari build from one source |
| Safari Web Extension app extension | `PasswordPie.app/Contents/PlugIns/PasswordPieSafari.appex`, target `PasswordPieSafari` | both |
| Chrome native messaging host | `PasswordPie.app/Contents/MacOS/PasswordPieBrowserHost`, target `PasswordPieBrowserHost` | direct only |
| Host manifest `com.oldcai.passwordpie.json` | written by the app to `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` | direct only |
| Bridge server (socket, peer check, pending fill) | main app, `BrowserBridge*.swift` | both |
| Transport (framing, socket path, peer check) | target `PasswordPieBridge` | shared by the app, the host and the appex |
| Site matching (eTLD+1), messages, pending fill rules | `PasswordPieCore` (`PublicSuffix.swift`, `BrowserFill.swift`) | both, tested with `swift test` |

## Transport: a Unix socket in the App Group container

All three processes are signed by team `2S468LUF8V` and share the App Group `2S468LUF8V.com.oldcai.passwordpie`. The main app
listens on a Unix domain socket at `~/Library/Group Containers/2S468LUF8V.com.oldcai.passwordpie/bridge.sock`
(`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`). The Safari appex and the Chrome host connect to it.

Why not XPC: the main app is a normal login-item app, not a launchd job, so it cannot vend a Mach service name that
`NSXPCConnection(machServiceName:)` could reach without adding a separate launchd helper. CFMessagePort works across the
sandbox with an app-group name, but it does not say who sent a message. A socket in the group container works in both
channels (sandboxed processes may use Unix sockets inside their group container) and the kernel tells each side who the
other one is:

- `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` gives the peer's audit token.
- `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` finds that exact process. Its signature's team
  (`kSecCodeInfoTeamIdentifier`, which also holds for builds the App Store re-signs) and identifier must be the expected
  ones. Then `SecCodeCheckValidity` requires `anchor apple generic and cdhash H"<the code directory hash read with them>"`
  of the running code, so a binary swapped on disk between the two reads fails.

| Side | Accepts only |
|---|---|
| App (server) | `com.oldcai.passwordpie.safari` (Safari appex) or `com.oldcai.passwordpie.browser-host` (Chrome host). The identifier, not anything in a message, says which browser is talking. |
| Chrome host (client) | `com.oldcai.passwordpie` (the app) |
| Safari appex (client) | not checked: inside Safari's sandbox, securityd cannot read the app's bundle and the check fails with `EPERM`. It relies on the app checking it, and on the socket being in the team's group container (owner-only), which another sandboxed app cannot reach. **Known gap:** a non-sandboxed process of the same user can take the socket over. It then learns the origin (scheme, host, port) of each tab the Safari extension reports, which is never a path or query, and it can answer with a fill of its own choosing. It never gets a credential from PasswordPie. Closing this needs a server proof the sandbox can check, such as a shared keychain item, which needs provisioning profiles (post-merge list). |

An ad-hoc signed build fails the check, so it never fills: test with `make install`, which signs with the development
certificate. The team is read from the signing information (`kSecCodeInfoTeamIdentifier`), which also holds for builds the
App Store re-signs.

Framing is the same as Chrome native messaging: a 32-bit little-endian length, then that many bytes of UTF-8 JSON. Frames
over 1 MiB close the connection. The Chrome host is a relay: it copies frames from stdin to the socket and from the socket
to stdout, and checks sizes. The Safari appex opens one connection per message, sends the frame, reads one frame back and
closes.

## Pull model

A Safari Web Extension can only message the native side when the extension asks; the reverse direction is a hint at best.
So credentials only ever travel as the answer to a request the extension made:

1. The user picks an account and presses Return. The app records one **pending fill**: entry id, target browser, target
   site (eTLD+1 of the entry website that matched), created at. It expires after 30 s. Whether the app opened a new
   tab makes no difference: any tab of that browser on that site may take it.
2. The app hides the panel (focus goes back to the browser) or opens the login URL in that browser
   (`NSWorkspace.open(_:withApplicationAt:)`, a new tab).
3. The app sends a **poke** (no data) so the extension asks now: over the host's open port for Chrome,
   `SFSafariApplication.dispatchMessage` for Safari. The extension also asks on its own when the active tab changes, a
   tab finishes loading, or the page regains focus, so a lost poke only costs a moment.
4. The extension sends a `tab` report: the active tab's URL. If a pending fill for that browser matches the URL's site,
   and the vault is unlocked, the answer carries the username and password, and the pending fill is deleted. Otherwise the
   answer is empty and the pending fill keeps waiting until it expires.

The same `tab` report keeps the app's "browser → current URL" cache fresh, for the "this site" list at the top of the panel.
No AppleScript is used, so there is no Automation prompt.

Premium follows the same rule: the app never asks the extension for it. The extension sends `premium` when something
changed on its side (sign-in, renewal, sign-out, 401), each time its connection comes up, and on a poke when its last try
found no app. Chrome's host keeps the port open while PasswordPie is not running, so the app starting later shows up as
the poke it sends when the host reaches it, and the pass follows at once. For Safari, "comes up" is the background starting; a pass renewed while the app was not running
reaches it at the next storage change or background start, and a pass already held lasts up to 7 days meanwhile.

## Messages

Every request has `type` and an `id` (an integer the extension picks). Every answer echoes `id`. Pushes have no `id`.

### `hello`

    → {"type":"hello","id":1,"version":1,"extension":"0.1.0"}
    ← {"type":"hello","id":1,"version":1,"locked":false}

Sent when the extension starts and when its port (re)connects. It makes the browser count as connected.

### `tab`

    → {"type":"tab","id":2,"url":"https://github.com/","reason":"activated"}
    ← {"type":"tab","id":2}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28}}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28,"otp":true}}

`reason` is one of `activated`, `updated`, `focus`, `poke`, `startup` (diagnostic only; it changes nothing). `url` is the
origin of the active tab's top frame in the focused window, written as `scheme://host[:port]/`: matching needs nothing
else, so a path, query or fragment (reset links, OAuth codes) never leaves the browser. An empty or non-http(s) `url`
clears the cached URL and never fills.
`expiresIn` is the whole seconds left of the pending fill's 30; the extension keeps its copy no longer than that.
`otp: true` says the account has a two-step code. It carries no code: the app now keeps a **pending code** for that
browser and the page's site for 30 seconds, and the extension watches that tab's frames of `origin` for a code field.

### `code`

    → {"type":"code","id":5,"url":"https://github.com/","entitlement":"<JWT from passwordpie.com, if signed in>"}
    ← {"type":"code","id":5,"otp":{"origin":"https://github.com","code":"492039","expiresIn":17}}
    ← {"type":"code","id":5,"premium":false}
    ← {"type":"code","id":5}

Sent when a frame of the fill's origin shows an empty code field, at most once per fill. `url` is that frame's origin,
written as in `tab`. The app answers a code only when the vault is unlocked, the pending code is for this browser and
the URL's site (same rules as a fill: eTLD+1, no downgrade), it is less than 30 s old, the account still has that website
and a code, and Premium holds: this Mac has it, or `entitlement` checks (ACCOUNTS.md, "Who decides").
`expiresIn` is the seconds left in the code's time step. The pending code is used up by the answer either way.
`premium: false` means everything matched but there is no Premium: no code was computed. An empty answer means nothing
was waiting. The token is not logged, kept or passed on by the app, the host or the appex.

    ← {"type":"tab","id":2,"wantIcon":true}

`wantIcon` (with or without a `fill`) asks for this tab's icon with an `icon` request. The app sets it only while
unlocked, when the tab's site (eTLD+1) has an account whose website host has no icon yet (none bundled, none cached), and
at most once per site every 10 minutes (`SiteIconLedger`). On any other site the answer has no `wantIcon`, so the
extension learns nothing new about the vault and sends nothing more.

### `premium`

    → {"type":"premium","id":6,"pass":"<JWT from passwordpie.com, aud passwordpie-app>"}
    ← {"type":"premium","id":6,"accepted":true}
    ← {"type":"premium","id":6,"accepted":false}
    → {"type":"premium","id":7,"drop":"signed-out" | "no-premium"}
    ← {"type":"premium","id":7}

The direct app has no sign-in, so the extension hands it the pass it got from passwordpie.com, and takes it back when it
signs out, gets a 401 (`signed-out`) or the site answers `premium: false` (`no-premium`). Exactly one of `pass` (not
empty) and `drop` is present, or the answer is `bad-request`. When it is sent is in ACCOUNTS.md, "Handing Premium to the
app".

- The app checks the pass with `EntitlementToken.verifyTrusted` and the pass audience, and keeps it in its keychain under
  the browser the peer check named (`pass.chrome`, `pass.safari`). `accepted: false`: it did not check, and nothing
  stored changed. Taking it back deletes only that browser's pass; another browser's pass or an activation still counts.
- Taken while the vault is locked too: Premium has nothing to do with the database.
- The answer never carries the pass. The app, the host and the appex never log it.
- Any process that reaches the bridge could send one, so it grants nothing but Premium, and only when passwordpie.com
  signed it.
- **The App Store app** answers `{"type":"error","id":6,"code":"bad-request"}` and keeps nothing; its Safari extension
  has no account and never sends it.
- **An app from before this message** answers the same error. The connection stays up and the extension treats it as
  "not taken"; codes still fill through the `code` request's token. The released v0.1.0 has no bridge at all.

### `icon`

    → {"type":"icon","id":5,"origin":"https://news.ycombinator.com","png":"iVBORw0KGgo…"}
    ← {"type":"icon","id":5}
    ← {"type":"error","id":5,"code":"bad-icon"}

Sent only after a `tab` answer with `wantIcon`, for that tab. `origin` is the reported tab's origin, exactly as the
`tab` report gave it. `png` is base64 of a PNG of at most 128 × 128 pixels and 64 KB. The extension tries, in order:
the page's declared `<link rel=icon>` / `apple-touch-icon` of at least 64 px (largest first; read by the content script
of the top frame, and only while it is still on that origin), the browser's own `tab.favIconUrl`, the smaller declared
icons, then `/favicon.ico`. SVG is skipped. It draws the first that decodes into a canvas no larger than 128 × 128 and
encodes it as PNG. It fetches from the background, with no cookies, only over https, as a `data:` URL, or over plain http
from the page's own origin when the page itself is http, and gives up on each after 5 seconds. If it cannot make an
icon within the limits, it sends nothing.

The app keeps it only if all of these hold, else answers `bad-icon` and keeps nothing:

- it asked this browser (from the peer's signature) for this exact origin less than 60 seconds ago; an ask is used by the
  first `icon` request for it, kept or not,
- the vault is unlocked,
- the bytes are base64 of a PNG (by its content, not a field) that decodes completely, at most 128 pixels a side and
  65,536 bytes.

The icon is then cached (see "Site icons" below) and the panel redraws.

### Site icons

The app makes no network request for icons. An entry's icon is looked up under its website host (one `www` removed),
then under that host's registrable domain, in this order:

1. **Bundled:** `Contents/Resources/SiteIcons/<host>.png` (64 px) and `<host>@2x.png` (128 px), for the top 100 sites of
   the Majestic Million. `make site-icons` (`Scripts/fetch_site_icons.py`) refetches them on a development Mac; sources
   are in `Assets/SiteIcons/SOURCES.md`.
2. **Cached:** icons from `icon` requests, in `~/Library/Caches/com.oldcai.passwordpie/favicons/` as
   `<sha256 of host>.png` (folder 0700, files 0600), so a directory listing is not a site list. An icon is stored under the
   tab's host, and under its registrable domain when that has no icon yet. macOS may purge the folder; the icon then comes
   back on the next visit.
3. **Letter tile.**

Icons are not written into the KDBX: that would change the user's database file under every other KeePass client. A later
option could save them as KeePass custom icons so they sync between devices; it is not built.

### `show`

    → {"type":"show","id":3}
    ← {"type":"show","id":3}

"Open PasswordPie" was clicked in the extension's popup, or its shortcut (`open-panel`, ⌥⇧P by default) was pressed.
With a popup, the toolbar button no longer sends `action.onClicked`; the popup's first and largest button, shown signed
in or not, does this instead. The app opens its panel over the browser as its shortcut does, locked or not; a request
while the panel is open brings it forward. Carries nothing and returns nothing. The popup closes itself.

When the app did not get the request, the Chrome host and the Safari extension handler, both inside `PasswordPie.app`,
look for it by bundle identifier (`AppLaunch`). Not running: they start that app and send the request again for up to
7 seconds. Running: they only retry for 2 seconds, and answer `app-not-responding` if it still says nothing. The
extension waits 12 seconds for this answer instead of 5; Safari's tries use 1-second timeouts to stay inside that. Only
`show` starts the app: a tab report never does. With no answer (Chrome cannot find the host because PasswordPie is not
installed) or `app-unavailable` (the app did not start), the extension opens `https://passwordpie.com/` in a new tab to
download it. After `app-not-responding` it does nothing: the app is installed.

### `poke` (app → extension)

    ← {"type":"poke"}

Ask now: send a `tab` report for the active tab.

### `error`

    ← {"type":"error","id":2,"code":"app-unavailable"}

Codes: `app-unavailable` (host could not reach the app), `app-not-responding` (`show` only: the app runs but did not answer), `bad-request` (also any message the app does not know, such as `premium` in the App Store app), `bad-icon` (`icon` only: not asked for, or not an acceptable PNG), `version`. The extension treats any error as "no fill", and an error to `premium` as "not taken".

## When a fill is allowed

All in `PasswordPieCore`, with tests:

- **Same site.** The registrable domain (eTLD+1 from the bundled Public Suffix List, ICANN and private sections) of the
  tab URL equals that of the entry website. `www.github.com`, `github.com` and `gist.github.com` are one site;
  `alice.github.io` and `bob.github.io` are not. Hosts with no public suffix (`localhost`, an IP address, `intranet`)
  match only themselves exactly, port included.
- **No downgrade.** An https entry does not fill an http page, except for `localhost` and `127.0.0.1`.
- **Fresh and once.** A pending fill is used by the first matching report and then deleted. After 30 s it is deleted
  unused. Locking the vault deletes it. A new pick replaces it.
- **Locked means nothing.** While the vault is locked, `tab` answers never carry a fill, and `hello` says `locked`.
- **Only the matching frame.** The answer names the exact `origin` of the URL that matched. The extension fills only frames
  whose origin equals it: the top frame and same-origin iframes. Cross-origin iframes get nothing (the background finds
  frames with `webNavigation.getAllFrames` and sends the fill to each matching `frameId`).
- **Two-step sign-in.** The background keeps the answer in memory, for that tab and origin only, until 30 s after the pick
  (`expiresIn`).
  A username-only page gets the username; when a password field appears (same page) or the next page of the same origin
  loads, it gets the password. Nothing is kept in extension storage.

### Inside the extension

Content script → background, never leaving the browser: `{"type":"ready"}` when a content script starts (a frame that
loads after the answer still gets the fill, if its origin matches), `{"type":"focus"}` from a top frame that regains focus
(report now), `{"type":"filled","password":true}` when a password filled late (drop the copy), and `{"type":"code-field"}`
when an empty code field showed up while the frame was watching. Background → content script:
`{"type":"fill","origin","username","password"}`, `{"type":"watch-code","origin","waitMs"}` (look for a code field until
then; carries nothing secret), `{"type":"code","origin","code"}` and `{"type":"code-hint","origin","upgradeUrl"?}` (no
Premium: a small note in the page's corner for 8 seconds, in a closed shadow root, taking no focus). All are sent only to
frames whose origin equals `origin`; the content script checks `location.origin` again and that it is the top frame or
same-origin with it. The background accepts a `code-field` only from a frame of the waiting origin.

Popup → background: `{"type":"open-panel"}` (send `show`), `{"type":"popup-status"}` (answers the site whose code was
skipped for lack of Premium in the last 10 minutes, kept in memory only) and `{"type":"app-premium"}` (send `premium` now
and answer `delivered`, `unreachable`, `refused` or `none`). Accepted only from extension pages, which have no tab.

### Two-step codes

`findCodeField` (`extension/src/lib/code-fields.ts`) looks, in this order, for a field with `autocomplete="one-time-code"`;
4 to 8 one-character boxes in a row (filled one digit each); one field whose name, id, placeholder, `aria-label` or label
says code, OTP, 2FA, MFA, verification or similar, but not zip, postal, promo, coupon, country, phone, card or captcha; or,
only when no username or password field is on the page, a lone numeric field of 6 to 8 characters. It never takes the
sign-in fields, hidden, disabled or read-only fields, or a field the user already typed in. It only runs after a fill of
an account with a code, on that origin, for 30 seconds.

## Secrets

- Two-step codes and entitlement tokens are never logged; codes are never written to `storage`. The token is kept in
  `browser.storage.local`, which the site issued it for, and handed to the direct app, which keeps it in its keychain. It
  unlocks nothing but Premium.
- Credentials exist only in memory: in the app, in the answer frame, in the relay's buffer, in the extension's service
  worker and content script, and then in the page's fields. They are never logged, never written to `storage`, and never
  written to disk by the app. The host and appex log only sizes and error codes.
- Tab URLs are used for matching, the "this site" list and `wantIcon` only: held in memory, never logged, never saved.
  A cached icon is the only trace of a visit on disk, and only for a site the vault already has an account on.
- The fill never submits the form.

## Chrome

- The host manifest's `allowed_origins` lists one extension ID, `BridgeConstants.chromeExtensionID`: the Chrome Web Store
  item's, `ebgkjnfglbkeckkknmeakpkbdpjndjhk`. `CHROME_KEY` in `extension/manifest.ts` is that item's public key, so an
  unpacked build (`pnpm build:chrome`) has the same ID and connects to any direct build, released or `make install`.
  `extension/tests/extension-id.test.ts` fails if the key and the Swift constant disagree. The store package
  (`pnpm zip:chrome-store`) leaves the key out, because the store rejects a manifest with one.
- That key is public, as every store item's is, so anyone can load an unpacked extension with this ID. It takes Developer
  mode and "Load unpacked" in the user's own Chrome profile: someone who can do that can already install any extension
  there. The host still requires Google Chrome as its parent, and the app still fills only the site the user picked.
- The host starts only for Chrome. Chrome passes the caller's origin as the first argument, but whoever starts the host
  can fake that, so the host also requires its parent process to be Google Chrome, checked by code signature (team
  `EQHXZ8M8AV`, `com.google.Chrome`). Chrome Beta, Dev and Canary, like other Chromium browsers, are not in v1: they keep
  typed keystrokes.
- The extension keeps one `chrome.runtime.connectNative` port open. That keeps its service worker alive and the host
  running, and it is how pokes arrive. "Connected" means the app has an authenticated host connection right now.
- The host exits when its connection to the app ends (the app quit or was updated); the extension's port then reconnects
  and Chrome starts a fresh host. It must not reconnect itself: an update replaces the host's executable too, and a host
  still running the old code fails the app's signature check ("the code on disk does not match what is running") on
  every connection, so the extension would stay disconnected and the panel would keep offering "Add Chrome Extension…".
  While the app is not running, a new host keeps trying to connect every second.
- The app writes the host manifest at launch (direct channel only), pointing at the host inside the running app bundle.
- **App Store channel: no Chrome in v1.** A sandboxed app cannot write into Chrome's `NativeMessagingHosts` folder, and a
  host launched by Chrome from inside a store app would have to be sandboxed without a way to receive Chrome's arguments
  reliably. The host target, the manifest writer and the "Add Chrome Extension…" row are `#if PP_DIRECT` / not assembled
  in `make mas-dev`.

## Releasing the Chrome extension

The listing text, privacy answers, promo tile and screenshots are in `extension/store/` (`LISTING.md`). The publisher
is the Image AI, LLC account in the Chrome Web Store developer dashboard.

1. Raise `version` in `extension/manifest.ts`; the store needs a higher version for every upload.
2. `cd extension && pnpm test && pnpm zip:chrome-store`. Upload
   `.output/passwordpie-extension-<version>-chrome-store.zip` under Package, and submit for review.
3. Leave "publish automatically after review" off when the update needs a newer app, such as a new message the released
   app does not answer. Publish by hand once that app is out. Updates the released app already serves can publish
   automatically.

The first listing went out this way: the extension was submitted with publishing deferred, because direct builds made
before `chromeExtensionID` was the store ID do not trust it. Publishing waits for a direct release that does.

## Safari

- `PasswordPieSafari.appex` is a sandboxed `com.apple.Safari.web-extension` app extension with the App Group entitlement.
  Its `Contents/Resources` holds the Safari build of the extension. Its `SafariWebExtensionHandler` relays each
  `browser.runtime.sendNativeMessage` to the socket and returns the answer.
- "Connected" means `SFSafariExtensionManager.getStateOfSafariExtension` says enabled. "Enable Safari Extension…" calls
  `SFSafariApplication.showPreferencesForExtension(withIdentifier:)`.
- Pokes use `SFSafariApplication.dispatchMessage(withName:toExtensionWithIdentifier:userInfo:)`; the extension listens on
  a `browser.runtime.connectNative` port. When the service worker is asleep the poke is lost, and the focus and tab events
  cover it.
- Works in both channels. The store build needs provisioning profiles for the appex and the App Group (post-merge list).

## Current URL from the window

Each time the panel opens over Chrome or Safari, it also reads the URL from the browser's window with the Accessibility API
(already granted for Fill): the `AXURL` of the focused window's `AXWebArea`, or for Chrome the value of the toolbar's
address field. The walk is bounded (0.25 s messaging timeout, 300 nodes, 0.3 s deadline) and runs off the main thread. It
needs Accessibility to be granted already and never asks for it.

- Without a connected extension it is the only source, for the "this site" list. Fill then types keystrokes as before.
- With the extension, it checks the extension's last report. Safari asks for access per site, and a tab the extension may
  not see sends no report, so the last one goes stale. When the window shows another site than the report, the window wins
  (`resolvedPageURL`), so Return opens a new tab instead of waiting on a tab that will never answer.

## Channel differences

| | Direct | App Store |
|---|---|---|
| Safari extension | yes | yes (needs profiles for the appex and App Group) |
| Chrome extension (Chrome Web Store), native host | yes | not in v1 |
| "Add Chrome Extension…" row | yes | not compiled |
| "Enable Safari Extension…" row | yes | yes |
| AX fallback for the current URL | yes, if Accessibility is granted | same code; untested in the sandbox (see CHANNELS.md) |

## Testing

- `swift test`: public suffix rules, same-site and downgrade rules, pending fill expiry and single use, message coding,
  framing, the "this site" list, site icon lookup order, when `wantIcon` is set, and which `icon` requests are refused.
- `cd extension && pnpm test`: choosing and scaling the tab's icon; field finding and filling against HTML fixtures
  (autocomplete hints, forms with no attributes, React controlled inputs, open shadow DOM, two-step sign-in, cross-origin
  refusal), code fields (one field, split boxes, decoys), the code flow in the background, the account and redeem calls,
  and the popup.
- `swift test --filter 'Entitlement|BridgeCode|BrowserCodeAccess'`: the token check (good, wrong key, changed claims or
  header, expired, wrong `aud` or `iss`, not Premium) and the `code` request rules.
- `swift test --filter 'DirectPremium|BridgePremium|BridgePassRelay'`: the `premium` request, what the direct app keeps,
  and that the App Store app ignores it (`PP_MAS=1 swift test --scratch-path .build-mas` runs that side).
- `cd extension && pnpm test tests/pass-relay.test.ts`: when the extension sends `premium`, taking it back, and the App
  Store build sending nothing.
- On a Mac: `make install`, load `extension/.output/chrome-mv3` unpacked in Chrome, enable the extension in Safari. See the
  demo script in UX.md.
