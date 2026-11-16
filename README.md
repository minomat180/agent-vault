# pi-vault (macOS + Linux)

An agentic vault for [Pi](https://github.com/earendil-works/pi-coding-agent). The agent can *use* a secret without ever *seeing* it.

Based on [isaaclins/pi-vault](https://github.com/isaaclins/pi-vault). Two backends, picked by platform:

- **macOS**: the login keychain, through `macos/pi-vault-keychain`, a small Swift helper that asks for **Touch ID on every read**. See [macOS](#macos).
- **Linux**: the freedesktop **Secret Service** (libsecret / gnome-keyring) through `secret-tool`.

Instead of pasting an API key into the chat, where it lives in the transcript forever, the agent names a secret and a command. You approve or deny. On approval the secret is read from the keyring and handed to that one child process as `$PI_VAULT_SECRET`.

## macOS

Build the helper once (needs the Xcode command line tools):

```bash
macos/build.sh
ln -s "$PWD/macos/pi-vault-keychain" ~/.pi/agent/bin/pi-vault   # optional, puts it on PATH
```

Add, list, remove (the value is read from a hidden prompt, never from argv):

```bash
pi-vault set OPENAI_API_KEY
pi-vault list
pi-vault delete OPENAI_API_KEY
```

Items show up in Keychain Access as `pi-vault: NAME` (login keychain, service `pi-vault`).
They are not in the Passwords app or iCloud Keychain: command-line tools cannot use those.

Why this one is an actual boundary:

- Each item is created by the helper, so its access list trusts only the helper's code signature.
  `security find-generic-password -w` from any other process gets the macOS keychain dialog, asking for the login password.
- The helper asks for Touch ID (login password as fallback) before every read, naming the secret and the reason.
  An agent can run it, but it cannot answer the prompt.
- A modified or rebuilt helper has a different signature, so the keychain dialog comes back.
  Click "Always Allow" only if you rebuilt it yourself.

So a release takes two answers: the pi dialog (which shows the exact command), then Touch ID.

## Linux status: not a security boundary yet

An agent with shell access can bypass this with one command while the keyring is unlocked:

```bash
secret-tool lookup service pi-vault account YOUR_SECRET
```

The gnome-keyring login collection is unlocked for your whole session, so that read succeeds with no prompt. What this buys you today: the secret stays out of the model's context and out of your transcript, it never appears in argv where `ps` can see it, and it is redacted if a command echoes it. Those are protections against accident and drift, not against intent.

A hardware-enforced equivalent of macOS Touch ID would need a keyring backend that prompts per-read (e.g. a separately-locked collection you unlock on demand). Until then, treat this as a convenience wrapper.

## Linux requirements

- `secret-tool` (Void: `xbps-install -S libsecret`)
- a running Secret Service daemon (gnome-keyring or KeePassXC's Secret Service)

## Install

Local checkout:

```bash
pi install ~/projects/pi-vault
```

Then `/reload` in Pi.

## Add a secret (Linux)

Add secrets yourself so the value never passes through the agent. `secret-tool store` prompts for the value on stdin, keeping it out of shell history and out of `ps`:

```bash
secret-tool store --label='pi-vault: OPENAI_API_KEY' service pi-vault account OPENAI_API_KEY
```

Remove one:

```bash
secret-tool clear service pi-vault account OPENAI_API_KEY
```

## Use

The agent calls:

```
vault_use
  name:    OPENAI_API_KEY
  reason:  refresh the expired auth token
  command: ["sh","-c","curl -sH \"Authorization: Bearer $PI_VAULT_SECRET\" https://api.openai.com/v1/models"]
```

You get a confirmation showing the name, the reason, the cwd, and the exact command. Denial (including cancel/Escape) reads nothing from the keychain or keyring.

`vault_list` returns the **names** of stored secrets only — never any values.

## Audit log

Every request, approved or denied, appends one JSON line to:

```
~/.local/state/pi-vault/audit.log
```

## License

MIT (same as upstream)
