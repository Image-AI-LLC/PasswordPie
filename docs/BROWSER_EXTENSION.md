# Browser extension (v1)

The PasswordPie extension fills the account chosen in the PasswordPie panel into the page in Chrome or Safari. The panel
does all the choosing and matching; the extension only reports the active tab, finds the sign-in form and fills it.
What the user sees is in "Fill in the browser" in [UX.md](UX.md).

v1 is fill only. Not in v1: an icon or menu inside page fields, saving new passwords, two-step codes, Firefox.

## Pieces

| Piece | Where | Channel |
|---|---|---|
| Extension (WXT + TypeScript, no UI framework) | `extension/` | Chrome build and Safari build from one source |
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
- `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` + `SecCodeCheckValidity` checks it against a code requirement:
  `anchor apple generic and certificate leaf[subject.OU] = "2S468LUF8V"` and the expected signing identifier.

| Side | Accepts only |
|---|---|
| App (server) | `com.oldcai.passwordpie.safari` (Safari appex) or `com.oldcai.passwordpie.browser-host` (Chrome host). The identifier, not anything in a message, says which browser is talking. |
| Host, appex (clients) | `com.oldcai.passwordpie` (the app) |

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
   site (eTLD+1 of the entry website that matched), kind (this tab, or a new tab), created at. It expires after 30 s.
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

## Messages

Every request has `type` and an `id` (an integer the extension picks). Every answer echoes `id`. Pushes have no `id`.

### `hello`

    → {"type":"hello","id":1,"version":1,"extension":"0.1.0"}
    ← {"type":"hello","id":1,"version":1,"locked":false}

Sent when the extension starts and when its port (re)connects. It makes the browser count as connected.

### `tab`

    → {"type":"tab","id":2,"url":"https://github.com/login","reason":"activated"}
    ← {"type":"tab","id":2}
    ← {"type":"tab","id":2,"fill":{"origin":"https://github.com","username":"octocat","password":"…","expiresIn":28}}

`reason` is one of `activated`, `updated`, `focus`, `poke`, `startup` (diagnostic only; it changes nothing). `url` is the
top frame URL of the active tab in the focused window. An empty or non-http(s) `url` clears the cached URL and never fills.
`expiresIn` is the whole seconds left of the pending fill's 30; the extension keeps its copy no longer than that.

### `poke` (app → extension)

    ← {"type":"poke"}

Ask now: send a `tab` report for the active tab.

### `error`

    ← {"type":"error","id":2,"code":"app-unavailable"}

Codes: `app-unavailable` (host could not reach the app), `bad-request`, `version`. The extension treats any error as "no fill".

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
(report now), and `{"type":"filled","password":true}` when a password filled late (drop the copy). Background → content
script: `{"type":"fill","origin","username","password"}`, sent only to frames whose origin equals `origin`; the content
script checks `location.origin` again and that it is the top frame or same-origin with it.

## Secrets

- Credentials exist only in memory: in the app, in the answer frame, in the relay's buffer, in the extension's service
  worker and content script, and then in the page's fields. They are never logged, never written to `storage`, and never
  written to disk by the app. The host and appex log only sizes and error codes.
- Tab URLs are used for matching and the "this site" list only: held in memory, never logged, never saved.
- The fill never submits the form.

## Chrome

- The host manifest's `allowed_origins` lists only the PasswordPie extension IDs: the unpacked development build, whose ID
  is pinned by the public `key` in `extension/wxt.config.ts` (`pbbiimlkojflhpopeplkbfeecanbbdoj`), and the Chrome Web Store
  ID once there is one. The host also checks Chrome's `chrome-extension://<id>/` argument against the same list.
- The extension keeps one `chrome.runtime.connectNative` port open. That keeps its service worker alive and the host
  running, and it is how pokes arrive. "Connected" means the app has an authenticated host connection right now.
- The app writes the host manifest at launch (direct channel only), pointing at the host inside the running app bundle.
- **App Store channel: no Chrome in v1.** A sandboxed app cannot write into Chrome's `NativeMessagingHosts` folder, and a
  host launched by Chrome from inside a store app would have to be sandboxed without a way to receive Chrome's arguments
  reliably. The host target, the manifest writer and the "Add Chrome Extension…" row are `#if PP_DIRECT` / not assembled
  in `make mas-dev`.

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

## Current URL without the extension

When the front browser's extension is not connected, the panel reads the URL from the browser's window with the
Accessibility API (already granted for Fill): the `AXURL` of the focused window's `AXWebArea`, or for Chrome the value of
the toolbar's address field. The walk is bounded (0.25 s messaging timeout, 300 nodes, 0.3 s deadline) and runs off the
main thread. It is used for the "this site" list only; without the extension, Fill keeps typing keystrokes as before. It
needs Accessibility to be granted already and never asks for it.

## Channel differences

| | Direct | App Store |
|---|---|---|
| Safari extension | yes | yes (needs profiles for the appex and App Group) |
| Chrome extension, native host | yes | not in v1 |
| "Add Chrome Extension…" row | yes | not compiled |
| "Enable Safari Extension…" row | yes | yes |
| AX fallback for the current URL | yes, if Accessibility is granted | same code; untested in the sandbox (see CHANNELS.md) |

## Testing

- `swift test`: public suffix rules, same-site and downgrade rules, pending fill expiry and single use, message coding,
  framing, the "this site" list.
- `cd extension && pnpm test`: field finding and filling against HTML fixtures (autocomplete hints, forms with no
  attributes, React controlled inputs, open shadow DOM, two-step sign-in, cross-origin refusal).
- On a Mac: `make install`, load `extension/.output/chrome-mv3` unpacked in Chrome, enable the extension in Safari. See the
  demo script in UX.md.
