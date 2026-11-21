# Release notes for the next version

The text for the next GitHub release, written while the work is fresh. At the release: raise the version as
[CHANNELS.md](CHANNELS.md) says, put the DMG's checksum in, and paste everything below the line as the release's
description. After publishing, replace it with the notes of the version after that. Earlier versions' notes are on the
[releases page](https://github.com/Image-AI-LLC/PasswordPie/releases).

Next version: **0.4.0** (after 0.3.0, build 7). Before it goes out, the owner's acceptance in
[AGENTS.md](AGENTS.md), "Trying it", and Chrome extension 0.8.0 in the Chrome Web Store (agents' website login needs
0.7.0, filling the sign-in page you are on needs 0.8.0).

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
- **A check before you delete the files.** `passwordpie check-import <folder>` compares every name and value in an imported folder of `.env` files with the database, inside PasswordPie after Touch ID, and prints same, differs or missing for each name, never a value
- **Many secrets in one request.** The approval window groups them by item: twelve fields of one item are one row that opens, with a checkbox for the item and one for each secret
- **Activity.** Preferences → Agents lists every request, allowed or not, with the processes that started it. It is kept for 90 days and never holds a value
- **A value on a command line.** While a command runs, PasswordPie warns when a value it handed out shows up in a process's arguments, where any program on the Mac can read it
- **The same database on two Macs.** Keep the file in a folder that Syncthing, iCloud Drive or Dropbox carries between your Macs. PasswordPie reads the file again when it changes and merges what both Macs changed, item by item. When both changed the same item, the later change is the item and the earlier one is in its history; one line says so, with a list to restore from. PasswordPie still opens no network connection: your own tool carries the file
- **Two databases unlocked at once.** Keep the secrets agents use in a database of their own beside your personal one: Preferences > Database > **Unlock…** opens a second database without locking the first, the menu and search show both, and ⌘L locks both. Preferences > Agents > **Agents database** chooses which one agents are served from; nothing in the other is ever found by a reference
- **A Mac where agents work alone.** Keep only the agents database there, and turn on **Keep “Agents.kdbx” unlocked while this Mac is awake** (off by default; sleep, the screen lock, logging out and Lock still lock it). A standing permission given on that Mac lets its night jobs run with nobody there; a new use is approved at that Mac, over Screen Sharing with its login password
- **Merge from File…** in the gear menu merges any KeePass database into the open one, and a copy a sync tool left beside the database is merged in by itself
- **Agents save the keys they make.** `some-command | passwordpie save pp://Agents/Stripe/API key` (or the `passwordpie_save` MCP tool, which runs the command itself) hands a new key to PasswordPie instead of the conversation or a file. You see where it goes, a new item or a change, never the value, and Save with Touch ID; a change keeps the old value in the item's history. One you do not answer waits in Preferences → Agents → Saves waiting for you, also on your other Mac when the file travels there. No standing permission ever covers a save
- **Locked.** A request while PasswordPie is locked waits: the lock screen says "Claude Code is waiting for 1 secret." Only you unlock
- **A folder of `.env` files becomes items.** Preferences → Import → A Folder of .env Files reads a folder of dotenv files: each file becomes an item named after it in a folder named after its folder, every variable a protected field, comment lines the notes, and key files beside it (PEM, `.p8`, a service-account JSON) attachments. You see the list before anything is written, importing the same folder again updates instead of doubling, and the folder itself is never changed. In the App Store app too
- **Attachments are listed.** An item's details name the files attached to it

### Changed
- On a sign-in page, an account you pick that does not list the page's site now fills that page, and the site is added to the account. A bubble names the site, with Undo. Before, the account's own website opened in a new tab, and an account with no website asked for Accessibility access to type. Needs Chrome extension 0.8.0 (Safari's comes with the app). ⌥Return, and a page with no sign-in form, still open the account's website in a new tab
- A save no longer writes over a database file that changed on disk since PasswordPie read it: it merges into it, and keeps this Mac's file from before as `Passwords.kdbx.before-merge-…`
- Preferences has an Agents pane, between Browsers and Import
- Premium now covers agents' standing permissions as well as two-step codes. An approval each time, and everything else, stays free

### Fixed
- A database made in PasswordPie named a Recycle Bin it did not have until something was deleted, and KeePassXC warned of "1 invalid group reference" when it opened the file. A new database now names none until it has one
- Files attached to an item in a 1Password export, or in a KeePass 1 or OPVault file opened as a database, were left out when the item was saved. They are now saved as the item's attachments

### Good to know
- Moving a folder of `.env` files into PasswordPie, step by step, on one Mac or two: [docs/MIGRATING_DOTENV.md](https://github.com/Image-AI-LLC/PasswordPie/blob/main/docs/MIGRATING_DOTENV.md)
- Agent access is in the downloaded app only. The App Store app has none of it
- PasswordPie still opens no network connection. The `passwordpie` tool is inside the app (`PasswordPie.app/Contents/Helpers`), and Preferences → Agents links it into `~/.local/bin`
- What it cannot do: hide a value the command changes (base64, a part of it), or stop a command from sending what it was given somewhere else. Share with agents only what they need
