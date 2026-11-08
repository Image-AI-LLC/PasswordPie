# UX notes

How PasswordPie should feel, and why. Each section describes one behavior from the user's side, so it can be
reused for the website and for demo videos. A new behavior is written here before it is built.
Visual rules live in [DESIGN.md](../DESIGN.md).

## Pick up where you left off

**In one line:** copy a username, paste it, and press the shortcut again. Your account is still selected, so the
password is one keystroke away.

### The problem

Signing in takes more than one copy. You find the account, copy the username, and switch back to paste it. Then you
need the password, and the search box is empty. You type the same search again to reach the account you had a few
seconds ago.

### What happens now

For 10 seconds after the menu closes, opening it again brings back what you were looking at:

- the search text and its results
- the selected account, also inside a submenu such as Favorites or a folder

The copy shortcuts work straight away, with no typing and no arrow keys.

| Shortcut | Copies |
|---|---|
| ⌃⌘C | Username |
| ⇧⌘C | Password |
| ⌥⌘C | One-time password |

Every time the menu closes, the 10 seconds start again. You can copy the username, then the password, then the
one-time code, with one search.

The search text comes back selected. If you want something else, just type: the first letter replaces the old search.

### When it starts fresh

| What you did | Next time you open the menu |
|---|---|
| Copied, filled, clicked elsewhere, or pressed the shortcut to close | Same search and account, for 10 seconds |
| Waited 10 seconds or more | Empty search |
| Pressed Esc to close | Empty search. Esc means you are done. |
| Locked, auto-locked, or switched database | Empty search, and only after unlocking |
| The selected account was deleted or no longer matches | Same search, first result selected |

Esc works as before: the first press clears the search, and the next press closes the menu.

### Privacy

- The search text and the selected account are held in memory only, never written to disk, and locking clears them.
- Passwords are not part of what comes back. The details popover stays closed, so a password you revealed is hidden
  again. Press → to open the details of the selected account.

### Demo script

Use a database with two accounts on one site, so the video shows that the right one stays selected.

1. Press the menu shortcut and type `github`. Press ↓ to select the second account.
2. Press ⌃⌘C. The menu closes. Paste the username into the sign-in form.
3. Press the menu shortcut. The search and the same account are back. Do not touch anything else.
4. Press ⇧⌘C. The menu closes. Paste the password.
5. Press the menu shortcut, then press Esc twice to clear the search and close. Press the shortcut again: empty search.
6. Search again, copy, and wait 10 seconds. Press the shortcut: empty search.

## Premium: two-step codes

**In one line:** PasswordPie is free to install and free to use. Only two-step codes need Premium, and Premium belongs
to your PasswordPie account, so it follows you to every Mac and into the browser extension.

### The problem

A password manager that also makes your two-step codes saves a trip to your phone at every sign-in. That is the one
thing worth paying for. Everything else, including storing the secret itself, stays yours for free.

Premium used to live in two places that knew nothing of each other: Apple's purchase history in the App Store app, and
nothing at all in the downloaded app. A purchase on one Mac did nothing in the browser, and the downloaded app could not
tell who had paid.

### What happens now

The free version does everything except make a code: search, copy, fill, edit, import, Touch ID, pinned windows.

An item with a two-step code still says so. Its "one-time password" row shows a lock, "Included with Premium", and an
Upgrade button. Upgrade opens a small Premium window.

Where Premium comes from depends on where the app came from.

| | App Store app | Downloaded app |
|---|---|---|
| Premium comes from | A purchase on your Apple Account, or activation from passwordpie.com | The PasswordPie account you sign in to |
| Signing in inside the app | Never. There is no account in this version. | Sign in with Apple, Google, or email |
| What the app sends over the network | Nothing | Your sign-in, to passwordpie.com |

| Plan | What you pay |
|---|---|
| Lifetime | One payment, in your local currency. |
| Yearly | A subscription that renews each year until you cancel it. |

The downloaded app needs a signed-in account with Premium for codes. This replaces the decision of 2026-11-05 that its
codes were free for everyone (see "Premium" in [CHANNELS.md](CHANNELS.md) for the switch that brings that back).

