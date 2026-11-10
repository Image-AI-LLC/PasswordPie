# OTP QR scan — technical design v1

## Core (`PasswordPieCore`)

- `TOTP.parseOTPAuth` (stored entries): query items folded first-value-wins (no `uniqueKeysWithValues` trap); host must be
  `totp`. Algorithm handling for stored entries is unchanged (lenient), so existing items keep their codes.
- `OTPAuthImport.parse(_:) -> Result<ScannedOTP, OTPImportError>` (scan input, strict). `ScannedOTP` = issuer, account,
  `OTPSettings`, normalized `uri` (`otpauth://totp/<Issuer>:<account>?secret=…&issuer=…&period=…&digits=…[&algorithm=…]`).
  `OTPImportError` cases: `notOTPAuth`, `hotp`, `migration`, `badSecret`, `digits(Int?)`, `period`, `algorithm(String)`,
  each with `message` (one English sentence). Named outside `TOTP.` so `PremiumGateTests`' regex still bans the app from
  `TOTP.parse*`; nothing here computes a code.
- `OTPScanMatch.candidates(in:issuer:account:pageURL:)`: same site (`BrowserSite.key`) first, username == account first
  inside it; without a site, entries whose title or website matches the issuer. Trashed entries are skipped.
- `QRCodeReader.payloads(in: CGImage)`: `VNDetectBarcodesRequest`, symbologies `[.qr]`, on-device.
- Bridge: `BridgeRequest` gains `otpauth`; new request `scan` → `{"type":"scan","id"}` always (or `error bad-otp` when the
  URI does not parse — says nothing about the vault). `BridgeState.handle` takes a `scan` closure.
  `PendingCode` gains `announce`; `BridgeState.expectScannedCode(...)` sets one; the next matching `tab` answer carries
  `"expectCode":{"origin","expiresIn"}` (no secret, no code) so the extension watches for the code field, then the usual
  `code` request runs under `browserCodeAllowed`.

## App

- `VaultSession.storeEntry(_:) -> Bool`: the write half of `saveEditing`, without touching `editing`; used by the scan
  confirmation. `saveEditing` calls it.
- KDBX history: `KDBXPreserve.applyEdits` already snapshots the previous version of a changed entry into `<History>`
  (KeePassXC rules, `HistoryMaxItems`/`HistoryMaxSize`). Replacing `otp` therefore keeps the old URI in history; a Core test
  pins it.
- Editor (`Pages.swift`): `qrcode.viewfinder` menu button (click = clipboard; menu: Scan Clipboard, Choose Image…), drop
  target on the row, ⌘V of an image while the field is focused (local key monitor; the field editor cannot paste images).
  `OTPInputScanner` (App) turns pasteboard / file / image into `ScannedOTP` or a failure message. Preview row reuses a
  shared `OneTimeCodeRow` that lives in `DetailsView.swift` (keeps `testCodesAreMadeInOnlyTwoPlaces`).
- `OTPScanModel` (@MainActor): one pending scan, 120 s, memory only, replaced by a newer one; phases
  `choosing → confirmReplace → added(id)` / `expired`; candidates, search, New Item. `add()` writes only from there.
- Confirmation UI: a small floating window "Add Two-Step Code" (`OTPScanConfirmView`). Locked → the panel opens on the lock
  screen; unlocking shows the window. Locking closes it.

## Extension

- `src/lib/qr-scan.ts`: `classifyOtpauth` (popup message), `pageQrCandidates(document, viewport)` → rasterizable elements in
  the viewport; `decodeQr(rgba)` via BarcodeDetector when present, else jsQR (Apache-2.0, bundled).
- Content script answers `{type:'qr-images'}` from the background only (runtime messages; pages cannot send these), top frame,
  with PNG data URLs of in-viewport same-origin-readable images/canvases/SVGs (max 8, max 2048 px).
- Background `scan-page` (popup only): ask the top frame → decode → else `tabs.captureVisibleTab` → decode → send
  `{type:'scan', otpauth, url}`; answer the popup with a status only. Nothing stored or logged.
- Tab answer `expectCode` → `expectCode(tabId, origin)` + `watchCode`.

## Decisions to record in the PR

- Confirmation is a floating window, not a page inside the panel (panel hides on focus loss; editor and Chrome review are windows).
- Stored-entry parsing keeps lenient algorithm handling; only the scan entry rejects unknown algorithms.
- Candidates come from database items only (not live Chrome logins).
