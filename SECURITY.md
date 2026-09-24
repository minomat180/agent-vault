# Security policy

Please report vulnerabilities privately through [GitHub Security Advisories](https://github.com/mino-shared/pi-vault/security/advisories/new) rather than a public issue.

Read the README's "Status: not a security boundary yet" section first: an
agent with shell access can currently bypass the approval flow with one
`secret-tool` command while the keyring is unlocked. This is a known,
documented limitation, not something you need to report — but anything
beyond that (e.g. a way to exfiltrate a secret value into model output
through the approved flow itself) is a real finding.