### The App Store app: no account

A password manager that keeps everything on your Mac should not need an account, so this version has none. It has no
sign-in, it asks for no email, and it never talks to passwordpie.com.

1. Press a plan. Apple's purchase sheet opens. Confirm.
2. The codes appear: the row in an open popover or pinned window turns into a live code. There is nothing to relaunch and
   nothing to type in.

Apple remembers the purchase. On another Mac with the same Apple Account, Premium is already there; Restore Purchases asks
Apple again if it has not arrived. An Ask to Buy approval unlocks the codes by itself. All of it works offline once Apple
has told this Mac about the purchase.

### Premium from passwordpie.com, in the App Store app

If you already have Premium on passwordpie.com, you do not pay again. The website does the signing in, and the app only
receives the result.

1. On passwordpie.com, signed in, open Settings > Premium and press **Activate the App Store app**.
2. Your browser asks to open PasswordPie. Allow it.
3. The Premium window says "Premium is on through November 9, 2027." The codes are unlocked.

The app checks the signature on what it received, without going online. Activation lasts a year, or until your Premium
ends if that is sooner. Press the button again to renew it; you never need to wait for it to run out.

The app itself never mentions the website, because App Store rules do not allow it to point elsewhere to buy. A link
that is damaged or out of date says "This activation link is not valid or has run out." and changes nothing.

### The downloaded app

Sign in inside the app and the codes unlock if the account has Premium, wherever it came from: bought or redeemed on
passwordpie.com. The same account unlocks codes in the browser extension.

The Premium window and Preferences offer the same choices, in this order:

1. **Sign in with Apple.** The first button, in Apple's own style. One click if Safari already knows your Apple Account.
2. **Other ways to sign in.** Google, or email and password.

Both open passwordpie.com in a secure sign-in sheet that belongs to PasswordPie, and come straight back to the app.
The app never sees your password. What it keeps is a sign-in token, in your keychain, and it is never written to a log.

Sign Out, in Preferences, forgets the token. Codes lock until you sign in again. Your Premium stays on the account.

The downloaded app cannot sell through Apple. Its Premium window offers Get Premium, which opens passwordpie.com to buy,
and Redeem a Key, which opens passwordpie.com/redeem. Back in the app, Premium arrives the next time you open the menu, or
straight away with Check Again.

### What the shortcuts do

A shortcut for a code never does nothing, and it never empties your clipboard.

| What you press | With Premium | Without Premium |
|---|---|---|
| ⌥⌘C in the menu, on an item with a code | Copies the code, closes the menu | Closes the menu, opens the Premium window. The clipboard is unchanged. |
| ⌥⌘C with a pinned window, in any app | Copies the code | Opens the Premium window. The clipboard is unchanged. |
| ⌥⌘C on an item with no code | Nothing to copy, same as before | Nothing to copy, same as before |
| ⌥Return, ⇧Return (Open and Fill, Fill) | Types the username and password | Types the username and password |

Fill never types a code, on either version.

### Your data stays yours

Going free, signing out, or letting a subscription end never touches your database. The secret stays in the KeePass
file exactly as it was, and saving keeps it. Import brings codes in too. You can still add or change a secret in the
item editor, and other KeePass apps can still read it. Get Premium again and the codes come back.

### Offline

**App Store app.** Nothing here needs a connection. Apple's record of a purchase is on this Mac, and an activation is
checked by its signature.

**Downloaded app.** passwordpie.com hands the app a signed pass that lasts up to 7 days. The app checks the signature
itself, so a pass cannot be made up or copied from another account, and it keeps working with no connection until it runs
out.

| What happened in the downloaded app | What you see |
|---|---|
| Offline, pass still good | Codes work. Nothing to see. |
| Offline for longer than the pass lasts | Codes lock. "PasswordPie could not reach passwordpie.com to renew Premium. Codes unlock as soon as it can." and Check Again |
| The site signed you out (password changed, session removed) | Codes lock. "You were signed out. Sign in again to use Premium." |

### When Premium ends

