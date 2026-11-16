import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile, spawn } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { approve } from "./capri-approval.ts";

/**
 * pi-vault (Linux port): let an agent use a secret without ever seeing it.
 *
 * The agent names a secret and a command. The human approves or denies. On
 * approval the secret is read from the freedesktop Secret Service (libsecret /
 * gnome-keyring) via `secret-tool` and handed to that one child process as
 * $PI_VAULT_SECRET. It is never returned to the model, and any occurrence of it
 * in the command output is redacted.
 *
 * The approval prompt lives inside execute() on purpose. A separate "ask first"
 * tool would only be a promise the agent could skip; this is a gate it cannot.
 *
 * Two backends, picked by platform:
 * - macOS: the login keychain, through macos/pi-vault-keychain (a small Swift
 *   helper). Items trust only that helper, and it asks for Touch ID before
 *   every read, so an agent with a shell cannot read them either.
 * - Linux: the freedesktop Secret Service via `secret-tool`. An agent with
 *   shell access can bypass this with `secret-tool lookup ...` while the
 *   keyring is unlocked; there it keeps secrets out of the transcript and out
 *   of argv/ps, but is not an enforced boundary.
 */

const SERVICE = "pi-vault";
const MAC = process.platform === "darwin";
const HELPER = join(dirname(fileURLToPath(import.meta.url)), "macos", "pi-vault-keychain");
const BACKEND = MAC ? "keychain" : "keyring";
const addHint = (name: string) =>
  MAC
    ? `${HELPER} set ${name}`
    : `secret-tool store --label='${SERVICE}: ${name}' service ${SERVICE} account ${name}`;
const AUDIT = join(homedir(), ".local/state/pi-vault/audit.log");
const REDACTED = "<redacted by pi-vault>";

export default function vault(pi: ExtensionAPI) {
  pi.registerTool({
    name: "vault_use",
    label: "Use Vault Secret",
    description:
      "Run one command with a secret from the user's vault injected as $PI_VAULT_SECRET. " +
      "The user must approve each use. The secret is never shown to you and is redacted from the output. " +
      "Use this instead of asking the user to paste a credential into the chat.",
    promptSnippet:
      "Use a stored secret in a single command without seeing its value. Requires the user to approve.",
    promptGuidelines: [
      "Give a specific reason; the user sees it verbatim when deciding.",
      "Reference the secret as $PI_VAULT_SECRET inside the command, never interpolate it yourself.",
      "One command per call. If the user denies, do not retry with a different wording.",
    ],
    parameters: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Name of the secret in the vault, for example OPENAI_API_KEY.",
        },
        reason: {
          type: "string",
          description: "Why you need it, in one line. Shown to the user verbatim.",
        },
        command: {
          type: "array",
          items: { type: "string" },
          description:
            'Command and arguments, e.g. ["sh","-c","curl -H \\"Authorization: Bearer $PI_VAULT_SECRET\\" https://api.example.com"].',
        },
      },
      required: ["name", "reason", "command"],
    },

    async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
      const name = String(params.name ?? "").trim();
      const reason = String(params.reason ?? "").trim();
      const command: string[] = Array.isArray(params.command) ? params.command.map(String) : [];

      if (!name || !reason || command.length === 0) {
        return text("vault_use needs name, reason and a non-empty command.");
      }

      // No UI means nobody can approve, so nothing is released.
      if (!ctx.hasUI) {
        audit({ name, reason, command, decision: "denied", note: "no interactive UI" });
        return text(`Denied: no interactive UI available to approve use of "${name}".`);
      }

      // ctx.ui.confirm() puts "Yes" first, so a reflexive Enter would release the
      // secret. Drive the selector directly instead, with denial as the default.
      const deny = `No, deny "${name}"`;
      const allow = `Yes, release "${name}"`;
      // Asked in the terminal and on Capri (if she's running); first answer wins.
      const { choice, via, report } = await approve(
        ctx,
        [
          `Release secret "${name}"?`,
          reason,
          "",
          `cwd:     ${process.cwd()}`,
          `command: ${command.join(" ")}`,
        ].join("\n"),
        { deny, allow },
        { vault: BACKEND, label: name, reason, command: command.join(" "), cwd: process.cwd(), agent: "pi", session: basename(process.cwd()) },
      );

      // Cancelling or dismissing is a denial, never a release.
      if (choice !== allow) {
        audit({ name, reason, command, decision: "denied", via });
        return text(`Denied by user: "${name}" was not released.`);
      }

      let secret: string;
      try {
        secret = await readSecret(name, reason);
      } catch (e: any) {
        if (e?.code === 3) {
          audit({ name, reason, command, decision: "denied", via: "touchid" });
          report({ error: "Touch ID was denied" });
          return text(`Denied at Touch ID: "${name}" was not released.`);
        }
        if (e?.code === 2 || e?.message === "empty" || !MAC) {
          audit({ name, reason, command, decision: "error", note: `not in ${BACKEND}` });
          report({ error: `it's not in the ${BACKEND}` });
          return text(`No secret named "${name}" in the vault. The user can add it with:\n  ${addHint(name)}`);
        }
        audit({ name, reason, command, decision: "error", note: String(e?.message ?? e) });
        report({ error: "the keychain helper failed" });
        return text(`Could not read "${name}": ${String(e?.message ?? e)}`);
      }

      const result = await run(command, secret);
      audit({ name, reason, command, decision: "approved", via, exitCode: result.code });
      report({ exitCode: result.code });

      return text(
        [
          `Ran with $PI_VAULT_SECRET from "${name}" (exit ${result.code}).`,
          result.stdout && `stdout:\n${redact(result.stdout, secret)}`,
          result.stderr && `stderr:\n${redact(result.stderr, secret)}`,
        ]
          .filter(Boolean)
          .join("\n\n"),
      );
    },
  });

  // Roadmap item from upstream: let the agent discover names without values.
  pi.registerTool({
    name: "vault_list",
    label: "List Vault Secrets",
    description:
      "List the names of secrets stored in the user's vault. Never returns any secret values, only names.",
    promptSnippet: "Discover which secret names exist in the vault, without seeing any values.",
    parameters: { type: "object", properties: {}, required: [] },
    async execute() {
      try {
        const names = await listSecretNames();
        if (names.length === 0) return text("The vault is empty. No secrets stored yet.");
        return text(`Secrets in the vault (names only):\n${names.map((n) => `  - ${n}`).join("\n")}`);
      } catch (e) {
        return text(`Could not list vault secrets: ${String(e)}`);
      }
    },
  });
}

