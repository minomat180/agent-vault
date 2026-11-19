# agent-vault

Let a coding agent (Claude Code) *use* a secret without ever *seeing* it.

The agent names a secret and one command. `vault-run` reads the secret, hands it
to that command as `$AGENT_VAULT_SECRET`, and replaces the value with
`[REDACTED]` in the output. The agent only ever sees names.

Originally based on [isaaclins/pi-vault](https://github.com/isaaclins/pi-vault).
Two backends behind the same commands, picked by platform:

- **macOS**: the login keychain, through `macos/agent-vault`, a small Swift
  helper that asks for **Touch ID on every read**.
- **Linux**: the freedesktop **Secret Service** (gnome-keyring, KeePassXC)
  through `secret-tool`.

## Commands

```bash
agent-vault list                 # names only, never values
agent-vault set NAME             # value from a hidden prompt or stdin, never argv
agent-vault delete NAME
agent-vault migrate [NAME...]    # move items from the old "pi-vault" service

vault-run NAME "reason" -- command [args...]
```

Example:

```bash
vault-run CLOUDFLARE_API_TOKEN "verify the token" -- \
  sh -c 'curl -sH "Authorization: Bearer $AGENT_VAULT_SECRET" https://api.cloudflare.com/client/v4/user/tokens/verify'
```

`vault-run` merges stderr into stdout, redacts the value (and each line of a
multi-line value), and exits with the command's status. Every attempt appends
one JSON line (time, host, name, reason, cwd, command, result; never the
value) to `~/.local/state/agent-vault/audit.log`.

## Install

```bash
./install.sh
```

It links `agent-vault` and `vault-run` into `~/.local/bin` and the Claude Code
skill `skill/` to `~/.claude/skills/vault`. On macOS it first builds the helper
with `macos/build.sh` (needs the Xcode command line tools).

## macOS

Items live in the login keychain, service `agent-vault`, label
`agent-vault: NAME` (Keychain Access shows them; they are not in the Passwords
app or iCloud Keychain).

Why this one is an actual boundary:

- Each item is created by the helper, so its access list trusts only the
  helper's code signature. `security find-generic-password -w` from any other
  process gets the macOS keychain dialog, asking for the login password.
- The helper asks for Touch ID (login password as fallback) before every read,
  naming the secret and the reason. An agent can run it, but it cannot answer
  the prompt.
- A modified or rebuilt helper has a different signature, so the keychain
  dialog comes back. Allow it only if you rebuilt it yourself.

### Moving from pi-vault

Items stored by the old `pi-vault-keychain` helper (service `pi-vault`) are
still found by `list` and `get`. To move them:

```bash
agent-vault migrate            # all of them
agent-vault migrate NAME ...   # or just some
```

It asks for Touch ID once. Because the old items trust only the old helper,
macOS also shows its keychain dialog for each item: enter the login password
and click "Allow". Each value is copied, read back and compared before the old
item is deleted.

## Linux

Requires `secret-tool` (libsecret) and a running Secret Service. Items have the
attributes `service agent-vault account NAME` and the label `agent-vault: NAME`.
`agent-vault set NAME` lets `secret-tool` prompt for the value, so it never
passes through the agent. `agent-vault migrate` pipes each old `pi-vault` item
from `secret-tool lookup` into `secret-tool store`, compares SHA-256 digests,
and only then clears the old item.

**Not a security boundary.** While the keyring is unlocked, any process of the
user can run `secret-tool lookup service agent-vault account NAME` with no
prompt. On Linux this keeps secrets out of the transcript, out of argv (`ps`)
and out of command output: protection against accident and drift, not intent.
`agent-vault get` refuses to run unless called by `vault-run`, so an agent does
not print a value by mistake.

## License

MIT
