# Store promo video

`passwordpie-fill-1080p.mp4`: 11 seconds, 1920x1080, 60 fps, H.264, with music (AAC stereo, -16 LUFS). For the Chrome
Web Store's "Global promo video", which takes a YouTube link (title and description in [../LISTING.md](../LISTING.md),
"Promo video"). `cover.jpg` is the thumbnail (1280x720), and the video's first frame is the same picture.

Everything in it is a real screen recording of the app built by `make install`, the unpacked extension from this repo
and the demo sign-in pages in [../../dev/mock-site.mjs](../../dev/mock-site.mjs). Scenes 1 and 3 and the PasswordPie
half of scene 4 play at real speed, every frame of the recording, cut only at their start and end. The slow-motion
replay and the sped-up typing say on screen how much slower or faster they are. The demo site is Fernway, a team
workspace made up for these pages, served as `https://fernway.example` (a reserved domain), so no real site or brand
appears. The vault is the marketing demo vault with one login added for Fernway; no real account is shown.

It is cut to a beat: 120 a minute, so a beat is half a second, 30 frames. Each scene starts on a beat, and what it is
about lands on one too.

| Time | Beats | Scene |
|---|---|---|
| 0–0.5 s | 1 | The cover: 448 ms, "From Return to a filled sign-in", the Return key and the two filled fields. It is the first frame, so the video starts as the thumbnail that was clicked, and lifts away as scene 1 comes in. |
| 0.5–2.5 s | 4 | "⌘\\, Return: filled." ⌘\\, the panel with FERNWAY.EXAMPLE on top, Return, filled at 2.0 s. Real time: 1.0 s from ⌘\\ to filled. |
| 2.5–4.5 s | 4 | A fill 3× slower (marked). A large counter runs from Return to the frame the fields fill in, at 4.0 s, and stops on the measured median, 448 ms; beside it the run count, p90 and the machine. |
| 4.5–6.0 s | 3 | "Two-step code? Filled on the next page." The filled form, Sign in, and the code fills itself on the next page at 5.0 s (Premium). Real time. |
| 6.0–9.0 s | 6 | The whole sign-in from the first key, side by side on the same page: typing it at about 40 words a minute (11.7 s; shown 6× faster, marked) and PasswordPie in real time (⌘\\, Return, filled at 7.5 s: 1.0 s), with bars on one scale. PasswordPie is done while the typing, six times faster than it was, still has a second to go. |
| 9.0–11.0 s | 4 | End card: on the left PasswordPie, Password Manager for Mac, with a Chrome extension, passwordpie.com; on the right 448 ms, from Return to a filled sign-in. |

- Scenes 1 and 4 are the `quick` take (in scene 4 closer in), scene 2 is the `fill` take, scene 3 the `twostep` take
  from just before Sign in: the same fill once more and the pause before Sign in are left out, and so are Verify and
  the page after it.
- Scene 4 times both sides from the first key, not from Return, so its 1.0 s includes opening the panel and a person's
  0.3 s before Return. Both sides start at the same moment. The typing take begins 1.8 s before its first key, so at
  6× its first frame, the untouched page, is held for 0.15 s. The typing in it is synthetic: keys sent one at a time
  with gaps between 60% and 140% of 300 ms (a fixed sequence), 307 ms on average in this take.
