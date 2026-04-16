// APNs HTTP/2 push client for Cloudflare Workers.
// Uses JWT provider token authentication.

interface APNsConfig {
  keyId: string;
  teamId: string;
  p8Key: string; // PEM-formatted ECDSA P-256 key
  bundleId: string;
}

export interface APNsPayload {
  alert?: { title: string; body: string };
  sound?: string;
  contentAvailable?: boolean;
  customData?: Record<string, unknown>;
}

// Cache JWT for up to 50 minutes (APNs limit is 1 hour)
let cachedJWT: { token: string; expires: number } | null = null;

async function signJWT(config: APNsConfig): Promise<string> {
  if (cachedJWT && Date.now() < cachedJWT.expires) return cachedJWT.token;

  const header = { alg: "ES256", kid: config.keyId };
  const payload = { iss: config.teamId, iat: Math.floor(Date.now() / 1000) };

  const b64url = (obj: unknown) => {
    const s = btoa(JSON.stringify(obj));
    return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const signingInput = `${b64url(header)}.${b64url(payload)}`;

  // Parse P-256 PEM
  const pemBody = config.p8Key
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const pkcs8 = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const token = `${signingInput}.${sigB64}`;
  cachedJWT = { token, expires: Date.now() + 50 * 60 * 1000 };
  return token;
}

export async function sendAPNs(
  deviceToken: string,
  payload: APNsPayload,
  config: APNsConfig
): Promise<{ ok: boolean; status: number; error?: string }> {
  const jwt = await signJWT(config);

  const apsBody: Record<string, unknown> = { aps: {} };
  const aps = apsBody.aps as Record<string, unknown>;
  if (payload.alert) aps.alert = payload.alert;
  if (payload.sound) aps.sound = payload.sound;
  if (payload.contentAvailable) aps["content-available"] = 1;
  if (payload.customData) Object.assign(apsBody, payload.customData);

  const resp = await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "content-type": "application/json",
    },
    body: JSON.stringify(apsBody),
  });

  if (resp.ok) return { ok: true, status: resp.status };
  const errText = await resp.text();
  return { ok: false, status: resp.status, error: errText };
}
