# Moving a folder of .env files into PasswordPie

A step-by-step guide for someone who keeps API keys in a folder of plain `.env` files, loads them into projects with a
generated file or a symlink, and uses more than one Mac: one they sit at, and perhaps one where agents and scheduled
jobs work alone. At the end the keys are in an encrypted database on each Mac, kept in step by a sync tool, projects
name only the keys they use in a `.env.pp` file, agents get them by asking PasswordPie, and the plain files are gone.

It uses features of the downloaded app (version 0.4.0 or later): the `passwordpie` tool and agent access are not in the
App Store app. The pieces are described in [UX.md](UX.md) and [AGENTS.md](AGENTS.md); this guide only puts them in order.

Do the steps in this order. Nothing is deleted until step 9, and every step before it can be undone by deleting the
database you made.

| Step | On | Takes |
|---|---|---|
| 1. A database for agents | the Mac you sit at | 5 minutes |
| 2. Import the folder | the Mac you sit at | 5 minutes |
| 3. Check the import | the Mac you sit at | 2 minutes |
| 4. A `.env.pp` in each project | the Mac you sit at | 5 minutes a project |
| 5. Run projects through `passwordpie run` | the Mac you sit at | as long as your scripts need |
| 6. A sync tool between your Macs | both | 15 minutes |
| 7. The Mac where agents work alone | that Mac | 15 minutes |
| 8. Try it | both | 15 minutes |
| 9. Delete the plain files | every Mac | 5 minutes |

The examples use a folder `~/secrets` laid out as `<service>/<account>.env`:

    ~/secrets/payments/work.env
    ~/secrets/payments/personal.env
    ~/secrets/mail/work.env
    ~/secrets/cloud/work-service-account.json
    ~/secrets/cloud/deploy.pem
    ~/secrets/_local/paths.env        # differs per Mac, not secret

## 1. A database for agents

Keep the keys agents use in a database of their own, not in your personal one: a Mac where agents work alone will hold
this database unlocked, and nothing personal should be on it ("Two databases at once, and a Mac nobody sits at" in
UX.md).

1. Choose where the file lives: a folder your sync tool will carry (step 6), with nothing else in it, for example
   `~/Sync/Agents/Agents.kdbx`. Do not put it in the folder of `.env` files.
2. Preferences > Database > **New…**, save it there, and give it a master password of its own. Keep that password where
   you keep your other master passwords: every Mac that opens this file needs it.
3. While it is the current database, the import in step 2 goes into it. Your personal database stays in the list:
   **Switch** back to it after step 3, then **Unlock…** the agents database beside it.

## 2. Import the folder

Preferences > Import > **A Folder of .env Files** ("A folder of .env files becomes items" in UX.md).

1. Choose `~/secrets`. Nothing is written yet, and the folder is never changed.
2. Type **Agents** in **Put them inside**, so everything lands in one folder (Agents › payments › work) that one tick
   shares with agents.
3. Read the page before you import:
   - **Items**: one per `.env` file, with its key files. Untick any you do not want agents to have at all.
   - **Left alone**: scripts, images, templates, `_local/`, `.backup/`, `*.bak`. Look at the line "N other files hold
     values from these files": those are the generated flat files, backups and scripts with a pasted key that step 9
     deletes too. Write their names down.
   - **To check**: a value a shell would read differently from a dotenv library (it has `$`, a backtick or a
     backslash). Check those by hand after the import.
4. **Import N Items**. Importing the same folder again later updates fields instead of adding items.
5. Preferences > Agents: turn on **Allow agents to ask for secrets**, press **Create Link in ~/.local/bin**, and tick
   **Agents** under **Shared with agents**. Choose this file under **Agents database**.

Paths that differ per Mac (`_local/` above) are not secrets. They stay in a file on each Mac (step 4).

## 3. Check the import

In a terminal:

    passwordpie check-import ~/secrets --inside Agents

PasswordPie asks once (Touch ID), compares every name and value in the folder with the database inside the app, and
prints `same`, `differs` or `missing` for each name, never a value. It exits 0 only when everything is `same`.

- `missing`: not imported, or not shared with agents. Tick the folder in Preferences > Agents, or import again.
- `differs`: the file changed after the import, or the value is one of those listed under To check. Import again, or
  fix the item by hand, and check again.
- `ambiguous`: two shared items are where the import would put it. Remove the extra one.

Do not go on until it prints only `same`.

## 4. A `.env.pp` in each project

In each project that uses the keys today:

    cd ~/code/shop
    passwordpie write-env

It finds the variables the project reads (its code, scripts, `Makefile`, `package.json`, and the `.env` it has now,
read through a symlink) and prints a `.env.pp` that names only those, as references:

    PAYMENTS_API_KEY=pp://Agents/payments/work/PAYMENTS_API_KEY
    CLOUD_CREDENTIALS=file:pp://Agents/cloud/work/attachment/work-service-account.json

