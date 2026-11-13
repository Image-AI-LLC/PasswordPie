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

**In one line:** PasswordPie is free to install and free to use. Only two-step codes need Premium. You get it where you
got the app, in the App Store or on passwordpie.com, and nothing ever asks you to sign in: not the app, and not the
browser extension.

### The problem

A password manager that also makes your two-step codes saves a trip to your phone at every sign-in. That is the one
thing worth paying for. Everything else, including storing the secret itself, stays yours for free.

For a while the browser extension had an account of its own: you signed in to it, and it carried Premium to the app.
That put a sign-in between a click on the toolbar button and your passwords. The extension is a bridge between the
browser and the app, and nothing more. Whether you have Premium is the app's business alone: it knows, it shows Upgrade
to unlock on the code's row when you do not, and it sends you to the right place to buy.

### What happens now

The free version does everything except make a code: search, copy, fill, edit, import, Touch ID, pinned windows.

An item with a two-step code still says so. Its "one-time password" row sits right under the password, with a small
lock after its name, six dots where the code would be, and an **Upgrade to unlock** button. The row is as tall as a live
code's, so nothing moves when Premium arrives. Clicking the row or the button opens a small Premium window. VoiceOver
reads the row as locked and included with Premium.

Where Premium comes from depends on where the app came from.

| | App Store app | Downloaded app |
|---|---|---|
| Premium comes from | A purchase on your Apple Account, or activation from passwordpie.com | Activation from passwordpie.com, where you buy it |
| Upgrade to unlock, on a code's row, opens | The plans, bought through Apple | The Premium window, whose **Get Premium** opens passwordpie.com |
| Signing in | Never. There is no account in this version. | Only on passwordpie.com, to buy and to press Activate. Never in the app or the browser extension. |
| What the app sends over the network | Nothing | Nothing |

| Plan | What you pay |
|---|---|
| Lifetime | One payment, in your local currency. |
| Yearly | A subscription that renews each year until you cancel it. |

The downloaded app needs Premium for codes. This replaces the decision of 2026-11-05 that its codes were free for everyone
(see "Premium" in [CHANNELS.md](CHANNELS.md) for the switch that brings that back). Neither app has a sign-in: the
downloaded one gave it up on 2026-11-10, and the browser extension gave up its own on 2026-11-11, so the two differ only
in how Premium is bought.

### The App Store app: no account

A password manager that keeps everything on your Mac should not need an account, so this version has none. It has no
sign-in, it asks for no email, and it never talks to passwordpie.com.

1. Press a plan. Apple's purchase sheet opens. Confirm.
2. The codes appear: the row in an open popover or pinned window turns into a live code. There is nothing to relaunch and
   nothing to type in.

Apple remembers the purchase. On another Mac with the same Apple Account, Premium is already there; Restore Purchases asks
Apple again if it has not arrived. An Ask to Buy approval unlocks the codes by itself. All of it works offline once Apple
has told this Mac about the purchase.

### Activation from passwordpie.com, in either app

If you already have Premium on passwordpie.com, you do not pay again. The website does the signing in, and the app only
receives the result.