- The first version (#52) was 25.5 s, the same five scenes with the waits left in and no sound.

## Cover and thumbnail

The store shows the video's YouTube thumbnail before it plays: the 16:9 picture in a 16:10 frame, with the store's
play button (about a tenth of the width) over its centre, and about 112 px wide in the strip under the carousel.
`store-board.png` lays four frames of the video out that way.

- `cover/cover.html` is drawn for that: the number is the picture, and the line from the Return key to the fields leaves
  a gap where the play button lands. `render-cover.mjs` renders it twice: `cover.jpg` to upload as the thumbnail, and
  at 1.5x as the video's first frame.
- YouTube takes a custom thumbnail only from a channel with a verified phone number. Without one it offers three frames
  of the video, from about 1/8, 3/8 and 7/8 of its length: 1.4 s (scene 1, the panel open), 4.1 s (scene 2, just
  filled) and 9.6 s (the end card). The end card is laid out to be that thumbnail: brand on the left, the number on the
  right, nothing under the play button, and everything in place by 9.5 s. Pick the third one.

## Sound

`music/synth.py` makes the music: sine waves and noise from a fixed seed, no samples and no third-party audio. The
drums are in front: a kick on every beat, a clap on two and four, sixteenth-note hats with the off-beat accented and a
bass line in eighths; a pad and a plucked figure stay behind them. It reads `composition/timing.js` for when things
happen and keeps no moment of the video itself:

- the tempo is the beat the scenes are cut to (the first scene is one bar), and a scene that does not start on a beat
  is refused;
- each scene starts a new chord (D, B minor, G, A), with the bar counted from where the scene starts;
- a two-note chime sounds on the frame each form fills (2.0, 4.0, 5.0 and 7.5 s), each on a beat with the clap or the
  kick, and what has a pitch steps back 3 dB under it;
- two taps over the cover lead into the first beat; a roll leads into the end card, where one hit lands, the drums
  stop, and a D chord on bells dies away before the video ends.

`build.mjs` turns it down by one fixed gain to -16 LUFS (true peak about -5 dBFS; no compressor or limiter) and puts
it under the picture. `music/check.py VIDEO` listens to a finished file: where each cue is, loudness, true peak.

## Files

- `record.mjs`: measures Return → filled, and records the takes. `tools/ppvideo.swift`: keys through the HID event tap
  (as from the keyboard), waiting for the panel, and the recorder (ScreenCaptureKit, only the windows of the recording
  Chrome and PasswordPie: no menu bar, notifications or other apps can get into a take).
- `chrome.mjs`: the Chrome used for recording, with its own profile and the unpacked extension.
- `takes/`: the four takes the video is cut from (`.mov`, variable frame rate, 2560x1440) and what happened when, in
  epoch ms (`.json`). `measurements.json`: the 25 measured fills.
- `composition/`: the HyperFrames project. `prep.mjs` cuts `takes/` into `clips/` and writes `timing.js` (when each
  key and fill happens in its clip, and when each scene starts in the video); `index.html` is the picture.
- `cover/cover.html`, `render-cover.mjs`: the cover. `cover/board.html`: a picture as the store shows it
  (`node render-cover.mjs board OUT.png FRAME.png…`).
- `music/synth.py`, `music/check.py`: the music and the check of the finished sound (Python, run with `uv`).
- `build.mjs`: all of it, from `takes/` to the finished video.
- Tests: `../../tests/promo-video.test.ts` (`pnpm test` in `extension/`).

## Measuring

From Return to the username and password both in the form: `record.mjs measure` presses ⌘\ in the page, waits for the
panel, waits 600 ms, notes the time and posts Return. A script added to the page before its own (through the DevTools
protocol, not part of the site) notes the time of the `input` event that leaves both fields non-empty, and the start of
the second animation frame after it (the frame with the values has been drawn). Both clocks are the Mac's wall clock
(`Date` in the helper, `performance.timeOrigin + now()` in the page). Each run reloads the page first.

The video checks the clocks: `prep.mjs` finds the frame where the email field changes in each take. In the fill and
two-step takes it is within 23 ms (about one frame) of the time the page noted.

## Recording it again

Needs Node 22, ffmpeg, Xcode's Swift, `uv`, and the screen for about ten minutes: keys go to the front window. Before
each take `record.mjs` waits while `/tmp/pp-store/busy` exists (someone else is using the screen).

To make the video again from the takes already here (a change to the cover, the music or the composition), only the
first three lines and step 6 are needed: nothing is recorded, every browser is headless, and the screen is not used.

```sh
W=$(mktemp -d)                                   # scratch
npm i --prefix "$W/node" puppeteer-core@24 hyperframes@0.9
export PUPPETEER="$W/node/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js" HYPERFRAMES="$W/node/node_modules/.bin/hyperframes"
swiftc -O tools/ppvideo.swift -o "$W/ppvideo" && export PPVIDEO="$W/ppvideo"

# 1. The app, as `make install` builds it, in its own preferences domain so nothing of the installed app is used.
#    The browser host only talks to an app signed as com.passwordpie, so only the bundle ID changes.
(cd ../../.. && make install PREFIX="$W/build")
A="$W/promo/PasswordPie.app"; mkdir -p "$W/promo"; cp -R "$W/build/PasswordPie.app" "$A"; rm -rf "$A/Contents/PlugIns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.passwordpie.promo" "$A/Contents/Info.plist"
codesign --force --sign "Apple Development: Xun Cai (Y743SM6XYD)" --identifier com.passwordpie \
  --entitlements ../../../build/noprofile/direct.entitlements "$A"

# 2. The demo vault with a Fernway login (demo vault from the marketing repo; its password is not a secret).
cp ~/projects/PasswordPie/marketing/demo/demo.kdbx "$W/demo.kdbx"
uv run -q --with pykeepass python -I - "$W/demo.kdbx" <<'EOF'
import sys; from pykeepass import PyKeePass
kp = PyKeePass(sys.argv[1], password='pie-demo-only')
e = kp.add_entry(kp.find_groups(name='Work', first=True), 'Fernway', 'sam@rivera.example', 'vR7#kQ2m!Lp9wXz4Tb6e',
                 url='https://fernway.example')
e.otp = 'otpauth://totp/Fernway:sam%40rivera.example?secret=JBSWY3DPEHPK3PXP&issuer=Fernway&period=30&digits=6'
kp.save()
EOF
D=com.passwordpie.promo
defaults write $D databasePath "$W/demo.kdbx"; defaults write $D databasePaths -array "$W/demo.kdbx"
defaults write $D chromeSyncEnabled -bool NO; defaults write $D "touchIDDeclined.$W/demo.kdbx" -bool YES
defaults write $D lockOnIdle -bool NO                 # read at launch; otherwise it locks after 5 idle minutes
defaults write $D panelTopLeft -string "{445, 716}"   # the panel right beside the form (window at 95,118)

# 3. Quit the installed PasswordPie (it holds ⌘\ and the extension's socket), start this one, and unlock it:
#    ⌘\, type pie-demo-only, Return. Then Premium, with the test key that only make install builds trust:
osascript -e 'tell application id "com.passwordpie" to quit'
open -a "$A"
open -a "$A" "$(node ../../../Scripts/mint-activation-link.mjs 3)"

# 4. The demo site on https://fernway.example (127.0.0.1:8443, a self-signed key that only this Chrome accepts).
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 30 \
  -subj /CN=fernway.example -addext subjectAltName=DNS:fernway.example
export SPKI=$(openssl x509 -in "$W/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
PORT=8443 TLS_CERT="$W/cert.pem" TLS_KEY="$W/key.pem" node ../../dev/mock-site.mjs &

# 5. Chrome (its own profile; the extension is built by make install), then measure and record.
UDD="$W/udd" node chrome.mjs &                    # prints its pid
export CHROME_PID=<pid> APP_PID=$(pgrep -f "promo/PasswordPie.app/Contents/MacOS/PasswordPie$")
node record.mjs measure 25 measurements.json
for t in fill twostep typing quick; do node record.mjs take $t takes; done

# 6. The video, with its sound: clips and timing, the cover, the picture, the music, and a check of the result.
#    (The cover is rendered in the installed Chrome, headless; CHROME_BIN=<a Chrome or headless shell> uses another.)
node build.mjs
```

Afterwards: quit the promo app and Chrome, `defaults delete com.passwordpie.promo`, remove the test activation
(`security delete-generic-password -s com.passwordpie.account -a activation`: the release build keeps it where the
installed app does, so check before activating that no such item exists. Do not read it back with `security … -w`: that
puts a keychain password prompt on the screen), and `open ~/Applications/PasswordPie.app`, which
writes its own Chrome host manifest back.

Things that bit:

- A puppeteer-installed extension starts with no site access, so it never reports the tab's site and the panel shows
  "Add Chrome Extension…". `chrome.mjs` grants all sites, as the store install does.
- The host checks that the app is signed as `com.passwordpie`; a re-sign that takes the identifier from the new bundle
  ID leaves the extension unconnected.
- Chrome shows a bar for `--host-resolver-rules`; `chrome.mjs` closes it. macOS draws a recording indicator where the
  window buttons are, so the video leaves out the tab strip.
- Synthetic Unicode key events do not reach PasswordPie's master password field (secure input); System Events
  `keystroke` does.
- The app locks after 5 idle minutes and reads `lockOnIdle` only at launch; a locked app turns ⌘\ into the unlock
  form and every take after it fails.
- The video's first frame is what a click on the thumbnail turns into. A fade-in from an empty screen there makes
  the start look like a jump, and YouTube may also show that frame while the video loads.
- YouTube picks its thumbnail candidates from fixed places in the video; an animation still running there (the first
  version's end card was still building up at 7/8) gives a half-drawn thumbnail.
- A clip whose first frame is not at time 0 (a seek that lands between two frames, or `setpts` after one) is played
  that much late by the renderer, although ffmpeg measures the fill in it at the right time. `prep.mjs` checks every
  clip's start.
- The two-step page comes up with its boxes empty and fills them two frames later; a check for "this part of the
  picture changed" finds the empty page.
- AAC adds 21 ms of silence before the sound; the file's edit list takes it out again, and `music/check.py` measures the
  cues as a player hears them.
- The takes have a frame only when the screen changed; `prep.mjs` makes them constant 60 fps before cutting, or every
  cut starts late by the length of the still stretch.