On standard error, names only: what the code reads that no shared item holds (usually a path: it goes into the second
file below), and what the old `.env` set that the code does not mention (a library may read it: add it with
`--also NAME`). A project that works with two accounts gets one file for each with `--identity work --identity
personal`.

When the printed file is right: `passwordpie write-env --write`. It never overwrites an existing `.env.pp` without
asking. `.env.pp` holds no secret: commit it.

**What differs per Mac** goes into a second file that is not committed, for example `.env.local`:

    DATA_DIR=/Users/me/data/shop

Add `.env.local` to `.gitignore`.

## 5. Run projects through `passwordpie run`

Wherever a script or a habit loads the old file, run the command through PasswordPie instead:

| Before | After |
|---|---|
| `source .env && ./deploy.sh` | `passwordpie run --env-file .env.pp --env-file .env.local -- ./deploy.sh` |
| `npm run deploy` (reading `.env` through `dotenv`) | `passwordpie run --env-file .env.pp -- npm run deploy` |
| `python job.py` (with `load_dotenv()`) | `passwordpie run --env-file .env.pp -- python job.py` |
| A generated flat `.env` linked into each project | Nothing: each project has its `.env.pp` |

- Programs read the environment as before: `load_dotenv()` and `dotenv.config()` find no `.env` and leave the variables
  PasswordPie set alone. Nothing in the program changes.
- Each run asks once with Touch ID. For a script that runs often, choose **Allow for 7 days ▾** in the window
  (Premium): the same script in the same project with the same keys then runs without asking, on this Mac.
- Wherever the command prints a key, the agent and the terminal read `[concealed by PasswordPie]`.
- An agent that uses MCP instead of a shell: Preferences > Agents > MCP server has the line to paste for Claude Code,
  Codex and Cursor; `passwordpie_run` takes `envFiles`.

When every project runs this way, remove the generated flat files, the script that made them and the symlinks from the
projects (the plain folder itself stays until step 9).

## 6. A sync tool between your Macs

PasswordPie opens no network connection: a tool you choose carries the database file between your Macs, and PasswordPie
merges what each Mac changed ("The same database on two Macs" in UX.md). Syncthing, Dropbox, iCloud Drive and Unison
work; what PasswordPie expects of the tool:

- **It carries the whole file and puts it in place in one step** (a new file renamed over the old one), as all four do.
  PasswordPie notices within seconds while the database is unlocked, reads the file, and merges it with what this Mac
  has. Locked, it reads the file at the next unlock.
- **When both Macs changed the file before either saw the other's, it keeps both**: Syncthing as
  `Agents.sync-conflict-<date>-<time>-<device>.kdbx`, Dropbox as `Agents (… conflicted copy …).kdbx`, Unison only with
  its `copyonconflict` preference, iCloud Drive as a conflict version of the file. PasswordPie finds these and merges
  them in by itself. Without such a copy one Mac's change could be lost before PasswordPie saw it, so turn on Unison's
  `copyonconflict`.
- **The file stays on disk.** Dropbox's online-only files and iCloud Drive's Optimize Mac Storage can remove the file
  and leave a placeholder; mark the folder as available offline (Dropbox) or keep it downloaded (iCloud Drive), above
  all on a Mac nobody sits at.
- **It never needs your master password**, and must not have it: it carries ciphertext.
- **Each Mac's clock is set from the network** (System Settings > General > Date & Time). The later change to an item
  wins; with a wrong clock the wrong one wins, and is still in the item's history.

Advice, not required: tell the tool to ignore `*.before-merge-*` and `*.snapshot`. These are this Mac's own copies from
before a merge or a save, encrypted with the master key of the time; each Mac keeping its own is enough, and they then
do not travel with an old password after you change it.

Put the agents database in the synced folder. Do not sync the folder of plain `.env` files or a per-Mac file such as
`.env.local`.

With the tool running, unlock the database on both Macs, add an item on one, and see it on the other within seconds.

## 7. The Mac where agents work alone

On the second Mac (one that runs agents and scheduled jobs with nobody at it):

1. Install the downloaded PasswordPie, and let the sync tool bring the agents database.
2. Open **only the agents database** (Open…), unlock it with its master password, and keep no other database in its
   list. Nothing personal is ever on this Mac.
3. Preferences > Agents: turn on **Allow agents to ask for secrets**, press **Create Link in ~/.local/bin**. **Agents**
   is already ticked: sharing comes with the file.
