# PasswordPie icon concepts — BRIEF (round 2)

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

## Round-2 goal (read carefully)

Round 1 feedback from the owner: the **shield + keyhole** concept won because it is *simple and symbolic*; the
detailed safes (steel door, cabinet, vault wheel, toy safe) felt illustrative rather than iconic. The owner wants
an **iconic mark**: one bold, instantly readable symbol, at most 2–3 shapes, recognisable as a silhouette in
solid black. It must **not** be a plain circle with a keyhole slot inside — avoid a
plain circle-with-keyhole and avoid blue (#0572EC-like) backgrounds.

Shared style for all round-2 tiles: a single centred symbol rendered in a refined, lightly dimensional material
(satin metal or soft enamel, subtle bevel, one soft highlight) on a rich two-tone gradient background. Big,
simple, confident; generous negative space; no small decoration, no rivets, no scenery.

## Directions

- **G — Shield keyhole, refined.** Evolution of the winner: a wide, softly rounded shield in satin titanium
  with a deep bevel; the keyhole is cut *through* the shield so the background gradient shows inside it
  (no glow). Background: deep plum #3B0764 to violet #6D28D9. Menu bar: solid shield, knocked-out keyhole —
  make the keyhole classic (round top + flared tapered slot), large enough to read at 18 px.
- **H — Combination dial.** The universal sign of a safe reduced to one object: a thick combination-dial ring
  (plain tick marks around it, a few longer ones, no numbers) with a single wedge-shaped index notch at the top
  and a solid knurled centre knob. Satin graphite-and-brass material. Background: warm charcoal #1C1917 to
  bronze #78350F. Menu bar: ring with 8 short tick notches cut into it and a solid centre dot plus a top pointer.
- **I — Dial padlock.** A padlock whose body is a squat rounded square with a combination dial on its face
  (dial = circle with a pointer notch). Thick rounded shackle. Polished silver with a deep emerald tone.
  Background: emerald #064E3B to teal #0F766E. Menu bar: solid padlock silhouette, dial knocked out as a ring.
- **J — Vault door with keyhole.** A square-ish safe door seen front-on as a simple emblem: thick rounded-square
  plate with two short hinge bars sticking out on the left edge and a classic keyhole in the centre. No dial,
  no handle, no rivets. Soft enamel in warm red-orange #EA580C on a dark ink #111827 to #1F2937 background.
  Menu bar: solid rounded square + two hinge tabs on the left + knocked-out keyhole.
- **K — Masked-password shield.** A password manager's own symbol: a rounded shield (or rounded-square badge)
  containing a horizontal row of three bold masked-password dots, like a hidden password field. Satin white
  badge, dots in deep ink; background: amber #F59E0B to orange #EA580C. Menu bar: solid shield with three
  knocked-out round dots in a row (each dot ≥ 2.5 units).
