#!/usr/bin/env bash
# Shell for docs/demo.tape: a throwaway gnome-keyring on a private D-Bus
# session, a temp HOME, and one fake secret DEMO_TOKEN. Your real keyring is
# never touched; everything is deleted when the shell exits.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z ${AGENT_VAULT_DEMO:-} ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT HUP TERM
  mkdir -p "$tmp/home" "$tmp/data" "$tmp/run" "$tmp/bin"
  chmod 700 "$tmp/run"
  ln -s "$repo/linux/agent-vault" "$tmp/bin/agent-vault"
  ln -s "$repo/bin/vault-run" "$tmp/bin/vault-run"
  env HOME="$tmp/home" XDG_DATA_HOME="$tmp/data" XDG_RUNTIME_DIR="$tmp/run" \
    XDG_STATE_HOME="$tmp/home/.local/state" PATH="$tmp/bin:$PATH" \
    AGENT_VAULT_DEMO="$tmp" dbus-run-session -- "$0" || true
  exit
fi
printf 'demo' | gnome-keyring-daemon --foreground --unlock --components=secrets >/dev/null 2>&1 &
keyring_pid=$!
trap 'kill "$keyring_pid" 2>/dev/null' EXIT HUP TERM
for _ in $(seq 100); do
  dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.NameHasOwner string:org.freedesktop.secrets 2>/dev/null | grep -q 'boolean true' && break
  sleep 0.1
done
printf 'demo-3f9a1c7e5b2d8046' | agent-vault set DEMO_TOKEN >/dev/null
cd "$HOME"
bash --noprofile --rcfile <(printf '%s\n' "PS1='\[\e[2m\]\$\[\e[0m\] '" 'clear') || true
