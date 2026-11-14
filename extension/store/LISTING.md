# Chrome Web Store listing

What goes into each field of the Chrome Web Store developer dashboard for the PasswordPie extension. Change this file
when the listing changes, so the next update starts from what is live. The package is `pnpm zip:chrome-store`
(see [../README.md](../README.md)).

## Package

- Item: `ebgkjnfglbkeckkknmeakpkbdpjndjhk` in the developer dashboard
  (https://chrome.google.com/webstore/devconsole/4192ce6b-4a2c-48f1-b441-97d51c404964/ebgkjnfglbkeckkknmeakpkbdpjndjhk),
  listed at https://chromewebstore.google.com/detail/ebgkjnfglbkeckkknmeakpkbdpjndjhk once published. Its public key is
  `CHROME_KEY` in [../manifest.ts](../manifest.ts).
- Submitting warns that `<all_urls>` may mean an in-depth review. `activeTab` cannot replace it: a fill starts from a
  pick in the app, or in a tab the app opened, with no click on the extension.
- Upload: `extension/.output/passwordpie-extension-<version>-chrome-store.zip` (no `key` in the manifest).
- Name and summary come from the Chrome build's manifest (store limits 75 and 132 characters,
  `tests/manifest.test.ts`): **PasswordPie: Password Manager for Mac**, "Autofill passwords from PasswordPie, the KeePass
  password manager for Mac. Needs the PasswordPie app." The Safari build keeps the name **PasswordPie**.

## Store listing

- **Category:** Productivity → Tools
- **Language:** English
- **Homepage URL:** https://passwordpie.com/
- **Support URL:** https://passwordpie.com/support
- **Small promo tile (440×280):** `promo-small-440x280.png`, from `promo-small.html` (`node render-promo.mjs`)
- **Screenshots (1280×800):** `screenshots/*.png`, in file name order
- **Global promo video:** the YouTube link under "Promo video" below
- **Mature content:** no

### Description

```text
PasswordPie fills the account you pick in PasswordPie, the KeePass password manager for Mac that lives in your menu bar, into the sign-in form of the page you're on.

This extension needs the PasswordPie app for Mac. It can't fill anything without it. Get PasswordPie at https://passwordpie.com/

HOW IT WORKS
• On a sign-in page, press ⌘\ or click the PasswordPie button in the toolbar. The PasswordPie panel opens with the accounts for that site at the top.
• Press Return. The username and password appear in the form. PasswordPie never presses Sign In for you.
• A sign-in that asks for the username first and the password on the next page gets both.
• Picked an account for another site? PasswordPie opens its website in a new tab and fills it when it loads.

BUILT TO FILL THE RIGHT PAGE
• It fills only a page on the account's own site. A look-alike domain gets nothing, because PasswordPie checks the domain itself, not what the page says.
• It never fills a frame from another site, a plain http page with an account saved for https, or anything while PasswordPie is locked.
• Each pick fills once, and is dropped if no matching page shows up within 30 seconds.

TWO-STEP CODES
• With Premium in the PasswordPie app, the two-step code fills itself on the next page after the password.
• Setting up two-step sign-in? Right-click the QR code the site shows and choose Scan QR code with PasswordPie. PasswordPie asks which account to add it to.

CHANGING A PASSWORD
• Press Reset Password on an account in PasswordPie. It makes the new password, opens the site's change-password page and fills in the current password and the new one.
• You press the site's own button. PasswordPie then asks whether the site accepted the new password, and saves it only when you say yes.

NO ACCOUNT, NO SIGN-IN
• The extension has no account and nothing to sign in to. Click its toolbar button and PasswordPie opens.

PRIVATE BY DESIGN
• Your passwords stay in your KeePass file on your Mac. They go only to the PasswordPie app on the same Mac, through Chrome's native messaging, and never to us or to any server.
• The extension has no account, stores nothing in the browser, and sends nothing to passwordpie.com or to us.
• It tells the app only the site of the active tab (such as https://example.com) and whether a window of this Chrome profile is in front, never the page's full address, its contents or your history.
• When PasswordPie has an account for that site but no icon for it, the extension sends the app the site's icon, which it fetches without cookies from the address the page gives for it.
• No analytics, no tracking, no remote code.

REQUIREMENTS
• A Mac with macOS 14 or later, and PasswordPie downloaded from passwordpie.com. The Mac App Store version supports Safari only, for now.
• Google Chrome.

Privacy policy: https://passwordpie.com/privacy-policy
Source code: https://github.com/Image-AI-LLC/PasswordPie
```

## Promo video

The store's "Global promo video" field takes a YouTube link. The file is `video/passwordpie-fill-1080p.mp4` (8.8 s,
1920x1080, 60 fps, cut to the beat of its music: synthesised for this video, no samples, nothing to license); how it is made and
measured is in [video/README.md](video/README.md). Upload it to YouTube as Public or Unlisted (the store needs a link
anyone can open), not made for kids, then paste the link here and in the dashboard.

- **Thumbnail:** the store shows the YouTube thumbnail with its play button over the centre. Upload `video/cover.jpg`
  (1280x720; the video's first frame is the same picture) as the custom thumbnail. That needs a channel with a verified
  phone number, which this one has had since 2026-11-14. On a channel without one, choose the third of the frames
  YouTube offers, the end card, which is laid out for it.
  `video/store-board.png` shows each choice as the store would.

- **YouTube URL:** https://www.youtube.com/watch?v=ROUwm3C5Ekk (the 8.8 s cut, public since 2026-11-14; its thumbnail is
  `video/cover.jpg`). Submitted to the store on 2026-11-14, to publish automatically after review. Until then the
  store shows the first cut, https://www.youtube.com/watch?v=E6M0nd_NERg (25.5 s, no sound), which becomes private once
  the new link is live.
