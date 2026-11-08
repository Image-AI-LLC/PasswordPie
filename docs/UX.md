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

Premium is a property of your **PasswordPie account**. Sign in inside the app and the codes unlock if the account has
Premium, wherever it came from: a purchase in the App Store app, or Premium bought or redeemed on passwordpie.com. The
same account unlocks codes in the browser extension.

| Plan | What you pay |
|---|---|
| Lifetime | One payment, in your local currency. |
| Yearly | A subscription that renews each year until you cancel it. |

Both versions of the app need a signed-in account with Premium for codes. This replaces the decision of 2026-11-05 that
the downloaded app's codes were free for everyone (see "Premium" in [CHANNELS.md](CHANNELS.md) for the switch that
brings that back).

### Signing in

The Premium window and Preferences offer the same choices, in this order:

1. **Sign in with Apple.** The first button, in Apple's own style. One click if Safari already knows your Apple Account.
2. **Other ways to sign in.** Google, or email and password.

Both open passwordpie.com in a secure sign-in sheet that belongs to PasswordPie, and come straight back to the app.
The app never sees your password. What it keeps is a sign-in token, in your keychain, and it is never written to a log.

Sign Out, in Preferences, forgets the token. Codes lock until you sign in again. Your Premium stays on the account.

### Buying in the App Store app

The App Store sets the prices and the currency. The window shows exactly what Apple gives it.

1. Press a plan. If you are not signed in yet, the window asks you to sign in first, with Sign in with Apple on top,
   so that Premium goes with your account. Once you are signed in, the purchase carries on by itself.
2. Apple's purchase sheet opens. Confirm.
3. "Adding Premium to your account…" for a moment, then the codes appear: the row in an open popover or pinned window
   turns into a live code. There is nothing to relaunch and nothing to type in.

A purchase that reaches this Mac while you are signed out, such as an Ask to Buy approval or a purchase from another
Mac, is never lost. It stays on this Mac, the Premium window says "Sign in to add this purchase to your account", and
it is added as soon as you sign in.

If passwordpie.com cannot be reached right after you buy, the window says your purchase is safe and that PasswordPie adds
it to your account as soon as it can. It tries again when you open the menu or bring the app forward.

### Restore Purchases and moving Premium to another account

One App Store purchase belongs to one PasswordPie account at a time.

Restore Purchases (sign in first if you have not) asks Apple for this Apple Account's purchases and adds them to your
account.

- **Already on this account, or on no account yet.** "Purchases restored." The codes unlock.
- **On another PasswordPie account.** PasswordPie asks first:

  > **Move Premium to this account?**
  > This purchase is on j•••@gmail.com. Moving it takes Premium from that account. A purchase can move to another
  > account once a year.
  >
  > [Cancel] [Move Premium]

  Move Premium moves it, and the window says so plainly: "Premium moved to this account. j•••@gmail.com no longer has
  Premium from this purchase."
- **Moved less than a year ago.** "This purchase moved to another account less than a year ago. It can move again on
  March 3, 2027." Nothing changes on either account.

The first time a purchase goes onto an account never counts as a move.

### The downloaded app

The copy from passwordpie.com cannot sell through Apple. Its Premium window offers Get Premium, which opens
passwordpie.com to buy, and Redeem a Key, which opens passwordpie.com/redeem. Back in the app, Premium arrives the next
time you open the menu, or straight away with Check Again.

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

passwordpie.com hands the app a signed pass that lasts up to 7 days. The app checks the signature itself, so a pass
cannot be made up or copied from another account, and it keeps working with no connection until it runs out.

| What happened | What you see |
|---|---|
| Offline, pass still good | Codes work. Nothing to see. |
| Offline for longer than the pass lasts | Codes lock. "PasswordPie could not reach passwordpie.com to renew Premium. Codes unlock as soon as it can." and Check Again |
| The site signed you out (password changed, session removed) | Codes lock. "You were signed out. Sign in again to use Premium." |

### When Premium ends

