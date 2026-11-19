# Security policy

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/minomat180/agent-vault/security/advisories/new),
not in a public issue. This is a one-person project; expect a reply within a
week or two, not hours.

Read the threat model in the [README](README.md#threat-model) first. These are
known and documented, not vulnerabilities:

- On Linux any process of the same user can read every item with `secret-tool`
  while the keyring is unlocked. There is no prompt.
- The command that `vault-run` starts receives the real value and can do
  anything with it, including printing it in an encoded form that redaction
  does not match.
- The value is in the child's environment while it runs.
- The audit log is a plain, editable file.

Real findings, for example:

- reading a macOS item without a Touch ID or login-password prompt, through the
  helper or around it
- the literal value (or a line of 8+ characters of a multi-line value)
  reaching `vault-run`'s output unredacted
- the value reaching argv, the audit log, or any file written by these scripts
- `agent-vault set` or `migrate` exposing the value to another process
