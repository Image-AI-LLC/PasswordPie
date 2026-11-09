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
  lock-card-height: 144
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
  paywall-width: 400
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
| `error` | `#AA3027` | `#FFA396` | Lock-screen errors, Preferences status errors and the shortcut hint, and a one-time code in its last 5 s. |

Lines and fills use `ink` (`MenuPalette.ink`): `#302A24` on light, `#FFF6E7` on dark,
at 3 % (group header fill), 20 % (group header lines) and 25 % (separators). The
details views use `Color.primary` at 10 % (dividers), 12 % (strength track) and
25 % (well stroke).

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

Entry rows show the site icon: bundled for the top 100 sites, otherwise the one the
browser extension handed over (see "Site icons without telling anyone" in
[UX.md](docs/UX.md)). The app never fetches icons. A letter tile stands in until one
arrives, and stays when none does. Extension icons are cached outside the database;
an option to save them into the KDBX as custom icons, so they sync, may come later.
The tile takes one of six hues (14°, 28°, 42°, 95°, 168°, 345°) from a stable FNV-1a
hash of the title. It runs from saturation 0.45 / brightness 0.95 to 0.7 / 0.78, with
a 0.5 pt black 25 % stroke and a white letter. Favorites get an 8 pt star badge:
`favorite`, or `on-selection` on a selected row.

An icon carries at most one mark, in its bottom-right corner. An account with anything synced from Chrome (direct
channel) shows a colour Chrome badge, 44 % of the 16 pt list icon and 38 % of the 32 pt details icon, with a 1 pt
(list) or 1.5 pt (details) ring in the colour of the row behind it: `surface`, or `selection` on a selected row. A
favorite shows only its star, where it has always been, and no badge. The badge is drawn, because the app icon's
padding leaves nothing readable at 7 pt. `[Chrome] updated …` on the `password` label and on previous passwords
describes one change, so it stays on favorites too.

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

- **Locked panel**: 300 pt wide and as tall as its content (281 pt for one field, 307 pt with
  Touch ID), corner radius 16, 20 pt horizontal inset. Stacked: 64 pt pie, wordmark, truncated
  database name with full name in help, one line of guidance. Inputs are 38 pt tall and the
  primary button 36 pt, both radius 9. Key-file and Touch ID actions have their own rows.
  An error replaces the guidance line in `error`, up to three lines, with the full message in
  help; no blank space is reserved for it. Open / New sit 14 pt under the last row.
- **Locked card**: shown while ⌘L locks the open menu. The menu's width, 144 pt tall, corner
  radius 16, hung from the menu's top-left corner. 46 pt pie 24 pt from the top, 14 pt gap,
  "Locked" in the wordmark face at 19 pt, 4 pt gap, database name in `caption`.
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
- **Generator**: a 412 × 300 pt child window; the password well is 28 pt tall, radius 5, and fills the row beside the button.
- **Detached windows**: Preferences is 560 × 800 pt (minimum height 480), About 440 pt wide,
  Editor 450 × 640 pt, the Premium window 400 pt wide. The warm surface runs under a transparent title
  bar. Preferences, About and the Premium window use radius 12 cards.
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
- **Unlock motion** — while a database opens, the form stays in place: the field, the Touch ID and
  key-file rows and Open / New dim to 55 % and 40 % and stop taking input, the button reads
  "Unlocking…", and the pie's rim spins (not with Reduce Motion). On success the pie pulses, then
  0.4 s later the form fades and scales to 0.97 over 0.3 s and the menu takes over. A wrong password
  shakes the window (8 pt, three swings, 0.5 s), then shows the error and selects the password.
- **Lock motion (⌘L)** — the locked card fades in over the menu while the panel folds to the card in
  0.2 s and its corners go from 5 to 16. At 0.22 s the pie settles and the padlock clicks. At 0.9 s
  the card lifts 6 pt and fades out over 0.3 s. The menu shortcut during the scene grows the card
  into the lock form.
- **Header** — pie (opens Open / New Database), search field without chrome, gear (search scope, New
  Item, Lock, Preferences, databases, Quit). The separator shows only while the field is empty.
- **Reopening** — within 10 seconds of closing, the menu comes back with its search (selected, so typing
  replaces it) and selected account. See "Pick up where you left off" in [docs/UX.md](docs/UX.md).
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
- **Details popover** — header, then one field per value: username, password (+ strength and previous passwords), website,
  one-time password, custom fields, notes, tags. Pin opens that account in its own utility window and
  hides the menu.
- **Pinned window** — one window per account; pinning again brings it forward and leaves it in place. A
  new window starts at the top-right of the screen; each further one steps 28 pt down and left. Its level
  is the main-menu level minus 2, so it stays above normal windows and under PasswordPie's menu, also after
  PasswordPie deactivates. It never takes focus, so the app underneath keeps the caret while a field is
  clicked. While one is open, Control-Command-C (username), Shift-Command-C (password) and Option-Command-C
  (one-time password) work in every app and copy from the top window; clicking a window brings it to the top.
  Only its close button dismisses it; clicking elsewhere and copying or opening a field do not. Locking the
  vault or trashing the account does.