- **Yearly runs out or is cancelled.** Codes lock when the paid year ends.
- **Apple refunds a purchase.** The App Store app locks the codes as soon as Apple tells this Mac.
- **An activation runs out.** Codes lock on that date in the App Store app, unless a purchase is also there.
- **A refund on passwordpie.com.** The downloaded app locks at its next check, within 7 days at the latest. An activation
  already in the App Store app cannot be taken back, because the app never talks to the site; it stops counting on the
  date it shows.

The app keeps no Premium flag of its own. What can unlock codes is Apple's verified purchase, or a signed pass or
activation, and only while its signature checks and it has not run out.

### Preferences

**App Store app:** a Premium section with what you have and until when, the plans you can still buy, Restore Purchases and
Manage Subscription. If you hold both plans, it reminds you that the yearly one keeps renewing until you cancel it.

**Downloaded app:** an Account section. Signed out: what Premium is, Sign in with Apple, and Other ways to sign in. Signed
in: the account's email, its Premium status, Sign Out, and Get Premium and Redeem a Key.

### When something goes wrong

| What happened | What you see |
|---|---|
| You close the sign-in sheet (downloaded app) | Nothing. The window stays as it was. |
| Sign-in fails (downloaded app) | "Could not sign in. Try again." |
| The App Store cannot be reached, or lists no plans | "The App Store did not return the plans", and Try Again |
| A purchase needs approval, such as Ask to Buy | "Waiting for approval". Premium unlocks by itself when it is approved. |
| You cancel the purchase | "Purchase cancelled." The plans stay. |
| The purchase fails | The reason from the App Store. The plans stay. |
| You already own the plan | The plan says "Owned" and cannot be bought twice. |
| Restore finds nothing | "No purchases to restore on this Apple Account." |
| An activation link is damaged or out of date | "This activation link is not valid or has run out." |

### Demo script

Use a database with one login that has a two-step code. For the App Store app, a sandbox Apple Account.

1. Press the menu shortcut, search for the login, and press → to open its details. The row shows the lock and Upgrade.
2. Copy something else to the clipboard. Press ⌥⌘C. The Premium window opens with the plans, and no sign-in anywhere.
   Paste: your clipboard is unchanged.
3. Pin the login with ⌘O. Buy Lifetime. The window closes, and the pinned window now shows a live code with its countdown.
4. Press ⌥⌘C and paste the code.
5. Turn Wi-Fi off and press ⌥⌘C again. The code still copies.
6. Activation from the website: on a Mac with no purchase, press Activate the App Store app on passwordpie.com and allow
   the browser to open PasswordPie. The window says Premium is on, and the codes unlock.

## Lock

**In one line:** press ⌘L and the vault locks with a click you can hear. The menu shows that it locked, then gets
out of your way.

### The problem

Locking used to be two clicks deep, in the gear menu. When it happened, the menu just vanished, so you could not tell
whether the vault locked or the menu only closed. And locking the Mac with the power button left the vault open: the
next person to press the shortcut saw every account.

The first version of the lock scene then showed the whole 360 pt lock screen inside whatever size the menu had. A
short menu cut off its top half, logo and all. And while a password was being checked, the form vanished and left
"Unlocking…" over a large empty space.

### What happens now

| What you do | What happens |
|---|---|
| Press ⌘L with the menu open | The vault locks. |
| Choose Lock in the gear menu | The same. ⌘L is shown next to it. |
| Lock the Mac: the power button, ⌃⌘Q, or the Lock Screen menu item | The vault locks, even if the screen never goes dark. |

Locking with the menu open plays a short scene, about 1.2 seconds in all:

1. The menu folds up into a small card, with the logo, "Locked" and the database name. The card keeps the menu's
   width and hangs from its top-left corner, so it is the same card whether the menu was a long list or a single
   line. The list is covered at once, and there is no password field, so nothing you type goes anywhere.
2. The logo settles and you hear the macOS padlock click, the same sound as the padlock in System Settings.
3. The card lifts slightly and fades out. Your screen is clear again.

Press the menu shortcut while it fades, and the card grows into the lock screen, ready for your password.