1. On passwordpie.com, signed in, open Settings > Premium and press **Activate**.
2. Your browser asks to open PasswordPie. Allow it.
3. The Premium window opens and says Premium is on through November 9, 2027. The codes are unlocked. (The App Store app
   says "Premium is on through November 9, 2027."; the downloaded app shows that date in its status and confirms "The
   activation link worked.")

The app checks the signature on what it received, without going online. Activation lasts a year, or until your Premium
ends if that is sooner, for every plan, lifetime included. Press the button again to renew it; you never need to wait for
it to run out.

The App Store app never mentions the website, because App Store rules do not allow it to point elsewhere to buy. In it, a
link that is damaged or out of date says "This activation link is not valid or has run out." and changes nothing. The
downloaded app says which: "This activation link has run out." or "This activation link is not valid.", each followed by
"Press Activate on passwordpie.com for a new one."

### The downloaded app

The downloaded app has no sign-in either, and it cannot sell through Apple. Premium is bought on passwordpie.com and
reaches this Mac by activation, the same one as above:

1. On a locked code's row, press **Upgrade to unlock**. The Premium window opens. **Get Premium** opens passwordpie.com to buy,
   once or yearly; **Redeem a Key** opens passwordpie.com/redeem.
2. After the payment or the key, the page shows **Activate**. Press it and allow the browser to open PasswordPie.
3. The Premium window says Premium is on, and until when. The codes are unlocked, in the app and in the browser.

It lasts a year and needs no browser extension. To renew it, or to bring Premium to another Mac, press Activate in your
account settings on passwordpie.com.

The Premium window says what this Mac has and what to do next:

| What this Mac has | The Premium window says |
|---|---|
| Nothing | "Free", what Premium gives, **Get Premium** and **Redeem a Key**, then "Already have Premium? Press Activate in your account settings on passwordpie.com." and **Open Account Settings** |
| An activation | "Premium is on. Activated through November 9, 2027. To renew it, press Activate in your account settings on passwordpie.com again, at any time." and **Open Account Settings**. In its last 30 days, also: "Premium on this Mac ends on November 9, 2027. Renew it before then to keep your two-step codes." |
| The activation ran out | "Premium is off. The activation from passwordpie.com ended on November 9, 2027. Press Activate in your account settings to renew it." and the choices of "Nothing" |

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

Going free or letting a subscription end never touches your database. The secret stays in the KeePass
file exactly as it was, and saving keeps it. Import brings codes in too. You can still add or change a secret in the
item editor, and other KeePass apps can still read it. Get Premium again and the codes come back.

### Offline

**App Store app.** Nothing here needs a connection. Apple's record of a purchase is on this Mac, and an activation is
checked by its signature.

**Downloaded app.** The app never goes online either. An activation is signed by passwordpie.com; the app checks the
signature itself, so it cannot be made up, and it lasts its year with no connection at all.

### When Premium ends

- **Yearly runs out or is cancelled.** Codes lock when the paid year ends.
- **Apple refunds a purchase.** The App Store app locks the codes as soon as Apple tells this Mac.
- **An activation runs out.** Codes lock on that date, unless a purchase through Apple is also there.
- **A refund on passwordpie.com.** An activation already in either app cannot be taken back, because the app never talks
  to the site; it stops counting on the date it shows, and the site gives no new one.

The app keeps no Premium flag of its own. What can unlock codes is Apple's verified purchase, or a signed activation,
and only while its signature checks and it has not run out.

### Preferences

**App Store app:** a Premium section with what you have and until when, the plans you can still buy, Restore Purchases and
Manage Subscription. If you hold both plans, it reminds you that the yearly one keeps renewing until you cancel it.

**Downloaded app:** a Premium section with the words and buttons of the Premium window. No sign-in, no email, no Sign Out.

### When something goes wrong

| What happened | What you see |
|---|---|
| The App Store cannot be reached, or lists no plans | "The App Store did not return the plans", and Try Again |
| A purchase needs approval, such as Ask to Buy | "Waiting for approval". Premium unlocks by itself when it is approved. |
| You cancel the purchase | "Purchase cancelled." The plans stay. |
| The purchase fails | The reason from the App Store. The plans stay. |
| You already own the plan | The plan says "Owned" and cannot be bought twice. |
| Restore finds nothing | "No purchases to restore on this Apple Account." |
| An activation link is damaged or out of date (App Store app) | "This activation link is not valid or has run out." |
| An activation link has run out (downloaded app) | "This activation link has run out. Press Activate on passwordpie.com for a new one." |
| An activation link is damaged, or is not an activation (downloaded app) | "This activation link is not valid. Press Activate on passwordpie.com for a new one." |

### Demo script

Use a database with one login that has a two-step code. For the App Store app, a sandbox Apple Account.

1. Press the menu shortcut, search for the login, and press → to open its details. The row shows the lock, six dots and Upgrade to unlock.
2. Copy something else to the clipboard. Press ⌥⌘C. The Premium window opens with the plans, and no sign-in anywhere.
   Paste: your clipboard is unchanged.
3. Pin the login with ⌘O. Buy Lifetime. The window closes, and the pinned window now shows a live code with its countdown.
4. Press ⌥⌘C and paste the code.
5. Turn Wi-Fi off and press ⌥⌘C again. The code still copies.
6. Activation from the website: on a Mac with no purchase, press Activate on passwordpie.com and allow the browser to open
   PasswordPie. The window says Premium is on, and the codes unlock.

For the downloaded app (`make install`, or a debug build in a bundle signed the same way: only those trust the test key):

1. Press ⌥⌘C on the login: the Premium window opens with Get Premium, Redeem a Key and Open Account Settings. No sign-in
   anywhere.
2. Open an activation link (`node Scripts/mint-activation-link.mjs`): the window says Premium is on through a date a year
   away. Press ⌥⌘C: the code copies.
3. Quit the browser and PasswordPie, open PasswordPie again: still on.

## The newest password wins

**In one line:** change a password in Chrome, and PasswordPie fills the new one next time. The old one is a click away.

This is the version downloaded from passwordpie.com. The App Store version does not read Chrome.

### The problem

You change a password when a site asks, and Chrome saves it. Your database still holds the old one. Filling it fails,
and you have to work out which of the two values is right.

### What happens now

The newest password wins, whichever side it came from. There is no Save button, no notice and no list of conflicts on
the main screen. Older passwords go into a collapsed **previous passwords** section in the account's details, and one
click brings any of them back.

- Return, Copy, Fill and the browser extension always use the saved password.
- Chrome is never changed. Restoring an old password here does not change the website or Chrome either.
- For 7 days after a Chrome update the label reads `password · [Chrome] updated 2 days ago`. Passwords you changed
  here have no icon.
- An account with anything synced from Chrome has a small Chrome badge on its icon. A favorite shows only its star.

### Which password is newest

| Chrome's password | What happens |
|---|---|
| Changed later than the saved one | It becomes the saved password. The old one goes to previous passwords. |
| Older, or changed at exactly the same time | The saved password stays. Chrome's goes to previous passwords. |
| No date, a date of 0, or a date in the future | The saved password stays. Chrome's goes to previous passwords as `date unknown`. |
| Several Chrome profiles disagree | The latest change wins. The others go to previous passwords. |

Chrome's date is when that login's password last changed. The saved password's date is when PasswordPie changed it. If
PasswordPie did not, it is the time of the oldest saved version still holding this password, so favoriting an account
does not make its password look new.

### When it does not replace anything

A password is replaced only on the same account: one live saved item, the same username with the same capitals, the
same scheme, host and port, and an ordinary sign-in form. Anything else stays a separate row, so nothing overwrites
another account.

- An item marked keep-separate never takes a Chrome password.
- An item that serves several sites is not changed by one of them. Chrome's password goes to its previous passwords,
  and you can adopt it there.
- A database PasswordPie cannot write back in place, such as a CSV, is left alone.

### Previous passwords

Below strength, closed by default, with its count: `▸ previous passwords (2)`. Each row shows when the password was set
on top, and the value with **Restore** and **Copy** on the right. A Chrome password that was never used shows **Use** and
`not used yet`.

- Up to 10 passwords, each kept for 90 days from when it entered the list. Your own history setting does not affect it.
- The password most recently replaced is always kept. Passwords from Chrome that were never used go first.
- **Restore** takes one click and no confirmation, because the password it replaces moves into the same list. Chrome's
  change that you just undid does not come back. If you change the password in Chrome again later, that newer change wins.
- `⋯` on the open header has **Clear Previous Passwords**, which asks first, because it cannot be undone.

Keyboard: up and down move between rows. On a previous password, Return copies and never fills, and ⌘Return restores.
After Restore, the selection moves to the `previous passwords` header, where Return only folds the list.

### Many at once

More than 10 updates inside 24 hours, including the first time after upgrading, write nothing. One row appears in the
panel, and the panel still works normally:

`12 passwords changed in Chrome   Review   ×`

**Review** lists the accounts, read-only, with one **Apply 12 Updates** button. **×** keeps the saved passwords and does
not ask about that batch again. Chrome's values stay under previous passwords.

### When something goes wrong

It is silent when it works. If the update cannot be written, the details show:

`[Chrome] Couldn't update. Using the saved password.`  **Try Again**

The database is only replaced after the new file reads back correctly and the file on disk is still the one PasswordPie
opened, so another app's or a sync client's change is never overwritten. A failed Restore shows on its own row and
changes nothing.

### Settings

Under the Chrome switch in Preferences: "Newer Chrome passwords replace saved ones. Chrome isn't changed."

### Demo script

Use a test database with `github.com` / `ann`, and Chrome signed in to the same account.

1. Change the password in Chrome. Press `⌘\`: the row shows the Chrome badge, and the details say `updated just now`.
2. Open **previous passwords (1)**. Press ⌘Return: the old password is back, and the Chrome one is in the list.
3. Change it in Chrome again: the newer change wins.
4. Change a dozen passwords, or use a database that is behind: the panel shows `12 passwords changed in Chrome`. Click
   **Review**, then **Apply 12 Updates**.

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

Clicking the PasswordPie button in the browser's toolbar does the same as `⌘\`: the panel opens over the browser with
the site's accounts at the top. There is no popup in between, and nothing to sign in to. ⌥⇧P in the browser does the same
(Chrome lets you change it under `chrome://extensions/shortcuts`). If PasswordPie is installed but not running, the button
starts it and then opens the panel. If it is not installed, it opens passwordpie.com in a new tab, to download it.
Right-click the button for **Scan QR code on this page** (see "Scan a two-step QR code") and, in Chrome, **Open
passwordpie.com**.

| What you press on an account | The site in the browser is the account's site | It is another site |
|---|---|---|
| Return | Fills this page | Opens the account's website in a new tab of the same browser, and fills it when it loads |
| ⇧Return (Fill) | Fills this page | The same as Return: a new tab, then fill |
| ⌥Return (Open and Fill) | Opens the website in a new tab and fills it | The same |

Return fills from the account's details too. Press → to see the username and password, then Return: with the username or
password selected it fills, exactly as Return on the account's row does. On the other fields of the details (the one-time
password, a website, notes, your own fields) Return keeps doing what that field's button does: open, or copy.

