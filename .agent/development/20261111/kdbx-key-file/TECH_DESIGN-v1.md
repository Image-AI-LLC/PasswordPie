# KDBX key file — technical design v1

## Core

### `KeyFile.swift` (new)

- `KeyFile.key(from: Data) throws -> Data` — the 32-byte key a file contributes, in KeePassXC 2.7+ order:
  1. XML whose root is `KeyFile`: `Meta/Version` 1.x → `Key/Data` is Base64; 2.0 → `Key/Data` is hex (whitespace
     ignored) and `Hash` (first 4 bytes of SHA-256, hex) must match. A `KeyFile` document that fails is an error, not a
     fallback (`KeyFileError`). Data is copied into a zeroed 32-byte key, as KeePassXC does.
  2. exactly 32 bytes → the bytes.
  3. exactly 64 hex characters → decoded.
  4. anything else non-empty → SHA-256 of the contents. Empty → error.
- `KeyFile.generate() throws -> Data` — XML v2 like KeePassXC writes (`SecRandomCopyBytes`, 32 bytes, upper-case hex
  in groups of 8, `Hash`).

### Composite key

`compositeKey(password:keyFile:)`: parts = SHA-256(password) unless the password is empty and a key file is given; then
the key file's 32 bytes. Composite = SHA-256(parts). Empty password and no key file stays SHA-256(SHA-256("")).
On load, an empty password with a key file that fails is retried once with the empty password included, as KeePassXC's
unlock does.

### API

Public entry points take `keyFile: Data?` with no default, so the app target cannot forget it:
`KDBX.load/loadRecovering/save`, `VaultFormat.load` (already had it; now also used for `.kdbx`),
`VaultFile.openRecovering`, `VaultFile.replace`. Password-only overloads stay `internal` for the tests.
The key file is always passed as the raw file bytes; only `KeyFile.key` interprets them.

`VaultFile.rekey(url:vault:password:keyFile:baseline:)` — saves with the new keys through `replace` (which reads the
temp file back with the new keys before swapping), refuses if the file no longer holds `baseline`, then overwrites
`.snapshot` with the new bytes so no copy beside the database still opens with the old keys alone. Returns the bytes.

### Remembered key file

`RememberedKeyFile { name, data }` with a checksummed envelope (`PPKN`), stored by the existing
`TouchIDSecretStore` under service `com.oldcai.passwordpie.keyfile`, account = database path. Bytes live in the login
keychain, so the sandboxed build needs no bookmark to the original file.

## App (`VaultSession`)

- `showsKeyFile`: `.kdb` and `.kdbx` (also while creating, as "Add Key File…").
- Key file for unlock/sibling/background reread: `.kdb` or `.kdbx` → the key bytes.
- `KeyFileKeychain` protocol (save/load/delete) injected in `init` (tests use an in-memory one).
- Lock screen loads the remembered key for the current database on `restore()`, `lock()` and database switches.
  A successful unlock with a key file remembers it (and renames it if needed). `forgetKeyFile()` deletes it, clears
  the draft, and rewrites the Touch ID secret without the key file (or turns Touch ID off if that fails).
- Siblings: `stored.keyFile ?? remembered key`.
- `OpenedFile.keyFile` is passed to every `KDBX.save` / `VaultFile.replace` / `openRecovering`, including
  `ChromeWrite` and the retry reread.
- Key changes (current `.kdbx`, unlocked): `addKeyFile()`, `useExistingKeyFile()`, `removeKeyFile()`,
  `changeMasterPassword(current:new:)`, all through one `rekey(password:keyFile:)` that uses `VaultFile.rekey` with
  the file's baseline, then updates the opened file, the remembered key, and the Touch ID secret. Each user-facing one
  asks first with an `NSAlert` warning. Panels run through `AppDelegate.presentFilePanel`, with a seam for tests.
- Add Key File: save panel → write → read back → bytes equal and `KeyFile.key` equal → rekey with the bytes read back.
  A key file saved in the database's folder asks again.
- Import sibling `.kdbx` from a `.kdb` keeps the `.kdb`'s key file, and the remembered key moves with the secret.
- New database: Add Key File on the lock screen (create new or use existing), Create writes password + key file.

## Preferences

Database card gets "Key file" (status + Add Key File… / Use Existing Key File… / Remove Key File… / Forget Key File)
and "Master password" (Change Master Password…, an alert with current / new / repeat fields).

## Argon2 default

`KDFParameters.default` → 64 MiB. Existing files keep the KDF blob from their header (`savePreserved`). Measure
`KDBX.load` on M2 for the PR.

## Tests

Core: five formats, v2 hash mismatch, key only, password + key, missing/wrong key, round trip, failed rekey leaves
the original, KeePassXC fixtures (open theirs; write ours, read back with `keepassxc-cli` manually for the PR).
App: lock-row presentation for `.kdbx`, remember/forget, add/use/remove, change password keeps key file.
