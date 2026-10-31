---
version: 1
name: PasswordPie — Satin Vault
description: >-
  A pocket-sized steel vault in the menu bar. Two layers: the brand (graphite
  tile, satin-silver shield with a keyhole cut through it) used for the app
  icon, the menu bar mark and anything outside the app; and the app UI. While
  locked, the UI is a light brushed-grey vault door with a dial. After unlock
  it is a native macOS menu: the system menu material, 14 pt rows, cascading
  submenu windows and a details popover beside the selected item. Restrained,
  tactile, quiet: the shield and the door are the only "objects"; everything
  after unlock is system material, system colours and hairlines, and follows
  the light or dark appearance.
lineage: >-
  Door tokens are #D6D6D6 for the door and #E6E6E6 for the seam band
  (Sources/PasswordPieApp/Palette.swift). Menu metrics are 21 pt rows, 11 pt
  separators, 16 pt group headers, a flat selection fill, and short hover
  delays (MenuListView.swift, MenuController.swift). Every surface is drawn
  in code. The brand layer comes from the round-5 icon decision (2026-10-31,
  option X6: Codex-generated satin shield on graphite, art/README.md). The
  brand mark is the shield; graphite and satin are the brand colours; the
  type scale and every colour that is a literal in code is named here.

colors:
  # Brand — app icon, menu bar mark, website, README. Not used inside the panel.
  brand-graphite: '#3A3F46'
  brand-graphite-deep: '#15181B'
  brand-satin: '#D7DCE1'
  brand-satin-shade: '#9AA3AD'
  on-brand: '#F4F6F8'
  # Door (lock screen). Light in both appearances.
  door: '#D6D6D6'
  door-band: '#E6E6E6'
  door-band-highlight: '#FAFAFA'
  door-band-line: '#666666'
  door-edge-light: '#EFEFEF'
  door-edge-dark: '#737373'
  door-field: '#FFFFFF'
  door-field-shade: 'rgba(0, 0, 0, 0.22)'
  door-field-frame: '#2B2B2B'
  door-field-split: '#3A3A3A'
  door-button-top: '#FCFCFC'
  door-button-bottom: '#E2E2E2'
  door-button-pressed-top: '#D2D2D2'
  door-button-pressed-bottom: '#E6E6E6'
  door-button-glyph: '#8C8C8C'
  text-door: '#555555'
  text-door-hint: '#6F6F6F'
  danger: '#C8372D'
  # Dial (on the door seam; also the 32 pt logo in the header)
  dial-rim-top: '#F0F0F0'
  dial-rim-bottom: '#C4C4C4'
  dial-rim-stroke: '#7A7A7A'
  dial-ring: '#FFFFFF'
  dial-inner-top: '#B8B8B8'
  dial-inner-bottom: '#D8D8D8'
  dial-inner-stroke: '#9A9A9A'
  dial-face-top: '#F6F6F6'
  dial-face-bottom: '#DEDEDE'
  dial-hub: '#E4E4E4'
  dial-hub-stroke: '#D0D0D0'
  dial-key: '#626262'
  dial-lug: '#8E8E8E'
  # Menu (unlocked panel, submenus, details popover, generator). Most are
  # system colours, resolved on macOS 27 with the default blue accent; a
  # -dark token is the same role in the dark appearance.
  menu-material: 'rgba(246, 246, 246, 0.85)'
  menu-material-dark: 'rgba(38, 38, 40, 0.85)'
  label: 'rgba(0, 0, 0, 0.85)'
  label-dark: 'rgba(255, 255, 255, 0.85)'
  label-secondary: 'rgba(0, 0, 0, 0.5)'
  label-secondary-dark: 'rgba(255, 255, 255, 0.55)'
  label-tertiary: 'rgba(0, 0, 0, 0.26)'
  label-tertiary-dark: 'rgba(255, 255, 255, 0.25)'
  label-disabled: '#666666'
  group-header-text: '#333333'
  group-header-text-dark: '#E6E6E6'
  ink: '#000000'
  ink-dark: '#FFFFFF'
  menu-arrow: '#999999'
  selection: 'rgba(0, 103, 244, 0.5)'
  selection-dark: '#0059D1'
  on-selection: '#FFFFFF'
  accent: '#007AFF'
  field-focus: 'rgba(0, 122, 255, 0.14)'
  well: '#FFFFFF'
  well-dark: '#1E1E1E'
  # Item icons (SF Symbol tints and letter tiles)
  favorite: '#F5B833'
  tint-login: '#738094'
  tint-note: '#E6B333'
  tint-card: '#808C9E'
  tint-identity: '#6699D9'
  tint-folder: '#599EE6'
  tint-tag: '#73B366'
  tile-stroke: 'rgba(0, 0, 0, 0.25)'
  on-tile: '#FFFFFF'
  # Status (system colours, light appearance)
  system-red: '#FF383C'
  system-orange: '#FF8D28'
  system-green: '#34C759'
  # Overlay
  large-type-bg: 'rgba(0, 0, 0, 0.88)'
  on-large-type: '#FFFFFF'
  on-large-type-digit: '#5CB3FF'
  on-large-type-symbol: '#FFBF59'
  on-large-type-space: 'rgba(255, 255, 255, 0.55)'
  large-type-stripe: 'rgba(255, 255, 255, 0.18)'
  large-type-stripe-alt: 'rgba(255, 255, 255, 0.09)'