A sign-in that asks for the username first and the password on the next step gets both: the username now, and the password
when its field appears, within 30 seconds.

Without the extension, or in any other app, Fill types the username and password as before.

### Getting the extension

When Chrome is in front and the profile you are using has no connected extension, the panel's first line, above the
search box, is **Add Chrome Extension…** with Chrome's icon. Click it to open PasswordPie's page in the Chrome Web
Store, in that Chrome profile. Once the extension is installed and talking to PasswordPie, the line goes away.

Safari has the same line, **Enable Safari Extension…**. It opens Safari's Extensions settings with PasswordPie selected,
where you turn it on.

The same two are always in **Preferences → Browser extensions**, whether or not a browser is in front. Each browser has
a line that says where it stands (**Connected**, **Connected in 2 profiles**, **Not connected**; **On** or **Off** for
Safari) and its button: **Add Chrome Extension…**, and **Enable Safari Extension…** (**Open Safari Settings…** once it
is on). **Add Chrome Extension…** stays there after Chrome is connected, because another profile may still need it.
**Browser Extensions…** in the gear menu, and in the menu that Option-clicking the menu bar icon opens, goes straight
to that section.

Chrome is in the version downloaded from passwordpie.com. The App Store version has Safari only, for now.

### More than one Chrome profile

