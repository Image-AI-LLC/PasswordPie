---
version: 2
name: PasswordPie
description: >-
  A warm, flat password menu in the menu bar. The keyhole pie is the only brand
  object. Locked, the panel is a compact cream or warm-dark form. Unlocked, the
  same surfaces carry a native-feeling menu: 14 pt rows, cascading submenu
  windows and a details popover beside the selected item.
source-of-truth: >-
  Colours in code live in Sources/PasswordPieApp/Palette.swift (Palette for
  SwiftUI, MenuPalette for AppKit). Mark geometry lives in art/source/mark.svg.
  Change this file and the code together.

colors:
  # Brand and selection. Same in both appearances.
  brand-accent: '#EE8C32'
  on-accent: '#302315'
  selection: '#EE8C32'
  on-selection: '#302315'
  # Roles with a light and a dark value.
  surface: '#FFF6E7'
  surface-dark: '#28231F'
  field-surface: '#FFFFFF'
  field-surface-dark: '#37302A'
  text: '#302A24'
  text-dark: '#FFF6E7'
  text-secondary: '#70604F'
  text-secondary-dark: '#D4C4B2'
  text-tertiary: '#8F7F6E'
  text-tertiary-dark: '#A39585'
  text-disabled: '#8F7F6E'
  text-disabled-dark: '#8F8172'
  border: '#C8BBAA'
  border-dark: '#776858'
  focus: '#A65312'
  focus-dark: '#F6B469'
  accent-text: '#A65312'
  accent-text-dark: '#F6B469'
  caret: '#A65312'
  caret-dark: '#F6B469'
  text-selection: '#F6C993'
  text-selection-dark: '#7A4E22'
  menu-arrow: '#A89A8A'
  menu-arrow-dark: '#94877A'
  # Errors. Never use orange to mean failure.
  error: '#AA3027'
  error-dark: '#FFA396'
  danger: '#C8372D'
  # Password strength.
  strength-weak: '#D6453A'
  strength-medium: '#E3B505'
  strength-strong: '#4C9F5B'
  # Item icons.
  favorite: '#F4B400'
  tint-folder: '#D18A32'
  tint-folder-dark: '#E2A052'
  tint-tag: '#6F9A58'
  tint-tag-dark: '#8DB877'
  tint-neutral: '#8B7A69'
  tint-neutral-dark: '#B3A493'
  tint-note: '#D9A520'
  tint-note-dark: '#E8BC4C'
  tint-identity: '#B8694A'
  tint-identity-dark: '#D48A6B'
  # Large Type, always on its dark panel.
  large-type-letter: '#FFF6E7'
  large-type-digit: '#FFAD5C'
  large-type-symbol: '#8CD6C3'

typography:
  # SF Pro and SF Mono are the macOS system fonts. The app never sets tracking or
  # line spacing, except the rounded lock-screen wordmark.
  wordmark: { family: 'SF Pro Rounded', size: 22, weight: 700 }
  display-code: { family: 'SF Mono', size: 54, weight: 500 }
  search: { family: 'SF Pro', size: 18, weight: 400 }
  code-lg: { family: 'SF Mono', size: 17, weight: 500 }
  title: { family: 'SF Pro', size: 16, weight: 600 }
  menu-item: { family: 'SF Pro', size: 14, weight: 400 }
  code-md: { family: 'SF Mono', size: 14, weight: 400 }
  body: { family: 'SF Pro', size: 13, weight: 400 }
  body-code: { family: 'SF Mono', size: 13, weight: 400 }
  control: { family: 'SF Pro', size: 12, weight: 400 }
  caption: { family: 'SF Pro', size: 11, weight: 400 }
  label: { family: 'SF Pro', size: 10, weight: 400 }
  tile-letter: { family: 'SF Pro', size: 9.5, weight: 600 }

rounded:
  panel-locked: 16
  control-locked: 9
  menu: 5
  card: 12
  well: 5
  large-type: 14
  large-type-stripe: 8
  item-icon: 3.5

spacing:
  panel-width: 300
  locked-height: 360
  create-height: 410
  header-height: 45
  logo-size: 32
  row-height: 21
  separator-height: 11
  group-header-height: 16
  details-width: 400
  details-max-height: 500
  generator-width: 412
  generator-height: 300
  preferences-width: 560
  preferences-height: 800
  about-width: 440
  editor-width: 450
  editor-height: 640
  menu-bar-icon: 18
---

# PasswordPie design

PasswordPie is a KeePass (KDBX) password manager that lives in the macOS menu bar.
This is the one design document. The front matter lists the tokens; the sections
below say where they go and how the interface behaves.

## Direction

- **Warm, flat and compact.** Cream and warm charcoal surfaces, one orange accent,
  hairlines. No metal, seams, bevels or vault-door metaphor.
