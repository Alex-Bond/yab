import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_BODY, MAX_PENDING } from "../src/webpush";
import { Client, call } from "./helpers";

const ORIGIN = "https://sync.test";
let counter = 0;

function newBox(): { id: string; secret: string } {
  counter += 1;
  return {
    id: `box${counter.toString().padStart(4, "0")}_${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 40),
    secret: crypto.randomUUID() + crypto.randomUUID(),
  };
}

async function open(): Promise<{ id: string; secret: string }> {
  const box = newBox();
  const res = await call(`/v1/webpush/boxes/${box.id}`, { method: "PUT", body: { secret: box.secret } });
  expect(res.status).toBe(201);
  return box;
}

async function subscribe(box: { id: string; secret: string }, vapid?: string): Promise<{ id: string; endpoint: string }> {
  const res = await call(`/v1/webpush/boxes/${box.id}/subs`, { method: "POST", token: box.secret, body: vapid ? { vapid } : {} });
  expect(res.status).toBe(201);
  return (await res.json()) as { id: string; endpoint: string };
}

// As a site's server sends: raw bytes, not JSON.
function send(endpoint: string, body: Uint8Array | null, headers: Record<string, string> = {}) {
  return SELF.fetch(ORIGIN + new URL(endpoint).pathname, {
    method: "POST",
    headers: { ttl: "60", ...(body ? { "content-encoding": "aes128gcm" } : {}), ...headers },
    body: body ?? undefined,
  });
}

async function messages(box: { id: string; secret: string }): Promise<any[]> {
  const res = await call(`/v1/webpush/boxes/${box.id}/messages`, { token: box.secret });
  expect(res.status).toBe(200);
  return ((await res.json()) as { messages: any[] }).messages;
}

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function vapidKeys() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { pair, key: b64url(raw) };
}

async function jwt(pair: CryptoKeyPair, claims: Record<string, unknown>): Promise<string> {
  const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const input = `${enc({ typ: "JWT", alg: "ES256" })}.${enc(claims)}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(input)));
  return `${input}.${b64url(signature)}`;
}

const now = () => Math.floor(Date.now() / 1000);
const payload = new Uint8Array([1, 2, 3, 4, 5]);

