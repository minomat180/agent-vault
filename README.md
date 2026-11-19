# agent-vault

agent-vault lets a coding agent such as Claude Code use an API token in a
shell command without the token appearing in the chat. The agent names the
secret and the command, the command gets the value in its environment, and the
value is replaced with `[REDACTED]` in the output the agent reads. For people
who run agents with shell access on their own machines: macOS (login keychain,
Touch ID on every read) and Linux (freedesktop Secret Service).

![agent-vault on Linux: list, a refused direct read, two vault-run calls, the audit log](docs/demo.gif)

Recorded against a throwaway keyring holding one fake secret
(`docs/demo.tape`, `docs/demo-shell.sh`). The `21` is the fake value's length,
so the command did receive it.

## Why

An agent that can run shell commands will eventually need an API token. Pasting
it into the chat puts it in the transcript, in the provider's logs and in every
later context window. Putting it in a `.env` file lets the agent `cat` it. (On
Linux the agent can read the keyring just as easily; there this tool prevents
accidents, see [Threat model](#threat-model).)

`vault-run` puts the boundary at the command instead:

```bash
vault-run GITHUB_TOKEN "list my repos" -- \
  sh -c 'curl -sH "Authorization: Bearer $AGENT_VAULT_SECRET" \
           https://api.github.com/user/repos'
```

- The value reaches that one process as `$AGENT_VAULT_SECRET`, never through
  argv, so it is not in the process's command line or in the command the agent
  wrote.
- stderr is merged into stdout, and every occurrence of the value on an output
  line is replaced with `[REDACTED]` before the agent reads it. For a
  multi-line value each line of 8 or more characters is also masked on its own.
- The exit status is the command's.
- Every `vault-run` call with valid arguments appends one JSON line to
  `~/.local/state/agent-vault/audit.log`: time, host, name, reason, working
  directory, command, and whether the secret was released (`released`,
  `not-released`, `empty`). Never the value, and not the command's exit status.

On macOS the read itself needs a person. A small Swift helper
(`macos/agent-vault.swift`) owns the keychain items, and before every read it
asks for Touch ID (login password as fallback) with the text
`release the secret "NAME" to an agent: REASON`. The agent can start that
prompt but cannot answer it. That flow is not in the recording above, which was
made on Linux.

## Threat model

What it is for: keeping secret values out of an agent's context, out of
transcripts and out of command lines, and on macOS making a human approve every
read.

What it protects against:

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

What it does not protect against:

- **A command that misuses the secret it was given.** The command runs with the
  real value. It can send it to another host, write it to a file, or print it
  base64-encoded or reversed; redaction only matches the literal value. The
  agent writes the command, so on macOS the Touch ID prompt is the only check,
  and it shows the name and the agent's stated reason, not the command. Read
  the reason before you approve.
- **Re-encoded copies, even by accident.** `curl -v -u user:$AGENT_VAULT_SECRET`
  prints a Basic header that is the token in base64. URL-escaped, JSON-escaped
  or line-wrapped copies pass through as well.
- **A direct `agent-vault get` on macOS.** The helper does not check who
  called it, and its Touch ID prompt looks the same whether `vault-run` or the
  agent asked. Approving a direct `get` prints the value unredacted into the
  agent's output. The Touch ID check lives in the helper's code, not in the
  keychain item, and `vault-run`, the redactor and the helper's source are
  files the agent's user can edit.
- **Anything on Linux, if the agent is hostile.** There is no prompt. While the
  keyring is unlocked, any process of the same user can run
  `secret-tool lookup service agent-vault account NAME`. `agent-vault get`
  refuses unless called by `vault-run`, but that check is an environment
  variable and only stops mistakes. On Linux this tool keeps values out of the
  transcript and argv; it is not a security boundary against the agent.
- **Same-user inspection while the command runs.** The value is in the
  environment of the command and of the redactor, readable by the same user
  (`/proc/PID/environ` on Linux, `ps -E` on macOS).
- **Overwriting or deleting secrets.** `set` and `delete` ask for nothing on
  either platform.
- **A tampered or incomplete audit log.** It is a plain file the agent's user
  can edit, a failed write does not stop the release, and reads that bypass
  `vault-run` are not logged.
- **Secrets shorter than 8 characters inside a multi-line value.** Those lines
  are only masked as part of the whole value.

## Install

```bash
git clone https://github.com/minomat180/agent-vault
cd agent-vault
./install.sh
```

`install.sh` symlinks `agent-vault` and `vault-run` into `~/.local/bin` and the
Claude Code skill `skill/` to `~/.claude/skills/vault`. On macOS it first builds
the helper with `macos/build.sh` (needs the Xcode command line tools; the build
is ad-hoc signed). On Linux it needs `secret-tool` (libsecret) and a running
Secret Service such as gnome-keyring or KeePassXC. `~/.local/bin` must be on
your `PATH`; otherwise `vault-run` cannot find `agent-vault` and reports the
secret as not released. After pulling a change to the Swift source, run
`macos/build.sh` again; `install.sh` only builds when the binary is missing.

Add secrets yourself, not through the agent:

```bash
agent-vault set GITHUB_TOKEN     # hidden prompt, or the value on stdin; never argv
```

## Commands

```bash
agent-vault list                 # names only, never values
agent-vault set NAME
agent-vault delete NAME
agent-vault migrate [NAME...]    # move items from the old "pi-vault" service name

vault-run NAME "reason" -- command [args...]
```

Exit codes of `vault-run`: the command's status, 1 if the secret was not
released (missing, denied, empty), 64 for bad usage. Values are text; trailing
newlines are stripped.

## How it works

| Piece | Platform | What it does |
| --- | --- | --- |
| `bin/vault-run` | both | Gets the value from `agent-vault get`, runs the command with it in the environment, pipes the output through a Perl redactor that receives the value through its own environment, writes the audit line. Bash 3.2 compatible for macOS. |
| `macos/agent-vault.swift` | macOS | Generic-password items in the login keychain, service `agent-vault`, label `agent-vault: NAME`. `get` checks existence by attributes first (no prompt for a missing name), then `LAContext` `.deviceOwnerAuthentication`, then reads. `set` deletes and re-adds, so a stored item always gets a fresh access list. |
| `linux/agent-vault` | Linux | The same interface over `secret-tool`. `migrate` pipes each value from lookup to store and compares SHA-256 digests before clearing the old item, so the value never sits in a shell variable. |
| `skill/SKILL.md` | both | The Claude Code skill that tells the agent to use `vault-run` and nothing else. |

## Tests

```bash
./tests/linux.sh
```

18 end-to-end checks on Linux (redaction of stdout and stderr, multi-line
values, exit status, audit log contents, `get` refusing direct calls,
migration, delete). The script starts its own gnome-keyring on a private D-Bus
session under a temp `HOME`, so it never touches your keyring. It needs
`dbus-run-session`, `gnome-keyring-daemon`, `secret-tool` and `perl`. CI runs
it on Ubuntu, runs ShellCheck, and builds the Swift helper on macOS. The macOS
Touch ID path has no automated test; it needs a person at the machine.

## Status

A personal tool I use with Claude Code on a Mac and a NixOS server. It
started as a Linux port of [isaaclins/pi-vault](https://github.com/isaaclins/pi-vault),
an extension for the pi coding agent; none of that code is left, and the pi
extension was dropped in favour of a plain CLI that any agent with a shell can
call. The `pi-vault` fallback and `migrate` exist for items stored by those
earlier versions.

## License

MIT, see [LICENSE](LICENSE).