typography:
  # SF Pro is the macOS system font (`.system(size:weight:)`, `NSFont.systemFont`,
  # `NSFont.menuFont`); SF Mono is `.system(..., design: .monospaced)`. The app
  # never sets line spacing, so line height is the font default: ascender plus
  # descender, measured at 1.178 for SF Pro and SF Mono at every size used, written
  # here as 1.18. Tracking is the SF tracking for the size; the app sets none, so
  # the system applies the same default. The one hand-set value is brand-wordmark,
  # a web-only lockup.
  display-code:
    fontFamily: 'SF Mono, ui-monospace, Menlo, monospace'
    fontSize: 54px
    fontWeight: 500
    lineHeight: 1.18
    letterSpacing: 0
  brand-wordmark:
    fontFamily: 'SF Pro Display, -apple-system, system-ui, sans-serif'
    fontSize: 28px
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: -0.4px
  search:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: -0.44px
  code-lg:
    fontFamily: 'SF Mono, ui-monospace, Menlo, monospace'
    fontSize: 17px
    fontWeight: 500
    lineHeight: 1.18
    letterSpacing: 0
  title:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 600
    lineHeight: 1.18
    letterSpacing: -0.31px
  menu-item:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: -0.15px
  code-md:
    fontFamily: 'SF Mono, ui-monospace, Menlo, monospace'
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0
  body:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: -0.08px
  body-code:
    fontFamily: 'SF Mono, ui-monospace, Menlo, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0
  control:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0
  caption-strong:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 11px
    fontWeight: 600
    lineHeight: 1.18
    letterSpacing: 0.06px
  caption:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0.06px
  caption-code:
    fontFamily: 'SF Mono, ui-monospace, Menlo, monospace'
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0
  label:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 10px
    fontWeight: 400
    lineHeight: 1.18
    letterSpacing: 0.12px
  tile-letter:
    fontFamily: 'SF Pro Text, -apple-system, system-ui, sans-serif'
    fontSize: 9.5px
    fontWeight: 600
    lineHeight: 1.18
    letterSpacing: 0

rounded:
  menu: 5px
  panel-locked: 8px
  field-group: 6px
  well: 5px
  editor-well: 4px
  item-icon: 22%
  large-type: 14px
  capsule: 999px
  app-icon: system squircle (macOS applies the mask)

spacing:
  # Panel (Metrics in Palette.swift, MenuGeometry.swift)
  panel-width: 300px
  menu-max-width: screen width / 4
  screen-margin: 8px
  locked-height: 280px
  create-height: 330px
  door-height: 96px
  dial-size: 96px
  door-field-width: 260px
  door-field-height: 42px
  # Header (HeaderView.swift)
  header-height: 45px
  logo-size: 32px
  search-field-height: 24px
  # Menu rows (MenuMetrics in MenuListView.swift)
  row-height: 21px
  separator-height: 11px
  group-header-height: 16px
  list-min-height: 24px
  row-icon: 16px
  row-icon-x: 16px
  row-title-x: 38px
  arrow-inset: 26px
  submenu-inset: 5px
  # Details popover, generator, Large Type
  details-width: 400px
  details-max-height: 500px
  details-row-min-height: 38px
  details-tile: 32px
  generator-width: 412px
  generator-height: 300px
  # Large Type sizes to the password. Its largest size is the visible frame
  # minus 48 px in width and in height. The type starts at 54 px and shrinks until it fits.
  large-type-padding: 24px
  large-type-group: 4
  large-type-gap: 8px
  # Rhythm
  space-1: 4px
  space-2: 5px
  space-3: 8px
  space-4: 10px
  space-5: 12px
  space-6: 14px
  space-7: 20px
  space-8: 24px
  menu-bar-icon: 18px

