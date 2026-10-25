// Delivers a group push to the recipients a GroupRoom named (Ruling 14).
// An account member is reached on EVERY device of the account, resolved at
// send time from D1/KV by fanOutPush — the room never stores an account
// member's devices. An anonymous member is reached only on the one device
// the room holds for it. Device lists and tokens stay inside this call:
// nothing is returned and nothing identifying is logged.
//
// Never throws: the event is already stored when this runs, so a push
// failure only costs the recipient a nudge.
import type { Env } from "./index";
import type { PushDeps } from "./notes";
import type { PushRecipient } from "./groupRoom";
import { fanOutPush, pushToDevice } from "./push";
import type { PushPayload } from "./push";

/**
 * At most this many recipients are being pushed at once. A Worker
 * invocation may hold only 6 outbound connections open at a time (more are
 * queued, and a queued fetch can stall the others), and every recipient
 * costs 1 D1 read + a KV read and a send per device; so a 49-member room's
 * fan-out is run through a small pool instead of 49 parallel chains.
 */
export const GROUP_PUSH_CONCURRENCY = 6;

/** Fixed log detail for a caught error: its class name only, never its message (which may hold a URL or token). */
export const errName = (e: unknown): string => (e instanceof Error ? e.name : "error");

export async function deliverGroupPush(env: Env, recipients: PushRecipient[], payload: PushPayload, deps: PushDeps): Promise<void> {
  let next = 0;
  const lane = async (): Promise<void> => {
    while (next < recipients.length) {
      const r = recipients[next++];
      try {
        if (r.kind === "account") await fanOutPush(env, r.accountId, payload, deps);
        else await pushToDevice(env, r.deviceId, null, payload, deps);
      } catch (e) {
        console.error("group push failed", errName(e));
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(GROUP_PUSH_CONCURRENCY, recipients.length) }, lane));
}
