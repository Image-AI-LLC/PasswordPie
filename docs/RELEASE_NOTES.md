# Release notes for the next version

The text for the next GitHub release, written while the work is fresh. At the release: raise the version as
[CHANNELS.md](CHANNELS.md) says, put the DMG's checksum in, and paste everything below the line as the release's
description. After publishing, replace it with the notes of the version after that. Earlier versions' notes are on the
[releases page](https://github.com/Image-AI-LLC/PasswordPie/releases).

Next version: **0.4.0** (after 0.3.0, build 7). Before it goes out, the owner's acceptance in
[AGENTS.md](AGENTS.md), "Trying it", and Chrome extension 0.7.0 in the Chrome Web Store.

---

PasswordPie 0.4.0 lets the AI agents on your Mac use a secret you approve with Touch ID, without the secret entering their conversation, and sign in on a website in your browser. Copies of 0.3.0 (7) update themselves to it within a week; if you want it now, open Preferences → General and press **Check Now**.

Website: [passwordpie.com](https://passwordpie.com/)

**Download:** `PasswordPie-0.4.0.dmg` (also published as `PasswordPie.dmg`, the name passwordpie.com links to). Open it and drag PasswordPie to Applications.

**Requires:** macOS 14 or later on an Apple Silicon Mac (M1 or newer). Intel Macs are not supported in this build.

**Signed and notarized:** signed with Developer ID (Image AI, LLC, team 2S468LUF8V), notarized by Apple, ticket stapled to both the DMG and the app.

SHA-256 of `PasswordPie-0.4.0.dmg` and `PasswordPie.dmg` (same file):
`<checksum>`

### New
- **Agents use a secret without seeing it.** Turn on Preferences → Agents → Allow agents to ask for secrets, and an agent on this Mac (Claude Code, Codex, Cursor) can run `passwordpie run --env TOKEN=pp://Agents/Cloudflare -- npm run deploy`. PasswordPie shows who is asking (worked out from the processes and their code signature, never from what the agent says), the command and the project. Allow Once, Touch ID, and the command gets the value in its environment, on its standard input or in a short-lived file. Wherever the command prints it, the agent reads `[concealed by PasswordPie]`
- **Agents see only what you share.** Tick a folder in Preferences → Agents, or Share with Agents in an item's details. Anything else answers exactly like an item that does not exist
- **The password itself, when you say so.** `passwordpie read` asks every time, with Show to Agent and a line saying the agent will see the value
- **Agents sign in on a website.** With the sign-in page open in Chrome or Safari, `passwordpie login pp://Web/GitHub --submit` fills the form through PasswordPie's extension and sends it, after Touch ID. The agent hears how it went and which account it was, never the password, and a login for one site is never filled into another. Sending the form needs version 0.7.0 of the Chrome extension
- **MCP tools.** `passwordpie mcp` gives agents `passwordpie_run`, `passwordpie_read`, `passwordpie_login`, `passwordpie_list` and `passwordpie_status`, with the same approvals. Preferences → Agents has the line to paste for Claude Code, Codex and Cursor
- **Do not ask me every time (Premium).** Allow for this agent session, 8 hours, 7 days or 30 days lets the same request through without a window: the same items, agent, project and program (a script is bound by its content, so an edited script asks once), on this Mac. Preferences → Agents lists each one with Revoke and Revoke All, and the gear menu has Revoke Agent Permissions. A use it lets through shows a dot on the menu-bar pie
- **A project's `.env.pp`.** `passwordpie write-env` reads which variables a project reads and writes a file of references for those only, one per account when a project uses two. `--env-file` can be given more than once, so paths that differ per Mac stay in a second file that is not committed
- **Many secrets in one request.** The approval window groups them by item: twelve fields of one item are one row that opens, with a checkbox for the item and one for each secret
- **Activity.** Preferences → Agents lists every request, allowed or not, with the processes that started it. It is kept for 90 days and never holds a value
- **A value on a command line.** While a command runs, PasswordPie warns when a value it handed out shows up in a process's arguments, where any program on the Mac can read it
- **The same database on two Macs.** Keep the file in a folder that Syncthing, iCloud Drive or Dropbox carries between your Macs. PasswordPie reads the file again when it changes and merges what both Macs changed, item by item. When both changed the same item, the later change is the item and the earlier one is in its history; one line says so, with a list to restore from. PasswordPie still opens no network connection: your own tool carries the file
- **Merge from File…** in the gear menu merges any KeePass database into the open one, and a copy a sync tool left beside the database is merged in by itself
- **Locked.** A request while PasswordPie is locked waits: the lock screen says "Claude Code is waiting for 1 secret." Only you unlock

### Changed
- A save no longer writes over a database file that changed on disk since PasswordPie read it: it merges into it, and keeps this Mac's file from before as `Passwords.kdbx.before-merge-…`
- Preferences has an Agents pane, between Browsers and Import
- Premium now covers agents' standing permissions as well as two-step codes. An approval each time, and everything else, stays free

### Fixed
- Files attached to an item in a 1Password export, or in a KeePass 1 or OPVault file opened as a database, were left out when the item was saved. They are now saved as the item's attachments

### Good to know
- Agent access is in the downloaded app only. The App Store app has none of it
- PasswordPie still opens no network connection. The `passwordpie` tool is inside the app (`PasswordPie.app/Contents/Helpers`), and Preferences → Agents links it into `~/.local/bin`
- What it cannot do: hide a value the command changes (base64, a part of it), or stop a command from sending what it was given somewhere else. Share with agents only what they need
