# Browser extension (v1)

The PasswordPie extension fills the account chosen in the PasswordPie panel into the page in Chrome or Safari. The panel
does all the choosing and matching; the extension only reports the active tab, finds the sign-in form and fills it.
What the user sees is in "Fill in the browser" in [UX.md](UX.md).

Filling the username and password is free. Filling the two-step code (TOTP) is Premium, and Premium is the app's alone:
the extension has no account, signs in nowhere, asks passwordpie.com nothing and stores nothing
([ACCOUNTS.md](ACCOUNTS.md)). Not yet: an icon or menu inside page fields, saving new passwords,
Firefox.

## Pieces

| Piece | Where | Channel |
|---|---|---|
| Extension (WXT + TypeScript: a background and a content script, no extension pages and no UI framework) | `extension/` | Chrome build and Safari build from one source, the same in both channels |
| Safari Web Extension app extension | `PasswordPie.app/Contents/PlugIns/PasswordPieSafari.appex`, target `PasswordPieSafari` | both |
| Chrome native messaging host | `PasswordPie.app/Contents/MacOS/PasswordPieBrowserHost`, target `PasswordPieBrowserHost` | direct only |
| Host manifests `com.passwordpie.json` and a legacy one (see "Host manifests") | written by the app to `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` | direct only |
| Bridge server (socket, peer check, pending fill, which Chrome profile is in front) | main app, `BrowserBridge*.swift` | both |
| Transport (framing, socket path, peer check) | target `PasswordPieBridge` | shared by the app, the host and the appex |
| Site matching (eTLD+1), messages, pending fill rules, the connection in front (`BridgeLinks`) | `PasswordPieCore` (`PublicSuffix.swift`, `BrowserFill.swift`) | both, tested with `swift test` |

## Host manifests

The extension connects with `connectNative('com.passwordpie')` from 0.5.0. Until 2026-11-13 everything was named
`com.oldcai.passwordpie`, and the store extension up to 0.4.0 still connects to that name. So at every launch the app
writes two manifests, `com.passwordpie.json` and `com.oldcai.passwordpie.json`, both naming the same
`PasswordPieBrowserHost` and the same `allowed_origins` (`BridgeConstants.chromeExtensionIDs`). The names are
`BridgeConstants.nativeHostNames`. Chrome starts the same host
for either name; the host does not care which one.

The legacy one is transitional: remove `legacyNativeHostName` (and its manifest) once the store's live version is 0.5.0
or later and has had time to update everyone. Remove it from the allow-list in `LegacyNamespaceGuardTests` too. A
manifest an earlier app left on disk stays; it is harmless once nothing connects to it.

## Transport: a Unix socket in the App Group container

All three processes are signed by team `2S468LUF8V` and share the App Group `2S468LUF8V.com.passwordpie`. The main app
listens on a Unix domain socket at `~/Library/Group Containers/2S468LUF8V.com.passwordpie/bridge.sock`
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
| App (server) | `com.passwordpie.safari` (Safari appex) or `com.passwordpie.browser-host` (Chrome host). The identifier, not anything in a message, says which browser is talking. |
| Chrome host (client) | `com.passwordpie` (the app) |
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
   site (eTLD+1 of the entry website that matched), created at, and for Chrome the connection of the profile in front
   (see "Chrome profiles"). It expires after 30 s. Whether the app opened a new tab makes no difference: any tab of that
   browser, in that profile, on that site may take it.
2. The app hides the panel (focus goes back to the browser) or opens the login URL in that browser
   (`NSWorkspace.open(_:withApplicationAt:)`, a new tab).
3. The app sends a **poke** (no data) so the extension asks now: over the open port of the profile in front for Chrome,
   `SFSafariApplication.dispatchMessage` for Safari. The extension also asks on its own when the active tab changes, a
   tab finishes loading, or the page regains focus, so a lost poke only costs a moment.
