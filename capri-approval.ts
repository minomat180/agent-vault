/**
 * Ask for approval in two places at once: pi's own dialog (ctx.ui.select: the TUI in a terminal,
 * or T3 Code's question card when pi runs inside T3) and Capri, the desktop pet, if she's running
 * (http://127.0.0.1:47823). First answer wins. No Capri: just the dialog, exactly as before.
 *
 * How the pieces talk (worked out 2026-10-26, see capri-desktop/linux/docs/vault-approvals.md):
 * - Capri accepts the answer only from a real click in her overlay, delivered over a private pipe
 *   from the overlay process, never from an HTTP call: an agent can't approve itself with curl.
 * - In a terminal, aborting the dialog closes it. Under T3 it does NOT: pi's RPC mode drops the
 *   request on its side but never tells T3, so T3 keeps a dead question card (answering it does
 *   nothing) until the turn ends. So under T3, a Capri click is submitted *through T3*
 *   (t3_pending_request_respond on this thread): T3 closes its card as answered, and pi gets the
 *   same answer the normal way. Only if that fails do we fall back to aborting.
 * - After the command runs, report() tells Capri how it went, so "released" isn't the last word
 *   when the command itself then fails.
 *
 * Same threat model as the vault: defence against accident and drift, not against a determined
 * local attacker. CAPRI_VAULT=0 keeps approvals in pi's dialog only.
 */

const CAPRI = `http://127.0.0.1:${process.env.CAPRI_PORT || 47823}`;

export interface CapriApprovalInfo {
  vault: "ipod" | "keyring";
  label: string;
  reason: string;
  command: string;
  cwd: string;
  agent: string;
  session: string;
}

export interface ApprovalResult {
  choice: string | undefined;
  via: "terminal" | "t3" | "capri";
  /** Tell Capri how the command went (no-op if she wasn't asked). */
  report: (outcome: { exitCode?: number; error?: string }) => void;
}

const sleep = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => { clearTimeout(t); resolve(); }, { once: true });
  });

