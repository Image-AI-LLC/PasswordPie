# Release channels

One source tree, two channels. The channel is chosen at build time, not by a runtime switch, so
App Store builds do not contain direct-only code.

| | Direct (default) | App Store |
|---|---|---|
| Build | `swift build` / `make install` / `make dist-direct` | `PP_MAS=1 swift build` / `make mas-dev` / `make dist-mas` |
| Swift flag | `PP_DIRECT` defined | not defined |
| Sandbox | no (hardened runtime, notarized) | yes (`Entitlements/mas.entitlements`) |
| Import CSV from Chrome / Apple Passwords | yes | yes |
| Changes made on two Macs are merged ([UX.md](UX.md), "The same database on two Macs") | yes | yes, the same code. The file and the copies a sync tool leaves beside it are read through the folder the app was allowed; not yet tried in the sandbox (see "Before an App Store submission") |
| Import a folder of `.env` files (Preferences > Import) | yes | yes |
| Live read of Chrome's password store | yes (Preferences > Browsers) | **not compiled in** |
| Two-step codes (Premium) | an activation from passwordpie.com, where Premium is bought. **No account, no sign-in in the app** | a StoreKit 2 purchase on this Apple Account, or an activation from passwordpie.com. **No account, no sign-in** |
| Two-step codes in the browser (Premium) | the app has Premium ([ACCOUNTS.md](ACCOUNTS.md)) | the app has Premium |
| Network from the app | **none** of its own; the separate updater asks GitHub for a newer version once a week (see "Network" and "Updates" below) | **none**: no `URLSession`, no `network.client` entitlement |
| Updates | `PasswordPieUpdater`, inside the app: weekly, from GitHub releases | the App Store; the updater is **not in the bundle** |
| Extension toolbar button | Opens PasswordPie. No popup, no account, no request to the site. Right-click: Scan QR code on this page, and in Chrome Open passwordpie.com | The same Safari build as the direct channel's: no line that opens the site |
| Agent access ([AGENTS.md](AGENTS.md)) | Preferences > Agents, `agent.sock`, the `passwordpie` tool in `Contents/Helpers` (`run`, `read`, `list`, `status`, `login`, `write-env`, `check-import`, `mcp`). An approval each time is free | **not compiled in**: the app links no `PasswordPieAgent`, and the bundle has no `Contents/Helpers` |
| Agents' standing permissions (Premium) | the app has Premium (`appHasPremium()`); nothing in a request says so | not there |
| Browser extension | Safari and Chrome (the Chrome Web Store extension; an unpacked build has the same ID) | Safari only; Chrome's native host is **not compiled in**. See [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md) |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

Check the store app has no agent access:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e agent.sock -e com.passwordpie.cli -e agentAccessEnabled -e PasswordPie.AgentSharing -e PasswordPie.AgentGrants -e agentGrantLength -e mcp_servers -e login-result   # expect 0
    test ! -e build/mas/PasswordPie.app/Contents/Helpers && echo ok                                  # expect ok

What stays in the store binary is view code both channels share and that does nothing there: the Agents pane's name in
the list of panes (the pane is left out), and the lock screen's field for "… is waiting for 1 secret".

Check the direct bundle carries the tool, signed as the app expects, and that no debug hook reached a release build
(`PASSWORDPIE_AGENT_APPROVE` answers the approval window without Touch ID; `PASSWORDPIE_AGENT_SOCKET` skips the tool's
check of the app):

    codesign -dv build/direct/PasswordPie.app/Contents/Helpers/passwordpie 2>&1 | grep -e '^Identifier=com.passwordpie.cli$' -e 'flags=.*runtime' -e '^TeamIdentifier=2S468LUF8V$' | wc -l   # expect 3
    strings -a build/direct/PasswordPie.app/Contents/MacOS/PasswordPie build/direct/PasswordPie.app/Contents/Helpers/passwordpie | grep -c -e PASSWORDPIE_AGENT_APPROVE -e PASSWORDPIE_AGENT_SOCKET   # expect 0
    nm -u build/direct/PasswordPie.app/Contents/Helpers/passwordpie | grep -c -i -e URLSession -e CFNetwork   # expect 0

Check no debug preview or mock site can reach a release store build, and that the direct binary does not link StoreKit:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e PASSWORDPIE_PREMIUM_PREVIEW -e PASSWORDPIE_SITE_URL   # expect 0
    otool -L "$(swift build -c release --show-bin-path)/PasswordPie" | grep -c StoreKit                     # expect 0