- **Split action button** — `SplitActionButton`, the one control for an action with an optional menu. The
  word runs the action; the arrow, present only when there is more, opens a menu that never repeats the word.
  Radius 5. Quiet: `field-surface`, `text` label, `text-secondary` arrow, ink 25 % hairline and divider. Primary:
  `brand-accent`, `on-accent` label and arrow, `on-accent` 28 % divider, no outline. Hover adds ink 10 %, pressed
  ink 18 %. Compact is 20 pt tall in `caption` with a 20 pt arrow; regular is 28 pt in `control` with a 24 pt arrow.
- **Detail field** — `label` over the value, with a hairline on top. States: normal; focused (keyboard,
  `brand-accent` 20 % fill); hover (a compact quiet split action button at the right: "Copy" for most fields,
  "Open" for a website; a password's arrow adds Reveal / Conceal and Large Type, a website's adds Copy and
  Open and Fill); flashing (Return shows the button at 40 % for 0.3 s, then runs the
  primary action). In the popover, copy and open hide the panel. Masked secrets show 8 to 16 bullets; holding
  Option or Reveal shows them in `body-code`. The pinned window does not inherit a held Option, and that
  reveal clears when PasswordPie resigns active. An explicit reveal stays until conceal. Notes wrap to 8 lines.
- **Previous passwords** — direct channel. Below strength: a 28 pt row, `▸ previous passwords (2)`, in `caption`
  `text-secondary`, keeping its count when open, with `⋯` at the right once open. A row is two lines: `label` for the time
  (`updated Oct 20`, `date unknown`, then `· not used yet` for a value never saved, and the Chrome mark for a value from
  Chrome), and the value below. Two compact quiet split action buttons sit at the right and are always visible: Restore
  (Use for a value never saved) and Copy. Focused, they read `Restore ⌘↩` and `Copy ↩`, and neither is styled as the
  default. Clear Previous Passwords asks inline, because a modal would close the popover.
- **Chrome update failed** — below strength: the Chrome mark, `caption` `error` text and a compact quiet Try Again.
- **Chrome batch row** — 26 pt, under the search field, ink 3 % fill and an ink 25 % line under it: `caption`-sized `text`
  summary, `accent-text` Review and a `text-secondary` ×. It never takes the keyboard.
- **One-time code** — grouped code in `code-lg` `accent-text` with a 14 pt countdown pie; both turn `error`
  in the last 5 s.
- **Locked one-time code** — no Premium, on both channels (direct: on the signed-in account, or nobody signed in). A 11 pt `lock.fill` in `text-secondary` and "Included with
  Premium" in `body` `text-secondary`, with a compact primary split action button, Upgrade, always visible at the right.
  Return on the row runs Upgrade. The item's code is never computed.
- **Premium window** — both channels. 40 pt pie, `title`, one line of `body` `text-secondary`. App Store channel: no
  sign-in block and no account line; the status line, the plan cards, Restore Purchases and Manage Subscription.
  Direct channel: signed out, the sign-in block; signed in, the account line and Get Premium. It closes by itself when
  Premium arrives, unless it has something to say, such as an activation.
- **Sign-in block** (direct channel) — one `body` `text-secondary` line on what the account is for, then Sign in with Apple full width,
  32 pt high, radius 7, black with white type and the `applelogo` symbol (white with black type in dark mode), Apple's
  own look; under it the system button Other Ways to Sign In…. While the sheet is open the pressed one says "Waiting…"
  and both are disabled.
- **Account line** (direct channel) — `person.crop.circle` in `text-secondary`, the email in `body`, and a small Sign Out at the right;
  under it the Premium status in `body` medium with its detail in `caption` `text-secondary`.
- **Plan card** — radius 12 on `field-surface` with an ink 7 % hairline: the plan name from Apple in `body` medium, one
  `caption` line, and a regular split action button at the right: primary for the one-time plan, quiet for the subscription,
  so the surface keeps one main action. The button shows the price from Apple, and no price is ever written in the code. While
  buying it says "Waiting…"; an owned plan shows "Owned" in `text-secondary`.
- **Premium section** (App Store channel) — first in Preferences: the status line, then the plans as rows.
- **Account section** (direct channel) — first in Preferences. The sign-in block, or the account line with the plans
  divided by hairlines and the same actions and terms (direct: Get Premium, Redeem a Key, Check Again). Errors use `error`; waiting, cancelled and restored use
  `text-secondary`. Orange is never a status.
- **Strength meter** — 5 pt capsule on a 12 % track, at least 6 pt wide: `strength-weak` below 0.4,
  `strength-medium` below 0.7, otherwise `strength-strong`.
- **Password Generator** — password well (`code-md`), a regular primary split action button (Copy, with Save as
  Password Item in its arrow), Characters / Words segmented control, slider rows (70 pt label, 24 pt value), "Avoid
  ambiguous characters" or a separator picker, Regenerate Password and a system progress bar for strength. The
  split button is ours; the rest are system controls.
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

The unlocked panel sizes itself to its rows, and resizes animate in 0.075 s. The locked panel sizes itself to its
form, and the locked card is always 144 pt tall. Every surface follows light and dark. Dynamic Type is not supported.

## Known gaps

- **Two panel radii**: the locked panel is 16 and the unlocked panel 5, so corners change during unlock.
- **Two reds**: `error` and `strength-weak` are close but separate.
- **Two strength meters**: details draws its own capsule; the generator uses a system `ProgressView`.
- **Shortcut recorder well** still uses the system text background (`PreferencesView.swift`).
