// Per-account settings (Task 7). Today there is exactly one: `notePush`
// (default true). Stored in the minimal `account_settings` table (see
// migrations/0004): no timestamps, no history, no IP, and nothing in this
// file logs an account id or a value.
import type { Env } from "./index";
import type { V3Auth } from "./index";
import { json, bumpQuota, dayKey } from "./notes";

export const SETTINGS_WRITES_PER_DAY = 60;
const BODY_MAX_BYTES = 1024;

/** The recipient's stored notePush value; true when there is no row. Throws on a D1 error. */
export async function readNotePush(env: Env, accountId: string): Promise<boolean> {
  const row = await env.ACCOUNTS_DB.prepare("SELECT note_push FROM account_settings WHERE account_id = ?1").bind(accountId).first<{ note_push: number }>();
  return row ? row.note_push !== 0 : true;
}

/**
 * GET/PUT /v3/account/settings. Returns null when `path` is not ours.
 * GET works on both auth lanes. PUT is Bearer-only: the key lane's device
 * id is self-asserted, and this setting decides whether someone else's
 * phone is told about their notes.
 */
export async function handleAccountSettingsRoute(request: Request, path: string, env: Env, auth: V3Auth): Promise<Response | null> {
  if (path !== "/v3/account/settings") return null;

  if (request.method === "GET") {
    return json({ notePush: await readNotePush(env, auth.accountId) });
  }

  if (request.method === "PUT") {
    if (auth.lane === "key") return json({ error: "bearer_required" }, 401);
    const raw = await request.text();
    if (raw.length > BODY_MAX_BYTES) return json({ error: "too_large" }, 413);
    let body: unknown;
    try { body = JSON.parse(raw); } catch { return json({ error: "invalid_settings" }, 400); }
    // Strict: exactly one key, and it must be a boolean. Unknown fields are
    // rejected (not ignored) so a newer client never believes a setting it
    // sent was stored when this Worker does not know it.
    if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "invalid_settings" }, 400);
    const keys = Object.keys(body);
    const value = (body as Record<string, unknown>).notePush;
    if (keys.length !== 1 || keys[0] !== "notePush" || typeof value !== "boolean") return json({ error: "invalid_settings" }, 400);
    if (!(await bumpQuota(env.V2_STORE, `settings-quota:${auth.accountId}:${dayKey()}`, SETTINGS_WRITES_PER_DAY, 2 * 86400))) return json({ error: "rate_limited" }, 429);
    await env.ACCOUNTS_DB.prepare("INSERT INTO account_settings (account_id, note_push) VALUES (?1, ?2) ON CONFLICT(account_id) DO UPDATE SET note_push = excluded.note_push")
      .bind(auth.accountId, value ? 1 : 0).run();
    return json({ notePush: value });
  }

  return null;
}
