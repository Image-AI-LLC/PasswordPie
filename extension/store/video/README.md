# Store promo video

`passwordpie-fill-1080p.mp4`: 9 seconds (8.8), 1920x1080, 60 fps, H.264, with music (AAC stereo, -16 LUFS). For the
Chrome Web Store's "Global promo video", which takes a YouTube link (title and description in
[../LISTING.md](../LISTING.md), "Promo video"). `cover.jpg` is the thumbnail (1280x720), and the video's first frame
is the same picture.

Everything in it is a real screen recording of the app built by `make install`, the unpacked extension from this repo
and the demo sign-in pages in [../../dev/mock-site.mjs](../../dev/mock-site.mjs). The demo (⌘\ to the two-step code)
is one stretch of one take at real speed, every frame of the recording, cut only at its start and end; so is the
PasswordPie half of the side-by-side. The sped-up typing says on screen how much faster it is. The demo site is
Fernway, a team workspace made up for these pages, served as `https://fernway.example` (a reserved domain), so no
real site or brand appears. The vault is the marketing demo vault with one login added for Fernway; no real account
is shown.

What it says about speed is **<0.5 s**, in seconds wherever it is big (the cover, the counter, the end card), with
"A heartbeat takes longer." beside it on the cover and the end card. Every one of the 25 measured runs was under 500 ms (the slowest 482 ms), and
a heart at rest beats once in 0.6 to 1 s. (Not "faster than a blink": a blink takes 0.1 to 0.4 s.) The median,
448 ms, is in the small print of the cover and of the end card, and nowhere else. A three-digit number of milliseconds did not read as fast.

It is cut to a beat the recording sets. In the two-step take the form fills and, on the next page, the code fills
66 frames (1.1 s) later; with a beat of 33 frames (0.55 s, 109 a minute) both land on a beat, two beats apart, with
nothing stretched. Each scene starts on a beat with a hard cut (on its first frame it is all there).

| Time | Beats | Scene |
|---|---|---|
| 0–0.55 s | 1 | The cover: <0.5 s, "From Return to a filled sign-in. A heartbeat takes longer.", the Return key and the two filled fields. It is the first frame, whole, so the video starts as the thumbnail that was clicked; the demo cuts in on the first beat. |
| 0.55–4.4 s | 7 | "⌘\\, then Return." One stretch of real time: the page, ⌘\\, the panel with FERNWAY.EXAMPLE on top, Return, filled at 2.2 s, Return (Sign in), and the two-step code fills itself on the next page at 3.3 s (Premium; a label beside it says so) and stays for two beats. From the cut to the code: 2.75 s. Beside the headline a counter runs from Return and stops on the frame the fields fill in, on 0.45 s; the only words with it are "Return → both fields filled". |
| 4.4–6.6 s | 4 | The whole sign-in from the first key, side by side on the same page: typing it at about 40 words a minute (11.7 s; shown 7× faster, marked) and PasswordPie in real time (⌘\\, Return, filled at 5.5 s: 1.0 s), with bars on one scale. PasswordPie is done while the typing, seven times faster than it was, has a third still to go. |
| 6.6–8.8 s | 4 | End card: on the left PasswordPie, Password Manager for Mac, with a Chrome extension, passwordpie.com; on the right <0.5 s, from Return to a filled sign-in, a heartbeat takes longer. |

- **The counter.** It runs in real time, for as long as this take took from Return to filled, and stops on the median
  of the 25 measured runs in seconds, 0.45 (447.7 ms), the number the cover's small print and the listing give. This
  take's own time is 451.5 ms by the page's clock: 3.8 ms more, less than a quarter of a frame (16.7 ms).
- The demo is the `twostep` take from 0.09 s before ⌘\ to 1.1 s after the code (half that was too short to see that
  the page had changed and filled itself); Verify and the page after it are
  left out. The panel is open 0.97 s before Return, as it was. The PasswordPie half of the side-by-side is the
  `quick` take: ⌘\ to filled in 1.0 s. The `fill` take is now only where the cover's two fields come from.
- The side-by-side times both sides from the first key, not from Return, so its 1.0 s includes opening the panel and
  a person's 0.3 s before Return. Both sides start at the same moment. The typing in it is synthetic: keys sent one
  at a time with gaps between 60% and 140% of 300 ms (a fixed sequence), 307 ms on average in this take.