async function post(path: string, body: unknown, ms = 1500): Promise<any> {
  const res = await fetch(`${CAPRI}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(ms),
  });
  if (!res.ok) throw new Error(`capri ${res.status}`);
  return res.json();
}

const validId = (id: unknown): id is string => typeof id === "string" && /^[0-9a-f]{32}$/.test(id);

// Ask Capri; resolves "allow" | "deny" from a click on her, or null (not running, withdrawn,
// expired). Keeps the question alive across a Capri restart by asking again. onId gets the
// current request id (for withdrawing and reporting).
async function askCapri(
  info: CapriApprovalInfo,
  signal: AbortSignal,
  onId: (id: string) => void,
): Promise<"allow" | "deny" | null> {
  if (process.env.CAPRI_VAULT === "0") return null;
  let id: string | null = null;
  let misses = 0;
  while (!signal.aborted) {
    if (!id) {
      try {
        const res = await post("/approval", info);
        if (!validId(res?.id)) return null;
        id = res.id;
        onId(res.id);
        misses = 0;
      } catch {
        // not running (or no overlay): try a few more times in case she's just restarting
        if (++misses > 3) return null;
        await sleep(2000, signal);
        continue;
      }
    }
    try {
      const res = await fetch(`${CAPRI}/approval/${id}`, { signal });
      if (res.status === 404) { id = null; continue; } // she restarted and forgot it: ask again
      const decision = (await res.json())?.decision;
      if (decision === "allow" || decision === "deny") return decision;
      if (decision) return null; // withdrawn / expired
      // null: long poll ran out, ask again
    } catch {
      if (signal.aborted) return null;
      id = null; // lost her: re-ask (after a pause), she may be restarting
      await sleep(2000, signal);
    }
  }
  return null;
}

// ---------- T3: answer pi's question card through T3 itself ----------

function parseRpc(body: string, contentType: string): any {
  if (contentType.includes("text/event-stream")) {
    for (const line of body.split("\n")) {
      const data = line.startsWith("data:") ? line.slice(5).trim() : "";
      if (!data) continue;
      const parsed = JSON.parse(data);
      if (parsed.id !== undefined || parsed.result !== undefined || parsed.error !== undefined) return parsed;
    }
    throw new Error("no JSON-RPC payload");
  }
  return JSON.parse(body);
}

async function t3Call(tool: string, args: Record<string, unknown>): Promise<any> {
  const url = process.env.T3_MCP_URL;
  const token = process.env.T3_MCP_BEARER_TOKEN;
  if (!url || !token) throw new Error("not in T3");
  let session: string | undefined;
  let next = 1;
  const call = async (method: string, params: unknown, notify = false) => {
    const headers: Record<string, string> = {
      accept: "application/json, text/event-stream",
      authorization: token.startsWith("Bearer ") ? token : `Bearer ${token}`,
      "content-type": "application/json",
      "mcp-protocol-version": "2025-06-18",
    };
    if (session) headers["mcp-session-id"] = session;
    const res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(notify ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", id: next++, method, params }),
      signal: AbortSignal.timeout(5000),
    });
    session = res.headers.get("mcp-session-id") || session;
    const body = await res.text();
    if (notify) return undefined;
    if (!res.ok) throw new Error(`T3 ${method} ${res.status}`);
    const parsed = parseRpc(body, res.headers.get("content-type") || "");
    if (parsed.error) throw new Error(parsed.error.message || `T3 ${method} failed`);
    return parsed.result;
  };
  await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "capri-approval", version: "1.0.0" } });
  await call("notifications/initialized", {}, true).catch(() => undefined);
  const result = await call("tools/call", { name: tool, arguments: args });
  if (result?.isError) throw new Error(`T3 ${tool}: ${JSON.stringify(result.content ?? "").slice(0, 200)}`);
  return result?.structuredContent ?? JSON.parse(result?.content?.[0]?.text ?? "null");
}

// Find this dialog's question card in T3 (same title, same two options) and answer it with
// `choice`. Throws if it can't.
async function answerInT3(title: string, options: { deny: string; allow: string }, choice: string): Promise<void> {
  const list = await t3Call("t3_pending_request_list", {});
  for (const requestId of list?.requestIds ?? []) {
    const read = await t3Call("t3_pending_request_read", { requestId });
    const q = (read?.questions ?? []).find((q: any) => {
      const values = (q.options ?? []).map((o: any) => o.value);
      return q.header === title && values.includes(options.allow) && values.includes(options.deny);
    });
    if (!q) continue;
    await t3Call("t3_pending_request_respond", { requestId, answers: { [q.id]: choice } });
    return;
  }
  throw new Error("question card not found in T3");
}

/**
 * Show pi's dialog and Capri's prompt together; returns the chosen option (one of `options`, or
 * undefined if dismissed), where it came from, and report() for the outcome.
 */
export async function approve(
  ctx: any,
  title: string,
  options: { deny: string; allow: string },
  info: CapriApprovalInfo,
): Promise<ApprovalResult> {
  const dialog = new AbortController(); // closes pi's dialog
  const capri = new AbortController();  // takes the question off Capri
  let capriId: string | null = null;
  const report: ApprovalResult["report"] = (outcome) => {
    if (capriId) post(`/approval/${capriId}/result`, outcome).catch(() => {});
  };
  const inT3 = Boolean(process.env.T3_MCP_URL && process.env.T3_MCP_BEARER_TOKEN);
  const where = inT3 ? "t3" : "terminal";

  const fromDialog = Promise.resolve(ctx.ui.select(title, [options.deny, options.allow], { signal: dialog.signal }))
    .then((choice: string | undefined) => ({ from: "dialog" as const, choice }));
  const never = new Promise<never>(() => {});
  const fromCapri = askCapri(info, capri.signal, (id) => { capriId = id; })
    .then((d) => (d ? { from: "capri" as const, choice: d === "allow" ? options.allow : options.deny } : never));

  const first = await Promise.race([fromDialog, fromCapri]);
  if (first.from === "dialog") {
    capri.abort();
    if (capriId) fetch(`${CAPRI}/approval/${capriId}`, { method: "DELETE" }).catch(() => {});
    return { choice: first.choice, via: where, report: () => {} };
  }

  // Capri answered. Under T3, answer T3's card with the same choice so it closes properly; pi's
  // dialog then resolves with that value through the normal path.
  if (inT3) {
    try {
      await answerInT3(title, options, first.choice);
      const settled = await Promise.race([fromDialog, sleep(5000).then(() => null)]);
      if (settled) return { choice: first.choice, via: "capri", report };
    } catch {
      // fall through: close our side; T3's card stays until the turn ends
    }
  }
  dialog.abort();
  if (inT3) {
    try { ctx.ui.notify?.(`Answered on Capri: ${first.choice}. The question card above is stale, ignore it.`, "info"); } catch { /* best effort */ }
  }
  return { choice: first.choice, via: "capri", report };
}