- **Title:** PasswordPie for Chrome: a sign-in filled in under half a second | Password Manager for Mac

### Description

```text
PasswordPie is a password manager for Mac that keeps your passwords in your own KeePass file. With its Chrome extension, press ⌘\ on a sign-in page and Return: the username and password are in the form in under half a second.

What you see is a real screen recording at real speed, except the typing, which is marked as sped up:
• ⌘\ opens PasswordPie with the accounts for the site you are on at the top. Return fills the form. PasswordPie never presses Sign in for you.
• From Return to both fields filled: under half a second in every one of 25 runs (median 448 ms, 90% within 464 ms, slowest 482 ms) on a MacBook Air (M2) with macOS 27 and Chrome 157. A heartbeat takes longer.
• In the same take, after Sign in, the two-step code fills itself on the next page (with PasswordPie Premium).
• The whole sign-in, typed by hand at about 40 words a minute (shown 7× faster), next to PasswordPie in real time.

The site in the video is a made-up demo site, and the account is a demo account.

The Chrome extension needs the PasswordPie app for Mac (macOS 14 or later). Get it at https://passwordpie.com/
Chrome extension: https://chromewebstore.google.com/detail/ebgkjnfglbkeckkknmeakpkbdpjndjhk
```

## Privacy practices

### Single purpose

```text
Fill the username, password and two-step code that the user picks in the PasswordPie app for Mac into the sign-in form of the current page, and hand the app a two-step QR code the user chooses to scan there.
```

### Permission justifications

**nativeMessaging**

```text
The extension's only channel to the PasswordPie app on the same Mac, through the native messaging host the app installs (com.passwordpie). It sends the origin of the active tab (such as https://example.com) and whether a window of this Chrome profile has the focus (so the app never fills a tab of another profile), and receives the username and password the user picked in the app, and the two-step code when the app has Premium. When the app has an account for that site but no icon for it, it also sends a PNG of the site's icon. When the user chooses Scan, it sends the otpauth:// link of the two-step QR code on the page. After the user presses Reset Password in the app, it also receives the new password the app made for the change-password form, and tells the app the page's origin once that form is submitted. It is not used for anything else.
```

**webNavigation**

```text
webNavigation.getAllFrames lists the frames of the active tab, so that a fill is sent only to frames whose origin equals the account's site. Cross-origin frames, such as ads or embedded widgets, never receive a username or password.
```

**alarms**

```text
One alarm a minute checks the native messaging connection to the PasswordPie app and reconnects it if the app was restarted or the service worker was suspended. Without it, the extension stays disconnected until the next tab change.
```

**contextMenus**

```text
Adds two lines to the right-click menu of the extension's toolbar button (Scan QR code on this page, Open passwordpie.com) and one line to the right-click menu of web pages (Scan QR code with PasswordPie). A click on the toolbar button opens the PasswordPie app and the extension has no popup, so these menus are how the user starts a scan. Nothing is read from the page until the user chooses a Scan line.
```

**Host permissions (<all_urls>)**

```text
Sign-in pages can be on any site; the user's database decides which. Host access lets the background read the active tab's URL (only its origin goes to the PasswordPie app, to find that site's accounts) and lets the content script find and fill the sign-in fields of the page the user asked to fill. After Reset Password in the app, it fills the site's change-password form (current and new password) and notices when the user submits it. If the app has an account for the site but no icon, the background asks the top frame for the page's icon links and fetches the icon without cookies. When the user chooses Scan QR code in a right-click menu, the top frame reads on-screen pictures that could be a QR code and, if none reads, the background takes one picture of the visible tab (tabs.captureVisibleTab); the code is decoded in the extension and only its otpauth:// link goes to the app. Otherwise the content script reads nothing until the user picks an account, and it never submits a form.
```

### Remote code

```text
No, I am not using remote code.
```

All JavaScript is bundled in the package, including the jsQR decoder. The extension loads no scripts, WebAssembly or code strings from anywhere.

### Data usage

Collected and handled only on the user's Mac, never sent to the developer or a server:

- **Authentication information:** the username and password the user picks in the PasswordPie app, put into the page;
  and, after Reset Password in the app, the new password the app made, put into the site's change-password form.
- **Web history:** the origin of the active tab, sent to the PasswordPie app on the same Mac to list that site's accounts.
- **Website content:** the site's icon, sent to the PasswordPie app on the same Mac when it has an account for that
  site but no icon for it; and, only when the user chooses Scan, the two-step QR code shown on the page, decoded in the
  extension and sent as an otpauth:// link to the PasswordPie app on the same Mac. The pictures are not kept.

Nothing is sent to passwordpie.com, to the developer or to any other server. The extension has no account, no
`storage` permission and no `identity` permission. Its one network request is the site icon above, fetched without
cookies from the address the page gives for it.

All three certifications are ticked: not sold or transferred to third parties outside the approved use cases, not used
for purposes unrelated to the single purpose, not used to determine creditworthiness or for lending.

**Privacy policy URL:** https://passwordpie.com/privacy-policy (section "Browser extension")

## Distribution

- **Visibility:** Public
- **Regions:** all
- **Publishing:** automatic after review, since the direct download (0.2.0 on) trusts the store extension. Turn
  "publish automatically after review" **off** for an update that needs a newer app than the released one, and publish
  by hand once that app is out. Steps in [docs/BROWSER_EXTENSION.md](../../docs/BROWSER_EXTENSION.md), "Releasing the
  Chrome extension".
