# Rename to com.passwordpie — tech design v1

## Identifiers

| What | Old | New |
|---|---|---|
| App bundle ID, Touch ID keychain service, UserDefaults domain | `com.oldcai.passwordpie` | `com.passwordpie` |
| Safari appex / AutoFill appex / Chrome host signing ID | `….safari` `….autofill` `….browser-host` | `com.passwordpie.…` |
| App Group (socket) | `2S468LUF8V.com.oldcai.passwordpie` | `2S468LUF8V.com.passwordpie` |
| Keychain: key files / Premium | `….keyfile` / `….account(.dev)` | `com.passwordpie.…` |
| IAP products | `….premium.yearly` / `.lifetime` | `com.passwordpie.premium.…` |
| Native messaging host | `com.oldcai.passwordpie` | `com.passwordpie` (+ old name kept, below) |
| Caches folder (site icons) | `~/Library/Caches/com.oldcai.passwordpie` | `~/Library/Caches/com.passwordpie` (not migrated: the extension re-sends icons) |

Core gets `AppNamespace` (`id`, `legacyID`, `legacyName(for:)` mapping `com.passwordpie.x` → `com.oldcai.passwordpie.x`), so
the old literal is written once in Core. Bridge (linked by the host and the appex, not Core) keeps its own literals and
adds `legacyNativeHostName` and `nativeHostNames`.

## Chrome host manifests

`ChromeHostManifest.manifest(name:hostPath:extensionIDs:)`; `install` writes one file per name in
`BridgeConstants.nativeHostNames` (`com.passwordpie.json`, `com.oldcai.passwordpie.json`), same host path and origins.
The legacy name serves the store extension ≤ 0.4.0; remove it once the store's live version is ≥ 0.5.0.

## Upgrade migration (direct channel only — the only build ever shipped under the old ID)

`LegacyMigration` in Core, run first thing in `applicationDidFinishLaunching` (before `VaultSession` reads defaults), once
per user (marker `legacyNamespaceMigrated` in the new domain):

1. **Preferences.** `UserDefaults.standard.persistentDomain(forName: legacyID)` → every key the new domain lacks is
   copied. Never overwrites.
2. **Keychain.** Accounts = migrated `databasePath` ∪ `databasePaths`. Items: Touch ID (`legacyID` → `id`) and key file
   (`.keyfile`) per account; Premium `activation` under `PremiumChannel.keychainService`'s legacy name. Each: skip when
   the new item exists; read the old one with keychain UI disabled (the `TouchIDSecretStore` path,
   `SecKeychainSetUserInteractionAllowed(false)`); copy on success; on any other status (in practice
   `errSecInteractionNotAllowed`: the item's ACL names the old code signature) leave it. Never deletes old items.
3. A Touch ID flag whose secret did not come over is already handled: `refreshTouchID` sees `.missingSecret`, disables
   quietly, the lock screen asks for the master password, and `didUnlock` re-stores the secret (UnlockMemory.shouldStore).

Seams for tests: `LegacyMigration.migratePreferences(from: [String: Any]?, into: UserDefaults)` and
`migrateKeychain(_ items:, keychain: LegacyKeychain)`; tests use a scratch `UserDefaults(suiteName:)`, real keychain items
under test-only services, and a fake keychain for unreadable/duplicate cases.

## Guard

`Tests/PasswordPieCoreTests/LegacyNamespaceGuardTests.swift` lists `git ls-files -co --exclude-standard`, counts lines with
the old prefix per file, and requires the exact allow-list (file → count, reason). `.agent/` is excluded (dated design
records).

## Extension

`NATIVE_APP = 'com.passwordpie'`, version 0.5.0 in three places. `tests/listing.test.ts` parses LISTING.md: every
permission justification ≤ 1000 chars, Description ≤ 16000, the nativeMessaging text names `com.passwordpie`.

## Not changed

`~/Library/Application Support/PasswordPie` (not namespaced); the Chrome extension ID; the `passwordpie://` scheme.
