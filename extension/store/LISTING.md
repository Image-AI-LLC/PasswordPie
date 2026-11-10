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

PRIVATE BY DESIGN
• Your passwords stay in your KeePass file on your Mac.
• The extension talks only to the PasswordPie app on the same Mac, through Chrome's native messaging. Nothing is sent to us or to any server.
• It tells the app only the site of the active tab (such as https://example.com), never the page's full address, its contents or your history.
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
Fill the username and password that the user picks in the PasswordPie app for Mac into the sign-in form of the current page.
```

### Permission justifications

**nativeMessaging**

```text
The extension's only channel to the PasswordPie app on the same Mac, through the native messaging host the app installs (com.oldcai.passwordpie). It sends the origin of the active tab (such as https://example.com) and receives the username and password the user picked in the app, and with Premium the two-step code. When the user is signed in to a PasswordPie account with Premium, it hands the app the signed Premium token from passwordpie.com, because the app has no sign-in of its own, and takes it back when the user signs out. When the app has an account for that site but no icon for it, it also sends a PNG of the site's icon. It is not used for anything else.
```

**webNavigation**

```text
webNavigation.getAllFrames lists the frames of the active tab, so that a fill is sent only to frames whose origin equals the account's site. Cross-origin frames, such as ads or embedded widgets, never receive a username or password.
```

**alarms**

```text
One alarm a minute checks the native messaging connection to the PasswordPie app and reconnects it if the app was restarted or the service worker was suspended. Without it, the extension stays disconnected until the next tab change.
```

**Host permissions (<all_urls>)**

```text
Sign-in pages can be on any website, and the user decides which ones by the accounts in their own password database. Host access lets the background read the URL of the active tab (only its origin is sent to the PasswordPie app, to find the accounts for that site) and lets the content script find and fill the username and password fields on the page the user asked to fill. When the app has an account for the site but no icon for it, the background also asks the content script of the top frame for the icon links the page declares (<link rel=icon>) and fetches that icon without cookies, to show it in the app's account list. Otherwise the content script reads nothing on a page until the user picks an account in the app, and it never submits the form.
```

### Remote code

```text
No, I am not using remote code.
```

All JavaScript is bundled in the package. The extension loads no scripts, WebAssembly or code strings from anywhere.

### Data usage

Collected (handled only on the user's Mac, never sent to the developer or a server):

- **Authentication information:** the username and password the user picks in the PasswordPie app, put into the page.
- **Web history:** the origin of the active tab, sent to the PasswordPie app on the same Mac to list that site's accounts.
- **Website content:** the site's icon, sent to the PasswordPie app on the same Mac when it has an account for that
  site but no icon for it.

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
