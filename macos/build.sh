#!/bin/bash
# Builds macos/pi-vault-keychain (ad-hoc signed). Needs the Xcode command line tools.
#
# Rebuilding changes the binary's signature, so the keychain no longer trusts
# it for secrets stored by the old build: the first read of each shows the
# keychain dialog. Enter your login password and click "Always Allow", or
# store the secrets again with `pi-vault-keychain set NAME`.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o pi-vault-keychain pi-vault-keychain.swift
codesign --force --sign - --identifier ch.mino.pi-vault-keychain pi-vault-keychain
echo "built $(pwd)/pi-vault-keychain"
