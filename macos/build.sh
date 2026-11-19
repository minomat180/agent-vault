#!/bin/bash
# Builds macos/agent-vault (ad-hoc signed). Needs the Xcode command line tools.
#
# Rebuilding changes the binary's signature, so the keychain no longer trusts
# it for secrets stored by the old build: the first read of each shows the
# keychain dialog. Enter your login password and click "Allow" (or "Always
# Allow"), or store the secrets again with `agent-vault set NAME`.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o agent-vault agent-vault.swift
codesign --force --sign - --identifier ch.mino.agent-vault agent-vault
echo "built $(pwd)/agent-vault"
