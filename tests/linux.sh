#!/usr/bin/env bash
# End-to-end test of linux/agent-vault and bin/vault-run against a throwaway
# gnome-keyring on a private D-Bus session. HOME, XDG dirs and the keyring all
# live in a temp directory, so your real keyring and audit log are never used.
#
# Needs: dbus-run-session, gnome-keyring-daemon, secret-tool, perl.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)

if [[ -z ${AGENT_VAULT_TEST_INNER:-} ]]; then
  for t in dbus-run-session gnome-keyring-daemon secret-tool perl; do
    command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 2; }
  done
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/home" "$tmp/data" "$tmp/state" "$tmp/config" "$tmp/run" "$tmp/bin"
  chmod 700 "$tmp/run"
  ln -s "$repo/linux/agent-vault" "$tmp/bin/agent-vault"
  ln -s "$repo/bin/vault-run" "$tmp/bin/vault-run"
  env HOME="$tmp/home" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
    XDG_CONFIG_HOME="$tmp/config" XDG_RUNTIME_DIR="$tmp/run" \
    PATH="$tmp/bin:$PATH" AGENT_VAULT_TEST_INNER="$tmp" \
    dbus-run-session -- "$0"
  exit
fi

# Inside the private session: start an empty, unlocked keyring.
printf 'test' | gnome-keyring-daemon --foreground --unlock --components=secrets >/dev/null 2>&1 &
keyring_pid=$!
trap 'kill "$keyring_pid" 2>/dev/null' EXIT
for _ in $(seq 50); do secret-tool search --all service none >/dev/null 2>&1 && break; sleep 0.1; done
[[ $(command -v agent-vault) == "$AGENT_VAULT_TEST_INNER/bin/agent-vault" ]] ||
  { echo "agent-vault on PATH is not the repo copy; refusing to run" >&2; exit 2; }
if secret-tool search --all service agent-vault 2>&1 >/dev/null | grep -q "^attribute"; then
  echo "test keyring is not empty; refusing to run" >&2; exit 2
fi

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
audit=$XDG_STATE_HOME/agent-vault/audit.log

value='tok_9f8e7d6c5b4a39281706'
printf '%s' "$value" | agent-vault set TEST_TOKEN >/dev/null
check "set stores the value from stdin" test "$(secret-tool lookup service agent-vault account TEST_TOKEN)" = "$value"
check "list prints the name" test "$(agent-vault list)" = TEST_TOKEN

out=$(agent-vault get TEST_TOKEN 2>&1) && rc=0 || rc=$?
check "get refuses without vault-run" test "$rc" -ne 0
check "refused get does not print the value" test "${out/$value/}" = "$out"

got=$(vault-run TEST_TOKEN "hash it" -- sh -c 'printf %s "$AGENT_VAULT_SECRET" | sha256sum | cut -d" " -f1')
check "command receives the exact value" test "$got" = "$(sha "$value")"

out=$(vault-run TEST_TOKEN "print it" -- sh -c 'echo "a=$AGENT_VAULT_SECRET"; echo "$AGENT_VAULT_SECRET" >&2')
check "stdout and stderr are redacted" test "$out" = $'a=[REDACTED]\n[REDACTED]'

vault-run TEST_TOKEN "exit code" -- sh -c 'exit 7' && rc=0 || rc=$?
check "exit status is the command's" test "$rc" -eq 7

vault-run NOPE "missing" -- true 2>/dev/null && rc=0 || rc=$?
check "missing name fails" test "$rc" -eq 1

vault-run TEST_TOKEN 2>/dev/null && rc=0 || rc=$?
check "bad usage exits 64" test "$rc" -eq 64

check "audit log never holds the value" sh -c '! grep -qF -- "$1" "$2"' _ "$value" "$audit"
check "audit log records release and refusal" sh -c \
  'grep -q "\"name\":\"TEST_TOKEN\",\"reason\":\"print it\".*\"result\":\"released\"" "$1" &&
   grep -q "\"name\":\"NOPE\".*\"result\":\"not-released\"" "$1"' _ "$audit"

multi=$'first-line-secret\nsecond-line-secret'
printf '%s' "$multi" | agent-vault set TEST_MULTI >/dev/null
out=$(vault-run TEST_MULTI "multi-line" -- sh -c 'printf "%s\n" "$AGENT_VAULT_SECRET"; echo "x second-line-secret x"')
check "multi-line value is redacted line by line" test "$out" = $'[REDACTED]\n[REDACTED]\nx [REDACTED] x'

printf '%s' "legacy-value-1234" | secret-tool store --label="pi-vault: OLD_ONE" service pi-vault account OLD_ONE
check "legacy items are listed" sh -c 'agent-vault list 2>/dev/null | grep -qx OLD_ONE'
agent-vault migrate >/dev/null
check "migrate moves the item" test "$(secret-tool lookup service agent-vault account OLD_ONE)" = legacy-value-1234
check "migrate clears the legacy item" sh -c '! secret-tool lookup service pi-vault account OLD_ONE >/dev/null 2>&1'

agent-vault delete TEST_TOKEN >/dev/null
check "delete removes the item" sh -c '! secret-tool lookup service agent-vault account TEST_TOKEN >/dev/null 2>&1'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