4. The extension sends a `tab` report: the active tab's URL. If a pending fill for that browser matches the URL's site,
   and the vault is unlocked, the answer carries the username and password, and the pending fill is deleted. Otherwise the
   answer is empty and the pending fill keeps waiting until it expires.

The same `tab` report keeps the app's "connection → current URL" cache fresh, for the "this site" list at the top of
the panel: the list is the tab of the connection in front, never another profile's. No AppleScript is used, so there is
no Automation prompt.

Premium is not part of any of this: the extension has none to report, and the app asks for none.

## Messages

Every request has `type` and an `id` (an integer the extension picks). Every answer echoes `id`. Pushes have no `id`.

### `hello`

    → {"type":"hello","id":1,"version":1,"extension":"0.5.0"}
    ← {"type":"hello","id":1,"version":1,"locked":false}

Sent when the extension starts and when its port (re)connects. It makes the browser count as connected.

### `tab`

    → {"type":"tab","id":2,"url":"https://github.com/","reason":"activated","focused":true}
    ← {"type":"tab","id":2}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28}}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28,"otp":true}}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28,"newPassword":"…"}}

`reason` is one of `activated`, `updated`, `focus`, `poke`, `startup` (diagnostic only; it changes nothing). `url` is the
origin of the active tab's top frame in the focused window, written as `scheme://host[:port]/`: matching needs nothing
else, so a path, query or fragment (reset links, OAuth codes) never leaves the browser. An empty or non-http(s) `url`
clears the cached URL and never fills.
`focused` (Chrome, from 0.4.0) says whether a window of the extension's profile has the focus as the report goes out
(`windows.getLastFocused`, every window type). Safari's build and older extensions leave it out. A report with
`focused: false` never gets a fill that is not for its own connection (see "Chrome profiles").
`expiresIn` is the whole seconds left of the pending fill's 30; the extension keeps its copy no longer than that.
`otp: true` says the account has a two-step code. It carries no code: the app now keeps a **pending code** for that
browser and the page's site for 30 seconds, and the extension watches that tab's frames of `origin` for a code field.
`newPassword` is there only after **Reset Password** in the direct app (docs/UX.md, "Reset Password makes the new
password for you"): the page is a change-password form. `password` is still the saved one, for the box that asks for the
current password; `newPassword` goes in the new and the confirm box. The key is left out of every other fill. The
extension never submits the form and never presses the site's button. See `changed` below.

### `code`

    → {"type":"code","id":5,"url":"https://github.com/"}
    ← {"type":"code","id":5,"otp":{"origin":"https://github.com","code":"492039","expiresIn":17}}
    ← {"type":"code","id":5,"premium":false}
    ← {"type":"code","id":5}

Sent when a frame of the fill's origin shows an empty code field, at most once per fill. `url` is that frame's origin,
written as in `tab`. The app answers a code only when the vault is unlocked, the pending code is for this browser and
the URL's site (same rules as a fill: eTLD+1, no downgrade), it is less than 30 s old, the account still has that website
and a code, and this Mac has Premium (ACCOUNTS.md, "Who decides"). The request carries nothing about Premium, and any
other field in it is ignored.
`expiresIn` is the seconds left in the code's time step. The pending code is used up by the answer either way.
`premium: false` means everything matched but there is no Premium: no code was computed, and the extension shows its
note with Upgrade. An empty answer means nothing was waiting.

    ← {"type":"tab","id":2,"wantIcon":true}

`wantIcon` (with or without a `fill`) asks for this tab's icon with an `icon` request. The app sets it only while
unlocked, when the tab's site (eTLD+1) has an account whose website host has no icon yet (none bundled, none cached), and
at most once per site every 10 minutes (`SiteIconLedger`). On any other site the answer has no `wantIcon`, so the
extension learns nothing new about the vault and sends nothing more.

### `changed`

    → {"type":"changed","id":6,"url":"https://github.com/"}
    ← {"type":"changed","id":6,"version":1}

The page that got a `fill` with `newPassword` took its form: the person pressed the site's own button. `url` is the
tab's origin, as in `tab`. The app then asks the person, in a small window over the browser, "Did github.com accept the
new password?" Nothing is saved before they answer: the extension cannot tell an accepted form from a refused one, and
neither can the app.

When the app hands out a fill with `newPassword`, it keeps one **pending change**: the account, the browser, the
connection that took the fill, and the site of the reset address. A `changed` request counts when it comes from that
browser and connection, from a page that site may fill (same site, no downgrade), within 600 seconds, while the vault is
unlocked and the account still has that site. It is used once; a newer one replaces it; locking deletes it. It holds
no password.

The extension reports for the newest page only: a tab that took an earlier reset fill stops sending `changed` once another
tab takes a new one, since the app waits for one change and would name the newer account.

The answer is always the same, matched or not, locked or not, with or without a `url`: it never says whether an account
was waiting. It is never an `error`.

Compatibility, both ways harmless:

- An extension from before this ignores `newPassword` and fills the username and the saved password as usual. It never
  sends `changed`, so the question does not come up, and the new password waits under previous passwords.
- An app from before this never sends `newPassword`, so the extension has nothing to report. If it did send `changed`,
  that app answers `{"type":"error","code":"bad-request"}`, which the extension ignores.
- The App Store app and Safari never get `newPassword`: Reset Password only opens the page there.

### `focus`

    → {"type":"focus","id":4,"focused":false}
    ← {"type":"focus","id":4}

Chrome only, from 0.4.0. The profile's windows gained or lost the focus (`windows.onFocusChanged`; `WINDOW_ID_NONE` is
lost). Sent at once, ahead of the debounced `tab` report that follows a focus gained, so the app stops taking this
profile's tab for the page in front as soon as the person leaves it. Carries nothing else, and the answer only
acknowledges it, locked or not. An app from before this message answers `bad-request`, which the extension ignores.
Without `focused` it is a `bad-request`.