Locking while the menu is closed (idle, sleep, screen lock) is silent. Nobody wants a click from a Mac that is going to
sleep.

The sounds follow the system setting "Play user interface sound effects" in Sound settings. Turn that off and
PasswordPie is quiet too.

### Unlock

The lock screen is only as tall as what it holds: no empty band between Unlock and the Open / New links.

Press Return or Unlock and the form stays exactly where it is while the password is checked. The field and the links
dim, the button says "Unlocking…", and the logo's rim turns. Nothing moves or empties.

- **Right password.** The padlock's opening click plays, the form fades and the menu takes over.
- **Wrong password.** The window shakes, the password stays selected so you can retype it, and the line under the
  database name says what went wrong in red, in place of "Your passwords, kept safe." Typing puts the line back.

### Why ⌘L

⌘L is Lock in KeePassXC, Bitwarden and Strongbox, so it is the key people already try. It works only while the
PasswordPie menu is open, so it never takes ⌘L from another app, such as the address bar in a browser. The system's
own Lock Screen is ⌃⌘Q, which locks the Mac and, now, the vault with it.

### Settings

"When the screen locks or the screen saver starts" in Preferences covers the screen lock. It is on by default.

### Demo script

1. Press the menu shortcut and search for an account.
2. Press ⌘L. The menu folds into the Locked card, the padlock clicks, and the card fades away.
3. Press the menu shortcut. The lock screen is there, with an empty search behind it. Unlock: the form stays put,
   the button says "Unlocking…", then the padlock opens.
4. Lock again, then type a wrong password: the window shakes and the line under the database name turns red.
5. Press the power button once to lock the Mac. Log back in and press the menu shortcut: the vault is locked.

## Fill in the browser

**In one line:** in Chrome or Safari, press `⌘\` and the accounts for the site you are on are already at the top.
Press Return and PasswordPie fills the sign-in form. It never presses Sign In for you.

### The problem

Fill used to type: it pressed keys into whatever had focus. If the caret was in the wrong field, or the page was still
loading, the password went somewhere else. And to fill the site you were looking at, you first had to search for it,
although the browser already knew where you were.

### What happens now

With the PasswordPie extension in Chrome or Safari:

1. Press `⌘\` on a sign-in page. Above the usual menu, a group named after the site (`GITHUB.COM`) lists the accounts for
   that site, the first one selected. Accounts count as the same site when their website shares the domain you would
   register: `github.com`, `www.github.com` and `gist.github.com` are one site; `alice.github.io` and `bob.github.io` are two.
2. Press Return. The panel closes and the username and password appear in the form. The page does not submit.

Typing in the search box works as always: the first letter replaces the site group with search results.

Clicking the PasswordPie button in the browser's toolbar opens a small popup. Its first line is a large
**Open PasswordPie** button, there whether or not you are signed in: it does the same as `⌘\`, the panel opens over the
browser with the site's accounts at the top, and the popup closes. ⌥⇧P in the browser does the same without the popup
(Chrome lets you change it under `chrome://extensions/shortcuts`). If PasswordPie is installed but not running, the button
starts it and then opens the panel. If it is not installed, it opens passwordpie.com in a new tab, to download it. Below
it is your PasswordPie account: see "Premium in the browser".

| What you press on an account | The site in the browser is the account's site | It is another site |
|---|---|---|
| Return | Fills this page | Opens the account's website in a new tab of the same browser, and fills it when it loads |
| ⇧Return (Fill) | Fills this page | The same as Return: a new tab, then fill |
| ⌥Return (Open and Fill) | Opens the website in a new tab and fills it | The same |

Return fills from the account's details too. Press → to see the username and password, then Return: with the username or
password selected it fills, exactly as Return on the account's row does. On the other fields of the details (a website,
the one-time password, notes, your own fields) Return keeps doing what that field's button does: open, or copy.

A sign-in that asks for the username first and the password on the next step gets both: the username now, and the password
when its field appears, within 30 seconds.

Without the extension, or in any other app, Fill types the username and password as before.

### Getting the extension

