// Shared Cloudflare TURN credential logic used by /room/:code/ice and /rv/ice.
export const TURN_TTL_SECONDS = 900; // 15 minutes

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export function stunOnlyServers(): IceServer[] {
  return [
    { urls: ["stun:stun.cloudflare.com:3478"] },
    { urls: ["stun:stun.l.google.com:19302"] },
  ];
}

/** STUN + short-lived Cloudflare TURN credentials; falls back to STUN only. */
export async function buildIceServers(env: { TURN_KEY_ID?: string; TURN_API_TOKEN?: string }): Promise<IceServer[]> {
  if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) return stunOnlyServers();
  try {
    const turnResponse = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.TURN_API_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
      },
    );
    if (!turnResponse.ok) throw new Error(`TURN API returned ${turnResponse.status}`);
    const turnData = (await turnResponse.json()) as {
      iceServers: { urls: string[]; username: string; credential: string } | { urls: string[]; username: string; credential: string }[];
    };
    // Cloudflare API returns iceServers as an object; normalize to array
    const rawServers = Array.isArray(turnData.iceServers) ? turnData.iceServers : [turnData.iceServers];
    // All variants share the same creds
    const creds = rawServers[0];
    return [
      { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] },
      {
        urls: [
          "turn:turn.cloudflare.com:3478?transport=udp",
          "turn:turn.cloudflare.com:3478?transport=tcp",
          "turns:turn.cloudflare.com:5349?transport=tcp",
        ],
        username: creds.username,
        credential: creds.credential,
      },
    ];
  } catch {
    return stunOnlyServers();
  }
}