Chrome keeps extensions per profile, so the PasswordPie extension in your work profile does nothing for your personal
one. PasswordPie goes by the profile whose window is in front:

- **A profile with the extension.** The site group is that window's tab, and Return fills that tab. A tab in another
  profile is never filled, even when it is on the same site.
- **A profile without it.** The first line is **Add Chrome Extension…**, and it opens the store page in that profile.
  Until it is installed there, PasswordPie does not go by what another profile's extension says: the site group comes
  from the window's address when PasswordPie has Accessibility access, and is left out when it has not, and Fill types
  the username and password, as in any app without the extension.
- **An Incognito window** counts as a profile without the extension, until you turn on "Allow in Incognito" for
  PasswordPie in `chrome://extensions`.

To add the extension to another profile later, bring a window of that profile to the front in Chrome, then choose
**Add Chrome Extension…** in Preferences: the store page opens in the profile you used last.

### What it will not do

- Fill a page from another site than the account's. A look-alike domain gets nothing, because the domain is checked by
  PasswordPie, not by what the page says.
- Fill a frame from another site inside the page, such as an ad or an embedded widget.
- Fill a plain `http://` page with an account saved for `https://`.
- Fill anything while PasswordPie is locked.
- Hold on to a request: if no matching page shows up within 30 seconds, it is dropped. Each Return fills once.

