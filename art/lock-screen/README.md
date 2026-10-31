# Password Pie locked panel

`imagegen-concept.png` is the built-in ImageGen design reference requested by the
user, and `imagegen-prompt.txt` is its complete prompt. It reimagines the old metal
vault-door panel as a flat, warm Password Pie form. This bitmap is not a runtime
background: the production screen is native SwiftUI with NSSecureTextField.

## Scope

The existing lock-panel interface and controller lifecycle remain. The new visual
system uses the shared brand accent, semantic light/dark surfaces and text, flat
inputs, separate Unlock/Create action and a fade/scale transition. The selected
pie geometry and 18pt menu template are unchanged. See `DESIGN_SYSTEM.md` for
implemented components and the explicitly unchanged native screens.

Open/New, key-file-only unlock, conditional Touch ID, first-responder handling,
Return-to-confirm/submit, wrong-password feedback and draft clearing are retained.
A long key-file name has its own truncating row; long errors are bounded to three
lines with full-message help, so footer actions remain available.

## Native verification

- `locked-{light,dark}.png`: initial running app, empty secure field already focused.
- `incorrect-password-{light,dark}.png`: incorrect password, selected secure contents and visible error.
- `create-{light,dark}.png`, `create-error-{light,dark}.png`: real new-database form and mismatch feedback.
- `keyfile-{light,dark}.png`: real key-file chooser row for an inert synthetic `.kdb` fixture; this fixture is not unlocked.
- `component-options-stress-{light,dark}.png`: native SwiftUI component fixture with Touch ID, long key-file name and a long error simultaneously. These are offscreen component renders, not a real biometric session.

The full app captures use the isolated `com.oldcai.passwordpie.brand-preview-20261031`
bundle, a synthetic `BrandPreview.kdbx` and newly generated disposable databases.
No personal vault, production installation, Touch ID enrollment or global shortcut
was changed. All preview processes were terminated and waited for.

Runtime checks passed in both light and dark appearance:
1. Existing database: initial secure focus, real keyboard input, Return, wrong-password
   feedback, Cmd+A and correction, Accessibility press of the real Unlock button,
   successful unlock with native search focus, then Escape to hide.
2. New database: Return moves to confirmation, mismatch remains locked, correction
   and Create Database succeed, the new file exists, search receives focus, Escape hides.
3. Key-file form: chooser row renders, Escape hides the locked panel.

Keyboard automation uses Accessibility to foreground only the isolated bundle and
real virtual key codes, checking the foreground PID before every event. Unicode
CGEvent injection did not enter the secure field; this was an automation limitation,
not counted as an application failure or a passing input test. Captures use only
the isolated application's window IDs. The empty unlocked database is shorter than
100 pt; the capture harness was corrected to accept that legitimate window size.

## Tests

- 9 lock-form tests cover field registration, Return handling, edit callbacks,
  initial empty-field focus, production KeyPanel's native Tab loop, focus handoffs,
  dynamic light/dark native colors and bounded layout.
- 10 icon geometry/render tests preserve the selected SVG and template parity.
- Full debug suite: 138 tests, 1 existing optional KeePassXC fixture skipped, 0 failures.
- Full release suite: 137 tests, the same 1 optional fixture skipped, 0 failures.
- Release product build succeeds. Existing unrelated MenuListView deprecation warnings remain.

## Reflection

A native secure field's editing notification does not establish its initial empty
focus state. Observe actual first-responder/field-editor transitions, and verify
with the production panel rather than a plain NSWindow. Explicit semantic text
and placeholder colors keep NSViewRepresentable aligned with SwiftUI appearance.
These lessons are captured by regression tests and this project-specific evidence;
no shared workflow or global memory change is needed.
