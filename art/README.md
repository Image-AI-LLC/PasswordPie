# PasswordPie icon art

The app icon is a satin-metal shield with a keyhole cut through it, on a graphite background
(round 5, option X6). The menu bar icon is the same shield as a one-colour template image.

## Files

| Path | What it is |
|---|---|
| `source/shield-tile-codex.png` | Original artwork from Codex `image_gen` (round 2, option G, purple background). |
| `source/shield-mark.png` | The shield lifted off that background, transparent, pixels unchanged. |
| `source/menubar.svg` | Menu bar icon, hand-written SVG by Codex (18×18). `Sources/PasswordPieApp/MenuBarIcon.swift` traces it. |
| `briefs/` | The Codex briefs for rounds 1–3. Rounds 4–5 only changed the background and size with the tools below. |
| `tools/` | The scripts below. |

The app icon itself lives in `Assets/`:

| Path | What it is |
|---|---|
| `Assets/AppIcon.icon/` | Icon Composer source. `Assets/tile.png` is the full-bleed 1024 px artwork (no rounded corners); the system applies the squircle mask. |
| `Assets/Assets.car`, `Assets/AppIcon.icns` | Compiled by `make icon` (Xcode `actool`). macOS 26+ reads `Assets.car`; older macOS falls back to the `.icns`. `make install` copies both. |

Why full-bleed: macOS 26 and later shrink an `.icns` drawn on the old Big Sur grid (824 px tile with a
transparent margin) into a grey rounded square. A full-bleed square compiled from an `.icon` is masked by the
system and shows no grey frame.

## Rebuild

```bash
# 1. Lift the shield off the Codex tile (only needed if the tile changes)
python3 art/tools/extract_mark.py art/source/shield-tile-codex.png art/source/shield-mark.png

# 2. Put it on the graphite background at 1.3x and save the full-bleed 1024 px artwork
mkdir -p /tmp/passwordpie-icon
python3 art/tools/compose_tile.py art/source/shield-mark.png /tmp/passwordpie-icon/tile.png '#3A3F46' '#15181B' 0.5 1.3
python3 -c "from PIL import Image; Image.open('/tmp/passwordpie-icon/tile.png').convert('RGBA').resize((1024, 1024), Image.LANCZOS).save('Assets/AppIcon.icon/Assets/tile.png')"

# 3. Compile Assets.car + AppIcon.icns (needs Xcode)
make icon

# Optional: previews on the old Big Sur grid, the Dock and the menu bar (used for the concept pages).
# Needs rsvg-convert (brew install librsvg) for the menu bar SVG.
cp art/source/menubar.svg /tmp/passwordpie-icon/
python3 art/tools/make_icon.py /tmp/passwordpie-icon

# Check the real menu bar icon code offline (black-on-transparent PNGs at 1x and 2x)
swiftc -parse-as-library art/tools/render_menubar.swift Sources/PasswordPieApp/MenuBarIcon.swift -o /tmp/render_menubar
/tmp/render_menubar /tmp/passwordpie-icon
```

Steps 1–2 reproduce the committed PNGs byte for byte. The concept rounds and their comparison pages are not
kept in the repo; only the chosen artwork and the tools are.
