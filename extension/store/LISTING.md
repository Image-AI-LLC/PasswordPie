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
- Name and summary come from the manifest: **PasswordPie**, "Fills sign-in forms from the PasswordPie app on your Mac.
  Needs PasswordPie for Mac."

## Store listing

- **Category:** Productivity → Tools
- **Language:** English
- **Homepage URL:** https://passwordpie.com/
- **Support URL:** https://passwordpie.com/support
- **Small promo tile (440×280):** `promo-small-440x280.png`, from `promo-small.html` (`node render-promo.mjs`)
- **Screenshots (1280×800):** `screenshots/*.png`, in file name order
- **Mature content:** no

### Description

```text
PasswordPie fills the account you pick in PasswordPie, the KeePass password manager in your Mac's menu bar, into the sign-in form of the page you're on.

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

## Privacy practices

### Single purpose

```text
Fill the username, password and two-step code that the user picks in the PasswordPie app for Mac into the sign-in form of the current page, and hand the app a two-step QR code the user chooses to scan there.
```

### Permission justifications

**nativeMessaging**

```text
The extension's only channel to the PasswordPie app on the same Mac, through the native messaging host the app installs (com.oldcai.passwordpie). It sends the origin of the active tab (such as https://example.com) and whether a window of this Chrome profile has the focus (so the app never fills a tab of another profile), and receives the username and password the user picked in the app, and the two-step code when the app has Premium. When the app has an account for that site but no icon for it, it also sends a PNG of the site's icon. When the user chooses Scan, it sends the otpauth:// link of the two-step QR code on the page. It is not used for anything else.
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
Sign-in pages can be on any website, and the user decides which ones by the accounts in their own password database. Host access lets the background read the URL of the active tab (only its origin is sent to the PasswordPie app, to find the accounts for that site) and lets the content script find and fill the username and password fields on the page the user asked to fill. When the app has an account for the site but no icon for it, the background also asks the content script of the top frame for the icon links the page declares (<link rel=icon>) and fetches that icon without cookies, to show it in the app's account list.  When the user chooses "Scan QR code on this page" in the toolbar button's right-click menu, or "Scan QR code with PasswordPie" in the page's right-click menu, the content script of the top frame reads the pictures on screen that could be a QR code and, if none can be read, the background takes one picture of the visible tab (tabs.captureVisibleTab); the two-step QR code is decoded inside the extension and its otpauth:// link goes only to the PasswordPie app on the same Mac. Otherwise the content script reads nothing on a page until the user picks an account in the app, and it never submits the form.
```

### Remote code

```text
No, I am not using remote code.
```

All JavaScript is bundled in the package, including the jsQR decoder. The extension loads no scripts, WebAssembly or code strings from anywhere.

### Data usage

Collected and handled only on the user's Mac, never sent to the developer or a server:

- **Authentication information:** the username and password the user picks in the PasswordPie app, put into the page.
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
- **Publishing:** deferred. Submit with "publish automatically after review" turned **off**: the direct-download app
  released before the store ID was added cannot connect to the store build, so the listing goes live together with the
  app release that trusts it. Steps in [docs/BROWSER_EXTENSION.md](../../docs/BROWSER_EXTENSION.md), "Releasing the
  Chrome extension".
