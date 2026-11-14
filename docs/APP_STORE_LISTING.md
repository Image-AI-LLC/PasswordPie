# Mac App Store listing

What goes into each field of App Store Connect for the App Store build of PasswordPie (`PP_MAS=1`, see
[CHANNELS.md](CHANNELS.md)). Change this file when the listing changes, so the next update starts from what is live.
`AppStoreListingTests` checks the store's length limits on every fenced value below, and that the description and
promotional text name nothing the App Store build does not have.

Everything here describes the App Store build only. It has no reader for Chrome's passwords, no Chrome extension, no
updater, and nothing that sends people to passwordpie.com to buy. Do not add any of it to this listing.

## App information

### App name

```text
PasswordPie: Password Manager
```

### Subtitle

```text
KeePass files, in the menu bar
```

- **Bundle ID:** `com.passwordpie`
- **Primary category:** Productivity (the build's `LSApplicationCategoryType` is `public.app-category.productivity`)
- **Secondary category:** Utilities
- **Copyright:** `2026 Image AI, LLC` (App Store Connect adds the ©)
- **Content rights:** the app ships the logos of about 100 popular sites, so it shows third-party content. Answer from
  where each logo came from, in [../Assets/SiteIcons/SOURCES.md](../Assets/SiteIcons/SOURCES.md): they are shown only to
  identify the site an account belongs to (README, "Credits").

## URLs

All four answer 200 on passwordpie.com (checked 2026-11-15). The same addresses are in the code
(`PremiumLinks` in `PasswordPieCore/Premium.swift`) and in [../extension/store/LISTING.md](../extension/store/LISTING.md).
`/privacy` and `/terms` are 404: do not use them.

- **Support URL:** https://passwordpie.com/support
- **Marketing URL:** https://passwordpie.com/
- **Privacy Policy URL:** https://passwordpie.com/privacy-policy
- **Terms of use (EULA):** https://passwordpie.com/terms-of-service, also at the end of the description (guideline 3.1.2)

## Version information

### Promotional text

```text
Your passwords in your own KeePass file, one shortcut away in the menu bar. No account and no sign-in. Free to install and use; two-step codes need Premium.
```

### Description

```text
PasswordPie is a password manager for Mac that lives in the menu bar. Your passwords stay in a standard KeePass file (.kdbx) on your Mac. There is no account and nothing to sign in to.

Free to install and use. Two-step codes need PasswordPie Premium, an in-app purchase.

ONE SHORTCUT AWAY
• Press ⌘\ in any app, or click the pie in the menu bar. You can change the shortcut.
• Type a few letters. Favorites come first, then the best matches, then the logins you used recently.
• Copy with the keyboard: ⌃⌘C for the username, ⇧⌘C for the password, ⌥⌘C for the two-step code. The clipboard clears itself after 90 seconds.
• Copied the username? Press ⌘\ again within 10 seconds: the same login is still selected, so the password is one keystroke away.
• Browse like a menu: Favorites, Logins, Secure Notes, Credit Cards, Identities, Folders and Tags.
• Pin a login with ⌘O. It stays above other windows and never takes the focus from the form you are filling.

FILL IN SAFARI
• Turn on the PasswordPie extension in Safari. On a sign-in page, press ⌘\: the accounts for that site are at the top.
• Press Return. The username and password appear in the form. PasswordPie never presses Sign In for you.
• It fills only a page on the account's own site. A look-alike domain gets nothing.

YOUR OWN FILE
• Reads and writes KeePass KDBX 4, and keeps what it does not edit. Other KeePass apps can open the same file.
• Keep the file wherever you like, and open several databases.
• Add a key file as a second key. It stays on this Mac, so a copy of the database that leaks cannot be opened with the master password alone.
• Unlock with Touch ID. PasswordPie locks after a few minutes of inactivity, when the Mac sleeps or the screen locks, and when you press ⌘L.

EVERYDAY TOOLS
• Password generator: random characters (4 to 64) or whole words (3 to 10).
• Large Type shows a password big, in groups of four, with letters, digits and symbols in different colors.
• Edit every field of an item: more than one website, your own fields, notes and tags.
• Set a reminder to change a password every 30, 60 or 90 days. The login moves to the top of the menu when it is due.

MOVING IN
• Import the CSV file your web browser or Apple's Passwords app exports. On macOS 26, Passwords can also hand its items to PasswordPie directly, with no file.
• Open the export files of several other password managers and KeePass 1 databases. The original file is left untouched.

TWO-STEP CODES (PREMIUM)
• The six-digit code for each login, with its countdown, next to the password. Press ⌥⌘C to copy it.
• In Safari, the code fills itself on the page after the password.
• Add a code from a screenshot of the QR code, or by right-clicking the QR code in Safari.
• Storing, importing and editing the secret is free. Without Premium, the code stays locked and your file keeps it as it is.
• Premium Lifetime is one payment. Premium Yearly is a subscription that renews each year until you cancel it in your App Store account settings.

PRIVATE BY DESIGN
• No account, no email, no sign-in.
• Your passwords stay in your file. PasswordPie sends them to no server, and has no analytics and no tracking.
• Logos of popular sites come with the app. PasswordPie asks no icon service for them.

REQUIREMENTS
• macOS 14 or later.

Terms of use: https://passwordpie.com/terms-of-service
Privacy policy: https://passwordpie.com/privacy-policy
```

### Keywords

Comma-separated, no space after a comma. No word from the app name (PasswordPie, password, manager), none from the
subtitle, and no other company's product name.

```text
kdbx,2fa,totp,otp,authenticator,two-factor,generator,vault,menubar,login,local,secure,touch id
```

### What's New

Not shown for the first version.

## Age rating

Every answer is None or No, so the rating is **4+**.

| Question | Answer |
|---|---|
| Parental controls | No |
| Age assurance | No |
| Unrestricted web access | No (the app has no web view; a website opens in the user's browser) |
| User-generated content | No |
| Messaging and chat | No |
| Advertising | No |
| Profanity or crude humor | None |
| Horror or fear themes | None |
| Alcohol, tobacco or drug use or references | None |
| Medical or treatment information | None |
| Health or wellness topics | No |
| Sexual content or nudity (all kinds) | None |
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Guns or other weapons | None |
| Simulated gambling | None |
| Contests | None |
| Gambling | No |
| Loot boxes | No |

## App Privacy

Answer **Data Not Collected**. Data handled only on the Mac is not collected, the app has no network code (no
`network.client` entitlement), and Apple handles the purchase. Keep it true: see "App Store privacy label" in
[CHANNELS.md](CHANNELS.md).

## Export compliance

The build's `Info.plist` says `ITSAppUsesNonExemptEncryption` = YES, so App Store Connect asks the questions for each
build. The app implements standard, published algorithms itself (AES-256, ChaCha20 and Twofish for the KeePass file;
Argon2 and AES-KDF to derive its key), in addition to Apple's. Choose **"Standard encryption algorithms instead of, or
in addition to, using or accessing the encryption within Apple's operating system"**. The encryption only protects the
user's own database on their Mac; the app sends nothing over a network. Answer any further question App Store Connect
shows (documentation) at submission, and record the answers here.

**France (decided 2026-11-15):** the first release is **not available in France**. Leave France out under Pricing and
Availability, so the French encryption declaration is not needed yet. Adding France later needs that declaration first.

## App Review notes

Paste into App Review Information > Notes, with a fresh activation link in place of the placeholder. Sign-in required:
**No** (leave the demo account empty). The field takes 4000 characters and a link is about 380, so the notes stay under
3500 with the placeholder (`AppStoreListingTests`).

```text
PasswordPie is a KeePass password manager for Mac. It has no account and needs no sign-in, so no demo account is needed.

OPENING IT
PasswordPie lives in the menu bar only (LSUIElement): no Dock icon, no window at launch. Click the pie icon in the menu bar, or press Command-Backslash (⌘\) in any app. Option-click the icon for Preferences… and Quit.

FIRST LAUNCH
The first launch creates a new, empty database in the app's own container. Choose any master password, type it twice and press Create Database. The menu then shows Get Started: Import Passwords…, New Item…, Password Generator.

The first time a database outside the app's container is opened or created (Open Database… or New Database… on the lock screen), a second panel asks to Allow its folder: PasswordPie keeps the previous version beside the database, so it needs the folder, not only the file. The folder is kept as a security-scoped bookmark.

TRYING IT
- New Item…: fill in a title, username, password and website, and Save. Search for it, then press ⌃⌘C (username) or ⇧⌘C (password).
- Import: Preferences > Import passwords takes the CSV that Chrome or Apple's Passwords app (File > Export All Passwords) exports. Any CSV with columns name,url,username,password works.
- macOS 26: in Passwords, File > Export All Items to App > PasswordPie. If it is not listed, turn PasswordPie on in System Settings > General > AutoFill & Passwords. The AutoFill extension exists only for this hand-over (Credential Exchange); it fills nothing and cancels AutoFill requests.
- Safari: turn on PasswordPie in Safari > Settings > Extensions (Preferences > Browser extensions > Enable Safari Extension… opens it) and allow it on the site. On a sign-in page, press ⌘\ or click its toolbar button; Return fills the username and password. It never submits the form.

PREMIUM (IN-APP PURCHASE)
Only two-step codes need Premium. To try it, paste this into an item's One-time password row in the editor and Save:
otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo
Without Premium the row shows Upgrade to unlock, which opens the plans: Premium Lifetime (com.passwordpie.premium.lifetime) and Premium Yearly (com.passwordpie.premium.yearly). Preferences > Premium has them too, with Restore Purchases and Manage Subscription.

ACTIVATION FROM THE WEBSITE (guideline 3.1.3(b))
Customers who bought Premium on passwordpie.com can use it here through a passwordpie://activate?token=… link that the website opens. The token is signed by the website and checked in the app, offline. There is no field in the app to type a key, and the app neither mentions the website nor sends anyone to buy elsewhere. The same plans are sold in the app through In-App Purchase.
To try it, open this link in Safari and allow it to open PasswordPie. The Premium window says Premium is on, and the code shows:
<ACTIVATION LINK FOR REVIEW — coordinator pastes a fresh one>

PRIVACY AND ENCRYPTION
The app opens no network connection of its own and has no network.client entitlement; StoreKit runs in Apple's process. App Privacy: Data Not Collected. It uses standard encryption algorithms (AES-256, ChaCha20, Twofish, Argon2) to protect the user's own database file on their Mac.
```

## In-app purchases

Set up in App Store Connect as in "Before Premium can be sold" in [CHANNELS.md](CHANNELS.md). Product IDs and names
match [../Configuration/PasswordPie.storekit](../Configuration/PasswordPie.storekit). Family Sharing off for both, as in
that file. Attach both to the first version submitted for review. The descriptions in the `.storekit` file are longer
than App Store Connect's 45 characters (48 and 50); use the ones below in App Store Connect.

**Review screenshot (both products):** the Premium window with the two plans and their prices, from a `make mas-dev`
build signed in to a sandbox tester (Upgrade to unlock on a code's row, or Preferences > Premium). One screenshot can
serve both.

### Premium Lifetime

- **Product ID:** `com.passwordpie.premium.lifetime`
- **Type:** Non-consumable
- **Reference name:** Premium Lifetime
- **Price:** US$29 (United States base price)

#### Lifetime display name

```text
Premium Lifetime
```

#### Lifetime description

```text
Two-step codes, with one payment.
```

### Premium Yearly

- **Product ID:** `com.passwordpie.premium.yearly`
- **Type:** Auto-renewable subscription, duration 1 year
- **Subscription group:** PasswordPie Premium (group display name: `PasswordPie Premium`)
- **Reference name:** Premium Yearly
- **Price:** US$10 (United States base price)
- **Billing Grace Period:** off (codes lock at the end of the paid year; see CHANNELS.md)

#### Yearly display name

```text
Premium Yearly
```

#### Yearly description

```text
Two-step codes, renewing each year.
```

## Screenshots

App Store Connect takes 1 to 10 Mac screenshots at 16:10. The set is the 2880x1800 PNGs in
`~/projects/PasswordPie/marketing/appstore/dist/en/` (marketing repo), uploaded in file name order. The first
release uploads **01, 02, 04 and 05** (decided 2026-11-15); `03-details.png` stays out until it is reshot. Checked against the
App Store build on 2026-11-15:

| File | What it shows | App Store build | Reshoot |
|---|---|---|---|
| `01-cover.png` | The menu open from the menu bar: Favorites (Amazon, Google, Instagram, PayPal, Reddit, Spotify), Password Generator, the categories, Folders, Tags. Caption "Every password, one shortcut away. ⌘\" | OK. Nothing direct-only; the stars are favorites, not Chrome badges | None needed. Optional: other sites' logos are third-party marks (PRODUCT.md calls brand names on store posters a review risk) |
| `02-search.png` | Search "go": Open Login group, Google (favorite), GoDaddy, Google. Caption "Favorites first. The logins you use most rise to the top." | OK. Minor wording: ranking boosts logins used **recently**, not most often (RANKING.md) | Only if the caption is redone: "…the logins you used recently rise to the top." |
| `03-details.png` | A Microsoft login's details: username, password, strength, website, a live one-time password, tags. Shortcuts ⌃⌘C / ⇧⌘C / ⌥⌘C. "Two-step codes need PasswordPie Premium." | Mismatch (minor): the build shows the one-time password right under strength, **before** the website (`DetailsView.detailFields`); the screenshot has it after. The Premium note is present, as guideline 2.3.2 asks | Retake the details popover from the current build (with Premium on, so the code shows) |
| `04-your-file.png` | Lock screen for Personal.kdbx with Unlock, Unlock with Touch ID, Choose Key File…, Open Database… / New Database…. "A standard KeePass .kdbx, kept where you choose. No account. Touch ID to open." | OK. All of it is in the App Store build; another folder asks once for access, which the caption does not contradict | None |
| `05-generator.png` | The password generator (Characters / Words, length, digits, symbols, Avoid ambiguous characters, Regenerate Password, Copy) and Large Type | OK | None |

None of the five shows Sync Chrome Passwords, a Chrome badge, the Chrome extension, Updates, or Get Premium on
passwordpie.com. No screenshot shows the Safari fill; one could be added.
