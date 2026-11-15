import { DurableObject } from "cloudflare:workers";
import { base64url, bearer, empty, fail, isString, json, readJson, sameDigest, sha256hex } from "./util";

// Web Push for Yab (docs/site-notifications.md, "Closed sites"): the push
// service a site's server sends to, the way sites send to FCM for
// Chromium browsers and to Apple for WebKit ones. Each Yab is a box, named by an id it made and opened
// with a secret only it knows. A site's subscription is an endpoint in the
// box; what a site sends there is encrypted to keys only that Yab holds
// (RFC 8291), so the box keeps and hands on bytes it can't read, and never
// learns which site a subscription is for.
//
// The site's side is RFC 8030: POST /v1/webpush/p/{box}.{sub} with TTL,
// Content-Encoding aes128gcm (or the older aesgcm with its Encryption and
// Crypto-Key headers), Topic and Urgency, signed with VAPID (RFC 8292) when
// the subscription named an applicationServerKey. Yab's side: a WebSocket
// that hands each message over as it comes and takes acks, and the same
// over HTTP for a Yab catching up.

export const BOX_ID = /^[A-Za-z0-9_-]{22,64}$/;
export const SUB_ID = /^[A-Za-z0-9_-]{22}$/;
// RFC 8030 asks a push service for at least 4096 octets of payload; a
// little over that, for the record's own header and tag.
export const MAX_BODY = 5120;
// Four weeks, as FCM keeps a message at most.
export const MAX_TTL = 28 * 24 * 60 * 60;
export const MAX_PENDING = 200;
export const MAX_SUBS = 1000;
const TOPIC = /^[A-Za-z0-9_-]{1,32}$/;
const URGENCY = new Set(["very-low", "low", "normal", "high"]);
const KEY = /^[A-Za-z0-9_-]{86,88}$/;
// What a VAPID token may claim past now, RFC 8292's day and some slack for clocks.
const VAPID_AHEAD = 24 * 60 * 60 + 5 * 60;

export type Message = {
  id: number;
  sub: string;
  enc: "aes128gcm" | "aesgcm" | "";
  body: string;
  encryption?: string;
  cryptoKey?: string;
  urgency: string;
  at: number;
};

type Row = {
  id: number; sub: string; enc: string; body: string; encryption: string; crypto_key: string;
  urgency: string; created: number;
};

