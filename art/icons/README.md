# Icon proportions and own-brand mark

The Mini panel now uses the existing PasswordPie shield vector from `MenuBarIcon.path()`
(the same outline as `art/source/menubar.svg`), not the former circular dial/keyhole
artwork. `PasswordPieMark` supplies the silver lock-screen/Preferences treatment and a
monochrome template treatment for the Mini header. The existing door-opening and
fade animations remain; the shield subtly brightens instead of turning like a dial.

Small AppKit menu icons and favourite badges are centered with proportional aspect
fit. This keeps the original square click/layout slots without stretching the
native SF Symbol artwork. The SwiftUI details tile also uses scaledToFit. Other
font-rendered symbols already keep their native proportions and are unchanged.

## Evidence

- `locked-light.jpg`: actual native lock screen with own-brand silver shield.
- `menu-light.jpg`, `menu-dark.jpg`: actual unlocked Mini menu, own-brand header,
  keys/cards/identity/tag icons and both appearances.
- `search-light.jpg`: actual favourite search result with star badge.
- The fixture contains synthetic Sample entries only. It uses a separately signed
  preview bundle and separate preferences; the production app/vault is untouched.
- Native UI verification unlocked the disposable fixture, searched Sample Login,
  and opened its details popover. The screenshot API captures the main app window,
  not that popover; its contents were verified through the accessibility tree.
- Five regression tests cover wide/tall/square and invalid dimensions, real SF
  Symbol images in icon and badge slots, canonical shield path identity/template
  geometry, and non-square shield canvases. Tests began red before implementation.

## Reflection

An NSImage destination rectangle does not preserve the source aspect ratio. Fit
its intrinsic size inside the layout slot instead of changing the slot or hit box.
Native captures complement the geometry tests; no shared workflow change is needed.
