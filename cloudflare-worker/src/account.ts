/** Account layer helpers shared by /v2 token issuance and /v3 routes. */
export async function scopeForDevice(db: D1Database, deviceId: string): Promise<string> {
  const row = await db.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1")
    .bind(deviceId).first<{ account_id: string }>();
  return row ? `account:${row.account_id}` : "default";
}

export function accountIdFromScope(scope: string): string | null {
  return scope.startsWith("account:") && scope.length > 8 ? scope.slice(8) : null;
}
