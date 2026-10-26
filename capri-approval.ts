/**
 * Ask for approval in two places at once: the terminal (ctx.ui.select, as before) and Capri, the
 * desktop pet, if she's running (http://127.0.0.1:47823). Whichever is answered first wins; the
 * other one is withdrawn. No Capri: just the terminal, exactly as before.
 *
 * Capri only accepts the answer from a real click in her overlay, delivered over a private pipe
 * from her overlay process, never from an HTTP call, so an agent can't approve itself with curl.
 * Same threat model as the vault itself: defence against accident and drift, not against a
 * determined local attacker (who could also fake a server on that port while Capri is down).
 * Set CAPRI_VAULT=0 to keep approvals in the terminal only.
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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// "allow" | "deny" from a click on Capri; null if she isn't there, or it was withdrawn/expired.
async function askCapri(info: CapriApprovalInfo, signal: AbortSignal): Promise<"allow" | "deny" | null> {
  if (process.env.CAPRI_VAULT === "0") return null;
  let id: string | undefined;
  try {
    const res = await fetch(`${CAPRI}/approval`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(info),
      signal: AbortSignal.any([signal, AbortSignal.timeout(1500)]),
    });
    if (!res.ok) return null;
    id = (await res.json())?.id;
  } catch {
    return null;
  }
  if (!id || !/^[0-9a-f]{32}$/.test(id)) return null;
  // answered in the terminal (or the tool stopped): take the question off her screen
  signal.addEventListener("abort", () => {
    fetch(`${CAPRI}/approval/${id}`, { method: "DELETE" }).catch(() => {});
  }, { once: true });
  while (!signal.aborted) {
    try {
      const res = await fetch(`${CAPRI}/approval/${id}`, { signal });
      const decision = (await res.json())?.decision;
      if (decision === "allow" || decision === "deny") return decision;
      if (decision) return null; // withdrawn / expired
    } catch {
      if (signal.aborted) return null;
      await sleep(2000); // she restarted, or a hiccup: ask again
    }
  }
  return null;
}

/**
 * Show the terminal selector and Capri's prompt together; returns the chosen option (one of
 * `options`, or undefined if dismissed) and where it came from.
 */
export async function approve(
  ctx: any,
  title: string,
  options: { deny: string; allow: string },
  info: CapriApprovalInfo,
): Promise<{ choice: string | undefined; via: "terminal" | "capri" }> {
  const ac = new AbortController();
  const never = new Promise<never>(() => {});
  const viaCapri = askCapri(info, ac.signal).then((d) =>
    d ? { choice: d === "allow" ? options.allow : options.deny, via: "capri" as const } : never,
  );
  const viaTerminal = Promise.resolve(ctx.ui.select(title, [options.deny, options.allow], { signal: ac.signal }))
    .then((choice: string | undefined) => ({ choice, via: "terminal" as const }));
  try {
    return await Promise.race([viaTerminal, viaCapri]);
  } finally {
    ac.abort(); // closes the other one
  }
}