components:
  panel-locked:
    background: '{colors.door}'
    rounded: '{rounded.panel-locked}'
    size: '{spacing.panel-width} × {spacing.locked-height} ({spacing.create-height} while creating)'
  door:
    background: '{colors.door}'
    seam: 'door-edge-light 0.5 · door-edge-dark 1 · door-band 18 · door-band-highlight 1 · door-band-line 0.5'
  door-field:
    background: '{colors.door-field}'
    inner-shade: 'door-field-shade to clear, 6px deep'
    frame: '1px {colors.door-field-frame}'
    rounded: '{rounded.field-group}'
    size: '{spacing.door-field-width} × {spacing.door-field-height}'
    typography: '{typography.menu-item}'
  door-button:
    background: 'linear-gradient(door-button-top, door-button-bottom)'
    pressed: 'linear-gradient(door-button-pressed-top, door-button-pressed-bottom)'
    glyph: '{colors.door-button-glyph}'
    split: '1px {colors.door-field-split}'
  panel-menu:
    background: 'system menu material ({colors.menu-material} stand-in)'
    rounded: '{rounded.menu}'
    width: '{spacing.panel-width} to {spacing.menu-max-width}'
  header:
    height: '{spacing.header-height}'
    logo: 'dial at {spacing.logo-size}'
    search: '{typography.search} {colors.label}; placeholder {colors.label-secondary}'
    gear: 'gearshape.fill 16pt {colors.label-secondary}'
    separator: '1px ink 25 %, hidden while a query is typed'
  menu-row:
    height: '{spacing.row-height}'
    typography: '{typography.menu-item}'
    text: '{colors.label}'
    username: '" — username" in {colors.label-secondary}'
    selected: '{colors.selection} ({colors.selection-dark} in dark), {colors.on-selection} text and icons'
    arrow: '{colors.menu-arrow}'
  group-header:
    height: '{spacing.group-header-height}'
    background: 'ink 3 %, 1px ink 20 % above and below'
    typography: '{typography.caption} uppercase, {colors.group-header-text}'
  menu-separator:
    height: '{spacing.separator-height}'
    line: '1px ink 25 %'
  submenu-window:
    background: 'system menu material'
    rounded: '{rounded.menu}'
    inset: '{spacing.submenu-inset} top and bottom'
  details-popover:
    width: '{spacing.details-width}'
    max-height: '{spacing.details-max-height}'
    title: '{typography.title} {colors.label}'
    tile: '{spacing.details-tile}'
  detail-field:
    label: '{typography.label} {colors.label-secondary}'
    value: '{typography.body} {colors.label}'
    focused: '{colors.field-focus}'
    divider: '0.5px ink 10 %'
    min-height: '{spacing.details-row-min-height}'
  otp:
    code: '{typography.code-lg} {colors.accent}'
    urgent: '{colors.system-red}'
    pie: 14px
  strength-meter:
    track: 'ink 12 %'
    fill: 'system-red below 0.4 · system-orange below 0.7 · system-green'
    height: 5px
    rounded: '{rounded.capsule}'
  generator:
    size: '{spacing.generator-width} × {spacing.generator-height}'
    password: '{typography.code-md} in a {rounded.well} {colors.well} well, 0.5px ink 25 %'
    typography: '{typography.control}'
  letter-tile:
    size: '{spacing.row-icon}'
    rounded: '{rounded.item-icon}'
    letter: '{typography.tile-letter} {colors.on-tile}'
    stroke: '0.5px {colors.tile-stroke}'
  large-type:
    background: '{colors.large-type-bg}'
    rounded: '{rounded.large-type}'
    typography: '{typography.display-code}'
    letters: '{colors.on-large-type}'
    digits: '{colors.on-large-type-digit}'
    symbols: '{colors.on-large-type-symbol}'
    space: '␣ in {colors.on-large-type-space}'
    groups: '4 characters on alternating {colors.large-type-stripe} / {colors.large-type-stripe-alt}'
    glyph: 'each character is as wide as its own glyph'
    fit: 'largest window is the visible frame minus 48px in width and height; type shrinks from 54px'
---

# PasswordPie — historical "Satin Vault" reference

