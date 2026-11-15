// FCM is an opaque wakeup channel. Only the paired Android device can open
// an approval's sealed record; no page, mail, recipient or amount is sent here.
import type { PushResult, PushTarget, Sealed } from "./push";

export interface Fcm {
  silent(target: PushTarget, approval?: string): Promise<PushResult>;
  alert(target: PushTarget, sealed: Sealed | null, id?: string): Promise<PushResult>;
}

export type FcmEnv = { FCM_PROJECT_ID?: string; FCM_CLIENT_EMAIL?: string; FCM_PRIVATE_KEY?: string };
export const FCM_BLOB_LIMIT = 3000;

/** Never log provider exceptions, credentials or payloads during delivery diagnosis. */
export function fcmFailureStage(error: unknown): "authorization" | "transport-or-key" {
  return error instanceof Error && ["FCM authorization is unavailable", "FCM authorization returned an invalid token"].includes(error.message)
    ? "authorization" : "transport-or-key";
}

export function fcmFromEnv(environment: unknown): Fcm | null {
  if (!environment || typeof environment !== "object") return null;
  const env = environment as FcmEnv;
  if (!env.FCM_PROJECT_ID || !env.FCM_CLIENT_EMAIL || !env.FCM_PRIVATE_KEY) return null;
  if (!/^[a-z][a-z0-9-]{4,61}$/.test(env.FCM_PROJECT_ID) || !/^[^\s@]+@[^\s@]+\.gserviceaccount\.com$/.test(env.FCM_CLIENT_EMAIL)) return null;
  return new GoogleFcm({ project: env.FCM_PROJECT_ID, email: env.FCM_CLIENT_EMAIL, privateKey: env.FCM_PRIVATE_KEY });
}

/** An invalid payload or a configuration error never revokes a newer registration. */
export function invalidatesFcmToken(result: PushResult): boolean {
  return result.status === 404 && result.reason === "UNREGISTERED";
}

export function fcmBody(target: PushTarget, kind: "sync" | "approval" | "withdraw", sealed: Sealed | null = null, id?: string): string {
  const data: Record<string, string> = { v: "1", kind };
  if (id) data.approval = id;
  if (sealed && sealed.blob.length <= FCM_BLOB_LIMIT) { data.n = sealed.name; data.b = sealed.blob; }
  return JSON.stringify({ message: {
    token: target.token,
    data,
    android: {
      priority: kind === "approval" ? "HIGH" : "NORMAL",
      ttl: kind === "sync" ? "300s" : "3600s",
      collapse_key: id ?? "sync",
      restricted_package_name: target.topic,
    },
  } });
}

type Configuration = { project: string; email: string; privateKey: string };
type Transport = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export class GoogleFcm implements Fcm {
  private key: Promise<CryptoKey> | null = null;
  private authorization: { value: string; expires: number } | null = null;
  private authorizing: Promise<string> | null = null;
  // Keep the platform fetch receiver, rather than calling it as a GoogleFcm method.
  constructor(private readonly config: Configuration, private readonly request: Transport = (input, init) => fetch(input, init), private readonly now: () => number = Date.now) {}

  async silent(target: PushTarget, approval?: string): Promise<PushResult> {
    return this.send(target, fcmBody(target, approval ? "withdraw" : "sync", null, approval));
  }
  async alert(target: PushTarget, sealed: Sealed | null, id?: string): Promise<PushResult> {
    return this.send(target, fcmBody(target, "approval", sealed, id));
  }
  private async send(target: PushTarget, body: string): Promise<PushResult> {
    if (target.env !== "fcm" || !/^[\x21-\x7e]{1,4096}$/.test(target.token) || !/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/.test(target.topic)) return { status: 400, reason: "INVALID_TARGET" };
    const response = await this.request(`https://fcm.googleapis.com/v1/projects/${this.config.project}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${await this.token()}`, "content-type": "application/json" },
      body,
    });
    if (response.ok) return { status: response.status };
    const value = await response.json().catch(() => null) as { error?: { status?: unknown; details?: { "@type"?: unknown; errorCode?: unknown }[] } } | null;
    const detail = value?.error?.details?.find(item => item["@type"] === "type.googleapis.com/google.firebase.fcm.v1.FcmError");
    const raw = detail?.errorCode ?? value?.error?.status;
    const reason = typeof raw === "string" && /^[A-Z_]{1,64}$/.test(raw) ? raw : undefined;
    if (response.status === 401) this.authorization = null;
    return { status: response.status, ...(reason ? { reason } : {}) };
  }
  private async token(): Promise<string> {
    if (this.authorization && this.authorization.expires > this.now()) return this.authorization.value;
    if (this.authorizing) return this.authorizing;
    this.authorizing = this.authorize();
    try { return await this.authorizing; } finally { this.authorizing = null; }
  }
  private async authorize(): Promise<string> {
    const seconds = Math.floor(this.now() / 1000);
    const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const claims = base64url(JSON.stringify({
      iss: this.config.email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: seconds,
      exp: seconds + 3600,
    }));
    const input = `${header}.${claims}`;
    this.key ??= importPrivateKey(this.config.privateKey);
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await this.key, new TextEncoder().encode(input));
    const assertion = `${input}.${base64url(new Uint8Array(signature))}`;
    const response = await this.request("https://oauth2.googleapis.com/token", {
      method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
    });
    if (!response.ok) throw new Error("FCM authorization is unavailable");
    const result = await response.json() as { access_token?: unknown; expires_in?: unknown };
    if (typeof result.access_token !== "string" || !result.access_token || typeof result.expires_in !== "number" || !Number.isFinite(result.expires_in) || result.expires_in < 120) throw new Error("FCM authorization returned an invalid token");
    this.authorization = { value: result.access_token, expires: this.now() + (Math.min(result.expires_in, 3600) - 60) * 1000 };
    return result.access_token;
  }
}

function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/\\n/g, "\n").replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s/g, "");
  const bytes = Uint8Array.from(atob(body), char => char.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", bytes, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}
function base64url(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