- **Yearly runs out or is cancelled.** Codes lock when the paid year ends.
- **Apple refunds a purchase.** Apple tells passwordpie.com, and the account loses Premium. Codes lock the next time the
  app checks, and within 7 days at the latest.
- **Premium moved to another account.** The same: this account's codes lock at the next check.
- **Another Mac.** Sign in with the same account. That is all.

The app keeps no Premium flag of its own. The only thing on disk that can unlock codes is the signed pass, and only
while its signature checks and it has not run out.

### Preferences

Preferences starts with an Account section:

- Signed out: what Premium is, Sign in with Apple, and Other ways to sign in.
- Signed in: the account's email, its Premium status, and Sign Out. In the App Store app also the plans you can still
  buy, Restore Purchases and Manage Subscription. If you hold both plans, it reminds you that the yearly one keeps
  renewing until you cancel it. In the downloaded app, Get Premium and Redeem a Key.

### When something goes wrong

| What happened | What you see |
|---|---|
| You close the sign-in sheet | Nothing. The window stays as it was. |
| Sign-in fails | "Could not sign in. Try again." |
| The App Store cannot be reached, or lists no plans | "The App Store did not return the plans", and Try Again |
| A purchase needs approval, such as Ask to Buy | "Waiting for approval". Premium unlocks by itself when it is approved. |
| You cancel the purchase | "Purchase cancelled." The plans stay. |
| The purchase fails | The reason from the App Store. The plans stay. |
| passwordpie.com cannot be reached after a purchase | "Your purchase is safe. PasswordPie adds it to your account as soon as it reaches passwordpie.com." |
| passwordpie.com does not accept the purchase | "passwordpie.com could not confirm this purchase with Apple. Press Restore Purchases to try again." |
| You already own the plan | The plan says "Owned" and cannot be bought twice. |
| Restore finds nothing | "No purchases to restore on this Apple Account." |

### Demo script

Use a database with one login that has a two-step code. For the App Store app, a sandbox Apple Account.

1. Press the menu shortcut, search for the login, and press → to open its details. The row shows the lock and Upgrade.
2. Copy something else to the clipboard. Press ⌥⌘C. The Premium window opens, asking you to sign in. Paste: your
   clipboard is unchanged.
3. Press Sign in with Apple. The window now shows the plans (App Store app) or Get Premium (downloaded app).
4. Pin the login with ⌘O. Buy Lifetime, or redeem a key on passwordpie.com and press Check Again. The window closes,
   and the pinned window now shows a live code with its countdown.
5. Press ⌥⌘C and paste the code.
6. Restore on a second account: sign out, sign in as someone else, press Restore Purchases, confirm Move Premium. The
   window names the first account, which no longer has Premium.

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

Clicking the PasswordPie button in the browser's toolbar does the same as `⌘\`: the panel opens over the browser, with
the site's accounts at the top. A second click while it is open brings it forward. If PasswordPie is installed but not
running, the click starts it and then opens the panel. If it is not installed, the click opens passwordpie.com in a new
tab, to download it.

| What you press on an account | The site in the browser is the account's site | It is another site |
|---|---|---|
| Return | Fills this page | Opens the account's website in a new tab of the same browser, and fills it when it loads |
| ⇧Return (Fill) | Fills this page | The same as Return: a new tab, then fill |
| ⌥Return (Open and Fill) | Opens the website in a new tab and fills it | The same |

A sign-in that asks for the username first and the password on the next step gets both: the username now, and the password
when its field appears, within 30 seconds.

Without the extension, or in any other app, Fill types the username and password as before.

### Getting the extension

When Chrome is in front and its extension is not connected, the panel's first line, above the search box, is
**Add Chrome Extension…** with Chrome's icon. Click it to open PasswordPie's page in the Chrome Web Store, in Chrome. Once the extension is installed
and talking to PasswordPie, the line goes away.

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
3. Go to example.com. Press `⌘\`, type `github`, press Return. A new tab opens github.com/login and fills it.
4. Lock PasswordPie with ⌘L and try again: nothing is filled until you unlock.
5. Repeat 2 and 3 in Safari after "Enable Safari Extension…".

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