When Chrome is in front and its extension is not connected, the panel's first line, above the search box, is
**Add Chrome Extension…** with Chrome's icon. Click it to open PasswordPie's page in the Chrome Web Store, in Chrome.
Once the extension is installed and talking to PasswordPie, the line goes away.

Safari has the same line, **Enable Safari Extension…**. It opens Safari's Extensions settings with PasswordPie selected,
where you turn it on.

Chrome is in the version downloaded from passwordpie.com. The App Store version has Safari only, for now.

### What it will not do

- Fill a page from another site than the account's. A look-alike domain gets nothing, because the domain is checked by
  PasswordPie, not by what the page says.
- Fill a frame from another site inside the page, such as an ad or an embedded widget.
- Fill a plain `http://` page with an account saved for `https://`.
- Fill anything while PasswordPie is locked.
- Hold on to a request: if no matching page shows up within 30 seconds, it is dropped. Each Return fills once.

### Privacy

- The site of the tab you are on (such as `https://github.com`, never the page or anything after it) goes from the
  extension to PasswordPie on your Mac, to find the accounts for it. It is kept in memory only, never written to disk or
  to a log, and never sent anywhere else.
- The username and password go only to the page you asked to fill, and only while PasswordPie is unlocked.
- The extension and PasswordPie check each other: Chrome lets only PasswordPie's extension start PasswordPie's helper, and
  PasswordPie answers only programs signed by Image AI, LLC.

### Demo script

Use a database with a GitHub login, and the PasswordPie extension installed in Chrome.

