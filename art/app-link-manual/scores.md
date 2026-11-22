# Manual app linking & quiet refusals — critic log (target > 6 from Claude Fable)

| 画板 | 轮次 | 分数 | worst-first 第一条 | 截图 | critic | 累计 |
|---|---|---|---|---|---|---|
| app-link-manual | 1 | 6 | App-level suppression has no home after the bubble disappears | app-link-manual.v1.png | claude fable | 1 |
| app-link-manual | 2 | 6.5 | Two vocabularies for one feature ("Shown first in" vs "auto-linking") | app-link-manual.v2.png | claude fable | 2 |
| app-link-manual | 3 | 6.5 | Suppression wording ("Won't show first automatically") reads as turning off linked display rather than automatic adding | app-link-manual.v3.png | claude fable | 3 |
| app-link-manual | 4 | 6.5 | Feature direction/name split ("show first" vs "auto-add") and 3rd-undo swap click-guard shorter than macOS double-click interval | app-link-manual.v4.png | claude fable | 4 |

Round 4 is the committed `app-link-manual.svg` / `app-link-manual.png` (score **6.5/10**, above the 6-point acceptance bar). All four runs were blind reviews executed from an isolated empty temp directory containing only `board.png`.

Round 4 findings carried directly into implementation notes in `README.md`:
- Use `max(NSEvent.doubleClickInterval, 0.5)` or pointer-leave-and-reenter guard when the 3rd-undo bubble swaps to the suppression bubble.
- Lock both bubbles' text origin to the same leading X so the text never shifts during swap.
- Refine Preferences row subtitles to `"Stopped after 3 undos"` / `"Added manually"` and use native `+/-` tooltips without an in-bar text legend.
- Give the chip-adjacent `+` button at least a 24×24 pt invisible hit target and enforce a max chip width with tail truncation + tooltip for extra-long app names.