- Earlier versions: the first (#52) was 25.5 s, with the waits left in, a slow-motion replay of the fill, and no
  sound. The second (#56) was 11 s at 120 a minute, said "448 ms", and showed the fill and the two-step code as two
  scenes from two takes (5.5 s for what is now 3.85 s).

## Cover and thumbnail

The store shows the video's YouTube thumbnail before it plays: the 16:9 picture in a 16:10 frame, with the store's
play button (about a tenth of the width) over its centre, and about 112 px wide in the strip under the carousel.
`store-board.png` lays four frames of the video out that way.

- `cover/cover.html` is drawn for that: the claim is the picture, and the line from the Return key to the fields leaves
  a gap where the play button lands. `render-cover.mjs` renders it twice: `cover.jpg` to upload as the thumbnail, and
  at 1.5x as the video's first frame.
- YouTube takes a custom thumbnail only from a channel with a verified phone number. Without one it offers three frames
  of the video, from about 1/8, 3/8 and 7/8 of its length: 1.1 s (the demo, the panel open), 3.3 s (the demo, the
  code filling in) and 7.7 s (the end card). The end card is laid out to be that thumbnail: brand on the left, the
  claim on the right, nothing under the play button, and it does not move, so any frame of it will do. Pick the
  third one.

## Sound

`music/synth.py` makes the music: sine waves and noise from a fixed seed, no samples and no third-party audio. The
drums are in front: a kick on every beat, a snare on two and four, sixteenth-note hats with the off-beat accented and
a bass line in eighths; a pad and a plucked figure stay behind them. It reads `composition/timing.js` for when things
happen and keeps no moment of the video itself:

- the tempo is the beat the scenes are cut to, and a scene that does not start on a beat is refused;
- each scene starts a new chord (D, G), with the bar counted from where the scene starts;
- what the interface does sounds like an interface, not like the tune: a key cap's click (a few ms of noise on a
  short thud, no pitch) at each ⌘\ and Return, and a soft pop (a sine sliding up from 330 to 660 Hz in a few
  hundredths of a second, never resting on a note) on the frame each form or code fills (2.2, 3.3 and 5.5 s), each
  on a beat. Both are dry, in the middle and in front: all of the music, the drums too, steps back 4 dB for a tenth
  of a second under each (a click that lands on a drum hit was not heard otherwise), and what has a pitch 3 dB more
  under a pop. Before, a two-note chime
  marked the fills: it sounded like one more instrument, and higher up, as a bare sine, it was piercing;
- the drums are played by a hand: the hats' off sixteenths come late (swing), each hat is a few ms early or late
  and no two are equally loud; the snare comes 3 to 9 ms behind the beat, softer on two than on four; the kick is
  harder on the one. No two bars are alike: each is played a little harder than the one before, up to the end
  card, and has its own extras (a soft kick before the three or before the one, a ghost note on the snare). The
  hats are noise between 6 and 10.5 kHz and nothing above: with everything above 7 kHz they sounded like sand. The snare is a drum head (two modes falling in pitch) with short, dark wires: its noise
  falls off above 1.5 kHz. Brighter or longer, it hissed;
- two taps over the cover lead into the first beat; a roll leads into the end card, where one hit lands, the drums
  stop, and a D chord on bells dies away before the video ends.

`build.mjs` turns it down by one fixed gain to -16 LUFS (true peak about -5 dBFS; no compressor or limiter) and puts
it under the picture. `music/check.py VIDEO` listens to a finished file: where each pop and each click is, loudness, true peak.

## Files

- `record.mjs`: measures Return → filled, and records the takes. `tools/ppvideo.swift`: keys through the HID event tap
  (as from the keyboard), waiting for the panel, and the recorder (ScreenCaptureKit, only the windows of the recording
  Chrome and PasswordPie: no menu bar, notifications or other apps can get into a take).
- `chrome.mjs`: the Chrome used for recording, with its own profile and the unpacked extension.
- `takes/`: the four takes the video and the cover are cut from (`.mov`, variable frame rate, 2560x1440) and what happened when, in
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
- A dissolve across a beat reads as a cut that comes late (or early, when it starts before the beat), and a
  dissolve between two full pictures (the cover and the demo) reads as a ghost. Every scene cuts hard on the beat.
- A key cap is dark: over the demo site's dark sidebar it was not seen. Key caps sit over the page and have a light
  edge.
- A first scene that is over in a second is not seen: the panel was on screen 0.3 s before Return. It needs the
  second it has in the take.
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