4. Turn on **Keep “Agents.kdbx” unlocked while this Mac is awake**, and read its note: on this Mac the lock no longer
   protects this database, and what you share and the standing permissions you give are the whole protection. Idle
   time no longer locks it; sleep, logging out, restarting, the screen lock and Lock still do.
5. In System Settings > Lock Screen, set "Require password after screen saver begins or display is turned off" to
   **Never**, or keep the display awake, if jobs must run while nobody looks: a locked screen locks the database.
   Keep the Mac from sleeping while it works (System Settings > Energy, or `caffeinate`).
6. **Standing permissions for night jobs are given on this Mac.** A standing permission counts only on the Mac where it
   was given, so one given on your own Mac does nothing here. The first time each job runs, approve it here with
   **Allow for 7 days ▾** (or 30 days): over Screen Sharing, with this Mac's login password ("Use Password…") where
   Touch ID cannot be used. Then it runs at night without a window.
7. A job that no standing permission covers opens the approval window on this Mac and waits two minutes, then fails
   with `timeout`. Approving from your own Mac without going to this Mac's screen is not built yet: run such a job
   again while you are connected, and give it a standing permission.
8. A key an agent makes here (`some-command | passwordpie save pp://Agents/…`) waits under **Saves waiting for you**,
   in the file: you can save it from Preferences > Agents on either Mac, with Touch ID on yours. Until then no agent can
   use it.

What happened on that Mac is in its Activity file. From your own Mac:

    ssh worker-mac 'tail -n 20 "Library/Application Support/PasswordPie/agent-activity.jsonl"'

## 8. Try it

These are the checks of "Acceptance, by the owner". The two-Mac behaviour is also covered by tests with two copies of
one database (`SecretsAcrossMacsAcceptanceTests`); these are the parts only you can see on real Macs.

| | Do | Expect |
|---|---|---|
| 1 | Turn off the sync tool. Add an item on the worker, change a different one on your Mac. Turn it on | Both Macs have both changes; nothing was asked |
| 2 | Turn off the sync tool. Change the same item on both, a minute apart. Turn it on | The later change is the item on both; "1 item was changed on both Macs"; **Review** › **History** shows the earlier one |
| 3 | Move an item to the Recycle Bin on one Mac | It leaves the menu on the other |
| 4 | Put a made-up value in an item, use it once through `passwordpie run`, then search: `grep -rIl --exclude='*.kdbx' "<the value>" ~` on each Mac | Nothing but the files of step 9 not yet deleted. Search for a made-up value only, never a real key: the command line and shell history would hold it |
| 5 | Let a job with a standing permission given on the worker run at night | It ran (Activity: "allowed by 7 days, this project"); nobody was asked |
| 6 | Ask an agent on the worker to make a key with `openssl rand -hex 32` and save it with `passwordpie save` | Its transcript says `pending` and an id, never the value; Saves waiting for you on your Mac; after **Save** it is on both Macs |
| 7 | Run each project with `passwordpie run --env-file .env.pp` | It works; the folder of `.env` files is no longer read |

## 9. Delete the plain files

Only when step 3 printed only `same`, every project runs from its `.env.pp`, and both Macs have the agents database:

1. Run `passwordpie check-import ~/secrets --inside Agents` once more. Exit 0.
2. On **every Mac**, delete:
   - the `.env` files and key files in the folder (`~/secrets/<service>/…`);
   - `.backup/` folders and `*.bak`, `*.old`, `*.orig` copies;
   - the generated flat files, the script that made them, and the `.env` symlinks in projects;
   - the files the import listed as "other files hold values from these files".

   Keep what is not a secret: scripts, notes, metrics, images, and the per-Mac paths file. Those can go into git.
3. Empty the Trash. If a backup tool (Time Machine, a cloud backup) has copies of the old files, they stay in its
   history; they are as old as the files.
4. **Rotating keys** is your decision. The keys were in plain files, and some of them in agent conversations and shell
   history. Rotate first the ones that spend money or have full access to an account, then save each new key into
   PasswordPie: in the item's field, or with `passwordpie save` from the command that prints it.

## When something goes wrong

| What you see | What to do |
|---|---|
| `missing` in check-import | Tick the folder under Shared with agents; or the agents database is not the one chosen in Preferences > Agents |
| A command waits, then `locked` | The agents database is locked, or not open on this Mac: unlock it (Preferences > Agents shows a field for it) |
| `not-available` | The reference names nothing shared: `passwordpie list` shows what agents see |
| "Agents.kdbx cannot be read" under the search field | The master password changed on the other Mac: lock, and unlock with the new one |
| "Possible copy: Agents 2.kdbx" | A file you or Finder may have made: **Merge…** if it is the other Mac's, else leave it |
| A job on the worker fails with `timeout` at night | No standing permission given on that Mac covers it (step 7) |
