# Release channels

One source tree, two channels. The channel is chosen at build time, not by a runtime switch, so
App Store builds do not contain direct-only code.

| | Direct (default) | App Store |
|---|---|---|
| Build | `swift build` / `make install` / `make dist-direct` | `PP_MAS=1 swift build` / `make mas-dev` |
| Swift flag | `PP_DIRECT` defined | not defined |
| Sandbox | no (hardened runtime, notarized) | yes (`Entitlements/mas.entitlements`) |
| Import CSV from Chrome / Apple Passwords | yes | yes |
| Live read of Chrome's password store | yes (Preferences > Chrome) | **not compiled in** |

Check the store binary has none of it:

    strings -a build/mas/PasswordPie.app/Contents/MacOS/PasswordPie | grep -ci -e 'safe storage' -e saltysalt   # expect 0

## Direct-only code

Everything is behind `#if PP_DIRECT`: `ChromeLogins.swift`, `VaultSession+Chrome.swift` (store build has no-op stubs),
the Chrome section of Preferences, and the Chrome tests. Live Chrome logins are held in `VaultSession.liveEntries`,
separate from `entries`, so `save()` can never write them into the KeePass file. They are read-only; the user
either edits them in Chrome or uses "Save to KeePass" on a single login.

## What was verified for the App Store channel (dev-signed, `make mas-dev`)

- Builds, signs with the sandbox entitlement, launches, and creates its container data folder. No sandbox denials in the log.
- Reading Chrome's folder is denied in the sandbox (this is why live read is direct-only).
- The legacy keychain (what Touch ID unlock uses today) works inside the sandbox: add, read, delete.

## Open items before an App Store submission

These could not be verified without a Distribution certificate and provisioning profile, or need design work:

1. **Remember the database across launches.** `databasePath` is a plain path in UserDefaults. Sandbox needs a
   security-scoped bookmark (`files.bookmarks.app-scope` is already in the entitlements, the code is not written).
2. **Import of non-KDBX databases writes a sibling `.kdbx`** next to the source file. The sandbox only grants the chosen
   file, not its folder, so this needs a save panel.
3. **Auto-fill / auto-type** uses `AXIsProcessTrusted` and `CGEventPost`. It was not confirmed that a sandboxed app can
   be granted Accessibility; test with a real store-signed build, and decide whether the store channel ships without it.
4. **Touch ID keychain.** The data-protection keychain (`kSecUseDataProtectionKeychain`) returns -34018 without a
   provisioning profile. With a profile the store channel can use the biometric access control the comment in
   `TouchIDSecretStore.swift` describes.
5. **In-app purchase** for any paid feature (App Store rule 3.1.1). The direct channel can use license keys instead.
6. **Site-ranking data licence.** See `Scripts/gen_domain_ranks.py` and the note in the delivery report.