export class PushBox extends DurableObject<Cloudflare.Env> {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.schema();
    // A socket's keepalive, answered without waking the object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private schema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS subs (id TEXT PRIMARY KEY, vapid TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS msgs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, sub TEXT NOT NULL, topic TEXT NOT NULL, enc TEXT NOT NULL,
        body TEXT NOT NULL, encryption TEXT NOT NULL, crypto_key TEXT NOT NULL, urgency TEXT NOT NULL,
        created INTEGER NOT NULL, expires INTEGER NOT NULL);`);
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  private meta(key: string): string | null {
    const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? row.value : null;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    const site = /^\/v1\/webpush\/p\/([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(path);
    if (site) {
      if (method !== "POST") return fail(405, "method");
      return this.receive(request, site[2], url.origin);
    }

    const box = /^\/v1\/webpush\/boxes\/[^/]+(\/.*)?$/.exec(path);
    if (!box) return fail(404, "not-found");
    const rest = box[1] ?? "";

    if (rest === "" && method === "PUT") return this.open(request);
    if (!(await this.authorized(request))) return fail(401, "unauthorized");

    if (rest === "" && method === "DELETE") {
      for (const ws of this.ctx.getWebSockets()) close(ws, 4003, "deleted");
      await this.ctx.storage.deleteAll();
      this.schema();
      return empty();
    }
    if (rest === "/socket" && method === "GET") return this.upgrade(request);
    if (rest === "/subs" && method === "POST") return this.subscribe(request, path, url.origin);
    const sub = /^\/subs\/([^/]+)$/.exec(rest);
    if (sub && method === "DELETE") {
      this.sql.exec("DELETE FROM subs WHERE id = ?", sub[1]);
      this.sql.exec("DELETE FROM msgs WHERE sub = ?", sub[1]);
      return empty();
    }
    if (rest === "/messages" && method === "GET") return json({ messages: this.pending() });
    if (rest === "/ack" && method === "POST") {
      const body = await readJson(request);
      if (!Array.isArray(body?.ids)) return fail(400, "bad");
      this.ack(body.ids);
      return empty();
    }
    return fail(404, "not-found");
  }

  // MARK: Yab's side

  // The first PUT names the box's secret; the same secret again is fine,
  // another is refused: the id is taken.
  private async open(request: Request): Promise<Response> {
    const body = await readJson(request);
    if (!isString(body?.secret, 256) || body.secret.length < 32) return fail(400, "bad");
    const hash = await sha256hex(body.secret);
    const known = this.meta("secret");
    if (known == null) {
      this.sql.exec("INSERT INTO meta (key, value) VALUES ('secret', ?)", hash);
      return new Response(null, { status: 201 });
    }
    return sameDigest(known, hash) ? empty() : fail(409, "taken");
  }

  private async authorized(request: Request): Promise<boolean> {
    const known = this.meta("secret");
    const token = bearer(request);
    if (!known || !token) return false;
    return sameDigest(known, await sha256hex(token));
  }

  // {"vapid": base64url of the site's applicationServerKey, if it gave one}
  // → {"id", "endpoint"}.
  private async subscribe(request: Request, path: string, origin: string): Promise<Response> {
    const body = await readJson(request);
    const vapid = body?.vapid == null || body.vapid === "" ? "" : body.vapid;
    if (vapid !== "" && (!isString(vapid, 100) || !KEY.test(vapid) || (await importVapid(vapid)) == null)) {
      return fail(400, "bad", "applicationServerKey is not a P-256 public key");
    }
    const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM subs").toArray()[0].n;
    if (count >= MAX_SUBS) return fail(429, "too-many");
    const id = base64url(crypto.getRandomValues(new Uint8Array(16)));
    this.sql.exec("INSERT INTO subs (id, vapid, created) VALUES (?, ?, ?)", id, vapid, Date.now());
    const box = /^\/v1\/webpush\/boxes\/([^/]+)/.exec(path)![1];
    return json({ id, endpoint: `${origin}/v1/webpush/p/${box}.${id}` }, 201);
  }

  private upgrade(request: Request): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return fail(426, "bad", "expected a WebSocket upgrade");
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    const waiting = this.pending();
    if (waiting.length) server.send(JSON.stringify({ t: "msgs", messages: waiting }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    let msg: any = null;
    try {
      msg = typeof raw === "string" ? JSON.parse(raw) : null;
    } catch {
      msg = null;
    }
    if (msg?.t === "ack" && Array.isArray(msg.ids)) this.ack(msg.ids);
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    close(ws, code === 1005 ? 1000 : code, "bye");
  }

  private ack(ids: unknown[]) {
    for (const id of ids.slice(0, 500)) {
      if (Number.isSafeInteger(id)) this.sql.exec("DELETE FROM msgs WHERE id = ?", id);
    }
  }

  private pending(): Message[] {
    this.sql.exec("DELETE FROM msgs WHERE expires <= ?", Date.now());
    return this.sql
      .exec<Row>("SELECT id, sub, enc, body, encryption, crypto_key, urgency, created FROM msgs ORDER BY id LIMIT 100")
      .toArray()
      .map(message);
  }

  // MARK: the site's side

  private async receive(request: Request, sub: string, origin: string): Promise<Response> {
    if (!SUB_ID.test(sub)) return fail(404, "not-found");
    const row = this.sql.exec<{ vapid: string }>("SELECT vapid FROM subs WHERE id = ?", sub).toArray()[0];
    // Gone: the site should forget this subscription (RFC 8030 §7.3).
    if (!row) return fail(410, "gone");

    if (row.vapid !== "") {
      const refused = await checkVapid(request, row.vapid, origin);
      if (refused) return refused;
    }

    const header = request.headers.get("ttl");
    const ttl = header == null ? MAX_TTL : Number(header);
    if (!Number.isSafeInteger(ttl) || ttl < 0) return fail(400, "bad", "TTL must be a whole number of seconds");
    const kept = Math.min(ttl, MAX_TTL);

    const body = new Uint8Array(await request.arrayBuffer());
    if (body.length > MAX_BODY) return fail(413, "too-large");
    const encoding = (request.headers.get("content-encoding") ?? "").trim().toLowerCase();
    let enc: Message["enc"] = "";
    let encryption = "";
    let cryptoKey = "";
    if (body.length > 0) {
      if (encoding === "aes128gcm") enc = "aes128gcm";
      else if (encoding === "aesgcm") {
        enc = "aesgcm";
        encryption = request.headers.get("encryption") ?? "";
        cryptoKey = request.headers.get("crypto-key") ?? "";
        if (!/salt=/.test(encryption) || !/dh=/.test(cryptoKey)) return fail(400, "bad", "aesgcm needs Encryption and Crypto-Key");
      } else return fail(415, "unsupported", "Content-Encoding must be aes128gcm or aesgcm");
    }
    const topic = request.headers.get("topic") ?? "";
    if (topic !== "" && !TOPIC.test(topic)) return fail(400, "bad", "Topic is up to 32 URL-safe base64 characters");
    const urgency = (request.headers.get("urgency") ?? "normal").toLowerCase();
    if (!URGENCY.has(urgency)) return fail(400, "bad", "unknown Urgency");

    const sockets = this.ctx.getWebSockets();
    const now = Date.now();
    const created = (id: number) => new Response(null, {
      status: 201,
      headers: { location: `${origin}/v1/webpush/m/${id}`, ttl: String(kept) },
    });

    // A message that may not wait goes now or not at all.
    if (kept === 0 && sockets.length === 0) return created(0);

    if (topic !== "") this.sql.exec("DELETE FROM msgs WHERE sub = ? AND topic = ?", sub, topic);
    const id = this.sql
      .exec<{ id: number }>(
        `INSERT INTO msgs (sub, topic, enc, body, encryption, crypto_key, urgency, created, expires)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
        sub, topic, enc, encode(body), encryption, cryptoKey, urgency, now, now + Math.max(kept, 60) * 1000,
      )
      .toArray()[0].id;
    // The oldest go first once a box holds more than it should.
    this.sql.exec(
      "DELETE FROM msgs WHERE id IN (SELECT id FROM msgs ORDER BY id DESC LIMIT -1 OFFSET ?)", MAX_PENDING,
    );

    const sent = message({ id, sub, enc, body: encode(body), encryption, crypto_key: cryptoKey, urgency, created: now });
    for (const ws of sockets) {
      try {
        ws.send(JSON.stringify({ t: "msgs", messages: [sent] }));
      } catch {
        // A socket going away; the message waits for the next one.
      }
    }
    return created(id);
  }
}