### Privacy

- The site of the tab you are on (such as `https://github.com`, never the page or anything after it) goes from the
  extension to PasswordPie on your Mac, to find the accounts for it. Chrome's extension also says whether a window of
  its profile is in front, and nothing else about your windows. It is kept in memory only, never written to disk or
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
7. Two Chrome profiles, the extension only in the first, both on github.com/login. In the first, `⌘\` shows GITHUB.COM
   and Return fills. Click the second profile's window and press `⌘\`: the first line is "Add Chrome Extension…", and
   ⇧Return types into this window; the first profile's tab stays empty. Click the line: the store page opens in the
   second profile.
8. Open Preferences from the gear menu's Browser Extensions…: Chrome says "Connected", with Add Chrome Extension… next
   to it.

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

The extension has no account and no sign-in. It asks PasswordPie on this Mac for the code, and the app answers when it
has Premium: a purchase in the App Store version, an activation in the downloaded one (see "Premium: two-step codes").

### The toolbar button

A click on the toolbar button opens PasswordPie, as `⌘\` does. It never opens a popup: the extension has nothing of its
own to show.

Right-click the button for the rest. These lines are above the browser's own (Pin, Manage Extension…):

| Line | What it does |
|---|---|
| **Scan QR code on this page** | Reads the two-step QR code the page shows. See "Scan a two-step QR code". |
| **Open passwordpie.com** | Opens the website in a new tab. In Chrome only: the Safari extension also ships inside the App Store app, which does not send you to a site that sells Premium. |

The same scan is in the page's own right-click menu, as **Scan QR code with PasswordPie**, so you can right-click the QR
code itself.

### Without Premium

The username and password still fill. On the code page, a small note appears in the corner for 8 seconds:
"PasswordPie Premium fills two-step codes for you. Upgrade". It takes no focus and fills nothing. **Upgrade** opens the
Premium window of PasswordPie on this Mac, the one a locked code's row opens: the plans in the App Store version, Get
Premium on passwordpie.com in the downloaded one. The extension itself links to no shop, and is the same in both.

### Privacy

- The code is made on your Mac when the page asks for it, goes only to that page, and is never saved or logged.
- The extension knows nothing about Premium. It asks for the code, and gets one or does not.
- The extension stores nothing in the browser: no account, no session, no token.

### Demo script

Use the demo pages (`node extension/dev/mock-site.mjs`, then `pnpm build:chrome`) and a database item "Demo" with website
`http://localhost:8787`, username `ada`, any password, and two-step code
`otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo`. Build the app with `make install` (or a debug build in a
bundle signed the same way: the bridge checks signatures); only those trust the test key.

