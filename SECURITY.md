# Security policy

Please report vulnerabilities privately through [GitHub Security Advisories](https://github.com/mino-shared/agent-vault/security/advisories/new) rather than a public issue.

Read the README's Linux "Not a security boundary" note first: on Linux an
agent with shell access can read any secret with one `secret-tool` command
while the keyring is unlocked. That is a known, documented limitation. Anything
beyond it (a way to read a macOS item without Touch ID, or to get a value into
the output of `vault-run`) is a real finding.
