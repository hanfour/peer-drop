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

export async function deliverGroupPush(env: Env, recipients: PushRecipient[], payload: PushPayload, deps: PushDeps): Promise<void> {
  await Promise.all(recipients.map(async (r) => {
    try {
      if (r.kind === "account") await fanOutPush(env, r.accountId, payload, deps);
      else await pushToDevice(env, r.deviceId, null, payload, deps);
    } catch (e) {
      console.error("group push failed", String(e));
    }
  }));
}
