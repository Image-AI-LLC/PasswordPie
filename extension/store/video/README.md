# Store promo video

`passwordpie-fill-1080p.mp4`: 25.5 seconds, 1920x1080, 60 fps, H.264, no sound. For the Chrome Web Store's "Global promo
video", which takes a YouTube link (title and description in [../LISTING.md](../LISTING.md), "Promo video").
`cover.jpg` is the thumbnail (1280x720).

Everything in it is a real screen recording at real speed of the app built by `make install`, the unpacked extension
from this repo and the demo sign-in pages in [../../dev/mock-site.mjs](../../dev/mock-site.mjs). The slow-motion replay
and the sped-up typing say so on screen. The demo site is Fernway, a team workspace made up for these pages, served as
`https://fernway.example` (a reserved domain), so no real site or brand appears. The vault is the marketing demo vault
with one login added for Fernway; no real account is shown.

| Time | Scene |
|---|---|
| 0–4.2 s | "⌘\\, then Return: filled in under half a second." ⌘\, the panel with FERNWAY.EXAMPLE on top, Return, filled. Real time. |
| 4.2–9.2 s | The same take again, 4× slower. A large counter runs from Return to the frame the fields fill in and stops on the measured median, 448 ms; beside it the run count, p90 and the machine. |
| 9.2–14.1 s | From Return: filled, Sign in, the two-step code fills on the next page (Premium), Verify, home. Real time. |
| 14.1–21.6 s | Filling a sign-in from the first key, side by side on the same page: typing it at about 40 words a minute (11.7 s from the first key to the last; sped up 4× after 3.6 s, marked) and PasswordPie (⌘\, Return, filled: 1.0 s), with bars on one scale. |
| 21.6–25.5 s | End card: PasswordPie, Password Manager for Mac, with a Chrome extension, passwordpie.com. |

These are the five scenes of the storyboard the video was asked for. Scene 4 times both sides from the first key, not
from Return, so its 1.0 s includes opening the panel and a person's 0.3 s before Return. The typing in it is synthetic:
keys sent one at a time with gaps between 60% and 140% of 300 ms (a fixed sequence), 307 ms on average in this take.

## Files

- `record.mjs`: measures Return → filled, and records the takes. `tools/ppvideo.swift`: keys through the HID event tap
  (as from the keyboard), waiting for the panel, and the recorder (ScreenCaptureKit, only the windows of the recording
  Chrome and PasswordPie: no menu bar, notifications or other apps can get into a take).
- `chrome.mjs`: the Chrome used for recording, with its own profile and the unpacked extension.
- `takes/`: the four takes the video is cut from (`.mov`, variable frame rate, 2560x1440) and what happened when, in
  epoch ms (`.json`). `measurements.json`: the 25 measured fills.
- `composition/`: the HyperFrames project. `prep.mjs` cuts `takes/` into `clips/` and writes `timing.js`;
  `index.html` is the video.

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

```sh
W=$(mktemp -d)                                   # scratch
npm i --prefix "$W/node" puppeteer-core@24 hyperframes@0.9
export PUPPETEER="$W/node/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js"
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

# 6. The video.
node composition/prep.mjs
(cd composition && npx --prefix "$W/node" hyperframes render . --quality high --fps 60 --output ../passwordpie-fill-1080p.mp4)
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
- The takes have a frame only when the screen changed; `prep.mjs` makes them constant 60 fps before cutting, or every
  cut starts late by the length of the still stretch.
