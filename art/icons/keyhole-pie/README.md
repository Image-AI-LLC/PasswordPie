# Selected B-keyhole: native verification

The user selected the flat keyhole pie and approved the larger app tile (84.2% visible diameter).
`size-comparison.png` records the approved SVG sizing change; it is a concept comparison, not a native screenshot.

## Actual native evidence

- `system-app-icon.png`: NSWorkspace reads the compiled app icon from a fresh-path preview bundle. macOS applies its own mask/material rendering; the source tile itself is flat.
- `locked-{light,dark}.png`: running app's lock screen, orange pie with transparent keyhole.
- `menu-{light,dark}.png`: running app's unlocked header, monochrome pie; synthetic Sample Login only.
- `preferences-{light,dark}.png`: running app's Preferences, flat orange pie.
- `native-status-item.png`: actual macOS status-bar crop of an isolated AppKit harness using the unmodified production `MenuBarIcon.image()`. Not a simulated strip. The screen region came from that item's own window frame; no other app was captured.
- `menubar_app_{1,2}x.png`: production native template image rendered offscreen at 18/36 pixels. These are not screenshots of a full menu bar.

The full app screenshots use a separately ad-hoc signed debug bundle with identifier
`com.oldcai.passwordpie.brand-preview-20261031`, its own UserDefaults and a disposable
`BrandPreview.kdbx` containing one synthetic Sample Login. The debug environment
sets `PASSWORDPIE_DB`, `PASSWORDPIE_DISABLE_HOTKEY=1`, `PASSWORDPIE_STICKY=1`,
`PASSWORDPIE_SHOW=1` and `PASSWORDPIE_APPEARANCE=light|dark`. The unlocked preview
uses the synthetic fixture password; Preferences uses `PASSWORDPIE_PREFERENCES=1`.
No personal database, production app installation, Touch ID enrollment or global
shortcut registration was changed. Every preview process was terminated and waited for.

## Tests and source parity

- New geometry tests started red against the old shield (44 assertion failures).
- 10 icon tests pass: all 120 outer vertices match `art/source/mark.svg` to 1e-9;
  keyhole circular arc, mirror symmetry, template alpha, non-square fit and
  canonical SVG path parity are covered. SwiftUI raster samples are exactly
  the selected opaque sRGB orange, with transparent keyhole pixels.
- Full debug suite: 129 tests, 1 existing optional KeePassXC fixture test skipped, 0 failures.
- Full release suite: 128 tests, the same 1 optional fixture skipped, 0 failures.
- Release product builds successfully; existing unrelated MenuListView deprecated-color warnings remain.
- `make icon` exports the approved SVG to a byte-identical PNG, then compiles `.car` and `.icns`.

## Reflection

Use one selected SVG geometry across app tile, native template and SwiftUI marks.
A geometry-only replacement would have retained the old silver gradients; the
actual lock-screen and Preferences captures verify the complete flat-style change.
The parity tests and this evidence document the project-specific lesson; no shared
workflow or memory update is needed.
