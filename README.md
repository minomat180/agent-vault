# pi-vault (Linux port)

An agentic vault for [Pi](https://github.com/earendil-works/pi-coding-agent). The agent can *use* a secret without ever *seeing* it.

This is a **Linux port** of [isaaclins/pi-vault](https://github.com/isaaclins/pi-vault), which was macOS-only (login keychain via the `security` binary). Here the store is the freedesktop **Secret Service** (libsecret / gnome-keyring) accessed through `secret-tool`.

Instead of pasting an API key into the chat, where it lives in the transcript forever, the agent names a secret and a command. You approve or deny. On approval the secret is read from the keyring and handed to that one child process as `$PI_VAULT_SECRET`.

## Status: not a security boundary yet

An agent with shell access can bypass this with one command while the keyring is unlocked:

```bash
secret-tool lookup service pi-vault account YOUR_SECRET
```

The gnome-keyring login collection is unlocked for your whole session, so that read succeeds with no prompt. What this buys you today: the secret stays out of the model's context and out of your transcript, it never appears in argv where `ps` can see it, and it is redacted if a command echoes it. Those are protections against accident and drift, not against intent.

A hardware-enforced equivalent of macOS Touch ID would need a keyring backend that prompts per-read (e.g. a separately-locked collection you unlock on demand). Until then, treat this as a convenience wrapper.

## Requirements

- `secret-tool` (Void: `xbps-install -S libsecret`)
- a running Secret Service daemon (gnome-keyring or KeePassXC's Secret Service)

## Install

Local checkout:

```bash
pi install ~/projects/pi-vault
```

Then `/reload` in Pi.

## Add a secret

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

You get a confirmation showing the name, the reason, the cwd, and the exact command. Denial (including cancel/Escape) reads nothing from the keyring.

`vault_list` returns the **names** of stored secrets only — never any values.

## Audit log

Every request, approved or denied, appends one JSON line to:

```
~/.local/state/pi-vault/audit.log
```

## License

MIT (same as upstream)
