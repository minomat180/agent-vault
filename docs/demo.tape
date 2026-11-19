# Terminal recording for the README. Render with:
#   nix shell nixpkgs#vhs nixpkgs#gnome-keyring nixpkgs#jq -c vhs docs/demo.tape
# docs/demo-shell.sh starts a throwaway keyring holding one fake secret.
Output docs/demo.gif

Set Shell bash
Set FontSize 20
Set Width 1240
Set Height 460
Set Padding 28
Set TypingSpeed 35ms
Set Theme "Builtin Dark"

Hide
Type "exec ./docs/demo-shell.sh" Enter
Sleep 2s
Show

Type "agent-vault list" Sleep 300ms Enter
Sleep 1.2s
Type "agent-vault get DEMO_TOKEN" Sleep 300ms Enter
Sleep 2s
Type `vault-run DEMO_TOKEN "show header" -- sh -c 'echo "Bearer $AGENT_VAULT_SECRET"'` Sleep 300ms Enter
Sleep 2.5s
Type `vault-run DEMO_TOKEN "count bytes" -- sh -c 'printf %s "$AGENT_VAULT_SECRET" | wc -c'` Sleep 300ms Enter
Sleep 2.5s
Type "jq -c '{name, reason, result}' ~/.local/state/agent-vault/audit.log" Sleep 300ms Enter
Sleep 4s
