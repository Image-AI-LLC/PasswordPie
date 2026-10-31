# PasswordPie icon concepts — BRIEF

PasswordPie is a tiny macOS menu-bar password manager (KeePass/KDBX vaults). We need a **safe / vault** themed
App icon plus a matching menu-bar (tray) icon. Several art directions are explored in parallel; **you only do
the one direction named in your task prompt**. Work only inside the directory `<LETTER>/` (create it).

## Deliverables for your direction (save exactly these files in `<LETTER>/`)

1. `tile.png` — App icon artwork, generated with your built-in `image_gen` tool.
   - Square, **full-bleed**: the background colour/material fills the whole canvas to all four edges.
     **No rounded corners, no outer border, no drop shadow around the tile, no transparent margin.**
     (We apply the exact macOS Big Sur squircle mask and shadow ourselves afterwards.)
   - Keep the main subject inside the central ~78% of the canvas so the rounded-corner mask never clips it.
   - Modern macOS app-icon quality (Big Sur and later): one clear centred subject, soft top-left light,
     gentle depth, crisp silhouette that still reads at 32 px. Not busy; few large shapes.
   - **Absolutely no text, letters, digits, numerals on dials, logos, or glyph-like marks.**
     Dial ticks are fine as plain short lines.
2. `menubar.svg` — the menu-bar icon, **written by you by hand as SVG code** (do not use image_gen for it).
   - `viewBox="0 0 18 18"`, `width="18" height="18"`. One colour: pure black `#000` fills/strokes only,
     transparent background. It will be used as a macOS *template image* (only alpha matters).
   - Same idea/silhouette as your App icon, simplified for 16–18 pt: solid silhouette with knocked-out
     details (use `fill-rule="evenodd"` or masks). Minimum feature/gap size 1.5 units. Snap edges to whole or
     half units so it is crisp at 1x (18 px) and 2x (36 px). Leave about 1 unit of padding on each side.
   - Check it: render with `/opt/homebrew/bin/rsvg-convert -w 18 menubar.svg -o menubar_18.png` and
     `-w 36 ... -o menubar_36.png`, look at the PNGs, and iterate until it is clearly recognisable as a safe at
     18 px. Keep both PNGs.
3. `NOTES.md` — 2–3 sentences: the concept, the palette (hex), and anything you'd tweak.

Generate `tile.png` once; if the first result breaks a rule above (text/letters, rounded corners, border,
subject clipped at the edge), regenerate once. Then do the SVG. Do not touch other directions' folders.

## Directions

- **A — Skeuomorphic steel safe door.** Front view of a heavy brushed-steel safe door with a large combination
  dial (plain tick marks, no numbers), a chunky three-spoke handle and two hinges on the left. Background:
  deep graphite-to-charcoal gradient. Palette: steel #C9CED6 / #8C939E, graphite #2A2E35, accent brass #C8A15A
  on the dial centre. Menu bar: rounded-square safe outline with a dial circle and a small handle.
- **B — Flat geometric safe cabinet.** Bold flat/semi-flat illustration: a squat front-facing safe cabinet built
  from simple geometric blocks, little feet, round dial on the right half, one lever. Background: saturated
  teal #0F766E with a subtle lighter radial highlight. Safe body warm off-white #F4EFE6, accents coral #F26B5B
  and ink #1F2937. Minimal shading (one soft shadow). Menu bar: filled safe body with a knocked-out dial ring.
- **C — Round bank-vault door.** Iconic circular vault door seen straight on: thick polished rim, ring of
  locking bolts around the edge, central spoke wheel (5–6 spokes). Background: midnight navy #0B1B3A to
  #1E3A8A gradient. Door in satin silver with a cool blue rim light; small gold hub #E2B44B.
  Menu bar: circle with bolt notches and a spoke wheel inside.
- **D — Shield-shaped vault with keyhole.** A rounded heraldic shield that is itself a thick vault door:
  bevelled metal edge, a classic keyhole cut-out in the centre glowing softly. Background: rich violet
  #4C1D95 to indigo #312E81. Shield in polished titanium with a faint violet reflection; keyhole glow
  #A78BFA. Menu bar: solid shield with knocked-out keyhole.
- **E — Minimal line-art safe.** Ultra-minimal: a safe drawn with a few thick, rounded, evenly weighted strokes
  (rounded-square body, circle dial, short handle line) glowing in a single gradient line from #34D399 to
  #22D3EE, on an almost-black #0B0F14 background with very soft vignette. Calm, premium, Apple-like.
  Menu bar: the same strokes, 1.5-unit line weight.
- **F — Soft 3D "mini" safe.** A cute, chunky, toy-like miniature safe in soft 3D (clay/matte plastic look),
  three-quarter view, rounded edges, big friendly dial, tiny feet. Background: warm sunrise gradient
  #FDBA74 to #F472B6. Safe body cream #FFF7ED with sky-blue #38BDF8 dial and door seam. Friendly but not
  childish. Menu bar: rounded safe silhouette (front view) with knocked-out dial and door seam.
