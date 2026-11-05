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

**In one line:** PasswordPie is free to install and free to use. Only two-step codes need Premium.

This is the App Store version. A copy downloaded directly from passwordpie.com has no paywall and keeps its codes.

### The problem

A password manager that also makes your two-step codes saves a trip to your phone at every sign-in. That is the one
thing worth paying for. Everything else, including storing the secret itself, stays yours for free.

### What happens now

The free version does everything except make a code: search, copy, fill, edit, import, Touch ID, pinned windows.

An item with a two-step code still says so. Its "one-time password" row shows a lock, "Included with Premium", and an
Upgrade button. Upgrade opens a small window with the two plans.

| Plan | What you pay |
|---|---|
| Lifetime | One payment, in your local currency. |
| Yearly | A subscription that renews each year until you cancel it. |

The App Store sets the prices and the currency. The window shows exactly what Apple gives it.

Buy a plan and the codes appear straight away: the row in an open popover or pinned window turns into a live code.
There is nothing to relaunch and nothing to type in.

### What the shortcuts do

A shortcut for a code never does nothing, and it never empties your clipboard.

| What you press | With Premium | Without Premium |
|---|---|---|
| ⌥⌘C in the menu, on an item with a code | Copies the code, closes the menu | Closes the menu, opens the plans. The clipboard is unchanged. |
| ⌥⌘C with a pinned window, in any app | Copies the code | Opens the plans. The clipboard is unchanged. |
| ⌥⌘C on an item with no code | Nothing to copy, same as before | Nothing to copy, same as before |
| ⌥Return, ⇧Return (Open and Fill, Fill) | Types the username and password | Types the username and password |

Fill never types a code, on either version.

### Your data stays yours

Going free, or letting a subscription end, never touches your database. The secret stays in the KeePass file exactly
as it was, and saving keeps it. Import brings codes in too. You can still add or change a secret in the item editor,
and other KeePass apps can still read it. Subscribe again and the codes come back.

### When Premium ends

- **Yearly runs out or is cancelled.** Codes lock when the paid year ends.
- **Apple refunds a purchase.** Codes lock as soon as the App Store tells the app.
- **Another Mac.** Premium follows your Apple Account. Press Restore Purchases if it has not arrived.

Apple is the only source of who has Premium. The App Store version keeps no flag of its own, so nothing on disk can
turn it on.

### Preferences

Preferences starts with a Premium section: your status, the plans you can still buy, Restore Purchases and Manage
Subscription. If you hold both plans, it reminds you that the yearly one keeps renewing until you cancel it.

### When something goes wrong

| What happened | What you see |
|---|---|
| The App Store cannot be reached, or lists no plans | "The App Store did not return the plans", and Try Again |
| A purchase needs approval, such as Ask to Buy | "Waiting for approval". Premium unlocks by itself when it is approved. |
| You cancel the purchase | "Purchase cancelled." The plans stay. |
| The purchase fails | The reason from the App Store. The plans stay. |
| You already own the plan | The plan says "Owned" and cannot be bought twice. |
| Restore finds nothing | "No purchases to restore on this Apple Account." |

### Demo script

Use a sandbox Apple Account and a database with one login that has a two-step code.

1. Press the menu shortcut, search for the login, and press → to open its details. The row shows the lock and Upgrade.
2. Copy something else to the clipboard. Press ⌥⌘C. The plans open. Paste: your clipboard is unchanged.
3. Pin the login with ⌘O and close the plans. Press ⌥⌘C from another app. The plans open again.
4. Buy Lifetime. The plans close, and the pinned window now shows a live code with its countdown.
5. Press ⌥⌘C and paste the code.
