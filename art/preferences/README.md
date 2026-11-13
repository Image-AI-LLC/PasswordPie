# Preferences redesign

> Historical shield-era screenshots. The current flat keyhole-pie assets and rebuild steps are documented in `art/README.md`.

`concept.png` was generated with the built-in `image_gen` tool; its full prompt is in
`prompt.txt`. It is a visual reference, not a runtime asset. The implementation uses
native SwiftUI/AppKit controls and semantic system colors, not the mockup bitmap.

## Design

- Four centered cards: Quick access, Security, Everyday, Database. Inside each card,
  labels share a left edge and controls share a right edge. In particular, the three
  security switches are **not** independently centered around their text.
- A 54-point shortcut recorder with keycaps, explicit recording/error hints and an
  inline ×. The × restores the original default (⌘\\), not an unbound shortcut;
  while recording it cancels. Escape cancels, Tab leaves, window/app deactivation
  cancels, and closing the window restores global registration.
- Coarse native menu pickers replace steppers. Existing non-preset durations are
  retained exactly; defaults stay 5 minutes idle and 90 seconds clipboard.
  “Never” maps only to the existing `lockOnIdle` flag. Sleep, screen saver and
  user-switch locking remain independent, as explained below the switches.
- Database filename is prominent, its directory is truncated with a full-path help
  tooltip; Touch ID shows enabled/locked/error state rather than an unexplained
  disabled action. Enabled databases keep an Update… action for re-enrollment after
  an external master-password change. No vault or authentication policy changes.
- The window is resizable, with a 560×480 minimum and scrollable content. Its initial
  560×800 content size is limited to the current screen. Credits and the repository
  link live in About, not in this window.

## Verification

- `swift test`: 76 tests; `swift test -c release`: 75 tests (the debug preview
  guard test is intentionally excluded). Each has 1 existing fixture-dependent
  test skipped and zero failures.
  The new duration tests began red; the new recorder tests use real NSWindow event
  identities without writing preferences or accessing a database.
- `swift build -c release`: succeeds. The existing MenuListView deprecated-color
  warning is unrelated. Preview environment hooks compile out of release.
- Actual app screenshots: `implemented-light.jpg`, `implemented-dark.jpg`, and
  `implemented-compact.jpg` (480-point content height, scrolled to the database).
- Real native UI checks: bare key rejected; ⌥⌘K recorded; Esc and Tab cancel;
  inline × restores ⌘\\; idle and clipboard menu selection works; closing while
  recording and reopening with ⌘, returns to the idle recorder. Values survived a
  preview restart. Legacy persisted Int values (7 minutes / 45 seconds) were
  retained; Never changed only lockOnIdle, preserving the three other lock flags
  and the saved timeout. These are native app captures, not HTML reproductions.

The QA app was a separately signed debug bundle (`com.passwordpie.preferences-preview`)
with its own preferences domain. Initial interaction checks used a nonexistent
`/tmp/passwordpie-preferences-qa/Preview.kdbx`; final screenshots used a disposable
synthetic `Icons.kdbx` fixture to show enabled database actions. The installed app and real vault were
not changed. No real biometric enrollment was performed. Preferences preview mode
now suppresses all global shortcut registration (including re-registration after
recording); normal panel previews can opt into the same safety boundary with
`PASSWORDPIE_DISABLE_HOTKEY=1`. Global registration checks above preceded that guard.

For a similarly isolated debug bundle, use these environment variables:

```
PASSWORDPIE_DB=/path/to/nonexistent/Preview.kdbx
PASSWORDPIE_PREFERENCES=1
PASSWORDPIE_APPEARANCE=light # or dark
PASSWORDPIE_PREFERENCES_HEIGHT=480 # optional, clamped to 480...800
```

Do not point UI verification at a personal vault or reuse the production bundle ID.

## Reflection

A SwiftUI switch outside a Form does not automatically give its label a full-width
row. Use an explicit label/Spacer/control row and preserve the switch's accessible
label and hint. Native screenshots caught the initial independent centering that
unit tests cannot detect. The focused regression tests and this design note cover
the reusable project lesson; no shared workflow changes are needed.