Check neither build has an account or a way to reach the site:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api/premium -e app/sign-in -e api/auth   # expect 0
    strings -a build/direct/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api/premium -e app/sign-in -e api/auth   # expect 0
    otool -L build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c AuthenticationServices.*Web   # informational: AutoFill links the framework
    codesign -d --entitlements :- build/mas/PasswordPie.app | grep -c network.client                      # expect 0
    grep -rlE 'api/premium|api/auth' build/mas/PasswordPie.app/Contents/PlugIns/*Safari*/Contents/Resources   # expect nothing

## Upgrading from v0.1.0 (the old bundle ID)

The direct build v0.1.0 was `com.oldcai.passwordpie`; everything is `com.passwordpie` since 2026-11-13. macOS sees the new
app as a different app, so on its first launch it brings over what it can, once (`LegacyMigration`, run before anything
reads a preference; marker `legacyNamespaceMigrated`):

| What | Carried over? |
|---|---|
| Preferences (database list, Touch ID flags, shortcuts, clipboard timeout…) | Yes: each key the new domain lacks is copied from the old one |
| Touch ID secret, remembered key file, Premium activation (login keychain) | Only when readable without a dialog. The old items' access lists name the old signature, so in practice no: the lock screen asks for the master password once, and that unlock turns Touch ID back on (a Touch ID flag with no secret turns itself off quietly). A key file is chosen again on the lock screen; Premium is activated again from passwordpie.com |
| Accessibility access (Fill by typing, the URL read) | No: macOS asks again at the first Fill. System Settings may list PasswordPie twice; the new one is the one that is off |
| Safari extension | No: Safari lists it as new; turn it on again in Safari's settings |
| AutoFill provider (`.autofill`) | No: a new provider to macOS; turned on again in System Settings > AutoFill & Passwords where it was on |
| Chrome extension | Yes: the app installs the old host name too (BROWSER_EXTENSION.md, "Host manifests") |
| Site icon cache | No: the extension sends icons again as sites are visited |
| Access to Chrome Safe Storage (Chrome passwords, when on) | No: that item's access list names the old signature, so macOS asks once; Always Allow ends it |

Keychain reads here never show a dialog (`TouchIDSecretStore` turns keychain UI off), and nothing old is deleted: the
old items belong to the old signature. Nothing on a development Mac needs cleaning either: old keychain items and the
socket in the old App Group container are never read by the new build.

## Releasing the direct download

Before the build:

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in the three `Info.plist` files (the app, AutoFill, Safari)
   and the version About falls back to (`AboutCopy.versionLabel`). `AboutScreenTests` fails if they disagree.
2. `swift test` and `cd extension && pnpm test`, in a terminal of the logged-in Mac session: over SSH the login
   keychain is out of reach and the keychain tests skip or fail.
3. The checks at the top of this file (`make dist-direct`, `make mas-dev`, then the `strings` / `otool` / `codesign`
   lines).
4. The release build trusts the site's key and not the test key. `swift test` cannot show it (tests are debug builds):
   link a few lines that print `EntitlementToken.trustedKeys.count` (expect 1) and
   `EntitlementToken.verifyActivation` of a `Scripts/mint-activation-link.mjs` token (expect nil) against the release
   `PasswordPieCore.o`.
