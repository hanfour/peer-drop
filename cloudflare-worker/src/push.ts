// Shared APNs fan-out: looks up every device bound to an account and sends
// one push per device that has a registered token. This is the generic
// engine notes.ts's fanOutNotePush and diary.ts's per-event pushes both
// build on (extracted from the original notes-only fanOutNotePush, which
// now just calls this with the note payload shape — see notes.ts).
//
// Never throws: a D1/KV outage or an individual send failure here must
// never turn an already-durable write (a stored note, a stored diary
// event) into a 500 for the caller — the recipient just misses (or
// partially misses) the push nudge and picks the change up on their next
// foreground sync.
import type { Env } from "./index";
import type { PushDeps } from "./notes";

export interface PushPayload {
  // Present for a visible (alert) push; absent for a silent one.
  alert?: { "loc-key": string; "loc-args"?: string[] };
  sound?: string;
  /**
   * Background/silent push: no alert, no sound, `content-available: 1`,
   * `apns-push-type: background`, `apns-priority: 5` (Apple requires 5,
   * not 10, for background pushes — 10 is rejected).
   */
  silent?: boolean;
  data: Record<string, unknown>;
}

/** APNs fan-out to every device bound to `accountId`. Never throws. */
export async function fanOutPush(env: Env, accountId: string, payload: PushPayload, deps: PushDeps): Promise<{ attempted: number }> {
  if (!env.APNS_KEY_P8) return { attempted: 0 };
  let attempted = 0;
  try {
    const devices = (await env.ACCOUNTS_DB.prepare("SELECT device_id, platform FROM account_devices WHERE account_id = ?1").bind(accountId).all<{ device_id: string; platform: string }>()).results;
    for (const d of devices) {
      const raw = await env.V2_STORE.get(`device:${d.device_id}`);
      if (!raw) continue;
      let info: { pushToken?: string; platform?: string };
      try { info = JSON.parse(raw); } catch { continue; }
      if (!info.pushToken) continue;
      attempted++;
      try {
        await deps.send(
          info.pushToken,
          payload.silent
            ? { contentAvailable: true, customData: payload.data }
            : { alert: payload.alert, sound: payload.sound, customData: payload.data },
          { keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, p8Key: env.APNS_KEY_P8, bundleId: env.APNS_BUNDLE_ID },
          payload.silent
            ? { topicOverride: deps.topicFor(info.platform ?? d.platform), pushType: "background", priority: 5 }
            : { topicOverride: deps.topicFor(info.platform ?? d.platform) },
        );
      } catch (e) {
        console.error("push failed", d.device_id, String(e));
      }
    }
  } catch (e) {
    console.error("push fan-out failed", String(e));
  }
  return { attempted };
}
