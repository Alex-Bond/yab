import { env, runInDurableObject } from "cloudflare:test";
import { Client, call } from "./helpers";

export const ORIGIN = "https://sync.test";
let counter = 0;

export function newHostId(): string {
  counter += 1;
  return `host${counter.toString().padStart(4, "0")}_${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 40);
}

export async function registerHost(id: string, secret = "s3cret"): Promise<string> {
  const res = await call("/v1/hosts", { method: "POST", body: { id, secret, name: "Test Mac" } });
  if (res.status !== 200) throw new Error(`register ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

export async function connectHost(id: string, token: string): Promise<Client> {
  const res = await call(`/v1/hosts/${id}/socket`, { token, headers: { upgrade: "websocket" } });
  if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade ${res.status}`);
  return new Client(res.webSocket);
}

// Sends hello and waits until the server has handled it (a ping's pong
// comes after it, and after any queued calls).
export async function hello(mac: Client, assistants: string[]): Promise<any[]> {
  mac.send({ t: "hello", v: 1, assistants });
  return flush(mac);
}

// Returns every message before the pong.
export async function flush(mac: Client): Promise<any[]> {
  mac.send({ t: "ping" });
  const before: any[] = [];
  for (;;) {
    const m = await mac.next();
    if (m.t === "pong") return before;
    before.push(m);
  }
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function pkce() {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: b64url(new Uint8Array(digest)) };
}

export function form(params: Record<string, string>) {
  return {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params).toString(),
  };
}

export async function registerClient(name = "Claude", redirect = "https://claude.ai/api/mcp/auth_callback") {
  const res = await call("/oauth/register", { method: "POST", body: { client_name: name, redirect_uris: [redirect] } });
  if (res.status !== 201) throw new Error(`client ${res.status} ${await res.text()}`);
  return (await res.json()) as { client_id: string; client_name: string; redirect_uris: string[] };
}

export async function authorize(clientId: string, redirect: string, challenge: string, state = "st4te") {
  const q = new URLSearchParams({
    response_type: "code", client_id: clientId, redirect_uri: redirect,
    code_challenge: challenge, code_challenge_method: "S256", state,
  });
  const res = await call(`/oauth/authorize?${q}`, { redirect: "manual" });
  const page = await res.text();
  const code = /<div class="code"[^>]*>([A-Z0-9-]+)<\/div>/.exec(page)?.[1];
  const link = /const link="([^"]+)"/.exec(page)?.[1];
  return { res, page, code: code!, link: link! };
}

export async function decide(hostId: string, token: string, link: string, allow: boolean, assistant?: { id: string; name: string }) {
  return call(`/v1/hosts/${hostId}/links/decide`, { method: "POST", token, body: { link, allow, assistant } });
}

// The whole authorization_code flow: returns the client's tokens.
export async function linkAssistant(hostId: string, hostToken: string, assistant: string, name = "Claude") {
  const redirect = "https://claude.ai/api/mcp/auth_callback";
  const client = await registerClient(name, redirect);
  const { verifier, challenge } = await pkce();
  const { code, link } = await authorize(client.client_id, redirect, challenge);
  const look = await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code } });
  if (look.status !== 200) throw new Error(`lookup ${look.status}`);
  const decided = await decide(hostId, hostToken, link, true, { id: assistant, name });
  if (decided.status !== 204) throw new Error(`decide ${decided.status}`);
  const status = (await (await call(`/oauth/link/${link}`)).json()) as any;
  const authCode = new URL(status.redirect).searchParams.get("code")!;
  const res = await call("/oauth/token", form({
    grant_type: "authorization_code", code: authCode, code_verifier: verifier,
    redirect_uri: redirect, client_id: client.client_id,
  }));
  if (res.status !== 200) throw new Error(`token ${res.status} ${await res.text()}`);
  const tokens = (await res.json()) as any;
  return { clientId: client.client_id, access: tokens.access_token as string, refresh: tokens.refresh_token as string };
}

export function mcp(token: string | undefined, body: unknown) {
  return call("/mcp", { method: "POST", token, body });
}

export function directoryStub() {
  return env.DIRECTORY.get(env.DIRECTORY.idFromName("directory"));
}

export function hostStub(id: string) {
  return env.HOST.get(env.HOST.idFromName(id));
}

export async function directorySql(query: string, ...args: unknown[]) {
  await runInDurableObject(directoryStub(), async (_instance, state) => {
    state.storage.sql.exec(query, ...args);
  });
}

export function toolText(answer: any): any {
  return JSON.parse(answer.result.content[0].text);
}