1. Click the toolbar button: the PasswordPie panel opens over the browser. No popup.
2. Open `http://localhost:8787/demo/login`, press `⌘\`, Return on Demo, then Sign In. The code page shows six empty
   boxes and the note in the corner. Click Upgrade in the note: the Premium window of PasswordPie opens.
3. Open an activation link (`node Scripts/mint-activation-link.mjs`): the window says Premium is on.
4. Repeat 2: the six boxes fill. Press Verify: "Signed in".
5. Right-click the toolbar button: Scan QR code on this page and Open passwordpie.com (Safari: the scan only).

## A new database says what to do next

**In one line:** open PasswordPie on a new, empty database and the menu leads with a "Get Started" group: the ways to
fill it, each with one line on what it does.

### The problem

A first-time user with an empty database saw one row, Password Generator, already highlighted. Resting the pointer on
it did nothing, because the row was selected before the pointer got there and hover only reacted to a change of row.
There was nothing else in the menu and no hint of where passwords come from. A first fix added the three actions as
plain menu rows under a greyed-out "No items yet", after the generator; they read like any other menu command, and
said nothing about what they lead to.

### What happens now

The menu of an empty database (nothing outside the Recycle Bin) is:

- A **GET STARTED** group header, in place of "No items yet".
- Two-line rows, each with an orange icon tile, a title and one line under it:
  - **Import Passwords…** — "From a Chrome or Apple Passwords export". Opens Preferences at Import passwords, which
    takes those two exports in both builds.
  - **Sync Chrome Passwords…** — "Search what Chrome saved on this Mac". Opens Preferences at Chrome. Only in the
    download from passwordpie.com; the App Store app cannot read Chrome. It does not turn sync on by itself: that asks
    macOS for the Chrome key, and you should see why first. With sync on, Chrome's passwords show up in search next to
    your own, read from Chrome's files on this Mac, and Chrome is never changed.
  - **New Item…** — "A login, password or secure note". Opens the editor, as New Item in the gear menu. The editor has
    no card or identity fields, so the line names only what it can make.
- A separator, then **Password Generator**, last. Resting the pointer on it opens the generator after 0.2 s, like any
  submenu.

Import Passwords… is selected when the menu opens. The arrow keys move through the actions and the generator; Return or
a click runs a row and hides the menu. The pointer on an action row only selects it. VoiceOver reads a row's title, then
its line.

The group goes away with the first item, and the menu is the usual one, with the generator back near the top. When the
browser is on a site with saved accounts, those come first and hold the first selection, as always. Searching an empty
database still says "No items found".

Hover works the same for any row that is selected but not open: the first row of a full menu (Favorites, or the site
the browser is on) opens when the pointer moves onto it, and an account the arrow keys moved to shows its details.

### Demo script

1. Choose New Database… in the gear menu and create one. The menu shows "Get Started", Import Passwords… highlighted,
   the other actions, and Password Generator at the bottom.
2. Move the pointer onto Password Generator: the generator opens.
3. Choose Import Passwords…: Preferences opens at Import passwords. Close it.
4. Open the menu, choose New Item…, and save an item. Open the menu again: the group is gone, and the item's
   category is there.

## Scan a two-step QR code

**In one line:** when a website shows the QR code for two-step sign-in, PasswordPie reads it from the page or from a
screenshot, so the code lands in the right item without typing a secret.

### The problem

Turning on two-step sign-in, a site shows a QR code and asks for the 6-digit code it makes. PasswordPie took only the
secret as text: you had to find the site's "can't scan it?" link, copy a long Base32 string and paste it into the item
editor. Most people gave up and used their phone.

### What happens now

**From the browser (with the extension).** On the page that shows the QR code:

1. Right-click the QR code (or anywhere on the page) and choose **Scan QR code with PasswordPie**. Or right-click the
   PasswordPie button in the toolbar and choose **Scan QR code on this page**.
2. PasswordPie opens an **Add Two-Step Code** window over the browser: the site and account the QR code names, and the
   item to add it to, already chosen. The best guess is the item for this site whose username is that account; other
   items for the site are listed under it. An item on another site that only names the issuer is listed, not chosen. You
   can search for any other item, or choose **New Item**.
3. Press **Add**. The window shows the current code, with **Copy**. If the page has a field for the code, the extension
   fills it, as it does after a sign-in. Press the site's Verify button yourself.

If PasswordPie is locked, it asks you to unlock first, then shows the window. Nothing is saved until you press Add.

A scan that finds nothing to hand over says why in a small note in the corner of the page, for 8 seconds, like the note
about Premium. When the page cannot show a note (a browser page, such as Settings), the toolbar button carries a "!" for
a few seconds and its tooltip says why.

**From a screenshot or an image, in the item editor.** Press ⌃⇧⌘4 and drag over the QR code: macOS copies it to the
clipboard. In the item's editor, click the QR button at the end of the **One-time password** row. The row fills in, and
the current code shows under it. The button's menu also has **Choose Image…**. You can also drag an image (or its file)
onto the row, or paste it into the field with ⌘V. A copied `otpauth://` link works the same way.