### `upgrade`

    → {"type":"upgrade","id":6}
    ← {"type":"upgrade","id":6}

**Upgrade** was clicked in the note the extension shows after `premium: false`. The app opens its Premium window, the one
a locked code's row opens: the plans through Apple in the App Store channel, Get Premium on passwordpie.com in the direct
channel. Carries nothing. The answer only acknowledges it, the same locked or not and whatever this Mac has. The
extension sends it only for a click in the frame it sent the note to, within 10 seconds, once per note.

The extension has no message that hands the app a proof of Premium. An extension from before 2026-11-11 sends
`{"type":"premium","pass":…}`; the app answers `{"type":"error","code":"bad-request"}`, keeps nothing and unlocks nothing.

### `scan`

    → {"type":"scan","id":8,"otpauth":"otpauth://totp/Demo:ada?secret=…&issuer=Demo","url":"https://example.com/"}
    ← {"type":"scan","id":8}
    ← {"type":"error","id":8,"code":"bad-otp"}

The user chose Scan in a right-click menu, and the extension read a two-step QR code on the page (see "Scanning
a QR code" below). `otpauth` is the QR code's text, at most 4,096 bytes; `url` is the tab's origin, written as in `tab`
(a non-web page or none means no site). The app checks the link with `OTPAuthImport.parse` (TOTP only; secret, digits
6–8, period above 0, SHA1/SHA256/SHA512) and answers:

- `scan`: it took it. The same answer whether the vault is locked or not, whether any item matches, and whatever the person
  does next. The extension learns nothing about the database from it, and nothing more is sent back later except the
  `expectCode` below.
- `bad-otp`: the link did not check. Nothing is kept.
- `bad-request`: no `otpauth`, one too long, or an app from before this message.

The app then keeps that one scan in memory for 2 minutes (a newer one replaces it), opens the unlock screen if it is
locked, and shows the Add Two-Step Code window. It writes the database only when the person presses Add there. The
secret is never logged, and the scan never reaches disk except as the item's `otp` field after Add.

After Add, if the item has a website on the scanned page's site (same rules as a fill), the app keeps a **pending code** for
that browser and site, for 30 seconds, and pokes. The next `tab` report from that site gets:

    ← {"type":"tab","id":9,"expectCode":{"origin":"https://example.com","expiresIn":28}}

once. It carries no code. The extension watches that tab's frames of `origin` for a code field, exactly as after a fill
with `otp: true`, and the `code` request that follows is answered under the same rules (Premium included: without it the
answer is `premium: false` and the page gets the note).

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
2. **Cached:** icons from `icon` requests, in `~/Library/Caches/com.passwordpie/favicons/` as
   `<sha256 of host>.png` (folder 0700, files 0600), so a directory listing is not a site list. An icon is stored under the
   tab's host, and under its registrable domain when that has no icon yet. macOS may purge the folder; the icon then comes
   back on the next visit.
3. **Letter tile.**

Icons are not written into the KDBX: that would change the user's database file under every other KeePass client. A later
option could save them as KeePass custom icons so they sync between devices; it is not built.

### `show`

    → {"type":"show","id":3}
    ← {"type":"show","id":3}

The toolbar button was clicked, or its shortcut (`open-panel`, ⌥⇧P by default) was pressed. The button has no popup
(the manifest's `action` has no `default_popup`), so a click arrives as `action.onClicked`. The app opens its panel over
the browser as its own shortcut does, locked or not; a request while the panel is open brings it forward. Carries nothing
and returns nothing.

When the app did not get the request, the Chrome host and the Safari extension handler, both inside `PasswordPie.app`,
look for it by bundle identifier (`AppLaunch`). Not running: they start that app and send the request again for up to
7 seconds. Running: they only retry for 2 seconds, and answer `app-not-responding` if it still says nothing. The
extension waits 12 seconds for this answer instead of 5; Safari's tries use 1-second timeouts to stay inside that. Only
`show` starts the app: a tab report never does. With no answer (Chrome cannot find the host because PasswordPie is not
installed) or `app-unavailable` (the app did not start), the extension opens `https://passwordpie.com/` in a new tab to
download it. After `app-not-responding` it does nothing: the app is installed.

### `poke` (app → extension)

    ← {"type":"poke"}

Ask now: send a `tab` report for the active tab. In Chrome it goes to the connection of the profile in front, or to
every connection when that is not known (extensions that say nothing about focus).

### `error`

    ← {"type":"error","id":2,"code":"app-unavailable"}

Codes: `app-unavailable` (host could not reach the app), `app-not-responding` (`show` only: the app runs but did not answer), `bad-request` (also any message the app does not know, such as an older extension's `premium`), `bad-icon` (`icon` only: not asked for, or not an acceptable PNG), `bad-otp` (`scan` only: the QR code's link did not check), `version`. The extension treats any error as "no fill".

## When a fill is allowed

All in `PasswordPieCore`, with tests:

- **Same site.** The registrable domain (eTLD+1 from the bundled Public Suffix List, ICANN and private sections) of the
  tab URL equals that of the entry website. `www.github.com`, `github.com` and `gist.github.com` are one site;
  `alice.github.io` and `bob.github.io` are not. Hosts with no public suffix (`localhost`, an IP address, `intranet`)
  match only themselves exactly, port included.
- **No downgrade.** An https entry does not fill an http page, except for `localhost` and `127.0.0.1`.
- **Fresh and once.** A pending fill is used by the first matching report and then deleted. After 30 s it is deleted
  unused. Locking the vault deletes it. A new pick replaces it.
- **A new password only to the account's own site.** Reset Password hands the new password to the bridge only when the
  reset address is on a site of the account under the two rules above, and only for Chrome with an extension that
  speaks for the profile. Otherwise the page just opens. The new password is never typed by keystrokes, and a new
  password that has become the saved one since the pick is left out.
- **The profile in front.** A pick made over Chrome is for the connection of the profile in front, and no other
  connection may take it, whatever site its tab is on. A two-step code goes to the connection that took the fill, and
  the code of a scan to the connection that scanned.
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
(report now), `{"type":"filled","password":true}` when a password filled late (drop the copy), `{"type":"code-field"}`
when an empty code field showed up while the frame was watching, and `{"type":"upgrade"}` when Upgrade was clicked in the
note about Premium. Background → content script:
`{"type":"fill","origin","username","password"}`, `{"type":"watch-code","origin","waitMs"}` (look for a code field until
then; carries nothing secret), `{"type":"code","origin","code"}` and `{"type":"code-hint","origin"}` (no
Premium: a small note in the page's corner for 8 seconds, in a closed shadow root, taking no focus, with an Upgrade
button that is not a link). All are sent only to
frames whose origin equals `origin`; the content script checks `location.origin` again and that it is the top frame or
same-origin with it. The background accepts a `code-field` only from a frame of the waiting origin.

There is no extension page, so nothing else sends the background a message.

### Scanning a QR code

Only the person starts it: **Scan QR code on this page** in the toolbar button's right-click menu, or
**Scan QR code with PasswordPie** in the page's right-click menu (`contextMenus`: context `action` for the button;
contexts `page`, `frame` and `image` on http(s) pages). Nothing scans by itself, and a web page cannot ask for it
(content scripts take runtime messages from the extension only, and none listens to the page). Both run the same scan of
the active tab. `extension/src/lib/toolbar.ts` adds the lines again each time the background starts; a line the browser
refuses is left out and the others stay.

A scan that reached the app shows nothing in the browser: the app's Add Two-Step Code window is the answer. One that
handed nothing over sends the top frame `{"type":"scan-note","kind":"none"}` (the outcome's name, never the link), and
its content script shows that outcome's line in the corner for 8 seconds, as the Premium note. If no content script
answers (a browser page), the button gets the badge "!" and the line as its title for 6 seconds. In Chrome the button's
menu also has **Open passwordpie.com** (a new tab, nothing fetched); the Safari build leaves it out, because it also
ships inside the App Store app (ACCOUNTS.md, "App Store rules").

1. The background asks the active tab's top frame (`{"type":"qr-images"}`, frame 0). Its content script
   (`extension/src/lib/qr-page.ts`) takes up to 8 `<img>` (including `data:` URLs), `<canvas>` and `<svg>` elements that
   are at least 48 px, about square and at least half in the viewport, draws each into a canvas (at most 2,048 px a side)
   and answers PNG data URLs. A picture from another site that the page did not allow cannot be read this way and is
   skipped.
2. The background decodes them (`extension/src/lib/qr-scan.ts`): with the browser's `BarcodeDetector` when it has one, else
   the bundled jsQR (Apache-2.0, `extension/public/THIRD_PARTY_NOTICES.txt`). No remote code; the data URLs are never fetched.
3. If none of them is a two-step link, it takes one `tabs.captureVisibleTab` picture of the visible tab and decodes that.
   This needs no new permission: `<all_urls>` already covers it. If the browser refuses (Safari may; untested there), only
   step 1 counts.
4. The first `otpauth://totp` link goes to the app as `scan`. An `hotp` link, a Google Authenticator export or any other
   QR code is reported in the note and sends nothing. With no app answering, the background sends `show` once (which starts
   an installed app) and tries again.

The pictures and the link live only in the service worker's memory for that click: nothing is stored, logged, or sent
anywhere but the native app.

### Two-step codes

`findCodeField` (`extension/src/lib/code-fields.ts`) looks, in this order, for a field with `autocomplete="one-time-code"`;
4 to 8 one-character boxes in a row (filled one digit each); one field whose name, id, placeholder, `aria-label` or label
says code, OTP, 2FA, MFA, verification or similar, but not zip, postal, promo, coupon, country, phone, card or captcha; or,
only when no username or password field is on the page, a lone numeric field of 6 to 8 characters. It never takes the
sign-in fields, hidden, disabled or read-only fields, or a field the user already typed in. It only runs after a fill of
an account with a code, on that origin, for 30 seconds.

## Secrets

- Two-step codes and scanned QR codes are never logged and never stored. The extension has no `storage` permission and
  keeps nothing between runs of its service worker: no account, no session, no token.
- Credentials exist only in memory: in the app, in the answer frame, in the relay's buffer, in the extension's service
  worker and content script, and then in the page's fields. They are never logged, never stored by the extension, and never
  written to disk by the app. The host and appex log only sizes and error codes.
- Tab URLs are used for matching, the "this site" list and `wantIcon` only: held in memory, never logged, never saved.
  A cached icon is the only trace of a visit on disk, and only for a site the vault already has an account on.
- The fill never submits the form.

## Chrome profiles

Chrome keeps extensions per profile, and starts one native host per profile that has the extension. The host manifest
is in `NativeMessagingHosts` beside the profile folders, so every profile finds it. The app therefore has one
connection per profile with the extension, and none for a profile without it. The server numbers the connections as
they arrive (`BridgePeer.link`); nothing in a message says which one is talking.

**Which connection is in front** (`BridgeLinks.front`, pure, in `PasswordPieCore`):

1. The connection whose extension said `focused: true` last. A profile's extension is told `WINDOW_ID_NONE` when the
   focus goes to another app, and also when it goes to a window of another profile, which it cannot see. So when every
   connection says `focused: false` while Chrome is the app in front, the window in front belongs to a profile nobody
   speaks for: no connection is in front. The same holds for an Incognito window the extension is not allowed in.
2. Else, among connections that never said anything about focus (an extension from before 0.4.0, or one that connected
   a moment ago), the one with the latest sign of life: a tab report, or a `show` (the toolbar button was clicked in
   that profile). This is how every connection counted before, so such an extension behaves as it did.
3. Else none.

**The panel takes the keyboard.** Opening PasswordPie's panel makes its window key, and Chrome then tells the extension
`WINDOW_ID_NONE` although Chrome is still the app in front (measured on Chrome 157; the same event as for another
profile's window). So the app holds the answer from the moment the panel begins to open (`BridgeLinks.hold`) until it
closes (`release`): the connection in front when it opened stays in front, a `focused: false` meanwhile changes
nothing, and a `focused: true` that arrives just after (the click on Chrome and the shortcut in quick succession) still
counts. A connection that had said nothing when the panel opened keeps counting under rule 2 until the panel closes,
whatever it says meanwhile: when the toolbar button starts the app, the first thing the extension says is that its
window lost the focus, to the panel that click opened.

**PasswordPie's own window in front.** With Preferences in front, the app the panel goes back to
is still Chrome, but no profile has the focus. That is not a profile without the extension: the profile used last
stands for Chrome (`BridgeLinks.recent`: the one in front, else the last that had the focus, else any connection),
as any connection did before. The fill is then for no connection in particular, and is taken once Chrome is in front
again and its profile says so.

**The panel closed.** A pinned account's Open and Fill runs with no panel, and its window never takes the focus. That
fill is for the app in front at that moment, not the one the panel last opened over (`PanelController.fillTarget`),
and the same rules apply to it: Chrome in front with no connection in front types keystrokes.

With no connection in front, for a pick made over Chrome:

- the panel shows **Add Chrome Extension…**, and it opens the store page with `NSWorkspace.open(_:withApplicationAt:)`
  on the Chrome that was in front. Chrome opens a link from another app in the profile whose window was used last
  (measured), which is the profile in front;
- the page is only what Accessibility read from the window, or unknown;
- Fill types keystrokes. Nothing is sent to, or opened for, another profile's connection.

With a connection in front, its `tab` report is the page, the pending fill is for it alone, and only it is poked.
A new tab opened by the app lands in the same profile, for the reason above. From another app (Open and Fill into the
default browser) the profile is not known in advance: the fill is for no connection in particular, and the first
connection to report the site takes it unless it says `focused: false`.

What a connection says about its focus is taken on trust between the app's own extensions. The extension's ID has a
public key (see "Chrome"), so someone who loads their own extension under it in a profile can claim the focus and be
taken for the profile in front. That gives them nothing new: before, any connection that reported the site took the
fill. Once a pick is bound to a connection, nothing another connection says redirects it.

Compatibility: an extension before 0.4.0 with this app is rule 2, so nothing changes for it, with one profile or
several. This extension with an older app sends one extra field the app ignores and a `focus` the app refuses; its
`tab` reports go out exactly when they did.

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
- The extension keeps one `chrome.runtime.connectNative` port open, in each profile it is installed in. That keeps its
  service worker alive and the host running, and it is how pokes arrive. "Connected" means the app has an authenticated
  host connection right now; Preferences counts them ("Connected in 2 profiles"). The panel's line asks more: a
  connection that is in front.
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
   From 0.5.0 it connects to `com.passwordpie`, which only apps from the rename on (direct 0.2.0) install. 0.5.0 went
   live in the store before that release was out, so until 0.2.0 the store extension could not reach the released app
   (v0.1.0 has no bridge at all).
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
| "Add Chrome Extension…" row, and Chrome's line in Preferences → Browser extensions | yes | not compiled / left out |
| "Enable Safari Extension…" row, and Safari's line in Preferences → Browser extensions | yes | yes |
| AX fallback for the current URL | yes, if Accessibility is granted | same code; untested in the sandbox (see CHANNELS.md) |

## Testing

- `swift test`: public suffix rules, same-site and downgrade rules, pending fill expiry and single use, message coding,
  framing, the "this site" list, site icon lookup order, when `wantIcon` is set, and which `icon` requests are refused.
- `swift test --filter 'BridgeLinks|BridgeProfiles|BrowserProfiles|ChromeFillRoute|ExtensionStatus'`: which connection is
  in front (focus said, lost, never said, held by the panel), that another profile's tab is neither the page nor
  filled, the banner for a profile without the extension, where the store page opens, and Preferences' lines.
- `cd extension && pnpm test`: choosing and scaling the tab's icon; field finding and filling against HTML fixtures
  (autocomplete hints, forms with no attributes, React controlled inputs, open shadow DOM, two-step sign-in, cross-origin
  refusal), code fields (one field, split boxes, decoys), the code flow in the background, the note and its Upgrade, the
  right-click menus (`toolbar.test.ts`), and both bundles having no account, no request to the site, no `storage` and no
  popup (`store-build.test.ts`).
- `swift test --filter 'Entitlement|BridgeCode|BrowserCodeAccess'`: the token check (good, wrong key, changed claims or
  header, expired, wrong `aud` or `iss`, not Premium) and the `code` request rules.
- `swift test --filter 'DirectPremium|BridgePremium|BridgeUpgrade'`: what the direct app keeps, the `upgrade` request, and
  that neither app takes a pass from an extension (`PP_MAS=1 swift test --scratch-path .build-mas` runs the App Store side).
- `swift test --filter 'BridgeChange|PasswordResetSession|PreviousPasswords'`: the `newPassword` key (present only for a
  reset fill), the pending change (once, its browser, connection, site, 600 seconds, locking), the same `changed` answer
  when nothing matched, the new password kept in the file without changing the saved one, and the question's two answers.
- `swift test --filter 'OTPAuthParsing|OTPScanMatch|QRCodeReader|BridgeScan|OTPScanSession'`: the link checks, which items
  come first, reading a QR code generated in the test with Vision, the `scan` request and `expectCode`, the old code kept
  in the item's history, and the confirmation (locked, replace, expiry, a newer scan).
- `cd extension && pnpm test tests/qr-scan.test.ts`: which page pictures are read, decoding a generated QR code with jsQR,
  the screenshot fallback, what is sent and what is not.
- On a Mac: `make install`, load `extension/.output/chrome-mv3` unpacked in Chrome, enable the extension in Safari. See the
  demo script in UX.md.
