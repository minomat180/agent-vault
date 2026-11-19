# Contributing

A personal tool for my own agent setup, not maintained as a general-purpose
open source project. Issues and pull requests are read, but may sit for a
while.

Before sending a change, run `./tests/linux.sh` and
`shellcheck -S warning bin/vault-run linux/agent-vault install.sh macos/build.sh tests/linux.sh docs/demo-shell.sh`.
Changes to `macos/agent-vault.swift` need a manual check on a Mac: `set`,
`get` through `vault-run` (Touch ID prompt appears), `list`, `delete`.
