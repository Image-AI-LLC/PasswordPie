# Manual app linking & quiet refusals

Design board for adding manual app linking (`+`) to account details, making per-account removals completely silent, and stopping automatic app linking at the app level after 3 distinct accounts are undone in the same app (e.g. AI agents, terminals, or chat apps).

## Files

- `app-link-manual.svg` / `app-link-manual.png` — final design board (`board5.py` with approved `+ Add app` unified copy, following Round 4's **6.5/10** blind critique by Claude Fable; see `scores.md`).
- `source/board1.py` .. `source/board5.py` — per-round SVG generators.

## Final UI / UX Spec

1. **Account details header (fixed 60 pt height across all states)**
   - **Empty state (0 linked apps):** `+ Add app` button on the second line under the title (18 pt tall, rx 5, `ink 25%` stroke, symmetric 8 pt padding, tooltip `"Show this account first in an app"`). No vertical jump when the first app is added or the last app is removed.
   - **Linked state (1+ apps):** `Shown first in` followed by shipped `LinkedAppToken` chips (`icon + name + ×`, capped at a max chip width with tail truncation + full-name tooltip), then a chip-adjacent `+` pill (24×18 pt visual, ≥24×24 pt hit target).
   - **Overflow state:** When linked apps exceed the header row width, remaining apps collapse into an interactive `N more ⌄` pill (no `+` sign, avoiding ambiguity with the adjacent `+` button). Clicking `N more ⌄` opens a warm-surface popover (`Shown first in`) listing every linked app with a direct `×` remove action per row.

2. **Manual picker popover (`+ Add app` / `+`)**
   - Opens as a warm-surface popover anchored below the trigger; **the account details stay open**.
   - **Order:** Active frontmost app at top (with `Active app` tag, if linkable and not already added) → divider → `Running apps` (sentence case, omitting browsers, PasswordPie, and already-added apps; any app previously removed from this account shows a quiet `Removed earlier` tag and can still be clicked to re-add) → divider → `Choose App…` (file picker defaulting to `/Applications`, reading `CFBundleIdentifier` and `SecStaticCode` team ID) → disabled footer `Browsers aren't listed — they match by site`.

3. **Per-account quiet removal**
   - Removing an app (via `×` in the header / overflow popover, or `Undo` on the auto-add bubble) records a per-account refusal (`!bundleID` in `PasswordPie.Apps`).
   - Subsequent password copies while that app is active copy to the clipboard **silently**: no auto-add, and **no** repeat `"Show first again?"` offer bubble.
   - Manually adding the app back via `+ Add app` / `+` clears the refusal immediately.

4. **App-level auto-link suppression (3-undo threshold)**
   - Tracks distinct accounts where an **automatically added** link was undone/removed for a given app (removing links the user added manually does **not** count).
   - On the **3rd distinct account undone** for the same app, PasswordPie adds that app to the app-level exclusion list and swaps to the 44 pt bottom-of-screen bubble:
     - Same leading text X as the Undo bubble (no horizontal text jump).
     - Copy: `Stopped adding <App> automatically` + `Turn Back On` button with a click guard (`>= max(NSEvent.doubleClickInterval, 0.5 s)`) so a stray double-click on `Undo` cannot accidentally cancel suppression.
     - `Turn Back On` re-enables future automatic adding for that app and resets its undo counter (the 3 already-unlinked accounts stay unlinked).
   - **Manual adding still works** for excluded apps at any time via `+ Add app` / `+`.

5. **Preferences › General — persistent & proactive management**
   - Bordered macOS exclusion list (`Don't add automatically`) with native `+` / `−` bar (tooltips: `Add app` / `Turn back on`), showing each app's reason (`After 3 undos` or `Excluded manually`), plus one calm footer line: `You can still add these apps manually from any account.`
   - Users can proactively exclude AI agents, terminals, or chat apps with `+`, or restore automatic adding with `−`.

## Rebuild

```sh
cd art/app-link-manual/source
python3 board5.py ..
rsvg-convert -z 1.5 ../app-link-manual.svg -o ../app-link-manual.png
```