5. The site signs with the private half of `EntitlementToken.publicKey`: see step 7 of "Before Premium can be sold".
6. Agent access under the release signature. The tool has no version of its own (it reads the app's `Info.plist`), so
   nothing more is raised. With the installed PasswordPie quit, start the `make dist-direct` bundle once with
   `open -n -a build/direct/PasswordPie.app --args -agentAccessEnabled YES` and run
   `build/direct/PasswordPie.app/Contents/Helpers/passwordpie status`: "running, locked", "Agent access: on" and the agent
   it sees mean the app and the tool accepted each other's Developer ID signature. `status` asks for nothing, so the
   lock screen stays as it is; quit the bundle and open the installed app again (it rewrites Chrome's host manifest).
   The rest of the path needs Touch ID: [AGENTS.md](AGENTS.md), "Trying it".
7. An agent login that sends the form needs extension 0.7.0 or later in the Chrome Web Store ("Releasing the Chrome
   extension" in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md)); an older one still fills, and the agent hears `filled`.
   The text for the GitHub release is in [RELEASE_NOTES.md](RELEASE_NOTES.md).

Then:

    Scripts/release-direct.sh

Notarization signs in with the notarytool keychain profile `passwordpie-notary` (another name: `NOTARY_PROFILE`), so
nobody types the app-specific password for a release and it is on no command line while the script waits for Apple.
On a Mac that has no such profile yet, give the script the credentials once, as
`NOTARY_ENV=<file with APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID>` or in the environment: it stores them as the profile
and uses that from then on. `Scripts/release-direct.sh --check` only signs in and says whether it works. The keychain
is locked to an SSH session, so run the script from a terminal of the logged-in desktop.

The release does not take its credentials from PasswordPie yet: the keychain profile stands in. Moving it to an App
Store Connect API key that `passwordpie run --file` hands out for the length of the run needs a key made in App Store
Connect first. What works today is making the profile from an item instead of a file of credentials, with the three
values as shared fields: `passwordpie run --env APPLE_ID=pp://… --env APPLE_PASSWORD=pp://… --env APPLE_TEAM_ID=pp://…
-- Scripts/release-direct.sh --check` (not yet tried with the real Apple ID). PasswordPie will then report that
`notarytool` was given the password as an argument: that is the script's one such moment, at `store-credentials`.
Either way a release runs on the Mac where PasswordPie is unlocked: approvals happen at that Mac.

It runs `make dist-direct`, notarizes and staples the app, then wraps it in `build/direct/PasswordPie-<version>.dmg`
(with an Applications shortcut), signs, notarizes and staples the DMG, and checks both with `spctl`. Attach the DMG and
its `.sha256` to a GitHub release tagged `v<version>`; passwordpie.com links to
`releases/latest/download/PasswordPie.dmg`, so upload a copy under that name too. Installed copies read the tag and
download `PasswordPie-<version>.dmg` within a week of the release being published (see "Updates"), so publish the
release only once that asset is attached.

Direct builds trust the Chrome Web Store extension's ID (`BridgeConstants.chromeExtensionID`). Releases made before it
was added cannot connect to the store extension. The Chrome extension itself ships through the Chrome Web Store: see
"Releasing the Chrome extension" in [BROWSER_EXTENSION.md](BROWSER_EXTENSION.md).

The build is Apple Silicon only: `libargon2.a` comes from Homebrew, which ships it for one architecture. An Intel or
universal build needs an x86_64 argon2 first.

The AutoFill extension's restricted entitlement is stripped unless `APP_PROFILE` and `APPEX_PROFILE` are passed, as with
every other target here.

## Releasing the App Store build

The App Store build is the same source with `PP_MAS=1`. Its App Store Connect record is for the bundle ID
`com.passwordpie` (the record made for 0.1.0 is locked to v0.1.0's old bundle ID and cannot take it). What goes into
each field of the listing, the review notes and the in-app purchases is in [APP_STORE_LISTING.md](APP_STORE_LISTING.md).

Once, on the developer site (team `2S468LUF8V`):

| App ID | Capabilities | Mac App Store distribution profile |
|---|---|---|
| `com.passwordpie` | In-App Purchase, App Groups (`2S468LUF8V.com.passwordpie`), AutoFill Credential Provider | PasswordPie Mac App Store |
| `com.passwordpie.autofill` | AutoFill Credential Provider | PasswordPie AutoFill Mac App Store |
| `com.passwordpie.safari` | App Groups (`2S468LUF8V.com.passwordpie`) | PasswordPie Safari Mac App Store |

The profiles are made for the "3rd Party Mac Developer Application" (Mac App Distribution) certificate, and the package
is signed with "3rd Party Mac Developer Installer". Install the profiles (double-click), or pass them as
`MAS_APP_PROFILE`, `MAS_AUTOFILL_PROFILE` and `MAS_SAFARI_PROFILE`.

Before the build: the same version steps as the direct download (both channels share the three `Info.plist` files). A
build number can be uploaded only once per version, so raise `CFBundleVersion` if this version was uploaded already.

Then:

    Scripts/release-mas.sh            # build/mas-dist/PasswordPie-<version>-<build>.pkg, checked
    Scripts/release-mas.sh --upload   # the same, then sent to App Store Connect

It finds the three profiles and checks each one: a distribution profile, for its bundle ID and team, not expired, made
for the certificate in the keychain, and the AutoFill one with its capability. Then `make dist-mas` builds with
`PP_MAS=1`, signs the Safari extension, the AutoFill extension and the app with their entitlements plus
`com.apple.application-identifier` and `com.apple.developer.team-identifier`, embeds each profile, and runs
`productbuild`. The script then checks the package and stops at the first failure: every bundle sandboxed, signed with
the App Store certificate and carrying its profile; no `network.client`; `Contents/MacOS` holds only `PasswordPie` (no
updater, no Chrome host); the `strings` checks at the top of this file and in "Updates"; the versions of the app and
both extensions; the App Store category; and `pkgutil --check-signature` names the installer certificate.

`--upload` wraps the signed app in an `.xcarchive` and gives it to `xcodebuild -exportArchive` with the destination
`upload`. That signs in as the Apple ID in Xcode > Settings > Accounts, so no password is typed or passed; if Xcode's
session has run out, sign in there again. Apple processes the build for a few minutes before it shows under TestFlight.

**Export compliance.** `Info.plist` leaves out `ITSAppUsesNonExemptEncryption`: the app implements standard algorithms
(AES, ChaCha20, Twofish, Argon2) to protect the user's own database, besides Apple's, so NO would be wrong, and YES makes
App Store Connect refuse the upload without an export compliance code. Answer the questions for each build in App
Store Connect ([APP_STORE_LISTING.md](APP_STORE_LISTING.md), "Export compliance"). Every extension needs a
`CFBundleDisplayName` too, or the upload is refused (`AppStoreInfoPlistTests`).

**Testing before upload.** A package signed for the App Store does not launch on a Mac: Apple signs it again. Test
with `make mas-dev` (sandboxed, development signature; the AutoFill extension's restricted entitlement is stripped
unless `APP_PROFILE` and `APPEX_PROFILE` name macOS development profiles), or install the uploaded build from
TestFlight. Its first launch copies the direct build's preferences into the sandbox container (the same bundle ID), so
the lock screen shows the direct build's database; unlocking it asks for its folder first (UX.md, "The App Store app
asks once for a database's folder"). Use a demo database: never unlock a real vault with a test build.

## Network

Neither channel's app opens a network connection of its own. `NetworkSourceTests` fails if any file under `Sources/`
(the app, its core, the bridge, the update library, the Chrome host, the Safari and AutoFill extensions) names
`URLSession`, `URLRequest`, `ASWebAuthenticationSession`, `NWConnection` or another networking API (`Network`, `WebKit`,
BSD inet sockets), except files on its allow-list. The allow-list has one file: `GitHubTransport.swift`, in the updater
(`Sources/PasswordPieUpdater`), a separate executable that only the direct channel's bundle contains (see "Updates"). No
entitlement file asks for `network.client`. Every `Data(contentsOf:)` in the sources reads a file URL (checked by reading
them; the test does not prove it).

What remains, none of it a connection the app makes:

- **Pages it opens in your browser.** Get Premium, Redeem a Key and Open Account Settings (passwordpie.com), Add Chrome
  Extension… (the Chrome Web Store), a database entry's website, the links in About. The browser loads them, not the app.
- **The browser extensions.** The app talks to them over a Unix socket in its App Group container, on this Mac. The
  Chrome host and the Safari extension relay frames to that socket and nothing else. The extension itself asks
  passwordpie.com nothing: it has no account. Its one kind of request is the icon of a site you have an account for,
  fetched from where the page says it is (BROWSER_EXTENSION.md, "Site icons").
- **The updater**, direct channel only: `PasswordPieUpdater` asks `api.github.com` for the latest release once a week
  and downloads its disk image from GitHub when it is newer. It is another process, with none of the database code.
- **macOS.** The system may check the app's signature and notarization, and Safari, Chrome and Passwords do their own
  networking. None of it is PasswordPie's code.

Site icons come bundled or from the extension (BROWSER_EXTENSION.md, "Site icons"); the app fetches none.

## Updates

Direct channel only; the user's side is "Updates that install themselves" in [UX.md](UX.md).

`Contents/MacOS/PasswordPieUpdater` is its own executable (`Sources/PasswordPieUpdater`, signed as
`com.passwordpie.updater`). It links `PasswordPieUpdate` and nothing else of ours: no core, no bridge. The app
(`UpdateCoordinator`, behind `#if PP_DIRECT`) starts it and reads one JSON line from its standard output.

| Command | What it does |
|---|---|
| `PasswordPieUpdater check` | Refuses unless the app around it is a Developer ID build of our team (so `make install` builds never ask GitHub). Reads `api.github.com/repos/Image-AI-LLC/PasswordPie/releases/latest`; when the tag is a higher version and the release has `PasswordPie-<version>.dmg`, downloads it to `~/Library/Caches/com.passwordpie.updater`, checks the disk image's signature, mounts it read-only without showing it, copies `PasswordPie.app` out and checks the copy. Prints `upToDate`, `staged` (with the path), `available` (newer, but this copy cannot be replaced), `notEligible` or `failed`. |
| `PasswordPieUpdater install <staged app> <pid> [relaunch]` | Waits for the app (`pid`) to exit, checks the staged app again, swaps it with the app around the updater by two renames on the same volume (the old app is put back if the second fails), and with `relaunch` opens the app again, whether or not the swap worked. |

What a download must pass (`ReleasePolicy`): a valid signature, checked strictly and with nested code, that satisfies
`anchor apple generic`, Developer ID Application, team `2S468LUF8V` and `notarized`; for the app, also identifier
`com.passwordpie` and a `CFBundleShortVersionString` higher than the installed one. The check does not depend on GitHub
being honest: a release someone else put there fails the signature, and an old release of ours fails the version.

The app decides when: `UpdateSchedule` says a check is due 7 days after the last one that got an answer, and 1 day after
one that failed. A staged update is installed when the vault is locked and no window is open, at quit, or at the next
start. The app forgets the staged path before it hands it to the updater, so an install that fails is tried once and
not on every start; the next weekly check stages it again.

Nothing changes in how a release is made: the updater reads the same GitHub release, and needs the tag `v<version>` and
the asset `PasswordPie-<version>.dmg`.

The first version with the updater is 0.2.0, build 3: About says "Version 0.2.0 (3)". Two older downloads have none and
are replaced by hand, by downloading the current version once:

- **0.1.0.**
- **The first 0.2.0 (build 2)**, public from 2026-11-14 until it was withdrawn on 2026-11-15. It carries the same
  version number, so nothing but the build tells them apart: About says "Version 0.2.0 (2)", and Preferences has no
  Updates section. The updater could not reach it in any case, since that copy has no updater to run.

A release that replaces a published one under the same version, as build 3 did, reaches nobody who already has that
version: the updater compares `CFBundleShortVersionString`, not the build. Raise the version instead whenever the
replaced copy has an updater.

Check the store build has no updater, and the direct build's app still links no networking of its own:

    ls build/mas/PasswordPie.app/Contents/MacOS                                   # expect PasswordPie only
    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -e api.github.com -e PasswordPieUpdater -e updateAutomatically   # expect 0
    nm -u build/direct/PasswordPie.app/Contents/MacOS/PasswordPie | grep -c -i -e URLSession -e CFNetwork   # expect 0

## Direct-only code

Agent access is direct-only as a whole: the `PasswordPieAgent` library and the `PasswordPieCLI` tool are not linked or
bundled by the store build, and the app's side (`AgentAccess.swift`, `AgentApproval.swift`, `AgentsPane.swift`,
`VaultSession+Agents.swift`, `BrowserBridge+AgentLogin.swift`) is behind `#if PP_DIRECT` ([AGENTS.md](AGENTS.md)).

The Chrome reader is behind `#if PP_DIRECT` too: `ChromeLogins.swift`, `ChromeUpdates.swift`, `VaultSession+Chrome.swift` and
`VaultSession+ChromeUpdates.swift` (store build has no-op stubs), the Chrome section of Preferences, and the Chrome tests.
Live Chrome logins are held in `VaultSession.liveEntries`, separate from `entries`, so `save()` can never write them
into the KeePass file. Chrome itself is read-only. A newer Chrome password on the same account replaces the saved one,
and older ones move to the protected `PasswordPie.PreviousPasswords` field; see "The newest password wins" in
[UX.md](UX.md). The store build leaves that field alone and hides it, as it does the other reserved fields.

## What was verified for the App Store channel (dev-signed, `make mas-dev`)

- Builds, signs with the sandbox entitlement, launches, and creates its container data folder.
- Reading Chrome's folder is denied in the sandbox (this is why live read is direct-only).
- The legacy keychain (what Touch ID unlock and remembered key files use) works inside the sandbox: add, read, delete.
- New Database… in a folder the app has no access to shows the folder panel in that folder; Cancel keeps the current
  database and writes nothing (2026-11-15).
- With the direct build's Chrome host still installed, the host connects to the store build's socket and the store
  build refuses it: its peer check cannot read the host (`deny file-read-data` in the sandbox log, about once a second).

## Key files in the sandbox

A key file is read once, when it is chosen in an open panel (Choose Key File…, Use Existing Key File…) or written to
the place chosen in a save panel (Add Key File…). Both are user-selected files, which
`com.apple.security.files.user-selected.read-write` covers. After the first unlock with it, PasswordPie keeps the
file's **contents** in the login keychain (generic password, service `com.passwordpie.keyfile`, account = the
database path, the same legacy keychain as the Touch ID secret, which works in the sandbox). Later unlocks read the
keychain, never the original path, so neither channel needs a security-scoped bookmark to the key file. Forget Key File
deletes the item; Remove Key File deletes it too, and so does removing the database from the list in Preferences. The Touch ID secret (`com.passwordpie`) holds only the master
password; a KeePass 1 key file that older builds put inside it is still read, and removed on Forget Key File.

## Before an App Store submission

What used to block a store build, and where each one stands:

1. **Remembering a database across launches, and saving it.** Done: the folder is asked for once and kept as a
   security-scoped bookmark (`FolderAccess`, `FolderGrants`; UX.md, "The App Store app asks once for a database's
   folder"). A save writes beside the database (`.snapshot`, a temporary file), which the file alone does not allow.
2. **An imported CSV, 1Password, Bitwarden, Proton Pass or KeePass 1 file is saved as a sibling `.kdbx`.** Done by 1:
   the folder holding the import is allowed when it is opened.
3. **Fill by typing and the browser URL read** use `AXIsProcessTrusted`, `CGEventPost` and the Accessibility API. A
   sandboxed app can be granted Accessibility; not yet confirmed on a store build. If it does not work, the store build
   hides Fill by typing; filling in Safari goes through the extension and needs no Accessibility.
4. **Touch ID.** Works in the sandbox with the legacy keychain, as above. The data-protection keychain is not needed.
5. **In-app purchase.** Built: see "Premium". What is left is in App Store Connect, under "Before Premium can be sold".
6. **Site-ranking data.** The Majestic Million is CC BY 3.0, which allows commercial use with attribution; About and the
   README credit it.
7. **The same database on two Macs** (UX.md). The merge itself needs nothing the sandbox withholds. Not yet tried on a
   store build: finding a sync tool's copy beside the database and reading it (in the allowed folder), the dated copy
   from before a merge, Move to Trash for a merged copy, and iCloud Drive's conflict versions (`NSFileVersion`).

## Premium

Two-step codes need Premium, on both channels, and so do agents' standing permissions in the direct one ("Do not ask
me every time" in [UX.md](UX.md); an approval each time is free). Everything else is free. The behavior is in "Premium:
two-step codes" in [UX.md](UX.md).

**Neither app has an account** (user decision, 2026-11-10, replacing 2026-11-08's "the direct app signs in"), **and
neither has the browser extension** (user decision, 2026-11-11, replacing 2026-11-10's "the extension signs in and hands
its pass to the direct app"). People sign in in one place only: passwordpie.com, to buy and to press Activate. The direct
app has no sign-in, no session and no call to passwordpie.com; it has Premium while it holds an **activation** from the
website. The two channels differ only in how Premium is bought: Apple's In-App Purchase in the App Store app,
passwordpie.com for the direct one. The extension is a bridge and knows nothing about Premium
([ACCOUNTS.md](ACCOUNTS.md)).

### Who has Premium: the App Store channel

`AppStorePremiumStore.hasPremium` is true while StoreKit reports a verified, unrevoked, unexpired purchase
(`PremiumStatus`), or while the keychain holds an **activation** that still checks. Nothing is sent anywhere.

An activation is a `passwordpie://activate?token=<JWT>` link opened from passwordpie.com. The token is an Ed25519 JWS
with `aud: passwordpie-activation` ([ACCOUNTS.md](ACCOUNTS.md), "The activation token"). `exp` is the earlier of
one year and the end of the account's Premium. It cannot be revoked, because the app never talks to the site, so a refund
on the site stops counting only at `exp`. The app keeps whichever valid activation runs out latest, and never logs the
token. Both channels register the `passwordpie` URL scheme (`CFBundleURLTypes` in the shared `Info.plist`) and share
`ActivationVault`; any other `passwordpie://` URL does nothing. An activation lasts a year for every plan, lifetime included:
pressing Activate again renews it, and no longer token is issued.

Guideline 3.1.3(b) allows access to what was acquired on your website as long as the same is sold in the app, which it
is. Guideline 3.1.1 forbids an app's own unlock mechanisms such as license keys, so activation has no UI in the app and no
field to type into, and the review notes must describe it, or guideline 2.3.1 (no hidden features) applies. If review
objects, removing `application(_:open:)` and the URL type drops activation and leaves purchases untouched.

### Who has Premium: the direct channel

`DirectPremiumStore.hasPremium` is true while the keychain holds an **activation** that checks: its Ed25519 signature
against a key built into the app (`EntitlementToken.trustedKeys`), `iss`, `aud: passwordpie-activation`, and an `exp` in
the future. It is the `passwordpie://activate` link above, exactly as in the App Store app. The rules are `DirectPremium`
in `PasswordPieCore/DirectPremium.swift` (tested in `DirectPremiumTests`). The app trusts the signature, never the sender.

| What happened | Premium |
|---|---|
| An activation link that checks | Yes, until its `exp` (the latest one held wins) |
| An activation link that ran out, or a token made for anything else sent as an activation | Refused, with a plain message. Nothing changes |
| The activation's `exp` passes | No, from that moment; the window says when it ended |
| Anything a browser extension sends | Nothing changes. The app knows no message that carries a proof of Premium |
| Nothing held | No |

The app re-evaluates when a link arrives, at launch, when the menu opens, and when the `exp` passes. No timer talks to a
site, because nothing does.

**After a purchase.** The site's page after checkout, and after redeeming a key, shows Activate; so does the account's
settings. Pressing it is the one step between paying and the codes. It has to be pressed again each year, and once on
each other Mac.

**Migration.** Direct builds made from `main` before 2026-11-11 kept more in the keychain: `session` and `email` (builds
between #37 and #43 signed in inside the app), and the passes `pass.chrome`, `pass.safari` and `pass` (builds from #43
on took a week-long pass from the browser extension). None of that was ever released: v0.1.0 had no account and no bridge,
and the extension in the Chrome Web Store (0.1.0) has no account. All five are deleted at every launch, unread; a Mac
that had Premium only from a pass says "Free" and how to activate.

**Keychain.** The legacy login keychain, service `com.passwordpie.account` (`.dev` in any debug build), account
`activation`. It works in the sandbox without a profile (see above). It is never logged, echoed over the bridge or
written anywhere else. Nothing is read from it before `PremiumStore.start()` or a link arriving.

**The browser.** `appHasPremium()` (the seam the browser bridge asks) is this Mac's own Premium: an activation, not the
free-codes switch.

**What a shared activation allows.** An activation is a bearer proof. Whoever copies the link before it is opened, or
the token from a keychain, gives another Mac Premium until its `exp`, at most a year. The site could limit how many it
issues per account; nothing in the app limits it. A refund cannot take one back, because the app never talks to the
site: this is what the extension's pass was for, and what was given up for an extension with no sign-in.

### App Store purchases

`StoreKitPremiumBackend` is the only code that imports StoreKit, and the whole file is outside `PP_DIRECT`.

- **Buy.** Apple's sheet; the verified transaction unlocks the codes.
- **Restore Purchases** runs `AppStore.sync()` and reads the entitlements again. No account is involved.
- **A purchase from elsewhere** (Ask to Buy, another Mac) arrives through `Transaction.updates`.

The prices shown are `Product.displayPrice`. The UI links only to the terms, the privacy policy and Apple's own
subscription page, and the App Store build says nothing about buying elsewhere (`PremiumGateTests`). Only
`PremiumDirectViews.swift`, wholly `#if PP_DIRECT`, sends people to passwordpie.com to buy or redeem a key.

**Direct channel.** No StoreKit. The Premium window offers Get Premium (passwordpie.com/pricing), Redeem a Key
(passwordpie.com/redeem) and Open Account Settings (passwordpie.com/settings/premium, where Activate is).

**Codes in the browser.** `browserCodeAllowed` in `PremiumChannel.swift` decides. App Store channel: the app has Premium.
Direct channel: this Mac has Premium (`appHasPremium()`: an activation). Nothing the extension sends counts
([ACCOUNTS.md](ACCOUNTS.md)), and `directChannelCodesAreFree` does not count there.

**The gate.** `OneTimeCodes.access(for:hasPremium:)` is the only code in the app target that may call `TOTP.code`.
`PremiumGateTests` fails if a call appears anywhere else. `Search.swift` and the menu never read a code. The gate changes
nothing on disk: the `otp` field stays in the KeePass file, and saving keeps it.

**Signing.** In-App Purchase is an App ID capability and needs no entitlement. The store build has dropped
`network.client`, because nothing in the app opens a connection and StoreKit runs in Apple's own process. This has not been
tested against the real store: do it at step 8 of the checklist. If the products do not load without it, put that one key
back in `Entitlements/mas.entitlements`; it changes nothing on the App Privacy label.

### App Store privacy label

Answer **Data Not Collected** in App Store Connect. Data processed only on the device is not collected, the app has no
network code, and Apple handles the purchase itself. Keep it true: any new request from the store build, or from the Safari
extension inside it, needs this answer checked first.

### Testing without the site

**Both channels.** `node Scripts/mint-activation-link.mjs [days] [plan] [audience]` prints an activation link signed with
the test key: a negative `days` for one that has run out, `passwordpie-app` as the audience for a token that is not an
activation. Open it with `open -a <the debug .app> '<link>'`.

**App Store channel.** `PASSWORDPIE_PREMIUM_PREVIEW` (debug only) fakes StoreKit, and `PASSWORDPIE_PREMIUM_SCRIPT` (debug
only) runs `buy-lifetime,buy-yearly,restore,refresh` for screenshots.

**Local StoreKit testing.** `Configuration/PasswordPie.storekit` holds both products. It works only through Xcode's Run
action: open `Package.swift` in Xcode, run with `PP_MAS=1` in the scheme's environment, and pick the file under Scheme >
Run > Options > StoreKit Configuration. Launching the built `.app` directly talks to the real store.

### Before Premium can be sold

These are in App Store Connect and the Apple Developer site, and cannot be done from this repo.

1. Check that In-App Purchase is on for the App ID `com.passwordpie` (with the other capabilities in "Releasing the
   App Store build").
2. Sign the Paid Apps agreement, and fill in the bank and tax details. Until they are active, products do not load.
3. Create the non-consumable `com.passwordpie.premium.lifetime`. Base price US$29 in the United States storefront.
4. Create a subscription group, such as "PasswordPie Premium". Add the auto-renewable subscription
   `com.passwordpie.premium.yearly` with a 1 year duration and a base price of US$10.
5. For both, add a display name, a description and a review screenshot of the Premium window.
6. Leave Billing Grace Period off. Codes lock at `expirationDate`, so a grace period would charge people for days they
   cannot use. Turning it on needs a code change first.
7. `EntitlementToken.publicKey` holds passwordpie.com's production public key (`kid: pp-1`, from passwordpie.com#8).
   Before a release, check the site signs with its private half: sign in on passwordpie.com with an account that has
   Premium, press Activate, and the app shows Premium (the link is from `/api/premium/activation`;
   `/api/premium/entitlement` carries no token). It needs a production account with Premium: nothing public proves it.
8. Create a sandbox tester under Users and Access > Sandbox, and sign in with it under System Settings > App Store on the test Mac. **Buy and restore with it on a `make mas-dev` build or the TestFlight build, to prove StoreKit works without `network.client`** (see Signing).
9. Upload a build (`Scripts/release-mas.sh --upload`, "Releasing the App Store build"), then attach both products to the app version for review. A product's first review has to go with a version.
10. Review notes: the text is in [APP_STORE_LISTING.md](APP_STORE_LISTING.md), "App Review notes". Replace its placeholder
   with a working activation link for the reviewer (`/api/premium/activation`, or `Scripts/mint-activation-link.mjs`
   only for a debug build: release builds trust the site's key alone).
11. Answer **Data Not Collected** in App Privacy.
12. The terms link is at the end of the description in [APP_STORE_LISTING.md](APP_STORE_LISTING.md), as guideline 3.1.2
   asks. The privacy policy URL goes in the App Privacy section.
