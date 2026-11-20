# The question about a browser built on Chromium

The design board for "Allow “ego lite” to fill passwords?", described for users in `docs/UX.md` ("Other browsers built
on Chrome") and specified in `DESIGN.md` ("Browser question window"). The code is
`Sources/PasswordPieApp/BrowserApprovalPrompt.swift`.

- `browser-approval-light.svg`, `browser-approval-dark.svg` (and their PNGs): the board, written by
  `source/panel.py`. The browser's icon is a stand-in, so the board carries no other company's artwork.
- `native-light.png`, `native-dark.png`: offscreen renders of the shipped SwiftUI window, with the system's icon for an
  app that is not installed. The buttons are the system's own: in a window on screen macOS draws them as it draws any
  large push button there.

## Why it changed

It was a system alert: two paragraphs, the signer in the middle of the second, and one tinted button, Don't Allow,
because Return had to be the safe answer. On 2026-11-20 the owner, meaning to allow ego lite, pressed that button: it
looked like the one that confirms. The answer is kept and nothing in the browser says so; the extension looked as if
PasswordPie were not installed.

What the window does about it:

- **Neither answer is pushed.** Two plain buttons of one width. Neither is the default, and no key presses either.
- **Who, what, when, in that order.** PasswordPie asks; the browser's icon, name and signer; what it gets; the rule for
  deciding as the last thing before the buttons; where to change the answer, smaller.
- **The browser's name never breaks across lines.**

## Critic

Two critics, GPT (`codex`, its default model) and Gemini (`agy`, `gemini-3.8-flash-high`), each run in an empty folder
with only the image. The log is in `scores.md`. The bar set for the work was 6/10 from each.

| Round | What they saw | GPT | Gemini |
|---|---|---|---|
| Phase 1 | Three directions on one sheet: facts as rows (A), a card for the browser (B), two icons meeting (C) | picks A | picks A |
| 1 | A with equal buttons and a tinted well for the browser | 6 | 4 |
| 2 | No well; what it gets under the question; two hairlines | 6 | 5 |
| 3 | No hairlines; everything on one text edge beside an icon column | 6 | 4 |
| 4 | The body back at the left edge; the note smaller | 8 | 7.5 |
| 5 | "PasswordPie" over the question; the rule names the browser | 8.5 | 7 |

Rounds 1 to 3 used the blind prompt of the `design-critic` skill (the image is the whole brief, strict scale). Under it
Gemini stayed at 4 to 5 and asked for opposite things in different rounds (remove the well, then add a container;
remove the rules, then add one), as it has on earlier boards. Rounds 4 and 5 used the other prompt this project's
boards have been measured with: the goal, the alert as it was, and JSON with a score and problems. Those two rounds are
what the bar was measured on. The two kinds of score do not compare.

After round 5 one word went back in ("yourself", which Gemini's round 5 asked for and round 4 had). Twelve critic runs
in all, the budget; it was not scored again.

What each round changed took only what both critics raised in that round, or what one raised and a fact confirmed.
Left alone: bordered buttons and a container for the browser (Gemini only, and the buttons are the system's); naming
the browser a third time in the body (GPT asked, Gemini asked for fewer).

## Rebuild

    cd art/browser-approval/source && python3 panel.py

Needs Pillow, the SF Pro fonts in `/Library/Fonts`, and `rsvg-convert` (`brew install librsvg`).
