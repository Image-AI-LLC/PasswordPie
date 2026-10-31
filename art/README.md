# Password Pie icon art

The selected brand is **B / Keyhole pie**: a flat orange (`#EE8C32`) scalloped pie
with a transparent keyhole. The app tile uses a warm cream (`#FFF6E7`) background.
The visible pie fills 84.2% of the app tile, matching the selected mark's proportions.
No baked-food texture, bevel, gradient or shadow is part of the brand artwork.

## Canonical assets

| Path | Purpose |
|---|---|
| `source/icon.svg` | Editable 1024×1024 full-bleed app tile, without pre-rounded corners. |
| `source/mark.svg` | Transparent 24×24 vector master; `currentColor`, even-odd keyhole. |
| `source/menubar.svg` | Same geometry in an 18×18 template image. |
| `../Sources/PasswordPieApp/MenuBarIcon.swift` | Native AppKit equivalent, 24-unit geometry scaled to 18 pt. |
| `../Sources/PasswordPieApp/BrandMark.swift` | Shared SwiftUI pie: flat orange for lock/Preferences, monochrome for the header. |
| `../Assets/AppIcon.icon/Assets/tile.png` | Raster export of `source/icon.svg`, consumed by Icon Composer. |
| `../Assets/AppIcon.icon/icon.json` | Icon Composer source, with matching cream fill. |
| `../Assets/Assets.car`, `../Assets/AppIcon.icns` | Compiled macOS 26+ assets and older macOS fallback. |

The user selected B from three ImageGen flat concepts, then approved increasing
the app mark from 60.6% to 84.2% of the canvas width. The SVG is the manually refined
vector master, not a bitmap embedded in an SVG. Menu bar and mark geometry were
not enlarged independently; the app tile now uses their original canvas proportions.

## Rebuild

Requires Xcode and `rsvg-convert` (`brew install librsvg`).

```sh
# SVG -> full-bleed tile PNG -> Assets.car and AppIcon.icns
make icon

# Build and install the app, using the committed compiled icon resources
make install

# Render the actual native menu-bar path at 1x and 2x
mkdir -p /tmp/passwordpie-icon
swiftc -parse-as-library art/tools/render_menubar.swift Sources/PasswordPieApp/MenuBarIcon.swift -o /tmp/render_menubar
/tmp/render_menubar /tmp/passwordpie-icon
```

The app tile must remain full-bleed with no pre-rounded corners: macOS applies
its own mask. The old 824 px Big Sur grid can produce a grey frame on macOS 26+.
The menu bar image must remain a transparent template (`isTemplate = true`), so
macOS supplies the correct light, dark and selected tint.

## Historical artwork

`source/shield-tile-codex.png`, `source/shield-mark.png`, `briefs/round*.md` and the
old raster-composition tools are retained as historical provenance, not production
inputs. Earlier screenshots under `icons/` and `preferences/` document the old
shield UI and are not current visual acceptance evidence.