- **One brand object.** The keyhole pie: a flat orange scalloped pie with a
  transparent keyhole. No baked-food texture, gradient or shadow.
- **A menu, not a window.** Rows are 21 pt, text is 14 pt, selection is a flat
  full-width fill, and the keyboard stays in the search field.
- **Native behavior, brand colors.** Secure input, keyboard focus, dialogs,
  biometrics and appearance changes stay platform-native. Layout and controls stay
  native; only their colors change. PasswordPie follows light and dark.

## Colors

All values are sRGB.

| Role | Light | Dark | Use |
|---|---|---|---|
| `brand-accent` | `#EE8C32` | same | Pie mark, primary action, toggles and control tint. Not for text. |
| `on-accent` | `#302315` | same | Label on the primary action. |
| `selection` / `on-selection` | `#EE8C32` / `#302315` | same | Selected row, and its text, icon, arrow and favorite badge. White fails contrast on this orange. |
| `surface` | `#FFF6E7` | `#28231F` | Lock screen, panel, submenus, details, generator, Preferences, About, editor, pinned windows. |
| `field-surface` | `#FFFFFF` | `#37302A` | Inputs, cards, generator well. |
| `text` | `#302A24` | `#FFF6E7` | Headings, row titles, search text. |
| `text-secondary` | `#70604F` | `#D4C4B2` | Placeholder, gear, " — username", guidance, group headers. |
| `text-tertiary` | `#8F7F6E` | `#A39585` | "Show N more" rows. |
| `text-disabled` | `#8F7F6E` | `#8F8172` | "No items found". |
| `border` | `#C8BBAA` | `#776858` | Quiet outlines on the lock screen. |
| `focus` | `#A65312` | `#F6B469` | Active field outline, shortcut recorder outline. |
| `accent-text` | `#A65312` | `#F6B469` | Links, website values, one-time codes, shortcut prompt. |
| `caret` / `text-selection` | `#A65312` / `#F6C993` | `#F6B469` / `#7A4E22` | Search and master-password fields. |
| `menu-arrow` | `#A89A8A` | `#94877A` | Submenu triangle. |
| `error` | `#AA3027` | `#FFA396` | Lock-screen errors, and a one-time code in its last 5 s. |
| `danger` | `#C8372D` | same | Status errors in Preferences. |

Lines and fills use `ink` (`MenuPalette.ink`): `#302A24` on light, `#FFF6E7` on dark,
at 3 % (group header fill), 20 % (group header lines) and 25 % (separators). The
details views use `Color.primary` at 10 % (dividers), 12 % (strength track) and
25–28 % (well and button strokes).

Rules:

- **Never use the system accent.** No `Color.accentColor` or system selection colors:
  a Mac set to a blue accent would bring blue back. `ThemePaletteTests` enforces this.
- **Tint system controls explicitly** with `.tint(Palette.brandAccent)`. A default-action
  button ignores tint, so it uses `BrandPrimaryButtonStyle`: `on-accent` text on `brand-accent`.
- **Orange is never a status.** Medium password strength is `strength-medium` yellow,
  and failure is red.
- **The menu-bar icon stays a monochrome template.** macOS owns its tints.

### Item icons

Rows that open a submenu show a 13 pt SF Symbol; on a selected row it uses
`on-selection`. Tints are in the front matter: `favorite` for `star.fill`,
`tint-folder` for `folder.fill`, `tint-tag` for `tag.fill`, `tint-note` for
`note.text`, `tint-identity` for `person.crop.rectangle.fill`, and `tint-neutral` for
`lock.square.fill`, `creditcard.fill`, `doc.fill` and `key.fill`.

Entry rows show the site favicon. A letter tile stands in until it arrives, and stays
when none does. The tile takes one of six hues (14°, 28°, 42°, 95°, 168°, 345°) from a
stable FNV-1a hash of the title. It runs from saturation 0.45 / brightness 0.95 to
0.7 / 0.78, with a 0.5 pt black 25 % stroke and a white letter. Favorites get an 8 pt
star badge: `favorite`, or `on-selection` on a selected row.

### Large Type

Black 88 % panel. Letters, digits and symbols use the three `large-type-*` inks, so
digits and symbols stay distinct at a glance. Stripes alternate white 18 % and 9 %. A
real space is drawn as ␣ at white 55 %.

## Typography

One family pair: **SF Pro** (system) and **SF Mono**. Never ship a web font in the
app. Size is the hierarchy.

