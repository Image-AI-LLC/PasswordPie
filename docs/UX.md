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

**In one line:** PasswordPie is free to install and free to use. Only two-step codes need Premium (and, in the
downloaded app, agents' standing permissions: see "Do not ask me every time"). You get it where you
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

An item with a two-step code still says so. Its "one-time password" row sits under the password and its strength bar,
with a small lock after its name, six dots where the code would be, and an **Upgrade to unlock** button. The row is as
tall as a live code's, so nothing moves when Premium arrives. Clicking the row or the button opens a small Premium
window. VoiceOver reads the row as locked and included with Premium.

Where Premium comes from depends on where the app came from.

| | App Store app | Downloaded app |
|---|---|---|
| Premium comes from | A purchase on your Apple Account, or activation from passwordpie.com | Activation from passwordpie.com, where you buy it |
| Upgrade to unlock, on a code's row, opens | The plans, bought through Apple | The Premium window, whose **Get Premium** opens passwordpie.com |
| Signing in | Never. There is no account in this version. | Only on passwordpie.com, to buy and to press Activate. Never in the app or the browser extension. |
| What the app sends over the network | Nothing | Nothing. Its separate updater asks GitHub for a newer version once a week: see [Updates that install themselves](#updates-that-install-themselves) |

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

**App Store app:** a Premium pane with what you have and until when, the plans you can still buy, Restore Purchases and
Manage Subscription. If you hold both plans, it reminds you that the yearly one keeps renewing until you cancel it.

**Downloaded app:** a Premium pane with the words and buttons of the Premium window. No sign-in, no email, no Sign Out.

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

Under the Chrome switch in Preferences > Browsers: "Newer Chrome passwords replace saved ones. Chrome isn't changed."

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
   An account's reset link counts as one of its websites here: on the page where you change the password, the account
   is listed and fills too ("A reminder to change a password").
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

The same two are always in **Preferences > Browsers**, under Extensions, whether or not a browser is in front. Each browser has
a line that says where it stands (**Connected**, **Connected in 2 profiles**, **Not connected**; **On** or **Off** for
Safari) and its button: **Add Chrome Extension…**, and **Enable Safari Extension…** (**Open Safari Settings…** once it
is on). **Add Chrome Extension…** stays there after Chrome is connected, because another profile may still need it.
**Browser Extensions…** in the gear menu, and in the menu that Option-clicking the menu bar icon opens, goes straight
to that pane.

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
4. Repeat 2: the six boxes fill. Press Verify: "Welcome back, Sam".
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
  - **Import Passwords…** — "From a browser or a password manager". Opens Preferences at Import, which leads
    through the export and takes the file ("Import with a guide"), in both builds.
  - **Sync Chrome Passwords…** — "Search what Chrome saved on this Mac". Opens Preferences at Browsers. Only in the
    download from passwordpie.com; the App Store app cannot read Chrome. It does not turn sync on by itself: that asks
    macOS for the Chrome key, and you should see why first. With sync on, Chrome's passwords show up in search next to
    your own, read from Chrome's files on this Mac, and Chrome is never changed.
  - **New Item…** — "A login, password or secure note". Opens the editor, as New Item in the gear menu. The editor has
    no card or identity form (a card is fields you add yourself: "Edit every field of an item"), so the line names
    only what it makes directly.
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
3. Choose Import Passwords…: Preferences opens at Import, on the list of sources. Close it.
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
| The item was moved to the trash or removed before the code was saved | "That item is no longer in the database. Choose another." The scan stays. |
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

## Updating from PasswordPie 0.1.0

PasswordPie 0.1.0 had another identity on the Mac. The next version is the same app under the name it keeps from now on,
so macOS treats it as new in a few places.

### What carries over

Your databases, the list in Preferences, the shortcuts and every other setting. The Chrome extension keeps working, with
the version you have and with the next one.

### What asks again, once

- **The master password.** The first unlock is with the master password; Touch ID works again from the next lock.
- **A key file**, if a database has one: choose it on the lock screen once more.
- **Accessibility access**, at the first Fill: macOS asks again. In System Settings, PasswordPie may be listed twice;
  turn on the one that is off. The other one can be removed with −.
- **The Safari extension**: turn PasswordPie on again in Safari > Settings > Extensions.
- **AutoFill**, if you turned PasswordPie on in System Settings > General > AutoFill & Passwords: turn it on again there.
- **Premium**: press Activate in your account settings on passwordpie.com again.

Nothing asks about what the old version kept in the keychain: it is left alone. One prompt can come from Chrome, not
from the update: with Chrome passwords turned on, macOS asks once more whether PasswordPie may use "Chrome Safe
Storage". Choose Always Allow, as the first time.

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

## Edit every field of an item

**In one line:** the editor shows everything an item holds: add a second website, and rename, change or delete
any other field, including the ones an import brought in.

### The problem

The editor had one Website box and no rows for anything else. An account that works on two sites (a shop and its
checkout domain) could only get its second website from an automatic merge or from Chrome. Fields from an import or a
merge (`no_name_eeaae`, `Group (2)`, a second title) showed in the details and, on a merged item, as a read-only list
in the editor. There was no way to fix or delete them.

### What happens now

The editor is one sheet: the site icon, the title and a star for Favorite at the top, then rows with the name on the
left and the value beside it.

**Websites.** Under the last Website row is **Add Website**. Press it for one more row; each website ends with a **−**
that removes it. Every website counts the same: search finds the item by any of them, and Fill offers the item on any
of them. Websites that came from a merge, from Chrome or from an import are rows here too.

- Remove or clear the first website and the next one takes its place.
- An empty row is dropped when you save.

**Other fields.** Every field without a row of its own is listed under **Other fields**: its name on the left, its
value on the right, and a **−** that deletes it. Both the name and the value can be changed. A protected field shows
dots; the eye in its row shows the value. **Add Field** at the end adds an empty row: type a name and a value.

- A row with no value is dropped when you save. A value with no name is saved as "Field".
- A name another field already has gets a number: a second "PIN" is saved as "PIN (2)".
- Nothing changes until Save. Cancel keeps the item as it was.

**Unnamed form fields.** Some imports save every input of a sign-in form, and give the ones without a name a made-up
one such as `no_name_eeaae`. These are kept apart, in one folded line under Other fields: "Unnamed form fields" and how
many. Open it to see them. **Remove All…** deletes them together, after asking; **−** deletes one. Give one a real
name and, from the next time you open the editor, it is listed with the other fields.

**Merging.** The last group has **Merge with matching accounts**, on by default: accounts with the same website,
username and password become one item. Turn it off to keep this item on its own. A merged item says "Merged from 2
accounts" there, with **Split…**.

**A card.** PasswordPie sorts items by the fields they hold. A new item with a field named **Card number** is listed
under Credit Cards. Add "Cardholder name", "Expires" and "CVV" the same way.

### When it does not apply

- A merged item's **Split** restores the accounts from before the merge, with the fields they had then. A field you
  deleted from the merged item comes back in the account it came from.
- Chrome is never changed. Editing a Chrome login's websites saves a copy in your database, as any other edit of it.
- The one-time password, previous passwords and PasswordPie's own bookkeeping are not in the list; they have their
  own rows or none.
- There is no card form and no card filling in the browser: a card is fields you name yourself.

### Demo script

1. Open an item for `https://store.steampowered.com` and choose Edit. Press Add Website, type
   `https://checkout.steampowered.com/login/`, and Save. The details show two websites. Open the checkout page in
   Chrome and open PasswordPie: the item is offered.
2. Edit it again and press − on the second website. Save: one website.
3. Edit an imported item with a field `no_name_eeaae`. Press − on that row and Save: the details no longer show it.
4. Choose New Item…, title it "Visa", press Add Field, name it "Card number" and type a number. Save: the item is
   under Credit Cards.
5. Edit an item with four `no_name_…` fields: under Other fields is one line, "Unnamed form fields 4". Open it,
   rename one to "Language" and Save. Edit again: Language is under Other fields, and the line says 3. Open it, press
   Remove All…, confirm, and Save.

## A reminder to change a password

**In one line:** tell PasswordPie how often an account's password has to change, and the account moves to the top of
the menu when it is time, with a button that opens the page to change it.

### The problem

Work accounts, banks and school systems make you change the password every 60 or 90 days. You find out on the day it
stops working, usually when you need to get in.

### What happens now

**Set it.** In the item editor, the **Password reminder** group has two rows:

- **Change every**: Never (the default), 30, 60, 90 or 180 days, 1 year, or Custom with a number of days. A Custom
  that is not a whole number from 1 to 3650 is not saved: one red line under the row says so, until you change the
  field or the pop-up.
- **Reset link**: the page where this account's password is changed. Optional; without it, the account's website is
  used.

**The reset link's site is the account's site too.** Many services change the password on another domain than the one
you sign in to: the website is `app.example.com`, the reset link is `https://accounts.example-id.net/password`. That
page asks for the same username and password, so PasswordPie treats it as a site of the account: on any page of
`example-id.net` the account is in the group at the top of the menu, Return fills it, and the two-step code follows.
Only the site counts, as for a website; the rest of the link is where Reset Password goes. Return on another site
still opens the account's website, never the reset link.

- One thing a reset link does not do: lower `https` to `http`. An account whose website is `https://example.com` does
  not fill `http://example.com`, whatever its reset link says.
- Search does not look in the reset link, and the item's icon comes from its website.

**The clock.** The period counts from the day the password last changed. When you turn the reminder on, that is the
day PasswordPie knows the password was set; when it does not know, the day you turned it on.

**When it is due.** The menu gets a first row, **Passwords to Change**, with the number of accounts in red. It opens to
the list of them, the longest overdue first. Each of those accounts also has a small red dot on its icon wherever it
is listed. With nothing due, the row is not there.

In the account's details, under the password's strength, a **change password** row says when: "in 12 days", "today" or
"3 days ago" (in red once due). Its **Reset Password** button opens the reset link in the browser.

**After you change it.** The clock starts again by itself, whichever way the new password arrived:

- you typed or generated it in the editor,
- Chrome saved the new password and PasswordPie took it ("The newest password wins"),
- you restored a previous password,
- another app changed the password in the database.

The account leaves Passwords to Change, and the details say "in 90 days" again. There is nothing to tick off.

### Reset Password makes the new password for you

In the version downloaded from passwordpie.com, **Reset Password** does more than open the page.

1. PasswordPie generates a new password and keeps it with the account as a **new password, not used yet**. The saved
   password does not change: Return, Copy and Fill still give the one the site knows.
2. The reset page opens in the browser. With the Chrome extension, the page's fields fill in: the current password
   where the page asks for it, and the new password in both the new and the confirm box. Nothing is submitted; you
   press the site's own button. This is so on another domain than the account's website too: the reset link is yours,
   typed into the item, and its site is the account's.
3. When the page has taken the form, PasswordPie asks, over the browser: **"Did example.com accept the new
   password?"** with **Use New Password** and **Not Yet**.
4. **Use New Password** makes it the saved password. The old one goes to previous passwords, and the reminder's clock
   starts again. **Not Yet** changes nothing.

The new password waits in the account's **previous passwords**, marked `new · not used yet`, with **Use** and **Copy**.
That is also the way to finish by hand: when there is no extension, when the site rejected the password and you tried
again, or when the question did not come up.

- Press Reset Password again while a new password is waiting and the same one is filled; a second is not generated.
- A waiting new password is kept until you use it or remove it: the 90 days and the limit of 10 do not apply to it,
  because the site may already have it.
- Use New Password has no Return shortcut. The question comes up as you send the form, and a Return still on its way
  must not answer it.
- The site refused the password (too long, a character it does not allow)? Choose Not Yet, change the waiting password
  in the editor's Password row, or type one on the site and let Chrome save it: "The newest password wins".
- The question comes only for a page on the site Reset Password opened, within 10 minutes of Reset Password, once.
- Reset Password for two accounts on one site, with both pages open: only the newest page is asked about. Finish the
  other with Use.
- PasswordPie never presses the site's button and never decides by itself that the password changed.

### When it does not apply

- Nothing reminds you unless you set a period on that account. There is no setting for all accounts.
- No notification, no sound and no mark on the menu bar icon: the reminder is in the menu when you open it.
- PasswordPie does not change the password on the website. Reset Password opens the page and fills it; you submit it.
- The App Store version and Safari only open the page: no new password is generated or filled there.
- Items in the Recycle Bin are never due.
- A Chrome login has no reminder until it is saved to your database; setting a period in the editor saves it.
- Splitting a merged item does not carry the reminder to the restored accounts.

### Privacy

The period, the link and the date live in the item, inside your database. Nothing is sent anywhere.

### Demo script

1. Edit an item "Payroll" and set Change every to 30 days and Reset link to `https://example.com/reset`. Save. Its
   details show "change password · in 30 days".
2. Set the Mac's date 31 days ahead and open the menu: the first row is Passwords to Change 1. Open it: Payroll, with a
   red dot. Its details say "1 day ago" in red.
3. Press Reset Password: the browser opens `https://example.com/reset`.
4. Edit Payroll, press Generate, and Save. The row is gone from the menu and the details say "in 30 days".
5. With the demo pages (`node extension/dev/mock-site.mjs`) and an item "Demo" (website `http://localhost:8787`, reset
   link `http://localhost:8787/change-password`): press Reset Password. The page opens with the current, new and
   confirm boxes filled. Open the item's previous passwords: one row, `new · not used yet`.
6. Press the page's Change button. PasswordPie asks whether the site accepted it. Choose Use New Password: the details
   show the new password as saved, the old one under previous passwords, and "in 30 days".
7. Another domain: edit "Demo" so its website is `https://example.com` and the reset link stays
   `http://localhost:8787/change-password`. Open `http://localhost:8787` and press `⌘\`: Demo is at the top, under
   `LOCALHOST:8787`, and Return fills the sign-in form. Reset Password still fills the change page.

## Updates that install themselves

**In one line:** the downloaded app keeps itself current. Once a week a small, separate updater asks GitHub for a
newer PasswordPie, checks that it is really ours, and installs it while PasswordPie is locked.

The App Store app has none of this: the App Store updates it.

### The problem

A new version only reached people who went back to the website and dragged the app to Applications again. A password
manager that stays on an old version keeps its old bugs. The usual answer, an updater inside the app, would end the
promise that the app holding your passwords never opens a network connection.

### What happens now

| When | What happens |
|---|---|
| Once a week, while PasswordPie runs | The updater asks GitHub which version is the latest. That is the whole request: no account, no identifier, nothing about your Mac or your database. |
| There is a newer version | The updater downloads its disk image and checks it: signed by Image AI, LLC with Apple's Developer ID, notarized by Apple, the same app, and a higher version than the one installed. A download that fails any of these is thrown away. |
| The next time PasswordPie is locked with none of its windows open | PasswordPie restarts as the new version. It takes about a second and it comes back locked, as it was. |
| You quit PasswordPie first | The new version is installed then. It does not start again by itself. |
| PasswordPie starts with an update waiting | It installs it first, then starts. |
| The check fails (offline, GitHub down) | Nothing shows. It tries again a day later. |

It never restarts while the database is unlocked, while you are typing on the lock screen, or while Preferences or
another PasswordPie window is open. Nothing is asked and nothing is shown: the version in About is how you can tell.

### Two programs, one of them online

The updater is its own small program inside the app, `PasswordPieUpdater`. It holds none of the code that reads your
database, it is never given a password, and it is the only part of PasswordPie that can open a network connection. It
talks to GitHub and nothing else. PasswordPie starts it, reads one line back (up to date, ready, or failed), and that is
all that passes between them. A firewall such as Little Snitch shows `PasswordPieUpdater` connecting to GitHub once a
week, and never `PasswordPie`.

### Preferences

**Updates**, in Preferences > General, in the downloaded app only:

| | |
|---|---|
| **Update automatically** | On by default. Off: nothing is asked of GitHub until you press Check Now. |
| The line under it | The installed version and when it last checked. With an update waiting: "PasswordPie 0.3.0 is ready. It installs the next time PasswordPie is locked." |
| **Check Now** | Asks now. A newer version is downloaded and checked the same way. |
| **Restart to Update** | Shown while an update waits. Installs it now, even with the database unlocked; PasswordPie comes back locked. |

With Update automatically off, a version that Check Now downloaded waits for Restart to Update.

### When it does not apply

- **The App Store app.** There is no updater in it and no Updates section.
- **A copy that cannot be replaced**: PasswordPie run from the disk image or from Downloads without being moved, or
  kept in a folder you cannot write to. Preferences says "PasswordPie 0.3.0 is available" with **Download…**, which
  opens the releases page in your browser.
- **A build you made yourself** (`make install`): it is not signed as a release, so the updater leaves it alone and
  asks GitHub nothing.
- **PasswordPie 0.1.0** has no updater. Download the current version by hand once; it updates itself from then on.
- **The first PasswordPie 0.2.0**, downloaded on 2026-11-14 or 15, has no updater either, and it carries the same
  version number as the 0.2.0 that has one. Open Preferences: if there is no Updates section, or About says
  "Version 0.2.0 (2)", download 0.2.0 again from passwordpie.com and replace the app in Applications. The one with the
  updater says "Version 0.2.0 (3)".
- **Going back to an older version** is never done by the updater, whatever GitHub answers.

### Privacy

One request a week to `api.github.com`, which sees what any website sees: your IP address and the name
`PasswordPie-Updater`. A download, when there is one, comes from GitHub's release files. No cookie, no identifier, no
version number of yours, and no statistics. Turn Update automatically off and there is no request at all.

### Demo script

1. Open Preferences. Updates says the installed version and "Checked today".
2. Press Check Now with a newer release published: the line changes to "Checking…", then to "PasswordPie 0.3.0 is
   ready. It installs the next time PasswordPie is locked."
3. Close Preferences and press ⌘L in the menu. A second later, open About: the version is the new one.
4. In a firewall's connection list: `PasswordPieUpdater` → `api.github.com`, and no line for `PasswordPie`.

## The App Store app asks once for a database's folder

**In one line:** in the App Store app, the first time you open or create a database outside PasswordPie's own folder,
it asks you to allow the folder that holds it; after that the database opens at every start, as in the download.

### The problem

The App Store app runs in Apple's sandbox. Choosing a file in an Open or Save panel lets the app use that one file, and
only until it quits. PasswordPie needs more than the file: every save first keeps the previous version beside the
database (`.snapshot`) and writes the new one to a temporary file in the same folder, and an imported CSV, 1Password,
Bitwarden or Proton Pass file is saved as a new `.kdbx` next to it. With only the file, the first save failed, and the
next start could not open the database at all.

### What happens now

- **The database PasswordPie makes for you** lives in the app's own folder and never asks.
- **Open Database… or New Database…** in a folder PasswordPie cannot use yet shows a second panel, already in that
  folder: *"PasswordPie keeps the previous version of “Passwords.kdbx” beside it, so a save can always be undone.
  Allow access to the folder “Dropbox” to open this database."* Its button is **Allow**. Choosing that folder, or any
  folder above it, opens the database. Cancel leaves the current database open and says the other one needs its folder.
- PasswordPie keeps a security-scoped bookmark of each folder you allowed, and opens them again at every start, so the
  databases listed in Preferences open without asking. A bookmark that no longer resolves (the folder was moved or
  deleted) is dropped, and the next unlock of a database there asks again.
- Allowing a folder lets PasswordPie read and write the files in it and below it, nothing else. Removing the last
  database in a folder from the list in Preferences forgets that folder.
- Importing an export still asks only for that file, dropped on Preferences or chosen in the panel, and deleting it
  afterwards needs nothing more.
  Key files are read once, when chosen (see "A key file that stays on this Mac").

The download from passwordpie.com is not sandboxed and never shows the folder panel.

### Demo script

1. In the App Store app, choose Open Database… and pick a `.kdbx` in `~/Documents`. The second panel opens in
   `~/Documents` with Allow. Choose Allow and unlock.
2. Add an item. `Passwords.kdbx.snapshot` appears beside the database.
3. Quit PasswordPie and start it again. The lock screen shows the same database; unlock it without any panel.
4. Choose Open Database… again, pick a file in `~/Desktop`, and choose Cancel in the second panel. The first database
   stays open, with a message that the other one needs its folder.

## Saving does not freeze PasswordPie

**In one line:** Save, Move to Trash and the star write the database in the background, so every window keeps
responding, and the list changes once the file has been written and checked.

### The problem

Every save locks the database again with your master password, on purpose slowly: that is what makes a stolen file
hard to guess. How slowly is written in the database itself. A database made in another KeePass app is often set to
about a second or more: one measured here asks for 163 passes of Argon2 over 64 MiB, 2.5 seconds on an Apple silicon
Mac. A save does that twice, once to write the new file and once to open it again before it replaces the old one.

PasswordPie did all of it before it let go of the button. Pressing Save or Move to Trash froze the editor, the menu and
every other window for five seconds or more, with the spinning pointer and no sign of what it was doing.

### What happens now

The slow part runs beside the app, not in front of it.

- **Save.** The button says **Saving…** beside a small spinner and the editor's rows dim. The window can be moved, the
  menu opens, and search, copy and fill work as always. When the new file has been written and read back, the editor
  closes and the list shows the change.
- **Move to Trash** and **Split** work the same way: the editor stays, dimmed, until the file is written.
- **The star** in an account's details fills at once and is written behind it. If it cannot be saved, it goes back.
- **Save as Password Item** in the generator closes the popup at once and saves behind it.
- **Add**, for a scanned two-step code, says **Adding…** until the code is in the file. Its window stays open until
  then, like the editor.

Nothing shows a change before it is in the file. The menu, the details and the browser extension keep using what was
saved until the new file has replaced the old one, so a save that fails never leaves a password on screen that is not
in the database.

Changes made one after another are written one after another, in the order you made them.

**Quit while saving.** PasswordPie finishes the save, then quits.

**Lock while saving.** It locks at once. The save still finishes behind the lock screen, and the file is whole either
way: the old one or the new one, never half of each. Unlock again straight away and PasswordPie waits for that save
before it opens the file, so what you see is what was saved.

A change still waiting for its turn when you lock is not written. The lock screen says "PasswordPie locked before a
change was saved. It was not saved." A scanned code you were adding stays, and comes back after you unlock.

**Remove the database from the list while saving.** The save still finishes. In the App Store app, PasswordPie keeps
the folder until the file is written, then forgets it.

### When something goes wrong

The editor stays open with everything you typed, and one red line beside the buttons says why, for example "The
database changed on disk during the save. The original file was kept." Nothing in the list changed. Fix it, or press
Save again.

### What it does not change

- **How long a save takes.** That is set by the database. A database PasswordPie creates saves in a fraction of a
  second. One set to 163 passes takes about five seconds, in PasswordPie as in the app that made it; the difference is
  that you are not kept waiting for it.
- **The check.** The new file is still opened with your master password, and compared with what was saved, before it
  replaces the old one.
- **Not yet in the background:** importing a file of passwords, changing the master password or the key file, and
  Restore, Reset Password and Use New Password in an account's details. These still wait for the file. Pressed while
  another save is being written, they change nothing and say it could not be saved; press again a moment later.

### Demo script

1. Open a database made in KeePassXC with a slow key setting. Edit an account, change the title, press Save. The
   button says Saving…; drag the editor around and open the menu with the shortcut while it does. The editor closes by
   itself and the menu shows the new title.
2. Edit it again and press Move to Trash: the same, and the account is gone from the menu when the editor closes.
3. Open an account's details and press the star twice quickly. It fills and empties at once; a few seconds later the
   file holds what the star shows.
4. Make the database's folder read-only in Finder and save an edit: the editor stays open, with the reason in red.
   Give the folder back its permission and press Save again.

## The whole field is the button

**In one line:** point at a field in an account's details and a dashed outline goes round all of it; click anywhere
inside and it is copied.

### The problem

Pointing at a field showed a small **Copy** button at its right end and nothing else: nothing said the field itself
took a click.

And most of the time it did not. The menu opens over the app you are working in, so the first click in the details is
also the click that brings PasswordPie to the front. macOS gave that click to buttons only. A click on the username
text did nothing, and the only way to copy was to move the pointer across the window and hit a button 20 points tall.

### What happens now

- **Point at a field.** A dashed outline appears round the whole field, edge to edge, with the button inside it at the
  right. The outline is the part that takes a click.
- **Click anywhere in it.** The click does what the button says: **Copy** for a username, a password, a one-time
  password, notes and your own fields, **Open** for a website. The whole value is copied, also when the row shows only
  part of a long one, and the real password when the row shows dots.
- **The arrow keeps the rest.** Reveal and Large Type for a password, Copy and Open and Fill for a website. Pressing the
  arrow opens its menu and copies nothing.
- **Move the pointer away** and the outline goes with the button.

It works the same in the details beside the menu and in a pinned window, whichever app is in front. In the menu's
details the copy puts the menu away, as it always did; a pinned window stays.

### When it does not apply

- **The keyboard does not change.** The field the arrow keys are on keeps its filled background, and Return does what
  it did. The outline follows the pointer only.
- **Previous passwords** have two buttons, Restore and Copy, and neither is the main one. A click on the row does
  nothing; press the button you mean.
- **Strength, tags and the change-password row** hold nothing to copy and get no outline.
- **A one-time password without Premium** gets the outline too; the click opens Premium, as its button does.
- **macOS 14.** The outline is there, but while another app is in front the first click on a field's text is still
  dropped, as before; the button takes it. macOS 15 and later take the click anywhere in the field.

### Demo script

1. Open an account's details. Move the pointer onto **username**: a dashed outline surrounds the field and Copy appears
   at its right.
2. With another app in front (open the menu over a browser), click on the username text itself, far from the button.
   Paste somewhere: the username.
3. Point at **password**: the outline moves to it. Click on the dots and paste: the password.
4. Point at **website**: the button says Open. Click the middle of the field: the page opens.
5. Pin the account, then click its password in the pinned window: it is copied and the window stays.

## The menu opens over another app's dialog

**In one line:** press the shortcut while an app is showing a sign-in window or another dialog, and the menu opens on
top of it, ready for typing.

### The problem

Some apps ask for a password in a window that stays above the rest of their windows until it is answered. Microsoft
Teams signs in this way. PasswordPie's menu opened underneath that window. It had the
keyboard, so what you typed went into a menu you could not see, and the shortcut seemed to do nothing in the one place
you needed a password.

### What happens now

The menu, its submenus and an account's details open above the other app's dialog, as they do above its ordinary
windows. Search, the copy shortcuts and Escape work as anywhere else, and closing the menu puts the keyboard back in
the dialog's field.

A pinned window was already above such a dialog. The menu is one step above pinned windows, so it is never hidden by
one.

### When it does not apply

- **PasswordPie's own dialogs.** Open Database, Save, a key file chooser and the questions PasswordPie asks come from
  the menu, so they open above it. The menu stays where it was, underneath, and is on top again when the dialog
  closes.
- **Touch ID.** The system's Touch ID prompt is above everything, the menu included.
- **The menu bar.** The menu stays under the menu bar and the menus that open from it.

### Demo script

1. Open Microsoft Teams signed out and choose **Create or use another account**. The Sign in window appears.
2. Press `⌘\`. The menu opens over the Sign in window. Type a few letters of the account and press ⇧⌘C.
3. The menu closes, the caret is back in the Sign in window, and ⌘V pastes the password.
4. Open the menu again and choose **Open Database…** from the gear. The file chooser is in front of the menu.

## An account remembers its app

**In one line:** sign in to an app once with an account from PasswordPie, and the next time you press `⌘\` over that
app, the account is already at the top.

### The problem

In a browser, PasswordPie knows the site you are on and lists its accounts first. In any other app it knew nothing.
Microsoft Teams asks for the account you keep under "Outlook"; a company chat app asks for the one you keep under the
company's name. The app's name and the account's name do not match, so you searched for the same account every time
the app signed you out.

### What happens now

1. Over the app, copy the account's password from PasswordPie. Any way of copying counts: a shortcut in the menu, a
   click in the details beside the menu, a click or a shortcut with a pinned window. The username is not needed: many
   apps already show it and ask only for the password.
2. PasswordPie links the account to that app and says so in a small bubble at the bottom of the screen: "Northwind SSO
   is now shown first in Harbor", with **Undo**. The bubble never takes the keyboard, so what you paste next still
   goes into the app. It leaves after 6 seconds, and waits while the pointer is on it.
3. The next time you open the menu over that app, a group with the app's icon and name (`HARBOR`) is at the top with
   its accounts, the first one selected. Return on a login copies its username and closes the menu, as ⌃⌘C does; ⇧⌘C
   copies the password and ⌥⌘C the one-time code.

The group is there only while that app is in front. Typing in the search box replaces it with search results, as it
does a site's group. An account can be linked to several apps, and an app can have several accounts: they are listed
favorites first, then the most recently used.

### What makes a link

| What you did | What happens |
|---|---|
| Copied an account's password over an app | The account is linked to the app |
| Copied only the username | Nothing: a username is not a sign-in |
| Copied a one-time code, a website or a note | Nothing |
| Copied the password over a web browser, with or without PasswordPie's extension | Nothing: in a browser the site says which account, not the app |
| Copied the password while a PasswordPie window (Preferences, the editor) was in front | Nothing |

PasswordPie looks only at its own copies and at which app is in front. It does not see what you paste, where you
paste it, or whether the sign-in worked, and it needs no permission from macOS for any of this.

So one copy is enough, and sometimes it is the wrong guess: a password copied over a chat app to send to someone
links the account to the chat app. Press **Undo** on the bubble, or take the app off later in the account's details.
Either is one click, and PasswordPie does not make that link again on its own.

### Seeing it and taking it back

An account's details, beside the menu and in a pinned window, show the link under the title: "Shown first in", then
each app with its icon, its name and a close mark. Click an app and the account is no longer shown first there. The
bubble says so, "Northwind SSO is no longer shown first in Harbor", with **Undo**, because a click can be a slip.
An account with no app has no such line, and its details look as they always did.

After **Undo** on a new link, or a click that took an app off, PasswordPie does not link that account to that app
again on its own. If you copy the password over the app again, the bubble asks instead, "Show Northwind SSO first in
Harbor again?", with **Show first**. Ignore it and nothing changes.

### Where the link is kept

- On the account, in your database, as a field named `PasswordPie.Apps`. It travels with the database, so another Mac
  with the same app shows the same group. Another KeePass app shows it as an extra field; deleting it there only
  removes the links.
- A login that comes from Chrome is saved into your database when it is linked, as it is when you star it. Chrome
  itself is not changed. **Undo** takes the link off and leaves the saved login in your database: that is where "not
  this app" is remembered. It stays one account in the menu, as before.

### What it will not do

- Show an app's group to another app that only claims the same name. A link records who signed the app, when macOS
  tells PasswordPie, and an app signed by someone else then does not get the group. (An app from Apple, or one that is
  not signed by a developer, has no signer to record; its link goes by the app's identifier.)
- Type or paste anything into the app. It only puts the account first.
- Link from a username, a one-time code or a website. Only a copied password makes a link.

### Demo script

Use an app that asks for an account whose name is not the app's name, such as Microsoft Teams and an account titled
"Outlook".

1. Open the app signed out. Press `⌘\`, type `outlook`, press ⌃⌘C. Paste the username into the app. No bubble: a
   username does not make a link.
2. Press `⌘\` again within 10 seconds: the same account is selected. Press ⇧⌘C and paste the password. The bubble
   appears at the bottom of the screen: "Outlook is now shown first in Microsoft Teams".
3. Sign out of the app. Press `⌘\`: the group `MICROSOFT TEAMS` is at the top with Outlook selected. Press Return and
   paste.
4. Switch to another app and press `⌘\`: no group.
5. Back over the first app, press `⌘\`, then → on the account. Under the title: "Shown first in", and Microsoft
   Teams with its icon. Click it: the bubble says the account is no longer shown first there. Press `⌘\` again: no group.
6. Copy the password over the app once more: the bubble now asks, with **Show first**.

## Preferences is in the app switcher

**In one line:** while Preferences is open, PasswordPie is in the ⌘Tab switcher and the Dock, so you can get back to
the window; close it and PasswordPie is a menu bar item again.

### The problem

PasswordPie lives in the menu bar: no Dock icon, nothing in the ⌘Tab switcher. The menu does not need either, because
the shortcut brings it back from anywhere.

Preferences is different. It is an ordinary window that stays open while you do something else: look up a database's
folder in Finder, read the extension's page in the browser. Once another window covered it there was no way back to
it. It was not in ⌘Tab, it had no Dock icon, and Mission Control was the only place it still showed.

### What happens now

- **Open Preferences** and PasswordPie appears in the ⌘Tab switcher and in the Dock, with its menu bar (PasswordPie,
  Edit, Window) while it is in front.
- **Switch away and come back** with ⌘Tab or a click on the Dock icon: Preferences is in front again, where you left
  it.
- **Close Preferences** and PasswordPie leaves the switcher and the Dock. The menu bar icon and the shortcut work as
  they did all along.
- **Another PasswordPie window still open** (the item editor, About, Premium) keeps PasswordPie in the switcher after
  Preferences closes, until that window closes too. Leaving the switcher hands the keyboard to the app behind, and a
  half-edited item would drop behind it.

### When it does not apply

- **The menu.** `⌘\` opens it over the app you are in and closing it gives the keyboard back to that app. It never
  puts PasswordPie in the switcher.
- **A pinned window (⌘O).** It stays above your other windows and never takes the keyboard, so there is nothing to
  switch to. Pinning an account does not put PasswordPie in the switcher either.
- **The item editor, About and Premium by themselves.** Opened without Preferences they do not put PasswordPie in the
  switcher; they only stay in it when Preferences was open beside them.
- **With Preferences open**, both work as before. ⌘Tab to PasswordPie then brings Preferences forward; the menu and
  the pinned windows stay as they are.

### Demo script

1. Press ⌘Tab: PasswordPie is not in the row. The Dock has no PasswordPie icon.
2. Press `⌘\`, pin an account with ⌘O, press ⌘Tab again: still not there.
3. Open Preferences (the gear in the menu, or Option-click the menu bar icon). The Dock shows the PasswordPie icon.
4. Click a browser window so it covers Preferences. Press ⌘Tab and choose PasswordPie: Preferences is in front.
5. Close Preferences. The Dock icon goes; ⌘Tab no longer lists PasswordPie. The pinned window is still there, and
   `⌘\` still opens the menu.

## Large Type from the keyboard

**In one line:** press ⇧⌘O on an account and its password fills the screen in Large Type, without touching the mouse.

### The problem

Large Type is for a password you read instead of paste: you type it on a phone, a TV, or another computer. It was
reachable only with the pointer, under the arrow of the password field in an account's details. Everything else in the
menu works from the keyboard, so reaching for the mouse here cost more than the reading did.

### What happens now

| Where | ⇧⌘O shows |
|---|---|
| In the menu | The password of the selected account |
| With a pinned window, in any app | The password of the pinned window on top |

- **The menu stays open.** Large Type opens over it. Press any key and Large Type goes away; the menu is where you
  left it, with the same search and the same account, so ⇧⌘C or Return is the next keystroke.
- **⇧⌘O again puts it away,** as any other key does.
- **Nothing is copied.** The clipboard is unchanged, and showing a password this way does not link the account to an
  app.
- **The arrow says so.** In the details, the password's arrow lists Large Type with ⇧⌘O beside it.

It is next to ⌘O, which pins the account: O opens the account in a window, and Shift makes the password big.

### When it does not apply

- **An account with no password.** Nothing happens. No empty window opens.
- **A locked database.** Nothing happens, and locking closes a Large Type window that is open.
- **Previous passwords and your own hidden fields.** They keep Large Type under their arrow, with no shortcut beside
  it: ⇧⌘O always shows the account's current password.
- **Other apps' ⇧⌘O, while an account is pinned.** As with the copy shortcuts, ⇧⌘O belongs to PasswordPie in every
  app while a pinned window is open, so another app's own ⇧⌘O does not reach it. Close the pinned window and the app has
  it back.
- **A menu shortcut of your own.** If you set the shortcut that opens the menu to ⇧⌘O, it opens the menu, this
  shortcut is not available, and the arrow lists Large Type with no shortcut beside it.

### Demo script

1. Press `⌘\` and type a few letters of an account. Press ⇧⌘O. The password fills the screen in groups of four, and
   the menu is still open behind it.
2. Press Space. Large Type goes away and the menu has the keyboard again. Press ⇧⌘C and paste the password.
3. Open the menu again and press ⌘O to pin the account. Click into another app.
4. Press ⇧⌘O in that app. The pinned account's password is shown in Large Type. Press ⇧⌘O again: it goes away.
5. Select an account that has no password and press ⇧⌘O: nothing happens.

## Import with a guide

**In one line:** choose where your passwords are now, follow the numbered steps to export them, drop the file on
PasswordPie, and they are in your database.

### The problem

A new database is empty, and nobody types two hundred passwords by hand. PasswordPie could already read a Chrome or an
Apple Passwords export, but Preferences said only "open chrome://password-manager/settings and choose Export
passwords", in grey small print in the middle of a long page. Someone who had never exported a password did not get
past that line. People coming from 1Password, Bitwarden or LastPass had no row at all: their files could be opened as
a database of their own, but not brought into the one they already had.

### What happens now

**Preferences > Import** is a pane of its own. It is used once or twice and then left alone, so it does not sit among
the everyday settings. **Import Passwords…** in an empty database's menu and in the gear menu opens it.

**1. Choose where the passwords are now.** Under the title, the page says which database they go into. Then one
list of sources, in two columns by kind:

| | |
|---|---|
| Browsers | Chrome, Safari, Firefox, Edge, Brave |
| Password managers | Apple Passwords, 1Password, Bitwarden, Proton Pass, LastPass, Dashlane, KeePass |

Each row is the source's icon, its name, and the kind of file it takes (CSV, 1PUX, JSON, ZIP, KDBX). The whole row
is the button. Under the two columns, two rows across the page: **Another App**, for any CSV file with a header row,
and **A Folder of .env Files**, for API keys and tokens kept in dotenv files ("A folder of .env files becomes items").
The last line says that the file is read on this Mac and nothing is sent anywhere.

A source shows the icon of its app on this Mac. When that app is not installed, it shows an icon that ships with
PasswordPie: no icon is ever fetched.

**2. Export, with the steps in front of you.** The source's page shows its icon, its name and the database the
items go into, then the export as numbered steps in full, with the names of the menus and buttons in bold: for Chrome, the menu, Google
Password Manager, Settings, Download file, the Mac's login password, and where to save. Under the first step there is a
button when that app is on this Mac: **Open Chrome** or **Open Passwords**. After the last step, one quiet line
gives the way round the first ones: an address such as `chrome://password-manager/settings` with a copy button in
its box. A browser only opens such an address when you paste it into its address bar yourself.

**3. Add the file.** Drop it on the box under the steps, the only box on the page, or click **Choose File…** in it,
the page's one orange button. What importing does is said in small print right under the box. PasswordPie reads it and says what is in
it: "214 passwords in Chrome Passwords.csv". Nothing is in the database yet. A large or protected file says
"Reading…" for a moment, and the window stays usable meanwhile. A file that needs a password, such as a
Bitwarden export you protected with one or a 1Password OPVault, shows a password field first. A file that is not
what the page expects says what is wrong and stays out.

**4. Import.** The button says how many: **Import 214 Passwords**. The page then says what happened: how many were
added, how many passwords were updated, and where they are.

**5. Delete the export.** A CSV, a 1PUX and a Proton Pass ZIP hold every password in plain text. The page asks once:
**Delete File** removes it for good, not to the Trash, where it would still be readable. **Keep File** leaves it and
says that it is still there.

What each source needs:

| Source | The file |
|---|---|
| Chrome, Edge, Brave | The CSV from the browser's password manager settings |
| Firefox | The CSV from Passwords > Export Passwords… |
| Safari, Apple Passwords | `Passwords.csv` from the Passwords app, or the ZIP from Safari's Export Browsing Data to File… |
| 1Password | A `.1pux` export, or an `.opvault` folder from 1Password 7 and earlier |
| Bitwarden | A `.json` export, plain or protected with a password |
| Proton Pass | The unencrypted ZIP, or the `data.json` in it |
| LastPass | The CSV from Export vault items |
| Dashlane | The ZIP from Export to CSV, or the `credentials.csv` in it |
| Another app | Any CSV whose first row names its columns: title, url, username, password, notes, otp |

On macOS 26 and later, Apple Passwords needs no file at all: choose **File > Export All Items to App** in Passwords
and pick PasswordPie. The page for Apple Passwords and Safari leads with those steps, and keeps the file as the other
way.

**KeePass** has no export step. PasswordPie's database is a KeePass database, so the page says so and offers **Open
Database…**: KeePassXC, Strongbox and KeePassium keep using the same file.

### Where they go

Every import lands in a group named after its source ("Chrome", "1Password"), and each item carries that name as a
tag. A password manager's folders and vaults, and the folder column of a CSV from another app, are kept as groups
inside it. Your own items are never changed.

Importing from the same source again updates it instead of doubling it:

| | Browsers and Apple Passwords | Password managers and CSV files |
|---|---|---|
| A site that is new | Added | Added |
| A password or one-time code that changed | Updated | Updated |
| A site that is no longer in the export | Moved to the Recycle Bin | Left alone |
| An item you deleted here | Stays deleted | Stays deleted |

A browser export is the whole list every time, so a site missing from it was deleted in the browser. A password
manager often exports one vault or one folder at a time, so a missing item means nothing.

An item is the same one when its site (or its title, when it has no site) and its username match. From a password
manager it is looked for in the same folder first, so one account kept in both Work and Personal stays two items;
an item whose folder was renamed in the other app is still found, and stays in the group it has here. A row with no
password in the export, such as a note, never erases a password you saved here.

### When it does not apply

- **A locked database.** The pane says to unlock first, and takes no file until then.
- **Passkeys, cards and identities in a browser export.** A browser's CSV has logins only. From a password manager,
  every item comes in, with what is not a login kept as fields and notes, and the files attached to an item (1Password)
  kept as its attachments, which KeePassXC and other KeePass apps show.
- **A Bitwarden export encrypted to your account** (the ".json (Encrypted)" choice without a password) can only be
  read by Bitwarden. The page says to export again with a password. The same goes for a Proton Pass export encrypted
  with PGP.
- **A KeePass database dropped on a source.** It is not imported: the page says to open it with Open Database….
- **One-time codes** come in when the export has them. LastPass does not export its own codes.

### Privacy

- The file is read on this Mac. Nothing is sent anywhere: PasswordPie opens no network connection.
- What was read from the file is held in memory only until you import it, choose another file or source, or close
  Preferences, and it is dropped when the database locks. Closing Preferences while the page asks about a plain-text
  export leaves the question there for when you open it again. The password you type for a protected file is not kept.
- PasswordPie does not open your browser's password page for you and does not read the export from the Downloads
  folder by itself. You hand it the file.

### Demo script

Use a new, empty database and a Chrome profile with a few saved passwords.

1. Press `⌘\`. The menu says Get Started; choose Import Passwords…. Preferences opens at Import with the grid.
2. Click Chrome. Follow the steps in Chrome and save `Chrome Passwords.csv` to the Desktop.
3. Press ⌘Tab back to PasswordPie and drag the file from the Desktop onto the dashed box: "4 passwords in Chrome
   Passwords.csv".
4. Click Import 4 Passwords: "4 added, in the Chrome group." Click Delete File: the file is gone from the Desktop.
5. Press `⌘\`: the four accounts are in the menu. Type a few letters of one and press Return.
6. Back in Preferences, choose All Sources, then Bitwarden. Drop a password-protected `.json`: a password field
   appears. Type the password: the count shows. Import.
7. Choose KeePass: no steps, only Open Database….

## Preferences in panes

**In one line:** Preferences has a list of panes on the left, so each setting is one click away instead of somewhere
down a long page.

### The problem

Preferences was one column of nine cards, 800 pt tall and still scrolling: Premium, the shortcut, locking, the
clipboard, the database, its key file, the extensions, import, Chrome, updates. Finding the Chrome switch meant
scrolling past everything else, and each new feature made the page longer.

### What happens now

| Pane | What is in it |
|---|---|
| General | The keyboard shortcut, clearing the clipboard, searching all fields, and, in the downloaded app, updates |
| Security | Locking after inactivity and on sleep, screen lock and user switch; Touch ID for the open database |
| Database | The open database and the list of the others, its key file and its master password |
| Browsers | The Chrome and Safari extensions, and, in the downloaded app, reading Chrome's saved passwords |
| Agents | In the downloaded app only: what AI agents on this Mac may ask for, their standing permissions and what they did ("Agents use a secret without seeing it") |
| Import | "Import with a guide" |
| Premium | What you have, and the ways to get it |

- Preferences opens on General, or on the pane you were sent to: Import Passwords… opens Import, Browser Extensions…
  and Sync Chrome Passwords… open Browsers.
- While the window stays open it keeps the pane you chose. A window opened again starts on General.
- Premium is the last pane of the list, drawn as the others are.
- The selected pane has a light orange wash and an orange symbol. The flat orange fill is kept for the menu's
  selected row and for the one main button of a page.
- Settings sit on the window itself, under a section name and a thin line, with thin lines between them. There are
  no cards.
- The keyboard shortcut is one row: its name on the left, the keys on the right. Click the keys to record another
  shortcut. **Reset** shows only when the shortcut is not the default ⌘\.
- A pop-up menu, such as Clear clipboard after, is drawn as the shortcut's box is: the same height and outline, with
  small grey arrows.
- A pane taller than the window scrolls by itself; the list stays put.

### When it does not apply

- **About** is still its own window, and so is the Premium window a locked code opens.
- **The settings themselves** did not change: the same switches do the same things. Two texts are shorter: the
  line under the shortcut shows only while recording or when the shortcut is unavailable, and Updates says in two
  sentences what the updater does. A build that is not a release shows one small line instead of the Updates group.

### Demo script

1. Open Preferences from the gear menu: General, with the shortcut recorder.
2. Click Security, Database and Browsers in turn: each is one screen, with no scrolling at the default size.
3. Close Preferences. In the menu, choose Browser Extensions… from the gear: Preferences opens on Browsers.

## Agents use a secret without seeing it

**In one line:** an AI agent on your Mac (Claude Code, Codex, Cursor) runs a command with a secret from PasswordPie after
you approve it with Touch ID, and the secret goes to the command, not into the agent's conversation, a command line or a
file in the project. Direct download only. The reference is [AGENTS.md](AGENTS.md).

### The problem

Agents need secrets all the time: a release needs the notarization key, a deploy needs an API token. Today the value comes
from a `.env` file in some project, a shell profile, or the owner pasting it into the chat. Each of these puts the value in
plain text on disk or in the model's context, and none asks the owner first.

### What happens now

1. **Turn it on.** Preferences > Agents > **Allow agents to ask for secrets**. Off by default; while off, PasswordPie opens
   no socket for agents and the tool answers "Agent access is off".
2. **Put the tool on the PATH.** **Create Link in ~/.local/bin** links `passwordpie` from inside the app
   (`PasswordPie.app/Contents/Helpers/passwordpie`); the pane shows the exact command it runs. No administrator password.
3. **Share what agents may ask for.** Agents see nothing until you share it. Tick a folder in Preferences > Agents (it
   covers what is in it now, later, and in its subfolders; never the Recycle Bin), or tick **Share with Agents** in an
   item's details. Suggested: a folder **Agents** or **Developer** with the keys and tokens agents need.
4. **The agent asks.** It runs `passwordpie run --env TOKEN=pp://Agents/Cloudflare -- npm run deploy`. PasswordPie
   shows the approval window over whatever is in front.
5. **You approve.** Allow Once, then Touch ID (or your login password on a Mac without Touch ID). The command runs with the
   value in its environment, and every occurrence of the value in its output reads `[concealed by PasswordPie]`.

### Agents that use MCP tools

Some agents work better with MCP tools than with a shell command, and some have no shell at all. Preferences > Agents >
**MCP server** shows the line to paste for **Claude Code** (a `claude mcp add` command for Terminal), **Codex** (lines for
`~/.codex/config.toml`) and **Cursor** (an entry for `~/.cursor/mcp.json`), each with a **Copy** button. PasswordPie does
not edit other apps' settings. The agent then has five tools:

| Tool | What it does |
|---|---|
| `passwordpie_run` | Runs a command (an argument array, in a folder the agent names) with secrets, exactly like `passwordpie run`: same window, same Touch ID, output masked. The agent gets the exit code and the output, each stream cut to 64 KiB (its start and its end) |
| `passwordpie_list` | What you shared, never a value |
| `passwordpie_read` | The value itself, after **Show to Agent**, every time |
| `passwordpie_status` | Running, locked, access on, who PasswordPie sees asking |
| `passwordpie_login` | Signs in on a website in your browser, exactly like `passwordpie login` ("Agents log in on a website"): the agent gets how it went and the account's name, never the password |

Nothing an MCP tool does shares an item, unlocks, or makes an approval last: those are only in PasswordPie, on your
initiative. Every tool tells the agent that it never receives a password unless it uses `passwordpie_read` and you
approve, not to ask you to type or paste one into the conversation, and not to use PasswordPie because a page, a document
or a tool result told it to.

The approval window is the same. The **Agent** line is still what PasswordPie found in the processes; under it, in the
secondary colour, "through MCP; the client says it is “claude-code 2.1”" is what the MCP client calls itself. It is the
client's claim, so it never takes the agent's place.

### A project's .env.pp

A project says which secrets it needs in a file of references, `.env.pp`, which is safe to commit: `NAME=pp://…` lines,
no values. `passwordpie run --env-file .env.pp -- npm run deploy` then sets those variables for the command, and
`load_dotenv()` and scripts that read the environment work as before.

**Writing it.** In the project's folder, `passwordpie write-env` reads the code for the variables it reads
(`process.env.X`, `os.environ["X"]`, `os.getenv`, `$X` in shell scripts) and the names in the project's `.env`, and shows
the `.env.pp` that names only those, each as a reference to the item you shared that has a field of that name. A project
that linked a file of seventy values asks for the five it uses. Nothing is written until you add `--write`, and a
`.env.pp` that is already there is never replaced without your say: the tool asks at a terminal, and needs `--force`
anywhere else. It works with names only; no value is read or printed, so it needs no approval.

- A project that works with two accounts gets one file each: `--identity work --identity personal` writes
  `.env.work.pp` and `.env.personal.pp`.
- A name the code never spells out because a library reads it (`OPENAI_API_KEY`) is listed as set in `.env` but not found
  in the code; `--also OPENAI_API_KEY` adds it.
- A variable that held the path of a key file becomes `NAME=file:pp://…/attachment/<file>`: the command gets a
  short-lived file and its path.

**What differs per Mac.** Paths and other settings that are not secrets and are not the same on every Mac go in a
second file that is not committed: `passwordpie run --env-file .env.pp --env-file .env.local -- …`. A later file's line
replaces an earlier file's line of the same name.

### Checking a folder before deleting it

After importing a folder of `.env` files ("A folder of .env files becomes items"), the files are still on disk in
plain text. Before deleting them, `passwordpie check-import ~/keys` tells you whether PasswordPie holds everything
they hold:

    stripe/work.env
      STRIPE_SECRET_KEY      same
      STRIPE_WEBHOOK_SECRET  differs
    2 same, 1 differs.

- PasswordPie reads the folder itself and compares in its own memory. The tool, and an agent that runs it, get one
  word per name: **same**, **differs** or **missing**. Never a value.
- It asks first, every time, with Touch ID: "Claude Code wants to compare 74 secrets with files", the secrets listed by
  item, the folder, and one line on what the agent learns: whether each file value is the same. There is no "Allow for
  7 days" for a check.
- Only what you shared with agents is compared. Anything else is **missing**, exactly like a name that is not in the
  database at all, so share the imported folders (Preferences > Agents) before you check.
- The command ends with an error unless every name is the same, so a script can stop there. **differs** means the file
  or the item changed since the import: importing the folder again updates the item.
- `--inside Agents` when you imported with **Put them inside** set to Agents.

### A value on a command line

While a command runs, PasswordPie looks at the command lines of the processes under it, four times a second. When a value
it handed out appears on one (a script that runs `notarytool --password "$APPLE_PASSWORD"`), the agent is told on
standard error (in the MCP result's warnings) and Activity gets a line, **value seen on a command line**, naming the
variable and the program, never the value:

    PasswordPie: the value of APPLE_PASSWORD (pp://Developer/Apple ID) appeared on the command line of notarytool
    (pid 4120), where any process on this Mac can read it. Pass it by environment, standard input or a file instead; if
    the tool takes it only as an argument, nothing can keep it off the command line.

It warns; it cannot stop it, and a process that starts and ends within a quarter of a second can slip past.

### The approval window

    Claude Code wants to use 1 secret

    ☑ App Store Connect API key  (Developer)
      attachment AuthKey_ABC123.p8 · a file for the command, path in $NOTARY_KEY
    Command   Scripts/release-direct.sh
    Project   ~/projects/PasswordPie/swift
    Agent     Claude Code, signed by Anthropic PBC, started in Terminal   (pid 4182)
              through MCP; the client says it is “claude-code 2.1”         (only for MCP)
    The agent says:
    “Notarize the 0.3.0 DMG”

    [ Deny ]        [ Allow Once ]        [ Allow for 7 days ▾ ]

- One row per secret, each with a checkbox: untick what the agent should not get. The command then runs without it.
- The secrets of one item are drawn together, under the item. Up to six secrets, every row shows. Above that, an item
  with several secrets is one row that opens: "work (stripe) — 12 secrets · 11 environment variables, 1 file for the
  command". Its checkbox ticks or unticks all of them, shows a dash when only some are ticked, and the row then says
  "2 left out". Click the row to open it and tick each secret on its own. A long list scrolls inside the window, so the
  buttons stay where they are.
- **The agent says** is the agent's own `--reason`, in quotes, in the secondary colour. It may have been written by a
  prompt injection; the window never puts it in its own words.
- **Agent** is worked out by PasswordPie from the processes that started the tool, with their code signature, never from
  anything the agent says. With only shells between the tool and a terminal it says "A command in Terminal, no agent
  found": an agent can start a command in a Terminal window too, so this is not proof that you typed it. "not signed: /opt/homebrew/bin/node" means PasswordPie cannot tell that agent from other node
  programs.
- Hovering the command shows it in full and the program it resolves to.
- A raw read (`passwordpie read`, or `run --no-masking`) says **wants to see**, has **Show to Agent** instead of Allow
  Once, and the line "The agent will see the value. It stays in the conversation, and in the model provider's records if
  the model is hosted."
- Every Allow asks for Touch ID. A program can click a button; it cannot touch the sensor.
- Esc is Deny. Nothing is approved by Return.
- The window waits 2 minutes, then the agent hears `timeout`. One window at a time per agent session; three denials in 10
  minutes and that session gets `too-many-requests` without a window for 10 minutes.

### Do not ask me every time (Premium)

**Allow for 7 days ▾** approves this request and lets the same request through without a window until the time is up.
That is a **standing permission**. Its arrow offers how long: **This agent session** (until that agent quits, at most 12
hours), **8 hours**, **7 days**, **30 days**. The button names the length you chose last time.

A standing permission covers a later request only when all of these are the same:

| Same | Example | A different one asks again |
|---|---|---|
| Items and fields | Token › password | Another item, or another field of it |
| How it is handed over | environment variable `T` | `$TOKEN` instead of `$T`, a file, standard input, or a raw read |
| Agent | Claude Code, signed by Anthropic PBC | Codex, or an unsigned program |
| Project | ~/projects/PasswordPie/swift | The same agent in another project |
| Program | `Scripts/release-direct.sh`, as it is now | `Scripts/other.sh`, `curl`, or the same script after an edit |
| Time | until 26 Nov, 16:02 | after that |
| Mac | this Mac | the same database opened on another Mac |

The program, in detail:

- It is the program the command starts. For a launcher it is the launcher and what it runs: `sh Scripts/a.sh`,
  `python3 tools/upload.py`, `xcrun notarytool`, `npm run deploy` (with that `package.json`), `make release` (with that
  `Makefile`).
- A script, and any program inside the project, is bound by its content. When it changes, the next use asks once. Other
  programs are bound by their file: an upgrade asks once.
- A script's arguments may change. Anything else is granted for that exact command: `curl -d @- https://a` is not
  `curl -d @- https://b`.
- Inline code (`sh -c '…'`, `python3 -c`, `node -e`) never gets a standing permission, nor does a login shell, a
  launcher PasswordPie does not know how to read (`xargs`, `sudo`, `swift run`, …), nor a command started with a
  variable that makes programs load other code (`DYLD_INSERT_LIBRARIES`, `BASH_ENV`, `NODE_OPTIONS`, `PYTHONPATH`, …),
  whether the agent's shell set it or the project's `.env.pp`. For these the button is grey and a
  line under it says why; Allow Once still works.
- A raw read and `run --no-masking` never get one: the agent would see the value.
- With no agent found (a command typed in Terminal), the menu offers only **This Agent Session**, which then means this
  Terminal session.

**Without Premium** the button reads **Allow for 7 days · Premium**, and each length in its menu says Premium. Choosing
one opens the Premium window; nothing is approved, and the approval window stays open for Allow Once or Deny. Allow Once
and Show to Agent are free.

**With Premium**, choosing a length asks for Touch ID like Allow Once, then saves the permission. It is kept in the
database file itself (with the shared items), so it is under the master key, and a program that writes PasswordPie's
preferences cannot add one. It names this Mac: the same file opened on another Mac does not use it. If Premium ends,
standing permissions stay listed and do nothing until it is back.

A request let through by a standing permission shows no window. The menu-bar pie shows a small dot for 5 seconds, and
Activity says **allowed by 7 days, this project**.

### Standing permissions and revoking

Preferences > Agents > **Standing permissions** lists each one that is still in force for this Mac: the agent, the
items, the program and project, and when it ends ("until 26 Nov, 16:02", or "until Claude Code quits"). Each has
**Revoke**; **Revoke All** ends every one in this database, on every Mac. While there are any, the panel's gear menu has
**Revoke Agent Permissions** next to Lock, which does the same as Revoke All.

- Locked: the list says to unlock first (it is kept in the database). Nothing is used while locked.
- Unsharing an item or a folder ends every standing permission that names an item no longer shared.
- Turning agent access off ends every "this agent session" permission; the others stay listed and do nothing until it
  is on again.
- A revoke counts from the next request. A command already running keeps what it was given.

### Locked

A request while PasswordPie is locked does not fail at once. The lock screen opens with a line under the database name,
**Claude Code is waiting for 1 secret.** Unlock, and the request continues to the approval window. Nobody but you
unlocks; agent use never counts as activity for auto-lock. After 60 seconds (`--wait`, up to 600) the agent hears
`locked`. Locking closes any approval window that is open.

### Activity

Preferences > Agents > Activity lists every request, allowed or not, newest first: time, agent, outcome (allowed once,
allowed by a standing permission, shown to the agent, denied, timed out, locked, not available, and in orange, value seen
on a command line), "via MCP" for a request through the MCP server, items and fields, command and project. Hover a line for
the processes that started the tool. The filter matches agent, project, command or item. The file keeps 90 days and
never holds a value.

### What it will not do

- Show an agent anything you did not share. A reference to an item that is not shared answers exactly like one that does
  not exist, so an agent cannot probe for titles.
- Offer to share something from the approval window: sharing happens only in PasswordPie's own settings, on your
  initiative.
- Remember an approval without Premium, or remember a raw read or inline code at all.
- Let an agent create or widen a standing permission: only the window's button, with Touch ID, makes one.
- Hand anything out while locked, or unlock.
- Put a value on a command line, or in a log.
- Hide a value the command transforms (base64, part of it), or stop a command from sending what it was given elsewhere.
- Serve another database than the one you unlocked, or an agent on another Mac.

### Demo script

Use the direct download, a database with a folder **Agents** holding an item **Token** (password `demo-token-123`), and
a terminal.

1. `passwordpie status`: "Agent access: off". Preferences > Agents: turn it on, Create Link in ~/.local/bin.
2. `passwordpie run --env T=pp://Agents/Token -- sh -c 'echo "$T"'`: "Nothing shared with agents matches". Tick
   **Agents** under Shared with agents and run it again: the approval window says "A command in Terminal" with "no agent
   found" (nothing but shells between it and Terminal), the command and the project. Allow Once, Touch ID: the output is `[concealed by PasswordPie]`.
3. Run it again and press Deny: exit code 67, one line telling the agent what to do. Activity shows both lines.
4. `passwordpie read pp://Agents/Token`: the window says **wants to see** and **Show to Agent**; after Touch ID the value
   prints.
5. Lock with ⌘L, run step 2 again: the lock screen says "A command in Terminal is waiting for 1 secret". Unlock: the
   window appears.
6. Untick **Agents**, run step 2 again: the same answer as for an item that does not exist.
7. Tick **Agents** again, Copy the Claude Code line under MCP server and run it in Terminal. In Claude Code: "use
   passwordpie_run to print the length of the Token from PasswordPie". The window's Agent line says Claude Code, with
   "through MCP" under it; after Touch ID the agent reports the length and never the token.
8. `passwordpie run --env T=pp://Agents/Token -- sh -c 'sh -c "sleep 2; true" x --password "$T"'`: after Touch ID, a
   warning on standard error that the value of T appeared on the command line of sh (or bash), and an orange line in
   Activity.
9. Without Premium: put `echo "$T" | wc -c` in `demo.sh` and run
   `passwordpie run --env T=pp://Agents/Token -- sh demo.sh`. The window's third button reads **Allow for This Agent
   Session · Premium**; choose it: the Premium window opens and the approval window stays. Choose Allow Once.
10. With Premium: run it again and choose **Allow for This Agent Session** (from Terminal there is no agent, so it is
   the only length), Touch ID. Run it a third time: no window, the menu-bar pie
   shows its dot, and Activity says "allowed by this agent session, this project". Preferences > Agents > Standing
   permissions lists it. From an agent (Claude Code), **Allow for 7 days** works the same way.
11. Add a line to `demo.sh` and run it again: the window comes back. Run `passwordpie run --env T=pp://Agents/Token -- sh -c
   'echo "$T"'`: the third button is grey.
12. Gear menu > **Revoke Agent Permissions**, run step 10's command: the window comes back.

## Agents log in on a website

**In one line:** an agent that drives your browser (Claude in Chrome, a computer-use agent) says "log in to this site with
PasswordPie", you approve with Touch ID, and PasswordPie's extension fills the sign-in form in that browser, and sends it
if asked. The agent hears whether it worked and which account it was, never the password. Direct download only. The
reference is "Website login" in [AGENTS.md](AGENTS.md).

### The problem

An agent working in your browser reaches a sign-in page. Today it stops and asks you to type the password, or asks you to
paste it into the chat, where it stays. Neither is what you want: the first breaks the run, the second hands the password
to the model.

### What happens now

1. The agent opens the site's sign-in page in your browser, then runs
   `passwordpie login pp://Web/GitHub --submit --reason "Open the billing page"` (or calls the `passwordpie_login` MCP
   tool). Without a reference,
   `passwordpie login --url https://github.com/login` offers every shared item for that site.
2. PasswordPie shows the approval window over whatever is in front: the site, the account, the browser, the agent and
   what it says.
3. **Allow Once**, Touch ID. The extension fills the username and password into the tab in front, in the browser and
   Chrome profile the agent is working in, and with `--submit` presses the form's own button.
4. The agent hears `submitted` (or `filled`) with the item's title, username and websites, and checks the page for
   whether the site accepted it. The password never leaves PasswordPie and the browser.

Two-step code: if the account has one and this Mac has Premium, the code goes into the code field when the site shows it,
exactly as when you fill it yourself. Without Premium the code is not filled; the page shows the usual note with Upgrade,
and the agent hears "two-step code not filled: needs PasswordPie Premium".

### The approval window

    Claude Code wants to log in to github.com

    ◉ GitHub  (Web)
      octocat · username and password, then sends the form
    Site      github.com
    Browser   Google Chrome
    Agent     Claude Code, signed by Anthropic PBC, started in Terminal   (pid 4182)
    The agent says:
    “Open the billing page”

    [ Deny ]                                   [ Allow Once ]

- One row per account. With `--url` and several shared accounts on that site, pick one; Allow Once stays off until you
  do.
- **Browser** names the Chrome profile only when several have the extension: "the profile in front", or "the profile used
  last" when Chrome is not the app in front (the agent's terminal often is).
- The window never shows the password, and nothing in it is the agent's but the quoted line.
- Every Allow asks for Touch ID, so an agent that can click cannot approve its own login.
- **Allow for 7 days ▾** (Premium, as for secrets) lets that agent log in with that account on that site again without
  asking, from any project, until the time runs out. Preferences > Agents > Standing permissions lists it as "Log in on
  github.com, any project", with Revoke. A login it lets through shows the menu-bar dot, as any silent use does. It
  covers the account and the site, not whether the form is sent or which browser. Without Premium the button says so and opens the Premium window; Allow Once
  still works. With several accounts offered, the lasting choice is for the one you picked; a login with several
  accounts to pick from always asks.

### What the agent hears

| Answer | Meaning | Exit code |
|---|---|---|
| `submitted` | Filled, and the form's own button was pressed. Whether the site accepted it shows on the page | 0 |
| `filled` | Filled; the form was not sent (no `--submit`, or no button was found) | 0 |
| `no-matching-tab` | The tab in front is not on the site: the agent's tab is in the background, or another page is open. PasswordPie never switches tabs. Also when no browser has PasswordPie's extension connected: the line then says that, and to ask you to turn it on in Preferences > Browsers | 74 |
| `site-mismatch` | The site asked for is not one of the item's websites. Nothing was filled, and nobody was asked. Answered first, with or without a browser | 75 |
| `timed-out` | No tab of that browser answered within 30 seconds: the extension is off or not installed in that profile | 76 |
| `no-fields` | The tab is on the site, but no password field appeared within 30 seconds | 77 |

Once you allowed it, every answer carries the item's title, username and websites. Never the password, never the code.
An answer given without asking you (the site or the tab did not match) carries neither the username nor the site your
tab is on: an agent cannot use `login` to watch what you browse.

### When it does not apply

- A site the item does not list. A request for github.com is never filled into another site, whatever the agent says.
- A headless browser, or a browser on another Mac: they have no PasswordPie extension. Agents there use `passwordpie run`.
- Safari fills, but only on sites where you allowed the extension.
- While locked: the request waits for you to unlock, as for a secret.

### Demo script

Use the direct download with the Chrome extension, an item **Demo Login** in **Agents** with website
`https://the-internet.herokuapp.com/login`, username `tomsmith` and password `SuperSecretPassword!`, and a terminal.

1. In Chrome open `https://the-internet.herokuapp.com/login`.
2. `passwordpie login 'pp://Agents/Demo Login' --submit`. The window says "wants to log in to
   the-internet.herokuapp.com"; Allow Once, Touch ID. The page shows "You logged into a secure area!"; the terminal prints `submitted` with the title, username and
   website, and no password.
3. Open another site in that tab and run step 2 again: `no-matching-tab`, nothing filled.
4. `passwordpie login 'pp://Agents/Demo Login' --url https://example.com/`: `site-mismatch` at once, no window.
5. Preferences > Agents > Activity shows each line with its outcome.

## A folder of .env files becomes items

**In one line:** point PasswordPie at the folder where your API keys sit in `.env` files, look at what it found, and
each file becomes an item with one protected field per variable. The files themselves are never changed.

### The problem

Developers keep keys in dotenv files: `stripe/work.env`, `cloudflare/personal.env`, a PEM key beside them. They are
plain text, readable by every program that runs as you, and today that includes AI agents. Import read exports of
logins from browsers and password managers; a folder of `NAME=value` files was nothing it knew. Nobody types seventy
variables into items by hand, so the files stayed where they were.

### What happens now

**Preferences > Import** has one more row under the two columns, below Another App: **A Folder of .env Files**.

**1. Choose the folder.** Drop it on the box, or click **Choose Folder…**. PasswordPie reads it on this Mac, with its
subfolders, and changes nothing in it: not now, and not after the import.

**2. Look at what it found.** Nothing is in the database yet. The page says, in this order:

- **Items**, one per `.env` file: where it goes ("stripe › work"), how many fields, the key files attached to it, and
  what importing would do: **New**, **2 fields change, 1 new**, or **Up to date**. Click a row to see the names of its
  variables and files. A value is never shown. Every row has a checkbox; untick one to leave it out.
- **Left alone**: every other file, counted by kind (scripts, images, templates, old copies), with the list one click
  away. A file left alone that holds one of the values being imported is named apart: "3 other files hold values from
  these files." Those are the generated copies, backups and scripts with a pasted token that you will want to delete
  too.
- **To check**: a line that could not be read (file and line number), a name set twice in one file, and values that
  a shell and a dotenv library read differently (see below). Names only.

**3. Import.** The button says how many: **Import 12 Items**. The page then says what happened: "9 added, 3 updated."

**4. The files are still there.** PasswordPie does not delete them: they are yours, and other programs may still read
them. The page says so, and that they still hold every value in plain text. In the downloaded app it names the check
to run before you delete them: `passwordpie check-import <folder>` compares every name and value in the files with the
database, inside PasswordPie, and prints **same**, **differs** or **missing** for each name, never a value ("Checking
a folder before deleting it", under "Agents use a secret without seeing it").

What becomes what:

| In the folder | In the database |
|---|---|
| `stripe/work.env` | Folder **stripe**, item **work** |
| `a/b/work.env` | Folder **a**, in it folder **b**, item **work** |
| `work.env` at the top | Item **work**, in no folder |
| `stripe/.env`, `stripe/.env.staging` | Folder **stripe**, items **env** and **staging** |
| `NAME=value` | A protected field **NAME** of that item |
| Lines that start with `#` | The item's notes. Not a line that switches a variable off (`# OLD_KEY=…`): notes are not a protected field, so it is left out and listed under To check |
| A key file beside it: a PEM key, `.p8`, `.p12`, `.pfx`, a JSON file with a private key or client secret, a file named `api_key`, `token`, `secret` or `credentials` | An attachment of the item of its folder |
| Anything else | Left alone, and listed |

Which item a key file goes to: the one whose name is in the file's name (`work.pem`, `work-service-account.json`), else
the only item of that folder, else an item **Key files** in that folder.

**Put them inside** is a field under the list, empty at first. Type a folder name such as **Agents** and everything
lands inside it (Agents › stripe › work), so one tick in Preferences > Agents shares all of it. A part called
**Recycle Bin** is dropped: the database keeps its Recycle Bin under that name.

An item's details list the names of its attachments under its fields. The files are not opened there: KeePass apps open
them, and an agent is handed one by its name ("Agents use a secret without seeing it").

How a value is read: as a dotenv library reads it. Quotes around a value are removed; in double quotes `\n`, `\t`,
`\"` and `\\` are what they stand for, and a value in quotes may run over several lines; without quotes, the value ends
at the end of the line or at ` #`. `export NAME=value` is the same as `NAME=value`. Nothing is expanded: `$OTHER` and
`${OTHER}` stay as typed. A value that has `$`, a backtick or a backslash in it is listed under To check, because a
shell that runs `source` on the file would have read it differently.

### Importing the same folder again

| | |
|---|---|
| A file that is new | A new item |
| A variable that is new | A new field of its item |
| A value that changed | The field is updated; the item's history keeps the version before |
| Comments that changed | The notes are replaced; the history keeps the version before |
| A key file that changed | The attachment is replaced; the history keeps the version before |
| A variable or a file that is gone | Left as it is. Nothing is ever removed |
| Nothing changed | "Already up to date. Nothing was changed." |

An item is the same one when it is in the same folder and has the same name. Other fields you added to it, its tags
and everything else in the database are not touched.

### When it does not apply

- **A locked database.** The pane says to unlock first.
- **Names that start with `.` or `_`.** A folder such as `.git`, `.backup` or `_local`, and a hidden file, are left
  alone and listed. The exception is `.env` itself and `.env.<name>`.
- **Templates and old copies.** `.env.example`, `.env.sample`, `.env.template`, `work.env.example` and anything ending
  in `.bak`, `.old`, `.orig` or `~` are left alone and listed.
- **A variable named like an item's own field** (`PASSWORD`, `USERNAME`, `URL`, `TITLE`, `NOTES`, `OTP`, in any case)
  is kept as the field **PASSWORD (variable)**, so it is not confused with the item's password.
- **A key file over 1 MB**, or a link to a file elsewhere, is left alone and listed.
- **An item in the Recycle Bin.** It is not brought back: importing its file again makes a new item.

### What it will not do

- Change, move or delete anything in the folder.
- Show a value in the preview, in a message or in a log.
- Remove a field, an attachment or an item because it is gone from the folder.
- Share what it imported with agents. Sharing is your tick in Preferences > Agents, as for any item.

### Privacy

- The folder is read on this Mac. Nothing is sent anywhere: PasswordPie opens no network connection.
- What was read is held in memory only until you import it, choose another folder or source, or close Preferences,
  and it is dropped when the database locks.
- The database file from before the import is kept beside it as `.snapshot`, as for every save.

### Demo script

Use a database with a few items, and a folder `keys` on the Desktop: `stripe/work.env` (two variables and a comment),
`stripe/personal.env`, `google/work.env`, `google/work-service-account.json`, `apple/AuthKey_ABC123.p8`,
`deploy.sh` and `stripe/work.env.bak`.

1. Preferences > Import > **A Folder of .env Files**. Drop `keys` on the box.
2. The page lists four items: stripe › work, stripe › personal, google › work with one key file, and apple › Key files
   with one key file; "2 files left alone", and that `work.env.bak` holds values from these files.
3. Click stripe › work: the names of its two variables, no values.
4. Click **Import 4 Items**: "4 added." Press `⌘\` and type "stripe": both items are there, each with its fields.
5. Change one value in `stripe/work.env` and drop the folder again: stripe › work says **1 field changes**, the others
   **Up to date**. Import: "1 updated."
6. In Finder the folder is exactly as it was.