> Current branding and locked-panel styling: see [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Metal-door descriptions below document the earlier visual design; unchanged native interaction contracts still apply.

PasswordPie is a KeePass (KDBX) password manager that lives in the macOS menu bar.
This file preserves the previous visual system and its machine-readable tokens.
`Design.html` renders that historical token set, not the current brand. For current
colors and locked-panel components, use `DESIGN_SYSTEM.md` and
`Sources/PasswordPieApp/Palette.swift`; do not export these legacy values over them.

## Overview

PasswordPie has two faces. Locked, it is a vault door: a 300 × 280 pt panel of
brushed grey with a dial on the seam and a master password field. Unlocked, the
same window becomes a native menu: a header with the dial
logo, a large search field and a gear, then menu rows. Rows open submenu
windows to the right (Favorites, Password Generator, the item categories,
Folders, Tags). An item row opens a details popover with its fields. Typing in
the search field replaces the menu with results grouped by category.

- **One object, many hairlines.** The vault is the only skeuomorphic thing: the
  satin shield in the brand, the brushed door and dial on the lock screen.
  After unlock everything is the system menu material, system colours and
  0.5–1 px lines.
- **A menu, not a window.** Rows are 21 pt, the text is 14 pt, selection is a
  flat full-width fill, and the keyboard stays in the search field. Width and
  height follow the content, not a fixed frame.
- **macOS-native behaviour.** System font, SF Symbols, system materials and
  semantic colours, template menu bar image. The menu, popover and generator
  follow the light or dark appearance. PasswordPie should feel like it shipped
  with the Mac.
- **Brand stays outside the panel.** Graphite and satin are for the app icon,
  menu bar mark, website and README. The door keeps its light greys in both
  appearances.

## Colors

All values are sRGB. The front matter is the full list; this section says
where each group goes.

### Brand

| Token | Hex | Use |
|---|---|---|
| `brand-graphite` | `#3A3F46` | Icon tile centre, website hero ground, README badges |
| `brand-graphite-deep` | `#15181B` | Icon tile corners, dark ground |
| `brand-satin` | `#D7DCE1` | Shield face, wordmark on graphite |
| `brand-satin-shade` | `#9AA3AD` | Shield bevel, secondary text on graphite |
| `on-brand` | `#F4F6F8` | Text on graphite |

The shield artwork itself is a raster (`Assets/AppIcon.icon/Assets/tile.png`);
never redraw it in flat colours. The menu bar mark is one-colour
(`MenuBarIcon.swift`, template image) and is tinted by the system.

### Door and dial

The lock screen is two door halves (`door #D6D6D6`) meeting at a seam band
(`door-band #E6E6E6` with a `#FAFAFA` highlight, a `#666666` line and
`#EFEFEF` / `#737373` edges). The password row is a white field
(`door-field`) with a 6 pt `door-field-shade` (black 22 % to clear) at its top,
framed in `door-field-frame #2B2B2B`. Door buttons are `#FCFCFC → #E2E2E2`,
pressed `#D2D2D2 → #E6E6E6`, with `#8C8C8C` glyphs and `#3A3A3A` splits.
Door text is `text-door #555555` (database name) and `text-door-hint #6F6F6F`
(hint and links), engraved with a white shadow 1 pt below. Errors are
`danger #C8372D`.

The dial uses a top-lit rim (`#F0F0F0 → #C4C4C4`, stroke `#7A7A7A`), a white
ring, an inner ring (`#B8B8B8 → #D8D8D8`, stroke `#9A9A9A`), a face
(`#F6F6F6 → #DEDEDE`), a hub (`#E4E4E4`, stroke `#D0D0D0`), a `#626262` key
slot and two `#8E8E8E` lugs. The same drawing, at 32 pt, is the header logo.

### Menu

The unlocked panel, submenu windows, the details popover and the generator use
the system menu material and semantic colours, so they follow the appearance.
Values were resolved on macOS 27 with the default blue accent; another accent
colour changes `selection`, `accent` and `field-focus`.

| Token | Light | Dark | Code source | Use |
|---|---|---|---|---|
| `menu-material` | stand-in | stand-in | `NSVisualEffectView.Material.menu` | Panel, submenus, generator. The rgba values are a preview stand-in only. |
| `label` | black 85 % | white 85 % | `labelColor` | Row titles, search text, field values |
| `label-secondary` | black 50 % | white 55 % | `secondaryLabelColor` | Search placeholder, gear, " — username", field labels, key icons, edit pencil |
| `label-tertiary` | black 26 % | white 25 % | `tertiaryLabelColor` | "Show N more …" rows |
| `label-disabled` | `#666666` | `#666666` | `NSColor(white: 0.4)` | "No items found" |
| `group-header-text` | `#333333` | `#E6E6E6` | `NSColor(white: 0.2 / 0.9)` | Search group headers |
| `ink` | black | white | `menuInk(_:)`, `Color.primary` | Lines and fills at an alpha (below) |
| `menu-arrow` | `#999999` | `#999999` | `NSColor(red: 0.6, …)` | Submenu triangle |
| `selection` | `#0067F4` at 50 % | `selection-dark #0059D1` | `keyboardFocusIndicatorColor` / `alternateSelectedControlColor` | Selected row fill |
| `on-selection` | `#FFFFFF` | `#FFFFFF` | `.white` | Text, icons and arrow on the selection |
| `accent` | `#007AFF` | `#007AFF` | `Color.accentColor` | URL values, OTP code and pie |
| `field-focus` | accent 14 % | accent 14 % | `accentColor.opacity(0.14)` | Focused details field |
| `well` | `#FFFFFF` | `well-dark #1E1E1E` | `textBackgroundColor` | Generator password well |

`ink` is used at these alphas only: 3 % (group header fill), 10 % (details
field divider), 12 % (strength meter track), 20 % (group header lines, notes
editor stroke) and 25 % (header separator, menu separators, generator well
stroke).

### Item icons

Rows that open a submenu show a 13 pt SF Symbol in a tint; selected rows draw
it white. Entry rows show a letter tile instead.

| Token | Hex | Symbol |
|---|---|---|
| `favorite` | `#F5B833` | `star.fill` (Favorites row, 8 pt badge on a favourite's tile, details star) |
| `tint-login` | `#738094` | `lock.square.fill` (Logins) |
| `tint-note` | `#E6B333` | `note.text` (Secure Notes) |
| `tint-card` | `#808C9E` | `creditcard.fill` (Credit Cards), `doc.fill` (Documents) |
| `tint-identity` | `#6699D9` | `person.crop.rectangle.fill` (Identities) |
| `tint-folder` | `#599EE6` | `folder.fill` (Folders and each folder) |
| `tint-tag` | `#73B366` | `tag.fill` (Tags and each tag) |
| `label-secondary` | — | `key.fill` (Password Generator, Passwords) |

The code gives these as float components (`NSColor(red: 0.96, green: 0.72,
blue: 0.2)` and so on); the hex is rounded half up.

Letter tiles take their hue from a stable FNV-1a hash of the title and run
from saturation 0.45 / brightness 0.95 at the top to 0.7 / 0.78 at the bottom,
with a 0.5 pt `tile-stroke` (black 25 %) and an `on-tile` white letter.

### Status and overlay

- `system-red #FF383C`, `system-orange #FF8D28`, `system-green #34C759`: the
  strength meter, and `system-red` for an OTP in its last 5 s. Dark values are
  `#FF4245`, `#FF9230` and `#30D158`.
- `large-type-bg` (black 88 %). Letters are `on-large-type` white, digits
  `on-large-type-digit` (`#5CB3FF`), other symbols `on-large-type-symbol`
  (`#FFBF59`). Stripes alternate white 18 % and white 9 %. A real space is
  drawn as ␣ at white 55 %.

## Typography

One family pair: **SF Pro** (system) and **SF Mono**. Never ship a web font in
the app. Size is the hierarchy; weights are 400, 500 and 600.

### Latin scale

| Token | Family | Size | Weight | Line | Tracking | Use |
|---|---|---|---|---|---|---|
| `display-code` | SF Mono | 54 | 500 | 1.18 | 0 | Large Type overlay (starts at 54 pt and shrinks to fit the screen) |
| `brand-wordmark` | SF Pro Display | 28 | 600 | 1.1 | −0.4 px | "PasswordPie" on website / README / About |
| `search` | SF Pro Text | 18 | 400 | 1.18 | −0.44 px | Header search field and its placeholder |
| `code-lg` | SF Mono | 17 | 500 | 1.18 | 0 | Live OTP code in the details popover |
| `title` | SF Pro Text | 16 | 600 | 1.18 | −0.31 px | Details popover title (entry name) |
| `menu-item` | SF Pro Text | 14 | 400 | 1.18 | −0.15 px | Menu rows, " — username", "Show N more", "No items found"; master password field |
| `code-md` | SF Mono | 14 | 400 | 1.18 | 0 | Generated password |
| `body` | SF Pro Text | 13 | 400 | 1.18 | −0.08 px | Details values (username, URL, notes, tags, masked dots); Editor and Preferences form text (system default) |
| `body-code` | SF Mono | 13 | 400 | 1.18 | 0 | Revealed secrets in details, revealed password in the Editor |
| `control` | SF Pro Text | 12 | 400 | 1.18 | 0 | Generator labels, buttons and toggles (values use monospaced digits); Editor notes |
| `caption-strong` | SF Pro Text | 11 | 600 | 1.18 | +0.06 px | Database name on the door |
| `caption` | SF Pro Text | 11 | 400 | 1.18 | +0.06 px | Door hint and error, the details "copy" menu button, search group headers (upper case) |
| `caption-code` | SF Mono | 11 | 400 | 1.18 | 0 | Database path in Preferences |
| `label` | SF Pro Text | 10 | 400 | 1.18 | +0.12 px | Details field labels, door links, form footnotes (`.caption`) |
| `tile-letter` | SF Pro Text | 9.5 | 600 | 1.18 | 0 | Letter on a 16 pt tile (drawn 2× in the 32 pt popover tile) |

Tracking values are the SF tracking for each size. The app sets none, so the
system uses the same default. Web renderings (website, Design.html) set the
values explicitly. `tile-letter` is a single glyph, so it has none. The
exception is `brand-wordmark`, a web-only lockup with its own −0.4 px.

Rules:

- Secrets (revealed passwords, OTP, generated strings, paths) are SF Mono.
  Masked secrets are bullets in `body`.
- Built-in details labels are lower case ("username", "one-time password");
  menu labels are title case. Search group headers are the only upper-case text ("OPEN
  LOGIN", "SECURE NOTES").
- Engraved door text: `text-door` or `text-door-hint` + white shadow at y = 1.
- Readable copy is ≥ 10 pt. The 9.5 pt tile letter is an icon label.
- Glyphs are not type tokens. SF Symbols are 13 pt in rows, 8 pt for the
  favourite badge, 13 pt (edit) and 15 pt (star) in the popover, 16 pt for the
  gear and the unlock lock, and 19 pt light for Touch ID. The submenu arrow is a
  drawn 8.5 × 10 pt triangle.

### CJK (简体中文) table

The UI is English today. When strings are localised, CJK text uses the system
cascade; no CJK font is bundled.

| Role | Latin | CJK fallback | Notes |
|---|---|---|---|
| Body, titles, captions, menu rows | SF Pro Text | PingFang SC | Same size as Latin. Line height +0.1 (e.g. `body` 1.28) so 汉字 do not touch. |
| Display / wordmark | SF Pro Display | PingFang SC Semibold | The wordmark stays Latin "PasswordPie"; never translate it. |
| Code | SF Mono | PingFang SC (system fallback) | Secrets are Latin by nature; CJK in a password field falls back without styling. |
| Weights | 400 / 500 / 600 | Regular / Medium / Semibold | Never synthesize bold or italic for CJK. |
| Tracking | as table | 0 | CJK is set without letter-spacing. |
| Minimum | 9.5 pt (tile letter) | 10 pt | A CJK first letter on a tile goes up to 10 pt. |

Search group headers are upper-cased in code; CJK has no case, so the header
shows as written.

## Layout

- **Locked panel**: 300 × 280 pt (330 while creating a database), corner
  radius 8. The top door is 96 pt; the 96 pt dial sits centred on the seam; the
  database name starts 58 pt below the seam; the password row is 260 × 42 pt
  with a 38 pt Touch ID button and a 40 pt unlock button. Links sit 12 pt above
  the bottom.
- **Unlocked panel**: corner radius 5. Header 45 pt (a 40 pt bar and a 5 pt
  band whose 1 pt separator line sits at y = 40): dial logo 32 pt at (4, 4),
  search field at x 38, 24 pt tall, gear 30 × 30 pt at the right edge minus 34.
  Below it the menu list, at least 24 pt tall.
- **Menu rows**: item 21 pt, separator 11 pt, group header 16 pt. Icon 16 pt at
  x 16, title at x 38, arrow slot 16 pt, 26 pt from the right edge. Group header
  text at x 6; "Show N more" text at x 42.
- **Width**: the widest row (title + 20 rounded up, + 16 + 22, + " — username",
  + 28 when it has an arrow), at least 300 pt, at most a quarter of the screen.
  The width never shrinks while the panel is open.
- **Height**: header + rows, kept inside the screen's visible frame inset 8 pt
  on the left, right and bottom. Longer lists scroll; hovering within 30 pt of
  the top or bottom edge auto-scrolls.
- **Placement**: from the menu bar icon, the panel hangs from the icon's left
  edge flush under the menu bar, with square top corners. From the shortcut, it
  opens at the saved position, or centred 20 % down the screen; it can be
  dragged, and a drop within 300 pt of the centre snaps back.
- **Submenus**: child windows to the right of the parent (to the left when they
  do not fit), with 5 pt of material above and below the rows so the first row
  lines up with its parent row. Width is the widest row, at least 50 pt.
- **Details popover**: a system popover on the right edge of the row, 400 pt
  wide and up to 500 pt tall (it scrolls). Header: 32 pt tile, title, edit and
  star buttons, 14 pt side padding, 10 pt vertical. Fields: 14 pt side padding,
  5 pt vertical, at least 38 pt tall.
- **Generator**: a 412 × 300 pt child window, 14 pt side padding, 12 pt
  vertical, 12 pt between rows; the password well is 310 × 28 pt.
- **Detached windows**: Editor 450 × 560 pt and Preferences 440 × 600 pt are
  standard titled windows with grouped forms. Large Type is a borderless
  window at screen-saver level, sized to the password. Its largest size is
  the visible frame minus 48 pt in width and in height.
- **Spacing rhythm**: 4 · 5 · 8 · 10 · 12 · 14 · 20 · 24.
- **Menu bar mark**: 18 × 18 pt, square status item.

## Elevation & Depth

- The door and dial draw depth with gradients and 1 pt highlight lines.
- The menu, submenus and generator use the system menu material (a
  behind-window blur). This is the only blur besides the shadows below.
- The complete list of drawn shadows. Nothing else may have one:
  - dial: black 35 %, radius 3 (scaled with the dial: 1 at the 32 pt logo), y 1
  - top door while opening or closing: black 35 %, radius 6, y 1
  - engraved door text and the password row: white, radius 0, y 1 (a highlight
    line, not a blur)
- The panel, submenu windows and the popover use the system window shadow and
  the system popover chrome. Design.html draws stand-ins for preview only.

## Shapes

- Radii: 4 (Editor notes stroke), 5 (unlocked panel, submenus, generator window,
  generator well), 6 (door field row), 8 (locked panel), 14 (Large Type), 22 %
  (letter tiles: 3.5 pt on 16 pt), capsule (strength meter). The app icon uses
  the system squircle: ship full-bleed art and let macOS mask it.
- When the panel hangs from the menu bar icon, only its bottom corners are
  rounded.
- Circles: dial, OTP countdown pie.

## Components

- **Door field row** — white field with a 6 pt top shade, in a `#2B2B2B` 1 pt
  frame (radius 6), joined to door buttons (Touch ID on the left when
  available, unlock on the right) by `#3A3A3A` 1 pt splits. Buttons: normal and
  pressed gradients.
- **Dial** — rim, white ring, inner ring, face, hub, staggered key slot and two
  lugs. Unlock: the key turns 90° (0.35 s ease-in-out), 0.4 s later the doors
  part (0.3 s ease-in) while the dial fades and scales to 1.25, then the menu
  takes over. Lock runs it in reverse and hides the panel. A wrong password
  shakes the window (8 pt, three swings, 0.5 s) and then shows the error.
- **Header** — dial logo (opens Open / New Database), search field without
  chrome, gear (search scope, New Item, Lock, Preferences, databases, Quit).
  The separator shows only while the field is empty.
- **Menu row** — 16 pt icon, `menu-item` title (middle-truncated), optional
  " — username" for duplicate titles, optional arrow. States: normal; selected
  (flat `selection` fill, everything white). Activating an item flashes the
  selection off for 50 ms, back on, and acts 150 ms later. Entry rows show a letter tile, with an 8 pt
  `favorite` star badge on its bottom-right corner for favourites.
- **Submenu arrow** — `menu-arrow` grey triangle, white when the row is
  selected.
- **Group header** — 16 pt band, ink 3 % fill, ink 20 % lines above and below,
  `caption` upper case in `group-header-text`. Not selectable.
- **Separator** — 11 pt row with a 1 pt ink 25 % line at its middle.
- **Show N more** — `label-tertiary` text at x 42; selectable, replaces itself
  with the hidden rows.
- **No items found** — `label-disabled`, not selectable.
- **Hover timing** — a submenu or the generator opens 0.2 s after the pointer
  rests on its row; the first details popover since launch waits 0.7 s (and
  animates in), later ones open at once without animation. Moving towards an open submenu delays the change of
  selection by 0.2 s.
- **Details popover** — header (32 pt tile, `title`, edit pencil, pin, favourite
  star in `favorite` or `label-secondary`), then one field per value:
  username, password (+ strength), website, one-time password, custom fields,
  notes, tags. Pin opens that account in its own utility window and hides the
  menu. Each account has one window: pinning it again brings that window
  forward and leaves it where it is. A new window starts at the top-right of
  the current screen; each further window steps 28 pt down and left. The level
  matches a detached 1Password mini: main-menu level minus 2, so it stays above
  normal windows and under PasswordPie's menu, including after PasswordPie
  deactivates. Only its close button dismisses it. Command-W, Escape, clicking
  elsewhere, and copying or opening a field do not. Locking the vault, or
  trashing the account, does.
- **Detail field** — `label` over the value, 0.5 pt ink 10 % line on top.
  States: normal; focused (keyboard, `field-focus` tint); hover (a small
  button at the right. Clicking the word runs the field's primary action.
  Username, password, notes, one-time password and custom fields say "copy".
  A password adds an arrow: reveal / conceal and large type. A website says
  "open" and adds an arrow: copy, open and fill. Other fields have no arrow.
  The pinned window uses the same hover as the popover.); flashing
  (Return: the button shows at 40 % for 0.3 s, then the primary action runs.
  In the popover, copy and open hide the panel.) Masked secrets show 8 to 16
  bullets; holding Option or "reveal" shows them in `body-code`. The pinned
  window does not inherit a held Option, and that reveal clears when
  PasswordPie resigns active. An explicit reveal stays until conceal. URLs are
  `accent`; notes wrap up to 8 lines.
- **OTP field** — grouped code in `code-lg` `accent` with a 14 pt countdown pie
  (ring at 35 %); both turn `system-red` in the last 5 s.
- **Strength meter** — 5 pt capsule: ink 12 % track, fill in `system-red`,
  `system-orange` or `system-green` by strength, at least 6 pt wide.
- **Password Generator** — child window: password well (`code-md`, `well`,
  0.5 pt ink 25 % stroke, radius 5), Copy button with a menu (Copy, Save as
  Password Item), Characters / Words segmented control, slider rows (70 pt
  label, 24 pt value), "Avoid ambiguous characters" toggle or a separator
  picker, Regenerate Password and a system progress bar for strength. All
  controls are system controls in `control`.
- **Editor and Preferences** — standard windows with grouped forms and system
  controls; footnotes in `label` (`.caption`) `label-secondary`, the
  unregistered-shortcut warning in `danger`.
- **Large Type** — `display-code` on `large-type-bg`, radius 14, 24 pt
  padding. Characters stay in groups of 4 on alternating stripes. Nothing is
  inserted between groups. Letters, digits and other symbols use the three
  overlay inks above. A space in the password is ␣. Each character is as wide
  as its own glyph. The window sizes to the password and wraps whole groups.
  The largest window is the visible frame minus 48 pt in width and in height.
  The type starts at 54 pt and shrinks until the window fits. It closes on
  any key, when it loses focus, and when the vault locks.
- **Letter tile** — first letter in `tile-letter` white on the hashed hue
  gradient, radius 22 %, 0.5 pt `tile-stroke`.

## Do's and Don'ts

Do:

- Use the token names above in new code; add a token here before using a new
  colour. Existing `Palette.swift` names that differ are listed under Known Gaps.
- Use system semantic colours and materials in the menu, popover and generator
  so they follow light and dark.
- Keep secrets in SF Mono and keep labels small and grey.
- Keep the door light; let macOS tint the menu bar mark.

Don't:

- Don't use the brand graphite inside the panel or the door greys in the brand.
- Don't add a second accent colour; the system accent is selection, URLs, the
  OTP and the focused field only.
- Don't add shadows or blurs beyond the ones listed, or gradients outside the
  door, its buttons, the dial and the letter tiles.
- Don't add a separate keyhole badge in the brand; the brand mark is the
  shield.
- Don't use a web font, emoji or illustrations in the panel.

## Responsive Behavior

The unlocked panel sizes itself to its rows: width from the widest row (300 pt
to a quarter of the screen), height from the row count (capped by the screen,
then it scrolls). Resizes animate in 0.075 s. The locked panel is fixed at
300 × 280 pt (330 pt while creating). The menu, submenus, popover, generator,
Editor and Preferences follow the light and dark appearance; the door does
not. Dynamic Type is not supported; the menu bar mark follows the system tint
for light, dark and highlighted menu bars.

## Known Gaps

The front matter matches the code today. These are the places where the code
is inconsistent with itself or with the rules above. Each needs a code change
or a decision.

- **Door in dark mode**: the door and dial are light-only, while the menu that
  replaces them follows the appearance. In dark mode, unlocking goes from a
  light door to a dark menu. A dark door palette is not designed.
- **Two panel radii**: the locked panel is 8 (`PanelController.swift:152`), the
  unlocked panel and submenus are 5 (`PanelController.swift:138`,
  `MenuController.swift:316`). The corners change during the unlock animation.
- **Two reds**: errors on the door and in Preferences use `danger #C8372D`
  (`Palette.danger`); the urgent OTP and the weak strength meter use the system
  red (`DetailsView.swift:276`, `:293`).
- **Two strength meters**: the details popover draws its own red / orange /
  green capsule (`DetailsView.swift:257`); the generator uses a system
  `ProgressView` (`GeneratorView.swift:92`) tinted by the accent.
- **Palette names**: `Palette.swift` holds five colours, three named
  differently. `band` is `door-band`, `bandHighlight` is
  `door-band-highlight`, `bandLine` is `door-band-line`. Rename them when the
  file is next touched.
- **Literal colours**: 23 distinct hex values in `LockScreen.swift` and 11
  `NSColor` / `Color` float colours in `MenuListView.swift` and
  `DetailsView.swift` are not in `Palette.swift`. All have tokens here; move
  them into `Palette` (the favourite yellow alone is written three times:
  `MenuListView.swift:322`, `:350`, `DetailsView.swift:167`).
- **Engraved highlight alphas**: the white highlight under door text and the
  password row is 70 %, 60 % and 90 % (`LockScreen.swift:91`, `:105`, `:169`).
  Pick one.
- **Lock screen dial and header logo** still draw a keyhole badge
  (`LockScreen.swift:249`, `HeaderView.swift:74`); they could adopt the
  shield mark in a later change.
