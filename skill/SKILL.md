---
name: vault
description: Use a stored secret (API key, token, password) in a command without ever seeing its value. Use whenever a task needs a credential - never ask mino to paste one into the chat and never read keychain or keyring items directly.
---

# vault

Secrets live in agent-vault (`~/Projects/agent-vault`), on both machines:

- **Mac**: the login keychain, service `agent-vault`. Each read asks mino for
  Touch ID, naming the secret and your reason, so a read you don't explain well
  will be denied. Items not yet migrated from the old service are still found.
- **minomatNix**: the Secret Service (gnome-keyring) via `secret-tool`,
  service `agent-vault`. No prompt there.

List the names (never values):

```bash
agent-vault list
```

Run one command with a secret:

```bash
vault-run GITHUB_TOKEN "list my repos" -- \
  sh -c 'curl -sH "Authorization: Bearer $AGENT_VAULT_SECRET" https://api.github.com/user/repos'
```

- The secret is in `$AGENT_VAULT_SECRET` for that one process only. Reference
  it inside `sh -c '...'` with single quotes, so your shell never expands it.
- Output is merged (stderr into stdout) and the value is replaced with
  `[REDACTED]`. Don't try to get around that: no `echo`, `base64`, writing it to
  files, or passing it to anything but the intended service.
- Never run `agent-vault get`, `secret-tool lookup` or `security
  find-generic-password` yourself; `vault-run` is the only way to use a secret.
- A missing secret: tell mino to add it himself with `agent-vault set NAME`.
  Never set it for him from a value in the chat.
- Every attempt is logged to `~/.local/state/agent-vault/audit.log`.
- Web-login passwords: on the Mac they are the `pw.*` entries here; on
  minomatNix they are in the iPod vault, not here.
