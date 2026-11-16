# An account remembers its app

The design board for linking an account to the app it signs in to, described for users in `docs/UX.md` ("An account
remembers its app") and specified in `DESIGN.md` ("Linked apps line", "Link bubble", and the app's group under "Group
header").

`app-link.svg` and `app-link.png` are the last round's board. It shows three things that are new:

- **The line under an account's title**: "Shown first in", then one token per app (icon, name, close mark).
- **The bubble** at the bottom of the screen: one line and one button, Undo or Show first. Its shape follows the bubble
  of the owner's other app, LazyTyper: an opaque card with a hairline, an icon, one line of text and one action.
- **The app's group** at the top of the menu, with the app's icon before its name.

Harbor, Ledger and Northwind are made up, so the board carries no other company's icon.

`native-light.png` and `native-dark.png` are offscreen renders of the shipped SwiftUI views (the details header with two
apps, then the bubble that says a link was made and the one that asks), with the Finder standing in for Harbor and an
app that is not installed for Ledger. The details view draws no surface of its own (the popover or the window does),
so the render is laid on the `surface` colour.

## Critic

The board went through six rounds of blind critique by two critics, GPT (`codex`, `gpt-6-astra`) and Gemini (`agy`,
`gemini-3.8-flash-high`), each seeing only the image. The log is in `scores.md`. The bar set for the work was 5/10 from
each, and 7 if it could be reached. GPT gave 6 in every round. Gemini gave 5, 5, 5, 4, 4 and then 5 in the round whose
prompt stated the bubble as a requirement. Neither reached 7: from round 3 on, the points raised were about the board's
composition and about parts of the product that were not open to change, and the two critics, and the same critic
in different rounds, asked for opposite things (hide the close mark until hover, keep it always visible; say "shown
first" everywhere, say it less).

What the rounds changed, taking the points both critics raised in the same round:

| Round | Change |
|---|---|
| 1 → 2 | One rule only: the offer after a single copy is gone. The line under the title says what the link does. Unlinking no longer moves the next app. |
| 2 → 3 | The close mark sits at the end of the token and is always there; the app's icon stays. The bubble lost the arrow between its two icons and took the product's own quiet button. Everything is drawn at 1:1. |
| 3 → 4 | The way back became a short line under the story. The group's header got the app's icon. One verb, "show first", in the line, the bubble and the button. |
| 4 → 5 | One Harbor window, not two. Cause and effect in a straight line, with the linked header in it. |
| 5 → 6 | The menu bar proves which app is in front. The step titles use the same words as the interface. Fewer notes. |

What was not taken, and why:

- **No bubble at the bottom of the screen** (Gemini, every round). The owner asked for this bubble. From round 6 the
  prompt states it as a fixed requirement.
- **A recessed tray, a Return glyph in place of the arrow, a heavier header for the group** (Gemini). The group uses the
  menu's existing header, rows and arrow, as a site's group does.
- **A separate "linked apps" row in the details** (Gemini). It would push the username and password down in a pinned
  window, which is where they are clicked.

## Rebuild

```sh
cd art/app-link/source
python3 board6.py ..        # writes ../app-link.svg
rsvg-convert -z 1.5 ../app-link.svg -o ../app-link.png
```

`board1.py` to `board5.py` hold the earlier rounds and the drawing helpers the later ones import. They also import the
pie mark and the text helper from `art/lock-motion/source`.
