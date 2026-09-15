/** Account layer helpers shared by /v2 token issuance and /v3 routes. */
//
// Device-token issuance must never fail closed on the accounts DB: both
// call sites (in /v2/device/attest and /v2/device/assert) sit inside those
// handlers' outer try/catch → 400, so an unhandled D1 error here would turn
// into a 400 for EVERY attest/assert call — locking every shipped device
// out of relay features on a D1 outage, an unbound binding, or a migration
// that hasn't landed yet at deploy time. Fail open to the "default" scope
// instead; a device that should have been account-scoped just behaves like
// an unbound one until the next successful lookup.
export async function scopeForDevice(db: D1Database, deviceId: string): Promise<string> {
  try {
    const row = await db.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1")
      .bind(deviceId).first<{ account_id: string }>();
    return row ? `account:${row.account_id}` : "default";
  } catch (err) {
    console.error("scopeForDevice: falling back to default scope", String(err));
    return "default";
  }
}

export function accountIdFromScope(scope: string): string | null {
  return scope.startsWith("account:") && scope.length > 8 ? scope.slice(8) : null;
}