describe("web push boxes", () => {
  it("is opened once, with its secret", async () => {
    const box = newBox();
    const put = (secret: string) => call(`/v1/webpush/boxes/${box.id}`, { method: "PUT", body: { secret } });
    expect((await put("short")).status).toBe(400);
    expect((await put(box.secret)).status).toBe(201);
    expect((await put(box.secret)).status).toBe(204);
    expect((await put(box.secret + "x")).status).toBe(409);
    expect((await call(`/v1/webpush/boxes/${box.id}/messages`)).status).toBe(401);
    expect((await call(`/v1/webpush/boxes/${box.id}/messages`, { token: "wrong" })).status).toBe(401);
    expect((await call(`/v1/webpush/boxes/x/messages`, { token: box.secret })).status).toBe(400);
  });

  it("keeps what a site sends until Yab acks it", async () => {
    const box = await open();
    const sub = await subscribe(box);
    expect(sub.endpoint).toBe(`${ORIGIN}/v1/webpush/p/${box.id}.${sub.id}`);
    const res = await send(sub.endpoint, payload, { urgency: "high" });
    expect(res.status).toBe(201);
    expect(res.headers.get("location")).toMatch(/\/v1\/webpush\/m\/\d+$/);
    expect(res.headers.get("ttl")).toBe("60");
    const [m] = await messages(box);
    expect(m).toMatchObject({ sub: sub.id, enc: "aes128gcm", body: btoa("\x01\x02\x03\x04\x05"), urgency: "high" });
    expect((await call(`/v1/webpush/boxes/${box.id}/ack`, { method: "POST", token: box.secret, body: { ids: [m.id] } })).status).toBe(204);
    expect(await messages(box)).toEqual([]);
  });

  it("hands messages over a socket, the waiting ones first", async () => {
    const box = await open();
    const sub = await subscribe(box);
    await send(sub.endpoint, payload);
    const res = await call(`/v1/webpush/boxes/${box.id}/socket`, { token: box.secret, headers: { upgrade: "websocket" } });
    expect(res.status).toBe(101);
    const socket = new Client(res.webSocket!);
    const first = await socket.next();
    expect(first.t).toBe("msgs");
    expect(first.messages).toHaveLength(1);
    await send(sub.endpoint, new Uint8Array([9]));
    const live = await socket.next();
    expect(live.messages[0].body).toBe(btoa("\x09"));
    socket.send({ t: "ack", ids: [first.messages[0].id, live.messages[0].id] });
    await new Promise((r) => setTimeout(r, 100));
    expect(await messages(box)).toEqual([]);
  });

  it("says gone for a subscription it doesn't have", async () => {
    const box = await open();
    const sub = await subscribe(box);
    expect((await call(`/v1/webpush/boxes/${box.id}/subs/${sub.id}`, { method: "DELETE", token: box.secret })).status).toBe(204);
    expect((await send(sub.endpoint, payload)).status).toBe(410);
    expect((await send(`${ORIGIN}/v1/webpush/p/${box.id}.AAAAAAAAAAAAAAAAAAAAAA`, payload)).status).toBe(410);
    expect((await send(`${ORIGIN}/v1/webpush/p/nope.AAAAAAAAAAAAAAAAAAAAAA`, payload)).status).toBe(404);
  });

  it("checks what a site sends", async () => {
    const box = await open();
    const sub = await subscribe(box);
    expect((await send(sub.endpoint, new Uint8Array(MAX_BODY + 1))).status).toBe(413);
    expect((await send(sub.endpoint, payload, { "content-encoding": "gzip" })).status).toBe(415);
    expect((await send(sub.endpoint, payload, { "content-encoding": "aesgcm" })).status).toBe(400);
    expect((await send(sub.endpoint, payload, { "content-encoding": "aesgcm", encryption: "salt=abc", "crypto-key": "dh=def" })).status).toBe(201);
    expect((await send(sub.endpoint, payload, { ttl: "-1" })).status).toBe(400);
    expect((await send(sub.endpoint, payload, { topic: "not a topic!" })).status).toBe(400);
    expect((await send(sub.endpoint, payload, { urgency: "now" })).status).toBe(400);
    // A push with no payload at all is a push too.
    expect((await send(sub.endpoint, null)).status).toBe(201);
    const kept = await messages(box);
    expect(kept.map((m) => m.enc)).toEqual(["aesgcm", ""]);
    expect(kept[0]).toMatchObject({ encryption: "salt=abc", cryptoKey: "dh=def" });
  });

  it("drops a message that may not wait when no Yab is there, and lets a topic replace the last", async () => {
    const box = await open();
    const sub = await subscribe(box);
    expect((await send(sub.endpoint, payload, { ttl: "0" })).status).toBe(201);
    expect(await messages(box)).toEqual([]);
    await send(sub.endpoint, new Uint8Array([1]), { topic: "inbox" });
    await send(sub.endpoint, new Uint8Array([2]), { topic: "inbox" });
    const kept = await messages(box);
    expect(kept).toHaveLength(1);
    expect(kept[0].body).toBe(btoa("\x02"));
  });

  it(`keeps at most ${MAX_PENDING}, the newest`, async () => {
    const box = await open();
    const sub = await subscribe(box);
    for (let i = 0; i < MAX_PENDING + 5; i++) await send(sub.endpoint, new Uint8Array([i % 256]));
    const res = await call(`/v1/webpush/boxes/${box.id}/messages`, { token: box.secret });
    const first = ((await res.json()) as { messages: any[] }).messages[0];
    expect(first.body).toBe(btoa(String.fromCharCode(5)));
  });

  it("asks a site that gave a key for VAPID, signed by that key", async () => {
    const { pair, key } = await vapidKeys();
    const other = await vapidKeys();
    const box = await open();
    const sub = await subscribe(box, key);
    const good = await jwt(pair, { aud: ORIGIN, exp: now() + 3600, sub: "mailto:test@example.com" });

    expect((await send(sub.endpoint, payload)).status).toBe(401);
    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${good}, k=${other.key}` })).status).toBe(403);
    const forged = await jwt(other.pair, { aud: ORIGIN, exp: now() + 3600 });
    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${forged}, k=${key}` })).status).toBe(403);
    const elsewhere = await jwt(pair, { aud: "https://fcm.googleapis.com", exp: now() + 3600 });
    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${elsewhere}, k=${key}` })).status).toBe(403);
    const old = await jwt(pair, { aud: ORIGIN, exp: now() - 10 });
    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${old}, k=${key}` })).status).toBe(403);
    const long = await jwt(pair, { aud: ORIGIN, exp: now() + 3 * 24 * 3600 });
    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${long}, k=${key}` })).status).toBe(403);

    expect((await send(sub.endpoint, payload, { authorization: `vapid t=${good}, k=${key}` })).status).toBe(201);
    // The drafts' way, as older libraries still send it.
    expect((await send(sub.endpoint, payload, { authorization: `WebPush ${good}`, "crypto-key": `p256ecdsa=${key}` })).status).toBe(201);
    expect(await messages(box)).toHaveLength(2);
  });

  it("refuses a key that isn't a P-256 point, and a box can be emptied", async () => {
    const box = await open();
    const res = await call(`/v1/webpush/boxes/${box.id}/subs`, { method: "POST", token: box.secret, body: { vapid: "A".repeat(87) } });
    expect(res.status).toBe(400);
    const sub = await subscribe(box);
    expect((await call(`/v1/webpush/boxes/${box.id}`, { method: "DELETE", token: box.secret })).status).toBe(204);
    expect((await send(sub.endpoint, payload)).status).toBe(410);
    // Emptied, the id can be opened again.
    expect((await call(`/v1/webpush/boxes/${box.id}`, { method: "PUT", body: { secret: box.secret } })).status).toBe(201);
  });
});
