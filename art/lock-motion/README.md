# Lock and unlock motion

Design boards for two fixes, described for users in `docs/UX.md` ("Lock", "Unlock") and specified in `DESIGN.md`
("Locked panel", "Locked card", "Unlock motion", "Lock motion").

- **⌘L** (`lock-scene.svg`): the first lock scene squeezed the 360 pt lock screen into the menu's frame, so a short
  menu cut off the logo. Now the menu folds into a 144 pt "Locked" card at the menu's width, hung from its top-left
  corner.
- **Unlock** (`unlocking.svg`): the form used to vanish and leave "Unlocking…" over an empty panel. Now it stays in
  place, dimmed, with "Unlocking…" on the button. The form is as tall as its content, and an error takes the
  guidance line instead of reserving blank space.

`native-{light,dark}.png` are offscreen renders of the shipped SwiftUI views: ready, unlocking, wrong password, a
long error, and the card at 300 and 360 pt. In offscreen renders the keyhole shows black instead of see-through.

## Critic

The boards went through four rounds of blind critique by Gemini (`agy`, `gemini-3.8-flash-high`). The log is in
`scores.md`. The score settled at 5/10. By round 4 the gaps it raised were the brand (the name, tagline, flat pie,
centred form) and the unchanged menu, which were out of scope. The owner accepted the round-4 boards at 5.

## Rebuild

```sh
cd art/lock-motion/source
python3 gen4.py ..        # writes ../lock-scene.svg and ../unlocking.svg
rsvg-convert -z 1.5 ../lock-scene.svg -o ../lock-scene.png
rsvg-convert -z 1.5 ../unlocking.svg -o ../unlocking.png
```

`gen.py` to `gen3.py` hold the earlier rounds and the shared drawing helpers that `gen4.py` imports.