| Token | Family | Size | Weight | Use |
|---|---|---|---|---|
| `wordmark` | SF Pro Rounded | 22 | 700 | "Password Pie" on the lock screen |
| `display-code` | SF Mono | 54 | 500 | Large Type (starts at 54 pt, shrinks to fit) |
| `search` | SF Pro | 18 | 400 | Header search field and placeholder |
| `code-lg` | SF Mono | 17 | 500 | Live one-time code |
| `title` | SF Pro | 16 | 600 | Details title |
| `menu-item` | SF Pro | 14 | 400 | Menu rows, " — username" |
| `code-md` | SF Mono | 14 | 400 | Generated password |
| `body` | SF Pro | 13 | 400 | Details values, masked dots, editor and Preferences text |
| `body-code` | SF Mono | 13 | 400 | Revealed secrets |
| `control` | SF Pro | 12 | 400 | Generator labels and controls |
| `caption` | SF Pro | 11 | 400 | Lock-screen guidance, search group headers (upper case) |
| `label` | SF Pro | 10 | 400 | Details field labels, lock-screen errors |
| `tile-letter` | SF Pro | 9.5 | 600 | Letter on a 16 pt tile |

- Secrets (revealed passwords, one-time codes, generated strings) are SF Mono. Masked
  secrets are bullets in `body`.
- Built-in details labels are lower case ("username", "one-time password"); menu labels
  are title case. Search group headers are the only upper-case text.
- Readable copy is at least 10 pt. The 9.5 pt tile letter is an icon label.
- SF Symbols are 13 pt in rows, 8 pt for the favorite badge, 13 pt (edit, pin) and 15 pt
  (star) in details, and 16 pt for the gear. The submenu arrow is a drawn 8.5 × 10 pt
  triangle.

### CJK (简体中文)

The UI is English today. When strings are localized, CJK uses the system cascade with
PingFang SC and no bundled font: same size as Latin, line height +0.1, no letter-spacing,
no synthesized bold or italic, at least 10 pt. The wordmark stays Latin. Search group
headers are upper-cased in code; CJK has no case, so they show as written.

## Layout

- **Locked panel**: 300 × 360 pt (410 while creating a database), corner radius 16,
  20 pt horizontal inset. Stacked: 64 pt pie, wordmark, truncated database name with full
  name in help, one line of guidance. Inputs are 38 pt tall and the primary button 36 pt,
  both radius 9. Key-file and Touch ID actions have their own rows. Errors reserve up to
  three lines, with the full message in help. Open / New stay visible at the bottom.
- **Unlocked panel**: corner radius 5. Header 45 pt (a 40 pt bar and a 5 pt band whose 1 pt
  line sits at y = 40): 32 pt pie at (4, 4), search field at x 38, 24 pt tall, gear
  30 × 30 pt at the right edge minus 34. Below it the menu list, at least 24 pt tall.
- **Menu rows**: item 21 pt, separator 11 pt, group header 16 pt. Icon 16 pt at x 16, title
  at x 38, arrow slot 16 pt, 26 pt from the right edge. Group header text at x 6; "Show N
  more" at x 42.
- **Width**: the widest row, at least 300 pt, at most a quarter of the screen. It never
  shrinks while the panel is open.
- **Height**: header + rows, inside the visible frame inset 8 pt on the left, right and
  bottom. Longer lists scroll; hovering within 30 pt of the top or bottom auto-scrolls.
- **Placement**: from the menu bar icon, the panel hangs from the icon's left edge flush
  under the menu bar, with square top corners. From the shortcut, it opens at the saved
  position, or centered 20 % down the screen; it can be dragged, and a drop within 300 pt of
  the center snaps back.
- **Submenus**: child windows to the right of the parent (left when they do not fit), with
  5 pt above and below the rows so the first row lines up with its parent. Radius 5.
- **Details popover**: a system popover on the right edge of the row, 400 pt wide, up to
  500 pt tall (it scrolls). The warm surface fills the popover frame, arrow included. Header:
  32 pt tile, title, edit, pin and star, 14 pt side padding, 10 pt vertical. Fields: 14 pt side
  padding, 5 pt vertical, at least 38 pt tall.
- **Generator**: a 412 × 300 pt child window; the password well is 310 × 28 pt, radius 5.
- **Detached windows**: Preferences is 560 × 800 pt (minimum height 480), About 440 pt wide,
  Editor 450 × 640 pt. The warm surface runs under a transparent title bar. Preferences and
  About use radius 12 cards.
- **Large Type**: a borderless window at screen-saver level, sized to the password. Its largest
  size is the visible frame minus 48 pt in width and height.
- **Spacing rhythm**: 4 · 5 · 8 · 10 · 12 · 14 · 20 · 24. **Menu bar mark**: 18 × 18 pt.

## Depth and shape

- Surfaces are opaque and flat. No drawn shadows and no blur besides system window and
  popover chrome.
- The only gradients are on letter tiles. Generated bitmaps are never interactive backgrounds.
- When the panel hangs from the menu bar icon, only its bottom corners are rounded.
- The app icon is a full-bleed cream tile with the pie at 84.2 % of its width; macOS applies
  the mask. See `art/README.md`.