Scanning and saving the secret is free. Seeing the code needs Premium: without it, the window and the editor show the
code row locked, six dots and **Upgrade to unlock**, as an item's details do.

### Replacing a code

If the item already has a two-step code, Add asks **Replace the existing code?** first. Replace keeps the old one in the
item's history in the database file, where KeePassXC and other KeePass apps show it, so a slip can be undone.

### What it will not do

- Scan anything you did not ask it to. The extension looks at the page only when you choose Scan in a right-click menu;
  a page cannot ask for it, and nothing scans by itself.
- Send the picture or the secret anywhere. The QR code is read on your Mac (the app uses macOS's own Vision) and inside the
  browser extension. The secret goes only from the extension to PasswordPie on this Mac. Nothing is stored in the browser
  or logged.
- Tell the page or the extension what is in your database. The extension hands the QR code over and learns only that
  PasswordPie got it.
- Keep a scan you did not confirm: it is dropped after 2 minutes, when you press Cancel, or when you scan another one.
- Record the screen or use the camera. On a page whose QR code the extension cannot read directly, it takes one picture of
  the visible tab, as a screenshot would, and only after you chose Scan.
- Counter-based (HOTP) codes, Steam codes, and Google Authenticator's "Transfer accounts" export. Each gets a plain message.

### When something goes wrong

| What happened | What you see |
|---|---|
| No QR code on the page or in the image | "No QR code found." |
| The clipboard has no image and no `otpauth://` link | "Copy a screenshot of the QR code first, or an otpauth:// link." |
| A QR code that is not for two-step sign-in | "This QR code is not a two-step code. Two-step QR codes start with otpauth://." |
| A counter-based code | "This is a counter-based (HOTP) code. PasswordPie makes time-based codes only." |
| Google Authenticator's export | "This is a Google Authenticator export. Scan the QR code the website shows instead." |
| A damaged secret, or unusual settings | One line saying which: the secret, the number of digits (6 to 8), the time step, or the algorithm (SHA1, SHA256, SHA512) |
| Two minutes passed before Add | "This scan has expired. Scan the QR code again." |
| PasswordPie is not running | The extension starts it, as a click on its toolbar button does |

### Demo script

Use a database with an item "Demo" (website `http://localhost:8787`, username `ada`), and a page showing the QR code for
`otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo`.

1. Open the page in Chrome. Right-click the QR code and choose Scan QR code with PasswordPie. The Add Two-Step Code
   window shows Demo and ada, with the Demo item chosen. Press Add: the code shows, counting down. Copy it.
   Right-click a page without a QR code and choose the same: the note in the corner says "No QR code found on this page."
   Right-click the toolbar button and choose Scan QR code on this page: the same window.
2. Scan again and press Add: "Replace the existing code?" Press Replace.
3. Lock PasswordPie with ⌘L and scan again: the unlock screen opens first, then the window.
4. In PasswordPie, open a new item's editor. Press ⌃⇧⌘4 over the QR code, then click the QR button in the One-time password
   row: the link fills in and the code shows. Save.
5. Copy some text and click the QR button: "Copy a screenshot of the QR code first, or an otpauth:// link."

## A key file that stays on this Mac

**In one line:** give a database a second key, a small file that stays on your Mac. A copy of the database that leaks
from a cloud folder cannot be opened with the master password alone, and every day you still unlock with just the
password or Touch ID.

### The problem

A KeePass database is one file, usually in a cloud folder so it reaches every device. If that folder leaks and the
master password is weak or reused, everything in it is readable, two-step secrets included. Encrypting the two-step
field separately would not help: the same password would open it. What helps is a second key the thief does not have,
the way 1Password's Secret Key stays on your devices. KeePass has one already, the key file, and KeePassXC, KeePassium
and Strongbox all understand it. PasswordPie could only use one for old KeePass 1 imports.

### What happens now

**Preferences > Database > Key file**, for the database that is open:

- **Add Key File…** makes a new key file: 32 random bytes in the KeePass XML 2.0 format that KeePassXC writes. You
  choose where to save it. PasswordPie reads the saved file back and checks it, then saves the database again,
  locked with the password and the key file. Saving it in the database's own folder asks again, because that folder is
  usually the one that syncs.
- **Use Existing Key File…** uses a file you already have, such as one from KeePassXC.
- **Remove Key File…** goes back to the password alone.
- **Forget Key File** forgets it on this Mac only. The database still needs it; the next unlock asks for the file.

Each change asks first, with the same warning: *Without this key file, the database cannot be opened, and PasswordPie
cannot recover it. Keep a backup somewhere else: not in the database's folder, and not in the same cloud storage.*

The database is written to a new file first. PasswordPie opens that file with the new keys, and only then replaces the
database. If anything fails, the database is left as it was and still opens with the old keys. The copy PasswordPie
keeps beside the database (`.snapshot`) is replaced too, so no file in that folder opens with the password alone.
Older copies elsewhere, such as your cloud's version history or a Time Machine backup, still open with the old keys.

**Unlocking.** The first time a database opens with a key file, PasswordPie keeps the key file in this Mac's login
keychain, for that database only. From then on the lock screen shows the file's name under the password field, and you
type the password or use Touch ID as before. The × next to the name forgets it, like Forget Key File. Choosing the
file again on the lock screen keeps it again after the next unlock.

**A new database** can have a key file from the start: Add Key File… on the New Database screen, under the two
password fields, makes a new one or uses an existing one.

**Change Master Password…** sits below it: the current password, then the new one twice. The key file stays as it
is.

A wrong password with a key file says "Incorrect password or key file." A damaged key file (a KeePass XML file whose
checksum does not match) says so, instead of blaming the password.

A database another app gave a key file (KeePassXC, KeePassium, Strongbox) opens the same way: choose the key file on
the lock screen once. PasswordPie reads every KeePass key file format: XML 1.0 and 2.0, a 32-byte file, a 64-character
hex file, and any other file, whose contents become the key.

### When it does not apply

- Imported files (CSV, 1Password, Bitwarden, Proton Pass) have no key file. A KeePass 1 database with a key file keeps
  it: the `.kdbx` written from it uses the same password and key file.
- Changing keys needs a `.kdbx` that PasswordPie can write, opened and unlocked.
- No hardware keys (YubiKey) and no challenge-response.
- Databases you already have are never given a key file or changed by themselves.

### Privacy

The key file never leaves this Mac. PasswordPie keeps a copy of its contents in the login keychain, next to the
Touch ID secret, so the App Store version needs no access to the place you saved it. Removing the database from the
list in Preferences forgets it too; the file you saved stays where it is.

### Demo script

1. Open a database and choose Preferences > Database > Add Key File…. Read the warning, choose Continue, and save the
   key file to Documents.
2. Lock with ⌘L. Open the menu: the lock screen shows the key file's name. Type the master password: it unlocks.
3. Copy the `.kdbx` to another folder and open that copy in KeePassXC with the password only: it refuses. Add the key
   file: it opens.
4. On PasswordPie's lock screen, click × next to the key file's name. Type the password: the window shakes, "Incorrect
   password." The password alone no longer opens it.
5. Choose Key File…, pick the file in Documents, and unlock. The name is back for the next time.
