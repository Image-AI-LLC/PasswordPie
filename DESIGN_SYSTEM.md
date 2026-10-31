# Password Pie design system

## Direction

Warm, flat and compact. The keyhole pie is the brand mark; the former silver shield,
metal seams, inset shadows and vault-door metaphor are retired on the locked panel.
Keep native macOS behavior: secure input, keyboard focus, menu selection, dialogs,
biometrics and appearance changes must remain platform-native.

## Implementation status

- **Shared:** the orange brand token is used by the lock screen, Preferences mark and app/header mark family.
- **Implemented first:** the lock form uses the semantic light/dark palette and flat input/button treatment.
- **Unchanged:** unlocked menu, details and Preferences layout remain native. This is not a claim that every screen has been rethemed.
- **Source of truth:** `Sources/PasswordPieApp/Palette.swift`; selected logo geometry in `art/source/mark.svg`.

## Color roles

| Role | Light | Dark | Usage |
|---|---|---|---|
| Brand accent | `#EE8C32` | `#EE8C32` | Pie mark and primary action; not every control. |
| On accent | `#302315` | `#302315` | Primary action label. |
| Surface | `#FFF6E7` | `#28231F` | Locked panel background. |
| Text | `#302A24` | `#FFF6E7` | Heading and primary content. |
| Secondary text | `#70604F` | `#D4C4B2` | Database label, guidance, secondary actions. |
| Field surface | `#FFFFFF` | `#37302A` | Native secure-input container. |
| Border | `#C8BBAA` | `#776858` | Quiet outlines and dividers. |
| Focus | `#A65312` | `#F6B469` | Active secure-field outline. |
| Error | `#AA3027` | `#FFA396` | Error messages; never use orange to mean failure. |

The primary button uses dark text on orange. Native secure-field text and placeholder
use semantic colors; the caret keeps system appearance behavior. Focus has a distinct accent outline rather than
relying on the insertion cursor alone. Template menu-bar icons stay monochrome;
macOS owns their light, dark and selected tints.

## Components and layout

- Locked panel: 300 pt wide; 360 pt tall, or 410 pt for database creation.
- Outer corners: 16 pt. Form controls: 9 pt corners, 38 pt input height, 36 pt primary button height.
- Horizontal content inset: 20 pt. Layout is stacked; key-file and Touch ID actions have their own rows.
- Header: flat pie, `Password Pie`, truncated middle database name with full-name help, one-line guidance.
- Existing database: one secure field and `Unlock`.
- Creation: two secure fields and `Create Database`; Return moves from the first field to confirmation, then submits.
- Errors reserve space for up to three lines; help exposes the full message. Bottom Open/New actions remain visible.
- Never disable Unlock just because the password is empty: a KeePass 1 key file may be sufficient.
- Motion: gentle brand pulse and a 0.3 s content fade/scale. Existing controller timing is retained; no splitting metal doors.

## Evidence

`art/lock-screen/` contains the ImageGen design reference and real native screenshots.
The generated image is design input only; no screenshot or generated bitmap is used
as an interactive UI background. The delivered form is SwiftUI and NSSecureTextField.
