# Agent access (direct download)

An AI coding agent on this Mac (Claude Code, Codex, Cursor and the like) can run a command with a secret from
PasswordPie after the owner approves it with Touch ID, without the secret passing through the agent's conversation, the
command line or a file in the project. This file is the reference for the pieces, the messages on `agent.sock`, the
command-line tool, references, exit codes and the security model. What the owner sees is in "Agents" in
[UX.md](UX.md) once the app side ships.

Direct download only (`#if PP_DIRECT`, and the App Store app links none of it): a sandboxed `passwordpie run` would start
`notarytool`, `psql` or `npm` inside PasswordPie's sandbox, unable to read the project.

**Status.** The shared library and the `passwordpie` tool are in the source tree; the app does not serve `agent.sock`
yet, so the tool answers `access-off` or `app-unavailable`. The app side (the socket server in the app, the Agents
pane, Share with Agents, the approval window, the lock screen line) comes next. Standing permissions ("do not ask me
every time", Premium), the MCP server and website login for agents come after that.

Free or Premium: using a secret with an approval each time is free, and so is a raw read. Standing permissions will be
Premium, checked by the app's own `appHasPremium()`; nothing in a request carries Premium state.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| `passwordpie` | `PasswordPie.app/Contents/Helpers/passwordpie`, target `PasswordPieCLI`, signing identifier `com.passwordpie.cli`, hardened runtime | `run`, `read`, `list`, `status`. Holds no vault: asks the app, then hands values to the command |
| Messages, references, `.env.pp`, refusal lines, output masking | target `PasswordPieAgent` (`AgentProtocol`, `AgentReference`, `AgentEnvFile`, `AgentErrors`, `OutputMasker`) | Shared by the app and the tool |
| Who is asking | `PasswordPieAgent/CallerIdentity.swift` | The kernel's view of the tool's process and its parents |
| `VaultBroker` | `PasswordPieAgent/VaultBroker.swift` | The one place a request that is not the owner clicking in PasswordPie is answered |
| `agent.sock` server | `PasswordPieAgent/AgentServer.swift` | Peer check, caller walk per request, hands requests to the broker |
| Activity log | `PasswordPieAgent/AgentActivity.swift`, file `~/Library/Application Support/PasswordPie/agent-activity.jsonl` | One line per request, no values |

Decision: the tool lives in `Contents/Helpers`, not `Contents/MacOS` as first planned. On a case-insensitive volume (the
default) `Contents/MacOS/passwordpie` would be the app's own `PasswordPie` executable. `Contents/Helpers` is where Apple
puts helper tools inside a bundle, and it is signed as nested code like the rest.

## The broker

Every request that does not come from the owner clicking in PasswordPie goes through `VaultBroker`. The tool, and later
the MCP server and the browser login, are thin relays. For each request it:

1. **Takes the caller** the app worked out from the kernel (below). Nothing in the request says who the agent is.
2. **Waits for an unlock** when the vault is locked, up to `--wait` (default 60 s, at most 600). The app shows its lock
   screen with "Claude Code is waiting for 2 secrets." Unlocking is only ever done by the owner.
3. **Resolves references against shared items only.** Unshared and nonexistent give the same answer.
4. **Decides**: a standing permission (`AgentGrantStore`; this version's store never grants), else the approval window
   (`AgentApprover`). A raw request never consults standing permissions.
5. **Writes one activity line**, whatever the outcome.

Rules it keeps:

| Rule | Detail |
|---|---|
| One prompt per agent session | A second request from the same session waits behind the first |
| Rate limit | 3 denials in 10 minutes from one session: `too-many-requests` without a prompt for 10 minutes |
| Timeout | The window waits 2 minutes, then answers `timeout` and closes |
| Hang-up | When the tool's connection closes (the agent killed it), its prompt is withdrawn and its wait ends |
| Partial approval | The owner can untick secrets in the window; unticked ones come back `declined` and the tool runs without them, saying so on standard error |
| Raw | `read`, and `run --no-masking`, show "The agent will see the value" and ask every time |
| Two-step codes | `…/otp` answers `not-available` in this version |

The seams for later work: `AgentGrantStore` (standing permissions fill `grant(covering:)`, `grants(for:)`, `covers` and
record a lasting choice in `approved(_:decision:)`); `AgentApprovalDecision` (an "Allow ▾" length can be added beside
`allow`); `AgentRequestKind.login` (reserved for website login, answered `usage` for now).

## Who is asking

The socket peer is always the `passwordpie` binary, so the peer check says only "PasswordPie's own tool". Any program
can start it, so the app looks further, itself, for every request (not once per connection):

1. **The working folder** of the tool's process, read by the app (`proc_pidinfo`, `PROC_PIDVNODEPATHINFO`). The project
   is the nearest folder at or above it holding `.git` (a folder, or a worktree's file), else that folder.
2. **The parent chain**, from the tool's parent up to launchd (`sysctl` `KERN_PROC_PID`, which also reads processes of
   other users such as the root `login` between a terminal and its shell). For each: pid, start time, executable path,
   and code signature (team, identifier, the certificate's organisation) when it is valid. A parent that started after
   its child is a later process that got an exited parent's pid: the walk stops there.
3. **The agent** is the nearest ancestor on the list of known agent hosts (`AgentHosts`: by signing identifier, by
   executable name, or for an interpreter such as `node` by its script's name), else the first that is not a shell,
   terminal or launcher.
4. **The agent session** is that process, by pid **and** start time. With no known agent in the chain, it is the tool's
   POSIX session (`getsid`), by the session leader's pid and start time.

What this cannot tell apart: anything the agent itself starts. A test suite or a package's install script running under
the agent is a descendant of the agent, in the same project, and looks exactly like it. That is why standing
permissions will be bound to the program, and project scripts by their content.

An agent on an unsigned interpreter is shown as "not signed: /opt/homebrew/bin/node", and its identity is that path.

## Transport

`~/Library/Group Containers/2S468LUF8V.com.passwordpie/agent.sock`, beside the browser's `bridge.sock`, on the same
`PasswordPieBridge` transport: 32-bit little-endian length, then UTF-8 JSON, 1 MiB limit; the socket is created 0600.

| Side | Accepts only |
|---|---|
| App (server) | `com.passwordpie.cli`, team `2S468LUF8V`, checked as the bridge checks its peers (audit token, then `SecCodeCheckValidity` against the cdhash) |
| Tool (client) | `com.passwordpie`, the app, same team. The tool is not sandboxed, so it can check, as the Chrome host does |

Decision (the PRD's): a separate socket, not new message types on `bridge.sock`. The browser server's peers and messages are fixed,
a bug in one dispatch table must not be able to hand a browser fill to the tool or a secret to the browser, and the
agent socket exists only while agent access is on.

Debug builds of the tool read `PASSWORDPIE_AGENT_SOCKET` and then skip the server check and the app start, so tests can
run it against a server in the test process. Release builds ignore it.

## Messages

Each connection carries requests and answers, one answer per request, matched by `id`. A request carries references and
a command line, never a value, and nothing about who the agent is or which project it is in. Nothing in a message is a
credential: the tool holds no token.

    → {"type":"hello","id":1,"version":1,"client":"cli","cliVersion":"0.3.0"}
    ← {"type":"hello","id":1,"version":1,"locked":false,"access":true}

    → {"type":"use","id":2,"secrets":[{"name":"NOTARY_KEY","ref":"pp://…","as":"file"}],
       "program":"/Users/…/Scripts/release-direct.sh","argv":["Scripts/release-direct.sh"],
       "reason":"Notarize 0.3.0","masking":true,"wait":60}
    ← {"type":"use","id":2,"secrets":[{"name":"NOTARY_KEY","ref":"pp://…","base64":"…"}],"by":"once"}
    ← {"type":"error","id":2,"code":"denied"}

| Type | Request | Answer |
|---|---|---|
| `hello` | `version`, `client`, `cliVersion` | `version`, `locked`, `access` |
| `use` | `secrets` (`name`, `ref`, `as`: `env`, `file`, `stdin`), `program`, `argv`, `reason`, `masking`, `wait` | `secrets` (`value` for UTF-8 text, `base64` otherwise, or `declined: true`), `by` (`once`, or a standing permission) |
| `read` | one secret with `as: "shown"`, `reason`, `wait` | `secrets` with the one value |
| `list` | `query`, `wait` | `items`: `ref`, `idRef`, `title`, `folder`, `fields`, `attachments`, `covered`. Never a value |
| `status` | none | `status`: `locked`, `access`, `agent`, `project`, `grants` |
| `error` | | `code` (below), `ref` (the reference it is about, as the agent typed it), `refs` (for `ambiguous`) |

## References

    pp://<folder path>/<item title>[/<field>]
    pp://id/<item UUID>[/<field>]

- `<folder path>` is the KeePass group path below the root group, `/`-separated. Segments are percent-encoded where they
  contain `/`, `%` or a control character; spaces stay as they are.
- `<field>` is `password` (the default), `username`, `url`, `notes`, a custom field by its exact (case-sensitive) name,
  or `attachment/<name>`. `otp` is reserved.
- `pp://id/<UUID>` survives renames and moves; the path form reads well in a committed `.env.pp`. `list` prints both.
- A path can be read more than one way (is the last part a field or the title?). Every reading is tried against the
  shared items. More than one match answers `ambiguous` with the matches' `pp://id/` references, only among shared items.
- References resolve against the unlocked database. With several databases open, all are searched; an item's UUID is
  its KeePass UUID.

### `.env.pp`

A plain file, safe to commit. Each line is `NAME=value`: `NAME=pp://…` sets the variable to the value,
`NAME=file:pp://…` writes the value to a short-lived file and sets the variable to its path, anything else is set
literally. `#` starts a comment, `export ` is allowed. No shell expansion; one pair of surrounding quotes is stripped.

    NOTARY_KEY=file:pp://Developer/App Store Connect API key/attachment/AuthKey_ABC123.p8
    NOTARY_KEY_ID=pp://Developer/App Store Connect API key/Key ID
    SIGNING_TEAM=2S468LUF8V

## The command-line tool

    passwordpie run [--env NAME=REF]... [--file NAME=REF]... [--stdin REF] [--env-file PATH]
                    [--reason TEXT] [--wait SECONDS] [--no-masking] -- COMMAND [ARG]...
    passwordpie read REF [--reason TEXT] [--wait SECONDS] [-n]
    passwordpie list [QUERY] [--json]
    passwordpie status [--json]

**`run`** asks the app for the values, starts `COMMAND` as its child with them, and waits.

- Values go into the child's environment, its standard input (written, then closed), or files.
- Files: one 0700 folder per run under `$TMPDIR` (`passwordpie-run.<pid>.<random>`), 0600 files named after the variable
  (with an attachment's extension, so `NOTARY_KEY.p8`). Removed when the child exits, also after the child is killed;
  a folder left by a tool that was itself killed is removed by the next `run`, which finds its pid gone.
- The child's output passes through the tool, which replaces every exact occurrence of each value of at least 6
  characters with `[concealed by PasswordPie]`, also when a value is split across reads. Shorter values are not masked,
  and the tool says so. Transformed values (base64, a substring, URL-encoded) are not caught.
- When the tool's standard output is a terminal, the child's output goes to a pseudo-terminal with the same settings
  and size, so progress bars and colours work. Its standard input stays the tool's own.
- `SIGTERM` and `SIGHUP` to the tool are passed on to the child, and `SIGINT` too when standard input is not a terminal
  (at a terminal, Ctrl-C reaches the child directly). The tool waits for the child, removes the files, then exits.
- The tool never puts a value on a command line and never logs one. The command's program must exist before anyone is
  asked.
- `--no-masking` makes the request a raw read: it asks every time, with the raw wording.
- The shell expands `$NAME` in the typed command **before** `passwordpie` runs, so
  `passwordpie run --env T=… -- curl -H "Authorization: $T"` sends an empty header. Put such commands in a script, or in
  `sh -c '…'` (which will always ask once standing permissions exist).

**`read`** prints one value on standard output, after a "Show to Agent" approval each time; `-n` leaves out the newline.
An attachment's bytes are written as they are. **`list`** prints the shared items matching `QUERY`. **`status`** prints
whether the app runs, is locked, whether agent access is on, who the agent is and the project; it never starts the app.

When PasswordPie is not running, `run`, `read` and `list` start it (`AppLaunch`) and wait up to 10 seconds for the
socket. Running without a socket means agent access is off.

## Exit codes

| Code | Name | Meaning |
|---|---|---|
| the child's | | `run` started the command (128 + the signal when a signal ended it) |
| 64 | `usage` | Bad arguments, a malformed reference or `.env.pp`, a command that does not exist |
| 65 | `not-available` | Not shared, or no such item or field (the same answer for both) |
| 66 | `ambiguous` | More than one shared item matches; the message lists their `pp://id/` references |
| 67 | `denied` | The owner pressed Deny (or unticked everything) |
| 68 | `timeout` | Nobody answered the prompt in 2 minutes |
| 69 | `locked` | Still locked after `--wait` |
| 70 | `app-unavailable` | PasswordPie is not installed, did not start, or did not answer |
| 71 | `access-off` | Agent access is off in Preferences |
| 72 | `too-many-requests` | Too many denied prompts from this agent session |
| 73 | `premium-required` | Reserved for Premium-only parts |

Each refusal prints one line on standard error that says what to do, for the agent to relay, and ends with "Do not ask
the owner to paste the value into the conversation." (`AgentRefusal`). The line is built from the code and what the
agent itself sent, so `not-available` never says which of its two cases it is:

    PasswordPie: Nothing shared with agents matches pp://Agents/Token. Check the name with `passwordpie list`; if the
    item exists, ask the owner to choose Share with Agents on it (or its folder) in PasswordPie. Do not ask the owner to
    paste the value into the conversation.

## Activity

Every `run`, `read` and `list` request is one JSON line in `~/Library/Application Support/PasswordPie/agent-activity.jsonl`,
mode 0600, whether it was allowed or not: time, kind, outcome (allowed once, allowed by a standing permission, shown to
the agent, denied, timed out, locked, not available, ambiguous, too many requests, not understood), agent and signature,
the agent's pid, project, command, items and fields (or the reference as typed when it found nothing), deliveries, the
agent's reason, and the walked chain (pid, path and signature of each ancestor). Never a value. Lines older than 90 days
are dropped. It is not tamper-proof: same-user code can edit or delete it.

## Security model

Trusted: the kernel's word about processes (audit token, process table) and Apple's code-signing checks; PasswordPie,
the `passwordpie` binary, and the owner at the Touch ID sensor. Not trusted: anything in a request (reason, argv), the
agent, the model, the project's files, the commands the agent runs, other processes of the same user.

| Threat | Mitigation | What remains |
|---|---|---|
| Prompt injection asks for a secret | Only shared items are reachable; raw reads ask every time with "the agent will see the value"; the reason is shown as the agent's claim; the prompt names the command; rate limit on denials | The owner approves a request they should not |
| A process talks to `agent.sock` directly | Peer check: only `com.passwordpie.cli` of team `2S468LUF8V`, cdhash-checked | none known |
| A process listens on `agent.sock` first | The tool checks the server is `com.passwordpie`; it sends references and a command line, never a value | Denial of service |
| Malware runs `passwordpie` | The agent is worked out from the parent chain, with signatures; outside the agent's tree it is a different agent and asks | Malware inside the agent's tree is the agent |
| Reading the secret in transit or use | No values on command lines; files 0600 in 0700, removed after the run; hardened runtime on the tool | Same-user code can read the file during the run, and a child's environment by other means; root can read anything |
| Replay | The tool holds no token; an approval answers one request on one connection | none known |
| Leaks into logs | No value in any log or the activity file; tests plant values and grep | The command's own logs |
| Leaks into the transcript | Output masking of exact values; files removed at exit | Transformed values; a command that writes the value to a project file |
| Clicking the prompt | Touch ID (or the login password) on every Allow | none known |
| Prompt fatigue | One prompt per session at a time; 3 denials block the session for 10 minutes | |
| Unlock coercion | Only the owner unlocks, in the lock screen; no message unlocks | |

What cannot be prevented: a command that receives a secret can do anything with it; code running as the same user can,
with effort, read what a command was given; a raw value given to an agent stays in its transcript, and with a hosted
model in the provider's records; an owner who approves the wrong thing.

## Testing

`swift test --filter PasswordPieAgentTests` runs the library's tests and the real tool against a server inside the test
process with a scripted vault and approver (`CommandLineToolTests`): masking and exit codes, no value on any command
line (`ps -axww`), file modes and removal (normal exit, a killed child, a killed tool), locked and unlocking within the
wait, identical answers for unshared and nonexistent items, raw reads asking with a standing permission in place, the
rate limit, the activity log holding no planted value, a pseudo-terminal through `script`, and a killed tool withdrawing
its prompt. `AgentSocketPeerTests` connects from the unsigned test process and is refused.