function message(r: Row): Message {
  return {
    id: r.id, sub: r.sub, enc: r.enc as Message["enc"], body: r.body,
    ...(r.encryption ? { encryption: r.encryption } : {}),
    ...(r.crypto_key ? { cryptoKey: r.crypto_key } : {}),
    urgency: r.urgency, at: r.created,
  };
}

function close(ws: WebSocket, code: number, reason: string) {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}

function encode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function decode(text: string): Uint8Array | null {
  try {
    const s = text.replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(s + "=".repeat((4 - (s.length % 4)) % 4));
    return Uint8Array.from(raw, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function plain(text: string): string {
  return text.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importVapid(key: string): Promise<CryptoKey | null> {
  const bytes = decode(key);
  if (!bytes || bytes.length !== 65 || bytes[0] !== 4) return null;
  try {
    return await crypto.subtle.importKey("raw", bytes, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch {
    return null;
  }
}

// RFC 8292: "Authorization: vapid t=JWT, k=KEY", or the drafts' "WebPush JWT"
// with the key in Crypto-Key's p256ecdsa. The key must be the one the
// subscription was made with, the token signed by it, for this push
// service, and not past its day.
export async function checkVapid(request: Request, expected: string, origin: string): Promise<Response | null> {
  const auth = request.headers.get("authorization") ?? "";
  let token = "";
  let key = "";
  const vapid = /^vapid\s+(.*)$/i.exec(auth);
  if (vapid) {
    for (const part of vapid[1].split(",")) {
      const [name, ...value] = part.trim().split("=");
      if (name.trim().toLowerCase() === "t") token = value.join("=").trim();
      if (name.trim().toLowerCase() === "k") key = value.join("=").trim();
    }
  } else {
    const draft = /^(?:webpush|bearer)\s+(\S+)$/i.exec(auth);
    if (draft) token = draft[1];
    const keys = request.headers.get("crypto-key") ?? "";
    const found = /p256ecdsa=([A-Za-z0-9_+/=-]+)/.exec(keys);
    if (found) key = found[1];
  }
  if (!token || !key) return fail(401, "unauthorized", "this subscription needs VAPID");
  if (plain(key) !== plain(expected)) return fail(403, "forbidden", "not the applicationServerKey of this subscription");

  const parts = token.split(".");
  if (parts.length !== 3) return fail(401, "unauthorized", "bad VAPID token");
  const verifier = await importVapid(expected);
  const signature = decode(parts[2]);
  if (!verifier || !signature) return fail(401, "unauthorized", "bad VAPID token");
  const signed = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, verifier, signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!signed) return fail(403, "forbidden", "VAPID signature doesn't match");
  let claims: any = null;
  try {
    claims = JSON.parse(new TextDecoder().decode(decode(parts[1]) ?? new Uint8Array()));
  } catch {
    claims = null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (!claims || claims.aud !== origin) return fail(403, "forbidden", "VAPID audience is not this push service");
  if (!Number.isFinite(claims.exp) || claims.exp <= now || claims.exp > now + VAPID_AHEAD) {
    return fail(403, "forbidden", "VAPID token expired or claims too long");
  }
  return null;
}
