#!/usr/bin/env bash
# Links agent-vault, vault-run and the Claude Code skill `vault` into place.
#   ~/.local/bin/agent-vault  -> macos/agent-vault (built here) or linux/agent-vault
#   ~/.local/bin/vault-run    -> bin/vault-run
#   ~/.claude/skills/vault    -> skill/
set -euo pipefail
repo=$(cd "$(dirname "$0")" && pwd)
mkdir -p ~/.local/bin ~/.claude/skills
case $(uname -s) in
  Darwin) [[ -x $repo/macos/agent-vault ]] || "$repo/macos/build.sh"; backend=$repo/macos/agent-vault ;;
  Linux) backend=$repo/linux/agent-vault ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac
ln -sfn "$backend" ~/.local/bin/agent-vault
ln -sfn "$repo/bin/vault-run" ~/.local/bin/vault-run
if [[ -e ~/.claude/skills/vault && ! -L ~/.claude/skills/vault ]]; then
  echo "$HOME/.claude/skills/vault is a real directory; move it away first" >&2; exit 1
fi
ln -sfn "$repo/skill" ~/.claude/skills/vault
echo "installed: agent-vault -> $backend, vault-run, skill vault"
