# PasswordPie

A keyboard-first KeePass password manager for Mac that lives in the menu bar.

**Website: [passwordpie.com](https://passwordpie.com/)**

![PasswordPie open from the menu bar](art/readme-hero.png)

## Download

[Download PasswordPie for Mac](https://github.com/Image-AI-LLC/PasswordPie/releases/latest/download/PasswordPie.dmg). Open the DMG and drag PasswordPie to Applications.

Requires macOS 14 or later on an Apple Silicon Mac. The DMG and the app are signed with Developer ID (Image AI, LLC) and notarized by Apple. Release notes and checksums are on the [releases page](https://github.com/Image-AI-LLC/PasswordPie/releases).

## What it does

- Press `⌘\` from any app, type a few letters, and copy: `⌃⌘C` username, `⇧⌘C` password, `⌥⌘C` one-time code
- Reads and writes standard KeePass KDBX 4 files, wherever you keep them. No account, no built-in sync
- Two-step codes (TOTP), a password generator, Large Type, and a pinned window that stays above other apps
- Touch ID unlock, auto-lock, and a clipboard that clears itself
- Imports KeePass 1, 1Password, Bitwarden, Proton Pass and CSV exports

More on [passwordpie.com](https://passwordpie.com/). Support: [support@passwordpie.com](mailto:support@passwordpie.com).

## Building

    make install          # direct channel, installs to ~/Applications
    make mas-dev          # App Store channel, sandboxed, for local testing
    Scripts/release-direct.sh   # signed, notarized DMG (see docs/CHANNELS.md)

Needs Xcode and Homebrew's `argon2`. Channel differences are in [docs/CHANNELS.md](docs/CHANNELS.md).
