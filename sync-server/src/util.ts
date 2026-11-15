export const ACCOUNT_ID = /^[A-Za-z0-9_-]{16,64}$/;
export const HOST_ID = /^[A-Za-z0-9_-]{16,64}$/;
export const DEVICE_ID = /^[A-Za-z0-9_-]{1,64}$/;
export const MAX_NAME = 200;

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function fail(status: number, code: string, message?: string): Response {
  return json(message ? { error: code, message } : { error: code }, status);
}

export function empty(): Response {
  return new Response(null, { status: 204 });
}

export async function sha256hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function newToken(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

// Compares two equal-length hex digests without leaking where they differ.
export function sameDigest(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  return match ? match[1] : null;
}

export async function readJson(request: Request): Promise<any> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

export function isString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length <= max;
}