1. Open Chrome without the extension. Press `⌘\`: the first line is "Add Chrome Extension…". Install it; press `⌘\` again:
   the line is gone.
2. Go to github.com/login. Press `⌘\`. The top group is GITHUB.COM, with the login selected. Press Return: both fields fill,
   and the page stays on the sign-in form.
3. Reload the page. Press `⌘\`, press → to open the login's details, then Return: both fields fill the same way.
4. Go to example.com. Press `⌘\`, type `github`, press Return. A new tab opens github.com/login and fills it.
5. Lock PasswordPie with ⌘L and try again: nothing is filled until you unlock.
6. Repeat 2 to 4 in Safari after "Enable Safari Extension…".

## Site icons without telling anyone

**In one line:** accounts show their site's logo, and PasswordPie never asks an icon service for one. The best-known sites'
logos come with the app; the browser extension fills in the rest as you visit your own sites.

### The problem

A logo next to each account makes the list quick to scan. The usual way to get logos is to ask an online icon service
for every website in the database. That tells the service which sites you have accounts on, which is exactly what a
password manager should keep to itself.

### What happens now

- The logos of the 100 most popular sites (Google, GitHub, Wikipedia, …) are built into PasswordPie. Those accounts show
  their logo from the first launch, offline.
- Any other account shows its letter tile at first. The next time you open that site in Chrome or Safari with the
  PasswordPie extension, the extension hands PasswordPie the site's own icon, the one the tab shows. The account's
  row picks it up straight away, and it stays from then on.
- PasswordPie asks the extension for an icon only when the tab's site has an account in your database and that account
  has no logo yet. On every other site, the extension sends nothing.
- Without the extension, accounts outside the top 100 keep their letter tile.

### Where the logos live

- Logos from the extension are kept in PasswordPie's cache folder on this Mac (`~/Library/Caches`), under scrambled
  names. They are not written into your database file, so your KeePass file does not change and other KeePass apps are
  not affected. They are not synced to your other Macs.
- macOS may clear the cache to free space; the logos come back the next time you visit those sites.
- Later, there may be an option to save them into the database as KeePass custom icons, so they sync with it.

### What it will not do

- Ask Google or any icon service for a logo, so no icon service learns which sites you have accounts on. The app itself
  makes no network request for icons. The extension downloads the logo only from where the page you are on already
  loads it (the site, or the image host the page names), over https (plain http only from a page that is itself plain
  http), without cookies, and only when PasswordPie asked for it.
- Ask for a logo of a site you have no account for, or learn which pages you visit: the extension tells PasswordPie only
  the site of the tab, as it already does to find accounts.
- Take an icon it did not ask for, an icon for another site than the one it asked about, or something that is not a small
  image.

### Demo script

Use a database with a GitHub login and a login for a smaller site (say `news.ycombinator.com`), and the PasswordPie
extension in Chrome. Turn off Wi-Fi.

1. Press `⌘\`. GitHub shows its logo; the smaller site shows its letter tile.
2. Turn Wi-Fi back on and open the smaller site in Chrome. Press `⌘\`: its row now shows the site's logo.
3. Quit PasswordPie and open it again: the logo is still there.

## Premium in the browser

**In one line:** with Premium, the two-step code fills itself on the page after the password, so a sign-in with a code
is one Return.

### The problem

Filling the username and password got you to the "Enter the 6-digit code" page, and there you had to open PasswordPie
again, find the item and copy its code.

### What happens now

1. Press `⌘\` on a sign-in page and Return on an account that has a two-step code. The username and password fill, as
   before.
2. Press Sign In. When the page asks for the code, within 30 seconds, PasswordPie fills it: into one field, or one digit
   per box when the page splits it. It does not press Verify for you.

The code also fills when it is on the same page as the password. It fills once per Return; if the site rejects it, copy
a fresh one from the panel.

In the downloaded app, Premium belongs to your PasswordPie account, bought on passwordpie.com (once or yearly) or from a
key, and the extension needs you signed in to that account. In the App Store version the Safari extension has no account
at all: it fills codes whenever the app has Premium.

### The popup

| You are | The popup shows |
|---|---|
| Signed out | **Open PasswordPie**, then Sign In with email and password (and Continue with Google in Chrome), Create an account, Forgot password? |
| Signed in, free | Your email and Sign Out; "Free · Two-step codes in the browser need Premium." with **Upgrade** (opens the pricing page) and a "Have a key?" field |
| Signed in, Premium | "Premium · Lifetime" (or Yearly or Key, with the end date if it has one): "Two-step codes fill in the browser after the password." |

The popup asks passwordpie.com for your Premium every time it opens, and the extension asks once a day. Offline, it keeps
what it knew; a session that ended signs you out.

A key looks like `PPIE-XXXX-XXXX-XXXX`. Lowercase and missing dashes are fine. A wrong key says it is not valid, a used
one that it was already used, an old one that it has expired, and too many tries ask you to wait a minute.

### Without Premium

The username and password still fill. On the code page, a small note appears in the corner for 8 seconds:
"PasswordPie Premium fills two-step codes for you. Upgrade". It takes no focus and fills nothing. The popup, for the next
ten minutes, says "The two-step code on github.com was not filled: it needs Premium."

In the Safari extension of the App Store version there is no sign-in, no Upgrade link and no key field, and the note has no link. Its popup only offers Open PasswordPie.

### Privacy

- The code is made on your Mac when the page asks for it, goes only to that page, and is never saved or logged.
- Your Premium proof is a signed token from passwordpie.com. PasswordPie checks the signature itself, so a changed or
  expired token gets no code.
- The extension stores your sign-in and that token in the browser's extension storage. Sign Out removes both.

### Demo script

Use the mock site (`node extension/dev/mock-site.mjs`, then `WXT_PP_SITE_URL=http://localhost:8787 pnpm build:chrome`)
and a database item "Demo" with website `http://localhost:8787`, username `ada`, any password, and two-step code
`otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo`. Build with `make install` (or a debug build in a bundle signed
the same way: the bridge checks signatures); only those trust the test key.

1. Click the toolbar button: the popup shows Open PasswordPie and Sign In. Sign in as `ada@example.com` / `password`:
   "Free".
2. Open `http://localhost:8787/demo/login`, press `⌘\`, Return on Demo, then Sign In. The code page shows six empty
   boxes and the note in the corner. The popup says the code on localhost:8787 was not filled.
3. In the popup, redeem `PPIE-TEST-TEST-TEST`: "Premium · Key".
4. Repeat 2: the six boxes fill. Press Verify: "Signed in".
5. Redeem `PPIE-USED-USED-USED`: "That key was already used."
6. Sign Out, repeat 2: no code, and the note again.
