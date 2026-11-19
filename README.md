<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
  <img alt="agent-vault" src="docs/assets/banner-light.svg" width="100%">
</picture>

<div align="center">

# agent-vault

### Use a secret in a command without the agent seeing it

**Your coding agent (Claude Code, or any agent with a shell) runs `curl` with your API token and reads `[REDACTED]` where the token was.**

[![License](https://img.shields.io/github/license/minomat180/agent-vault?style=flat-square&color=e3b341)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/minomat180/agent-vault/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/minomat180/agent-vault/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-e3b341?style=flat-square)](#platforms)
[![Bash](https://img.shields.io/badge/bash-3.2%2B-e3b341?style=flat-square&logo=gnubash&logoColor=white)](bin/vault-run)
[![Swift](https://img.shields.io/badge/swift-macOS%20helper-e3b341?style=flat-square&logo=swift&logoColor=white)](macos/agent-vault.swift)

[Quick start](#quick-start) · [How it works](#how-it-works) · [Threat model](#threat-model) · [Tests](#tests)

`git clone https://github.com/minomat180/agent-vault && cd agent-vault && ./install.sh`

<br><br>

<img src="docs/demo.gif" width="1000" alt="agent-vault on Linux: list, a refused direct read, two vault-run calls, the audit log">

<sub>Recorded on Linux against a throwaway keyring holding one fake secret (<code>docs/demo.tape</code>, <code>docs/demo-shell.sh</code>). The <code>21</code> is the fake value's length, so the command did receive it.</sub>

</div>

---

An agent that can run shell commands will eventually need an API token. Pasting
it into the chat puts it in the transcript, in the provider's logs and in every
later context window; putting it in a `.env` file lets the agent `cat` it.
agent-vault puts the boundary at the command: the agent names the secret and
one command, the command gets the value in its environment, and the agent reads
the output with the value replaced by `[REDACTED]`.

```bash
vault-run GITHUB_TOKEN "list my repos" -- \
  sh -c 'curl -sH "Authorization: Bearer $AGENT_VAULT_SECRET" \
           https://api.github.com/user/repos'
```

- **The value never goes through argv.** It reaches that one process as
  `$AGENT_VAULT_SECRET`, so it is not in the process's command line or in the
  command the agent wrote.
- **Output is redacted before the agent reads it.** stderr is merged into
  stdout, and every occurrence of the value on an output line becomes
  `[REDACTED]`. For a multi-line value each line of 8 or more characters is also
  masked on its own.
- **On macOS a person approves every read.** A small Swift helper owns the
  keychain items and asks for Touch ID (login password as fallback) before each
  read, with the text `release the secret "NAME" to an agent: REASON`. The
  agent can start that prompt but cannot answer it.
- **Each `vault-run` call is logged.** `~/.local/state/agent-vault/audit.log`
  gets one JSON line per call with valid arguments: time, host, name, reason,
  working directory, command, and whether the secret was released (`released`,
  `not-released`, `empty`). Never the value.
- **The exit status is the command's.** Scripts and agents can keep checking
  `$?`.

> [!NOTE]
> On Linux there is no prompt and any process of the same user can read the
> keyring, so there it prevents accidents, not a hostile agent; see
> [Threat model](#threat-model). The recording is from Linux, so the macOS
> Touch ID flow is not in it.

## Platforms

| Platform | Store | Read approval | Needs |
| --- | --- | --- | --- |
| macOS | Login keychain, service `agent-vault`, label `agent-vault: NAME` | Touch ID or login password, every read | Xcode command line tools (to build the helper) |
| Linux | freedesktop Secret Service via `secret-tool`, same service and label | None | `secret-tool` (libsecret) and a running Secret Service such as gnome-keyring or KeePassXC |

## Quick start

```bash
git clone https://github.com/minomat180/agent-vault
cd agent-vault
./install.sh
```

`install.sh` symlinks `agent-vault` and `vault-run` into `~/.local/bin` and the
Claude Code skill `skill/` to `~/.claude/skills/vault`. On macOS it first builds
the helper with `macos/build.sh` (ad-hoc signed).

`~/.local/bin` must be on your `PATH`; otherwise `vault-run` cannot find
`agent-vault` and reports the secret as not released. After pulling a change to
the Swift source, run `macos/build.sh` again; `install.sh` only builds when the
binary is missing.

Add secrets yourself, not through the agent:

```bash
agent-vault set GITHUB_TOKEN     # hidden prompt, or the value on stdin; never argv
```

### Commands

| Command | What it does |
| --- | --- |
| `agent-vault list` | Names only, never values |
| `agent-vault set NAME` | Stores a value from a hidden prompt or stdin |
| `agent-vault delete NAME` | Removes the item |
| `agent-vault migrate [NAME...]` | Moves items from the old `pi-vault` service name |
| `vault-run NAME "reason" -- command [args...]` | Runs one command with the secret in `$AGENT_VAULT_SECRET` |

`vault-run` exits with the command's status, 1 if the secret was not released
(missing, denied, empty), 64 for bad usage. Values are text; trailing newlines
are stripped.

## How it works

| Piece | Platform | What it does |
| --- | --- | --- |
| `bin/vault-run` | both | Gets the value from `agent-vault get`, runs the command with it in the environment, pipes the output through a Perl redactor that receives the value through its own environment, writes the audit line. Bash 3.2 compatible for macOS. |
| `macos/agent-vault.swift` | macOS | Generic-password items in the login keychain. `get` checks existence by attributes first (no prompt for a missing name), then `LAContext` `.deviceOwnerAuthentication`, then reads. `set` deletes and re-adds, so a stored item always gets a fresh access list. |
| `linux/agent-vault` | Linux | The same interface over `secret-tool`. `migrate` pipes each value from lookup to store and compares SHA-256 digests before clearing the old item, so the value never sits in a shell variable. |
| `skill/SKILL.md` | both | The Claude Code skill that tells the agent to use `vault-run` and nothing else. |

## Threat model

What it is for: keeping secret values out of an agent's context, out of
transcripts and out of command lines, and on macOS making a human approve every
read.

**What it protects against**

- **The value landing in the transcript by accident**, for example an error
  message quoting a connection string, or `curl -v` echoing a Bearer header.
  The value is redacted wherever it appears whole on one output line.
- **Other processes reading macOS items quietly.** Items are created by the
  helper, so their access list trusts only the helper's code signature.
  `security find-generic-password -w` or any other binary gets the macOS
  keychain dialog asking for the login password. A modified or rebuilt helper
  has a different signature and gets the same dialog; deny it unless you
  rebuilt the helper yourself.
- **An agent reading a macOS secret without asking.** Each read is one Touch
  ID prompt naming the secret and the reason.

> [!IMPORTANT]
> **Linux is not a security boundary against the agent.** There is no prompt.
> While the keyring is unlocked, any process of the same user can run
> `secret-tool lookup service agent-vault account NAME`. `agent-vault get`
> refuses unless called by `vault-run`, but that check is an environment
> variable and only stops mistakes. On Linux this tool keeps values out of the
> transcript and argv, and nothing more.

> [!WARNING]
> **The command gets the real value, and the agent writes the command.** It can
> send the value to another host, write it to a file, or print it
> base64-encoded or reversed; redaction only matches the literal value. On
> macOS the Touch ID prompt is the only check, and it shows the name and the
> agent's stated reason, not the command. A direct `agent-vault get` shows the
> same prompt as `vault-run` (the helper does not check who called it) and, if
> approved, prints the value unredacted into the agent's output. Read the reason
> before you approve.

**What else it does not protect against**

- **Re-encoded copies, even by accident.** `curl -v -u user:$AGENT_VAULT_SECRET`
  prints a Basic header that is the token in base64. URL-escaped, JSON-escaped
  or line-wrapped copies pass through as well.
- **Edits to the tool itself.** The Touch ID check lives in the helper's code,
  not in the keychain item, and `vault-run`, the redactor and the helper's
  source are files the agent's user can edit.
- **Same-user inspection while the command runs.** The value is in the
  environment of the command and of the redactor, readable by the same user
  (`/proc/PID/environ` on Linux, `ps -E` on macOS).
- **Overwriting or deleting secrets.** `set` and `delete` ask for nothing on
  either platform.
- **A tampered or incomplete audit log.** It is a plain file the agent's user
  can edit, a failed write does not stop the release, reads that bypass
  `vault-run` are not logged, and the command's exit status is not recorded.
- **Secrets shorter than 8 characters inside a multi-line value.** Those lines
  are only masked as part of the whole value.

Reporting a vulnerability: see [SECURITY.md](SECURITY.md).

## Tests

```bash
./tests/linux.sh
```

18 end-to-end checks on Linux: redaction of stdout and stderr, multi-line,
short and regex-metacharacter values, exit status, audit log contents, `get`
refusing direct calls, migration, delete. The script starts its own
gnome-keyring on a private D-Bus session under a temp `HOME`, so it never
touches your keyring. It needs `dbus-run-session`, `dbus-send`,
`gnome-keyring-daemon`, `secret-tool` and `perl`. CI runs it on Ubuntu, runs
ShellCheck, and builds the Swift helper on macOS. The macOS Touch ID path has
no automated test; it needs a person at the machine.

## Status

A personal tool I use with Claude Code on a Mac and a NixOS server. It started
as a Linux port of [isaaclins/pi-vault](https://github.com/isaaclins/pi-vault),
an extension for the pi coding agent; none of that code is left, and the pi
extension was dropped in favour of a plain CLI that any agent with a shell can
call. The `pi-vault` fallback and `migrate` exist for items stored by those
earlier versions.

## License

MIT, see [LICENSE](LICENSE).