## Components

- **Lock form** — one secure field and Unlock, or two fields and Create Database. Return moves
  from the first field to confirmation, then submits. Never disable Unlock just because the
  password is empty: a key file may be sufficient.
- **Unlock and lock motion** — the pie pulses, then 0.4 s later the form fades and scales to 0.97
  over 0.3 s and the menu takes over. Locking runs in reverse and hides the panel. While a database
  opens, the pie's rim spins (not with Reduce Motion). A wrong password shakes the window (8 pt, three
  swings, 0.5 s), then shows the error and selects the password.
- **Header** — pie (opens Open / New Database), search field without chrome, gear (search scope, New
  Item, Lock, Preferences, databases, Quit). The separator shows only while the field is empty.
- **Menu row** — icon, `menu-item` title (middle-truncated), optional " — username" for duplicate
  titles, optional arrow. Selected is a flat `selection` fill. Activating an item flashes the selection
  off for 50 ms, back on, and acts 150 ms later.
- **Group header** — 16 pt band, ink 3 % fill, ink 20 % lines above and below, `caption` upper case.
  Not selectable.
- **Separator** — 11 pt row with a 1 pt ink 25 % line at its middle.
- **Show N more** — selectable; replaces itself with the hidden rows.
- **Hover timing** — a submenu or the generator opens 0.2 s after the pointer rests on its row. The first
  details popover since launch waits 0.7 s and animates in; later ones open at once. Moving towards an
  open submenu delays the change of selection by 0.2 s.
- **Details popover** — header, then one field per value: username, password (+ strength), website,
  one-time password, custom fields, notes, tags. Pin opens that account in its own utility window and
  hides the menu.
- **Pinned window** — one window per account; pinning again brings it forward and leaves it in place. A
  new window starts at the top-right of the screen; each further one steps 28 pt down and left. Its level
  is the main-menu level minus 2, so it stays above normal windows and under PasswordPie's menu, also after
  PasswordPie deactivates. Only its close button dismisses it; Command-W, Escape, clicking elsewhere and
  copying or opening a field do not. Locking the vault or trashing the account does.
- **Detail field** — `label` over the value, with a hairline on top. States: normal; focused (keyboard,
  `brand-accent` 20 % fill); hover (a small button at the right whose word runs the primary action:
  "copy" for most fields, "open" for a website; a password's arrow adds reveal / conceal and large type, a
  website's adds copy, open and fill); flashing (Return shows the button at 40 % for 0.3 s, then runs the
  primary action). In the popover, copy and open hide the panel. Masked secrets show 8 to 16 bullets; holding
  Option or "reveal" shows them in `body-code`. The pinned window does not inherit a held Option, and that
  reveal clears when PasswordPie resigns active. An explicit reveal stays until conceal. Notes wrap to 8 lines.
- **One-time code** — grouped code in `code-lg` `accent-text` with a 14 pt countdown pie; both turn `error`
  in the last 5 s.
- **Strength meter** — 5 pt capsule on a 12 % track, at least 6 pt wide: `strength-weak` below 0.4,
  `strength-medium` below 0.7, otherwise `strength-strong`.
- **Password Generator** — password well (`code-md`), Copy with a menu (Copy, Save as Password Item),
  Characters / Words segmented control, slider rows (70 pt label, 24 pt value), "Avoid ambiguous characters"
  or a separator picker, Regenerate Password and a system progress bar for strength. All system controls.
- **Large Type** — `display-code`, radius 14, 24 pt padding. Characters stay in groups of 4 on alternating
  stripes, with nothing inserted between groups. The window wraps whole groups. It closes on any key, when it
  loses focus, and when the vault locks.

## Do's and don'ts

Do:

- Add a token here and in `Palette.swift` before using a new color.
- Check contrast: at least 4.5:1 for text.
- Keep secrets in SF Mono and labels small.

Don't:

- Don't bring back the silver shield, metal seams, door or dial.
- Don't use blue as an accent, or look like 1Password (circle with keyhole, blue).
- Don't add a second accent color. Don't use `brand-accent` as text on cream.
- Don't add shadows, blurs or gradients beyond the ones listed.
- Don't use a web font, emoji or illustrations in the panel.

## Responsive behavior

The unlocked panel sizes itself to its rows, and resizes animate in 0.075 s. The locked panel has its two fixed
heights. Every surface follows light and dark. Dynamic Type is not supported.

## Known gaps

- **Two panel radii**: the locked panel is 16 and the unlocked panel 5, so corners change during unlock.
- **Three reds**: `error`, `danger` and `strength-weak` are close but separate.
- **Two strength meters**: details draws its own capsule; the generator uses a system `ProgressView`.
- **Shortcut recorder well** still uses the system text background (`PreferencesView.swift`).