/** Reads one secret. The value goes to stdout only, never argv. */
function readSecret(name: string, reason: string): Promise<string> {
  if (MAC) {
    return new Promise((resolve, reject) => {
      // No timeout: the helper waits for Touch ID, which takes as long as it takes.
      execFile(HELPER, ["get", name, reason], { maxBuffer: 1 << 20 }, (error: any, stdout, stderr) => {
        if (error) {
          if (error.code === "ENOENT") return reject(new Error(`helper not built: run ${dirname(HELPER)}/build.sh`));
          const err: any = new Error(String(stderr || error.message).trim());
          err.code = error.code;
          return reject(err);
        }
        if (stdout === "") return reject(new Error("empty"));
        resolve(stdout);
      });
    });
  }
  return new Promise((resolve, reject) => {
    execFile(
      "secret-tool",
      ["lookup", "service", SERVICE, "account", name],
      (error, stdout) => {
        // secret-tool exits non-zero AND prints nothing when the item is missing.
        if (error) return reject(error);
        if (stdout === "") return reject(new Error("empty"));
        resolve(stdout.replace(/\n$/, ""));
      },
    );
  });
}

/** Lists secret names by searching the service attribute. Values never leave the keyring. */
function listSecretNames(): Promise<string[]> {
  if (MAC) {
    return new Promise((resolve, reject) => {
      execFile(HELPER, ["list"], (error: any, stdout, stderr) => {
        if (error) return reject(new Error(error.code === "ENOENT" ? `helper not built: run ${dirname(HELPER)}/build.sh` : String(stderr || error.message).trim()));
        resolve(stdout.split("\n").map((s) => s.trim()).filter(Boolean));
      });
    });
  }
  return new Promise((resolve, reject) => {
    execFile("secret-tool", ["search", "--all", "service", SERVICE], (error, _stdout, stderr) => {
      // `secret-tool search` writes the attribute dump to stderr.
      if (error && !stderr) return reject(error);
      const names = new Set<string>();
      for (const line of (stderr || "").split("\n")) {
        const m = line.match(/^attribute\.account\s*=\s*(.+)$/);
        if (m) names.add(m[1].trim());
      }
      resolve([...names].sort());
    });
  });
}

/** The secret reaches the child through the environment, so it never hits a command line. */
function run(command: string[], secret: string): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(command[0], command.slice(1), {
      env: { ...process.env, PI_VAULT_SECRET: secret },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (e) => resolve({ code: 1, stdout, stderr: stderr + String(e) }));
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

/** Last line of defence: a command that echoes the secret still cannot leak it. */
function redact(value: string, secret: string): string {
  return secret ? value.split(secret).join(REDACTED) : value;
}

function audit(entry: Record<string, unknown>): void {
  try {
    mkdirSync(dirname(AUDIT), { recursive: true });
    appendFileSync(AUDIT, JSON.stringify({ ts: new Date().toISOString(), cwd: process.cwd(), ...entry }) + "\n");
  } catch {
    // An unwritable log must not silently become a released secret, but the
    // release already happened or was denied above, so there is nothing to undo.
  }
}

function text(content: string) {
  return { content: [{ type: "text", text: content }] };
}
