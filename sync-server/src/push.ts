// Silent pushes to iPhones in the back (R2, Phone/Reference/digest/sync-ios.md):
// when the account changes and a device with a push token has no socket, the
// account's Durable Object asks APNs to wake it ("content-available", priority
// 5, collapsed), so its line catches up before it is opened. A hint only: the
// iPhone catches up on its own when it comes to the front.
//
// A question a person must answer (an agent's yes on the Mac, sealed in the
// journal) goes as an alert instead, at once, to a device that asked for
// them: generic words, with the question's sealed record riding along for
// the iPhone's notification extension to open and show (the Worker never
// can). Too big for APNs's 4 KB, it goes without, and the app shows it.
//
// The key is the team's APNs auth key (.p8), in Worker secrets: APNS_KEY (the
// PEM's text), APNS_KEY_ID, APNS_TEAM. Without them nothing is sent. APNS_HOST
// sends every push to one place instead of Apple's (local checks).

export type PushTarget = { device: string; token: string; env: string; topic: string };

// APNs 410 timestamps use milliseconds since the Unix epoch.
export type PushResult = { status: number; reason?: string; timestamp?: number };

// A sealed record as stored: its opaque name and its base64 blob.
export type Sealed = { name: string; blob: string };

// Room left in APNs's 4096 bytes for a record's blob, past the rest.
export const ALERT_BLOB = 3500;

export interface Apns {
  // Preserve Apple's reason: a request/configuration error is not a revoked token.
  silent(target: PushTarget, approval?: string): Promise<PushResult>;
  alert?(target: PushTarget, sealed: Sealed | null, id?: string): Promise<PushResult>;
}

export function alertBody(sealed: Sealed | null): string {
  const aps = {
    alert: { title: "Yab", body: "Needs your answer" },
    // The question's own two notes in the iPhone app (ask.caf), and through
    // Focus: someone waits. Builds without the file play the default sound.
    sound: "ask.caf",
    "interruption-level": "time-sensitive",
    "mutable-content": 1,
    "content-available": 1,
    "thread-id": "approval",
  };
  const ride = sealed && sealed.blob.length <= ALERT_BLOB ? { yab: { n: sealed.name, b: sealed.blob } } : {};
  return JSON.stringify({ aps, ...ride });
}

export function invalidatesToken(result: PushResult): boolean {
  return (result.status === 410 && result.reason === "Unregistered") ||
    (result.status === 400 && result.reason === "BadDeviceToken");
}

export async function readPushResult(response: Response): Promise<PushResult> {
  if (response.ok) return { status: response.status };
  const body: unknown = await response.json().catch(() => null);
  const reason = body && typeof body === "object" && "reason" in body ? body.reason : undefined;
  const timestamp = body && typeof body === "object" && "timestamp" in body ? body.timestamp : undefined;
  return {
    status: response.status,
    ...(typeof reason === "string" && /^[A-Za-z]{1,64}$/.test(reason) ? { reason } : {}),
    ...(response.status === 410 && typeof timestamp === "number" && Number.isSafeInteger(timestamp) && timestamp >= 0 ? { timestamp } : {}),
  };
}

type ApnsEnv = { APNS_KEY?: string; APNS_KEY_ID?: string; APNS_TEAM?: string; APNS_HOST?: string };

export function apnsFromEnv(env: unknown): Apns | null {
  const e = env as ApnsEnv;
  if (!e.APNS_KEY || !e.APNS_KEY_ID || !e.APNS_TEAM) return null;
  return new AppleApns(e.APNS_KEY, e.APNS_KEY_ID, e.APNS_TEAM, e.APNS_HOST);
}

const HOSTS: Record<string, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

class AppleApns implements Apns {
  private jwt: { value: string; made: number } | null = null;
  private key: Promise<CryptoKey> | null = null;

  constructor(
    private readonly pem: string,
    private readonly keyID: string,
    private readonly team: string,
    private readonly host?: string,
  ) {}

  async silent(target: PushTarget, approval?: string): Promise<PushResult> {
    const base = this.host ?? HOSTS[target.env] ?? HOSTS.production;
    const response = await fetch(`${base}/3/device/${target.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.token()}`,
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-topic": target.topic,
        "apns-collapse-id": approval ?? "sync",
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { "content-available": 1 } }),
    });
    return readPushResult(response);
  }

  async alert(target: PushTarget, sealed: Sealed | null, id?: string): Promise<PushResult> {
    const base = this.host ?? HOSTS[target.env] ?? HOSTS.production;
    const response = await fetch(`${base}/3/device/${target.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.token()}`,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": target.topic,
        // The question's id: the phone's own notification of it replaces this one.
        ...(id ? { "apns-id": id, "apns-collapse-id": id } : {}),
        "content-type": "application/json",
      },
      body: alertBody(sealed),
    });
    return readPushResult(response);
  }

  // APNs takes a provider token for up to an hour and refuses one remade
  // more often than every 20 minutes: made again after 50.
  private async token(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.made < 50 * 60) return this.jwt.value;
    const header = b64url(JSON.stringify({ alg: "ES256", kid: this.keyID }));
    const claims = b64url(JSON.stringify({ iss: this.team, iat: now }));
    const input = `${header}.${claims}`;
    this.key ??= importKey(this.pem);
    // WebCrypto signs ECDSA as r || s, which is what a JWS wants.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await this.key, new TextEncoder().encode(input));
    const value = `${input}.${b64url(new Uint8Array(signature))}`;
    this.jwt = { value, made: now };
    return value;
  }
}

function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

function b64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
