import { DurableObject } from "cloudflare:workers";
import { Apns, PushTarget, Sealed, apnsFromEnv, invalidatesToken } from "./push";
import {
  DEVICE_ID,
  MAX_NAME,
  bearer,
  empty,
  fail,
  isString,
  json,
  newToken,
  readJson,
  sameDigest,
  sha256hex,
} from "./util";
import { devicePlatform } from "./census";
import { Fcm, fcmFailureStage, fcmFromEnv, invalidatesFcmToken } from "./fcm";

export const MAX_BLOB = 96 * 1024;
// Agent chats share the sealed journal with tabs and approval requests.
// A busy real profile exceeds 50 MiB before its questions can be published.
export const MAX_ACCOUNT = 250 * 1024 * 1024;
export const BATCH = 500;
// Keeps one catch-up message well under the WebSocket message limit.
const BATCH_BYTES = 4 * 1024 * 1024;
const MAX_CHANGES = 500;
const MAX_PRESENCE = 8 * 1024;
const SEEN_EVERY = 60 * 1000;
// The census (src/census.ts) hears of the account at most this often while
// its devices only come and go; a device added or removed tells it at once.
const CENSUS_EVERY = 60 * 60 * 1000;
// A device not heard from in this long isn't counted in the census.
const CENSUS_GONE = 30 * 24 * 3600 * 1000;
// A device without a socket hears of changes at most once a minute.
export const PUSH_EVERY = 60 * 1000;
// A question for a person goes at once; a burst of them, every 5 seconds.
export const ALERT_EVERY = 5 * 1000;
const PUSH_TOKEN = /^[0-9a-f]{16,200}$/;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const REGISTER_MISSES = 5;
const REGISTER_WINDOW = 10 * 60 * 1000;

type Attachment = { device: string; ready: boolean; androidSync?: number };
type Item = { name: string; version: number; seq: number; blob: string };
type Rejected = { name: unknown; code: string };
type PendingPush = { target: PushTarget; registeredAt: number; revision: string; sealed?: Sealed | null; id?: string; withdraw?: boolean };
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export class Account extends DurableObject<Cloudflare.Env> {
  // Where silent pushes go: APNs with the Worker's key, or nowhere without
  // one. Tests put a recorder here.
  apns: Apns | null;
  fcm: Fcm | null;

  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.schema();
    this.apns = apnsFromEnv(env);
    this.fcm = fcmFromEnv(env);
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  private schema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS records (
        name TEXT PRIMARY KEY, version INTEGER NOT NULL, seq INTEGER NOT NULL,
        blob TEXT NOT NULL, size INTEGER NOT NULL, updated INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS records_seq ON records (seq);
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, model TEXT NOT NULL,
        token_hash TEXT NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS presence (device TEXT PRIMARY KEY, blob TEXT NOT NULL, at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS approval_withdrawals (
        device TEXT NOT NULL, question TEXT NOT NULL, at INTEGER NOT NULL,
        PRIMARY KEY (device, question));
      CREATE TABLE IF NOT EXISTS push (
        device TEXT PRIMARY KEY, token TEXT NOT NULL, env TEXT NOT NULL, topic TEXT NOT NULL,
        last INTEGER NOT NULL DEFAULT 0, registered_at INTEGER NOT NULL DEFAULT 0,
        revision TEXT NOT NULL DEFAULT '', alerts INTEGER NOT NULL DEFAULT 0, alert_last INTEGER NOT NULL DEFAULT 0);`);
    // Existing accounts keep their registrations when these columns are added.
    const columns = new Set(this.sql.exec<{ name: string }>("PRAGMA table_info(push)").toArray().map((row) => row.name));
    if (!columns.has("registered_at")) this.sql.exec("ALTER TABLE push ADD COLUMN registered_at INTEGER NOT NULL DEFAULT 0");
    if (!columns.has("revision")) this.sql.exec("ALTER TABLE push ADD COLUMN revision TEXT NOT NULL DEFAULT ''");
    if (!columns.has("alerts")) this.sql.exec("ALTER TABLE push ADD COLUMN alerts INTEGER NOT NULL DEFAULT 0");
    if (!columns.has("alert_last")) this.sql.exec("ALTER TABLE push ADD COLUMN alert_last INTEGER NOT NULL DEFAULT 0");
    // An old cached token proves account membership, never upgraded client semantics.
    const devices = new Set(this.sql.exec<{ name: string }>("PRAGMA table_info(devices)").toArray().map((row) => row.name));
    if (!devices.has("platform")) this.sql.exec("ALTER TABLE devices ADD COLUMN platform TEXT NOT NULL DEFAULT ''");
    if (!devices.has("form_factor")) this.sql.exec("ALTER TABLE devices ADD COLUMN form_factor TEXT NOT NULL DEFAULT ''");
    if (!devices.has("android_sync")) this.sql.exec("ALTER TABLE devices ADD COLUMN android_sync INTEGER NOT NULL DEFAULT 0");
  }

  private meta(key: string): string | null {
    const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? row.value : null;
  }

  private setMeta(key: string, value: string | number) {
    this.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, String(value));
  }

  private num(key: string): number {
    return Number(this.meta(key) ?? 0);
  }

  // HTTP

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname.replace(/^\/v1\/accounts\/[^/]+/, "");
    const method = request.method;

    if (path === "/devices" && method === "POST") return this.register(request);

    const device = await this.authenticate(request);
    if (!device) return fail(401, "unauthorized");

    if (path === "/socket" && method === "GET") return this.upgrade(request, device);
    if (path === "/devices" && method === "GET") return this.listDevices();
    if (path === "" && method === "DELETE") return this.deleteAccount();
    const removal = /^\/devices\/([^/]+)$/.exec(path);
    if (removal && method === "DELETE") return this.revoke(decodeURIComponent(removal[1]));
    const push = /^\/devices\/([^/]+)\/push$/.exec(path);
    if (push) {
      // A device says where its own pushes go, never another's.
      if (decodeURIComponent(push[1]) !== device) return fail(403, "not-yours");
      if (method === "PUT") return this.setPush(request, device);
      if (method === "DELETE") {
        this.sql.exec("DELETE FROM push WHERE device = ?", device);
        return empty();
      }
    }
    return fail(404, "not-found");
  }

  // A device's APNs token for silent pushes while it has no socket (an
  // iPhone in the back): {"token": hex, "env": "sandbox"|"production", "topic": bundle id,
  // "alerts": true when it shows questions as alerts (its notifications allowed)}.
  private async setPush(request: Request, device: string): Promise<Response> {
    const body = await readJson(request);
    const firebase = body?.env === "fcm";
    const validToken = firebase
      ? typeof body?.token === "string" && /^[\x21-\x7E]{16,4096}$/.test(body.token)
      : isString(body?.token, 200) && PUSH_TOKEN.test(body.token);
    if (
      !validToken ||
      (body.env !== "sandbox" && body.env !== "production" && !firebase) ||
      !isString(body.topic, MAX_NAME) || body.topic.length === 0 ||
      (body.alerts !== undefined && typeof body.alerts !== "boolean")
    ) {
      return fail(400, "bad");
    }
    if (firebase) {
      const owner = this.sql.exec<{ platform: string; android_sync: number }>("SELECT platform, android_sync FROM devices WHERE id = ?", device).toArray()[0];
      if (owner?.platform !== "android" || owner.android_sync < 1 || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(body.topic)) {
        return fail(400, "bad");
      }
    }
    this.sql.exec(
      `INSERT INTO push (device, token, env, topic, last, registered_at, revision, alerts) VALUES (?, ?, ?, ?, 0, ?, ?, ?)
       ON CONFLICT (device) DO UPDATE SET token = excluded.token, env = excluded.env, topic = excluded.topic,
       registered_at = excluded.registered_at, revision = excluded.revision, alerts = excluded.alerts`,
      device, body.token, body.env, body.topic, Date.now(), crypto.randomUUID(), body.alerts === true ? 1 : 0,
    );
    return empty();
  }

  private async register(request: Request): Promise<Response> {
    const body = await readJson(request);
    const d = body?.device;
    if (
      !isString(body?.secret, 512) || body.secret.length === 0 ||
      !isString(d?.id, 64) || !DEVICE_ID.test(d.id) ||
      !isString(d.name, MAX_NAME) || !isString(d.model, MAX_NAME) ||
      (d.platform !== undefined && !["ios", "macos", "android"].includes(d.platform)) ||
      (d.formFactor !== undefined && !["phone", "tablet", "desktop"].includes(d.formFactor)) ||
      (d.androidSync !== undefined && (!Number.isSafeInteger(d.androidSync) || d.androidSync < 0 || d.androidSync > 100)) ||
      (d.androidSync > 0 && d.platform === undefined)
    ) {
      return fail(400, "bad");
    }

    const digest = await sha256hex(body.secret);
    const platform = devicePlatform(d.platform, d.model);
    const androidSync = d.androidSync ?? 0;
    const token = newToken();
    const tokenHash = await sha256hex(token);
    let denied: Response | undefined;
    // Admission and mutation are one transaction: concurrent legacy and Android joins
    // cannot each observe an account without the other's incompatible registration.
    this.ctx.storage.transactionSync(() => {
      const verifier = this.meta("verifier");
      if (verifier !== null && !sameDigest(verifier, digest)) { denied = this.refuseRegistration(); return; }
      const existing = this.sql.exec<{ revoked: number; platform: string }>("SELECT revoked, platform FROM devices WHERE id = ?", d.id).toArray()[0];
      if (existing?.revoked) { denied = fail(403, "revoked"); return; }
      if (existing?.platform && existing.platform !== "unknown" && existing.platform !== platform) {
        denied = fail(409, "device-platform-changed", "Use a new device identity for a different platform."); return;
      }
      const hasAndroid = this.hasAndroid();
      const incompatible = this.sql.exec("SELECT 1 FROM devices WHERE revoked = 0 AND id != ? AND android_sync < 1 LIMIT 1", d.id).toArray().length > 0;
      const incompatibleSocket = this.ctx.getWebSockets().some((ws) => {
        const attachment = ws.deserializeAttachment() as Attachment | null;
        return ws.readyState === WebSocket.OPEN && attachment?.device !== d.id && (attachment?.androidSync ?? 0) < 1;
      });
      if ((platform === "android" && (androidSync < 1 || incompatible || incompatibleSocket)) || (hasAndroid && androidSync < 1)) {
        denied = fail(409, "android-sync-upgrade-required", "Update every device before syncing with Android."); return;
      }
      if (verifier === null) { this.setMeta("verifier", digest); this.setMeta("seq", 0); this.setMeta("bytes", 0); }
      this.sql.exec(
        `INSERT INTO devices (id, name, model, token_hash, last_seen, revoked, platform, form_factor, android_sync) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET name = excluded.name, model = excluded.model,
           token_hash = excluded.token_hash, last_seen = excluded.last_seen, platform = excluded.platform,
           form_factor = excluded.form_factor, android_sync = excluded.android_sync`,
        d.id, d.name, d.model, tokenHash, Date.now(), platform, d.formFactor ?? "", androidSync,
      );
    });
    if (denied) return denied;
    // Re-registering invalidates the former software's live or hibernated socket too.
    for (const ws of this.ctx.getWebSockets(d.id)) close(ws, 4004, "device-registration-changed");
    this.setMeta("register_misses", 0);
    this.census(true);
    return json({ token });
  }

  // Only incorrect secrets are throttled. Checking this before the digest
  // would let five guesses lock the account's owner out of registration.
  private refuseRegistration(): Response {
    const now = Date.now();
    const began = this.num("register_misses_at");
    const misses = this.num("register_misses");
    if (misses > 0 && now - began < REGISTER_WINDOW) {
      if (misses >= REGISTER_MISSES) return fail(429, "later", "Too many wrong secrets; try again in a few minutes.");
      this.setMeta("register_misses", misses + 1);
    } else {
      this.setMeta("register_misses_at", now);
      this.setMeta("register_misses", 1);
    }
    return fail(403, "secret");
  }

  private async authenticate(request: Request): Promise<string | null> {
    const token = bearer(request);
    if (!token || this.meta("verifier") == null) return null;
    const row = this.sql
      .exec<{ id: string }>("SELECT id FROM devices WHERE token_hash = ? AND revoked = 0", await sha256hex(token))
      .toArray()[0];
    return row ? row.id : null;
  }

  private listDevices(): Response {
    const devices = this.sql
      .exec<{ id: string; name: string; model: string; last_seen: number; revoked: number; platform: string; form_factor: string; android_sync: number }>(
        "SELECT id, name, model, last_seen, revoked, platform, form_factor, android_sync FROM devices ORDER BY id",
      )
      .toArray()
      .map((r) => ({ id: r.id, name: r.name, model: r.model, platform: devicePlatform(r.platform, r.model), formFactor: r.form_factor || null,
        androidSync: r.android_sync, lastSeen: r.last_seen, revoked: r.revoked === 1 }));
    return json({ devices });
  }

  private revoke(id: string): Response {
    const found = this.sql.exec("SELECT 1 FROM devices WHERE id = ?", id).toArray().length > 0;
    if (!found) return fail(404, "not-found");
    this.sql.exec("UPDATE devices SET revoked = 1 WHERE id = ?", id);
    this.sql.exec("DELETE FROM presence WHERE device = ?", id);
    this.sql.exec("DELETE FROM push WHERE device = ?", id);
    this.census(true);
    for (const ws of this.ctx.getWebSockets(id)) close(ws, 4003, "revoked");
    return empty();
  }

  private async deleteAccount(): Promise<Response> {
    for (const ws of this.ctx.getWebSockets()) close(ws, 4003, "deleted");
    await this.ctx.storage.deleteAll();
    this.schema();
    const counts = this.env.CENSUS.get(this.env.CENSUS.idFromName("census"));
    this.ctx.waitUntil(counts.forget(this.ctx.id.toString()).catch(() => {}));
    return empty();
  }

  // Tells the census how many Macs and iPhones this account syncs: on a
  // device added or removed, else at most once an hour. Never fails a sync.
  private census(now: boolean) {
    const at = Date.now();
    if (!now && at - Number(this.meta("census_at") ?? 0) < CENSUS_EVERY) return;
    this.sql.exec("INSERT INTO meta (key, value) VALUES ('census_at', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", String(at));
    const devices = this.sql
      .exec<{ model: string; platform: string }>("SELECT model, platform FROM devices WHERE revoked = 0 AND last_seen >= ?", at - CENSUS_GONE)
      .toArray();
    const macs = devices.filter((d) => devicePlatform(d.platform, d.model) === "macos").length;
    const androids = devices.filter((d) => devicePlatform(d.platform, d.model) === "android").length;
    const phones = devices.filter((d) => ["ios", "android"].includes(devicePlatform(d.platform, d.model))).length;
    const counts = this.env.CENSUS.get(this.env.CENSUS.idFromName("census"));
    this.ctx.waitUntil(counts.note(this.ctx.id.toString(), macs, phones, at, androids).catch(() => {}));
  }

  private upgrade(request: Request, device: string): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return fail(426, "bad", "expected a WebSocket upgrade");
    }
    const row = this.sql.exec<{ android_sync: number }>("SELECT android_sync FROM devices WHERE id = ?", device).toArray()[0];
    const announced = request.headers.get("X-Yab-Android-Sync") === "1" ? 1 : 0;
    const androidSync = Math.min(announced, row?.android_sync ?? 0);
    if (this.hasAndroid() && androidSync < 1) return fail(409, "android-sync-upgrade-required");
    const [client, server] = Object.values(new WebSocketPair());
    // The tag lets revoke find a device's sockets after hibernation.
    this.ctx.acceptWebSocket(server, [device]);
    server.serializeAttachment({ device, ready: false, androidSync } satisfies Attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  // Socket

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const at = ws.deserializeAttachment() as Attachment;
    let msg: any;
    try {
      msg = typeof raw === "string" ? JSON.parse(raw) : null;
    } catch {
      msg = null;
    }
    if (!msg || typeof msg !== "object") return sendError(ws, "bad", "expected a JSON object");

    switch (msg.t) {
      case "hello":
        if (!Number.isSafeInteger(msg.cursor) || msg.cursor < 0 || msg.v !== 1) {
          return sendError(ws, "bad", "hello needs an integer cursor and v 1");
        }
        if (!this.touch(ws, at.device)) return;
        this.catchUp(ws, msg.cursor);
        // Where the others last said they were, right after the catch-up:
        // a phone that just connected knows the Mac's tab and whether it
        // sleeps without waiting for its next beat.
        this.sendPresence(ws, at.device);
        ws.serializeAttachment({ ...at, ready: true } satisfies Attachment);
        return;
      case "push":
        if (!isString(msg.id, 200) || !Array.isArray(msg.changes) || msg.changes.length > MAX_CHANGES) {
          return sendError(ws, "bad", "push needs an id and at most 500 changes");
        }
        if (!this.touch(ws, at.device)) return;
        // "alert": the name of the change in it that asks a person (an
        // agent's question), for an alert push instead of a silent one.
        return this.push(ws, msg.id, msg.changes, isString(msg.alert, MAX_NAME) ? msg.alert : undefined,
          typeof msg.alertID === "string" && UUID.test(msg.alertID) ? msg.alertID.toLowerCase() : undefined, msg.withdraw === true);
      case "presence":
        // A Mac says where it is about once a minute: that is also what
        // keeps its lastSeen fresh while nothing else changes.
        if (!this.touch(ws, at.device)) return;
        if (!isString(msg.blob, MAX_PRESENCE)) return sendError(ws, "bad", "presence needs a blob");
        // Kept, the last one per device (sealed: the server can't read it).
        this.sql.exec(
          "INSERT OR REPLACE INTO presence (device, blob, at) VALUES (?, ?, ?)",
          at.device, msg.blob, Date.now(),
        );
        return this.broadcast(ws, { t: "presence", device: at.device, blob: msg.blob });
      default:
        return sendError(ws, "bad", "unknown message");
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    close(ws, code === 1005 ? 1000 : code, reason);
  }

  // Updates last_seen at most once a minute; closes the socket if its device is gone.
  private touch(ws: WebSocket, device: string): boolean {
    const row = this.sql
      .exec<{ last_seen: number; revoked: number; android_sync: number }>("SELECT last_seen, revoked, android_sync FROM devices WHERE id = ?", device)
      .toArray()[0];
    if (!row || row.revoked) {
      close(ws, 4003, "revoked");
      return false;
    }
    if (this.hasAndroid() && (row.android_sync < 1 || ((ws.deserializeAttachment() as Attachment | null)?.androidSync ?? 0) < 1)) {
      close(ws, 4004, "android-sync-upgrade-required");
      return false;
    }
    const now = Date.now();
    if (now - row.last_seen >= SEEN_EVERY) {
      this.sql.exec("UPDATE devices SET last_seen = ? WHERE id = ?", now, device);
      this.census(false);
    }
    return true;
  }

  private catchUp(ws: WebSocket, cursor: number) {
    for (;;) {
      const rows = this.sql
        .exec<Item>("SELECT name, version, seq, blob FROM records WHERE seq > ? ORDER BY seq LIMIT ?", cursor, BATCH + 1)
        .toArray();
      const items: Item[] = [];
      let bytes = 0;
      for (const row of rows.slice(0, BATCH)) {
        if (items.length > 0 && bytes + row.blob.length > BATCH_BYTES) break;
        items.push(row);
        bytes += row.blob.length;
      }
      const more = rows.length > items.length;
      // Nothing new: the cursor is the server's current seq.
      cursor = items.length ? items[items.length - 1].seq : this.num("seq");
      ws.send(JSON.stringify({ t: "changes", items, cursor, more }));
      if (!more) return;
    }
  }

  private sendPresence(ws: WebSocket, device: string) {
    const rows = this.sql
      .exec<{ device: string; blob: string }>(
        `SELECT p.device, p.blob FROM presence p JOIN devices d ON d.id = p.device
         WHERE p.device != ? AND d.revoked = 0 ORDER BY p.at`,
        device,
      )
      .toArray();
    for (const row of rows) ws.send(JSON.stringify({ t: "presence", device: row.device, blob: row.blob }));
  }

  private push(ws: WebSocket, id: string, changes: any[], alert?: string, alertID?: string, withdraw = false) {
    const accepted: { name: string; version: number; seq: number }[] = [];
    const conflicts: { name: string; version: number; blob: string | null }[] = [];
    const rejected: Rejected[] = [];
    const items: Item[] = [];

    this.ctx.storage.transactionSync(() => {
      let seq = this.num("seq");
      let bytes = this.num("bytes");
      const now = Date.now();
      for (const c of changes) {
        const { name, base, blob } = c ?? {};
        if (
          !isString(name, MAX_NAME) || name.length === 0 ||
          !Number.isSafeInteger(base) || base < 0 ||
          typeof blob !== "string" || !BASE64.test(blob)
        ) {
          rejected.push({ name, code: "bad" });
          continue;
        }
        if (blob.length > MAX_BLOB) {
          rejected.push({ name, code: "too-big" });
          continue;
        }
        const current = this.sql
          .exec<{ version: number; size: number; blob: string }>("SELECT version, size, blob FROM records WHERE name = ?", name)
          .toArray()[0];
        const version = current?.version ?? 0;
        if (base !== version) {
          conflicts.push({ name, version, blob: current?.blob ?? null });
          continue;
        }
        const grown = bytes - (current?.size ?? 0) + blob.length;
        if (grown > MAX_ACCOUNT) {
          rejected.push({ name, code: "full" });
          continue;
        }
        bytes = grown;
        seq += 1;
        this.sql.exec(
          "INSERT OR REPLACE INTO records (name, version, seq, blob, size, updated) VALUES (?, ?, ?, ?, ?, ?)",
          name, version + 1, seq, blob, blob.length, now,
        );
        accepted.push({ name, version: version + 1, seq });
        items.push({ name, version: version + 1, seq, blob });
      }
      this.setMeta("seq", seq);
      this.setMeta("bytes", bytes);
    });

    for (const code of new Set(rejected.map((r) => r.code))) {
      const names = rejected.filter((r) => r.code === code).map((r) => r.name);
      sendError(ws, code, `${MESSAGES[code]}: ${names.join(", ")}`, id);
    }
    const reply: Record<string, unknown> = { t: "pushed", id, accepted, conflicts };
    if (rejected.length) reply.rejected = rejected;
    ws.send(JSON.stringify(reply));

    if (items.length) {
      this.broadcast(ws, { t: "changes", items, cursor: items[items.length - 1].seq, more: false });
      const from = (ws.deserializeAttachment() as Attachment).device;
      const asked = alert ? items.find((item) => item.name === alert) : undefined;
      const alerted = asked ? (withdraw
        ? (alertID ? this.withdrawTargets(from, alertID) : [])
        : this.alertTargets(from, { name: asked.name, blob: asked.blob }, alertID)) : [];
      const told = new Set(alerted.map((p) => p.target.device));
      const targets = [...alerted, ...this.pushTargets(from).filter((p) => !told.has(p.target.device))];
      if (targets.length) this.ctx.waitUntil(this.notify(targets));
    }
  }

  // Devices to wake: a push token, no socket open, not the sender, not
  // told within the last minute. Marked told now, so pushes in a burst
  // coalesce into one.
  private pushTargets(from: string): PendingPush[] {
    const now = Date.now();
    const rows = this.sql
      .exec<PushTarget & { last: number; registered_at: number; revision: string }>(
        `SELECT p.device, p.token, p.env, p.topic, p.last, p.registered_at, p.revision FROM push p JOIN devices d ON d.id = p.device
         WHERE p.device != ? AND d.revoked = 0`,
        from,
      )
      .toArray()
      .filter((r) => {
        const eligible = now - r.last >= PUSH_EVERY;
        const offline = this.ctx.getWebSockets(r.device).length === 0;
        if (r.env === "fcm" && (!eligible || !offline)) console.log("FCM wake deferred", { reason: !offline ? "open-socket" : "minute-window" });
        return eligible && offline;
      });
    for (const r of rows) this.sql.exec("UPDATE push SET last = ? WHERE device = ?", now, r.device);
    return rows.map(({ device, token, env, topic, registered_at, revision }) => ({
      target: { device, token, env, topic }, registeredAt: registered_at, revision,
    }));
  }

  // Devices to alert of a question: one that asked for alerts, a push token,
  // no socket open (a phone in front shows it already), not the sender, not
  // alerted in the last 5 seconds. Also marked told for the silent minute:
  // the alert wakes the app as well.
  private alertTargets(from: string, sealed: Sealed, id?: string): PendingPush[] {
    const now = Date.now();
    const rows = this.sql
      .exec<PushTarget & { alert_last: number; registered_at: number; revision: string }>(
        `SELECT p.device, p.token, p.env, p.topic, p.alert_last, p.registered_at, p.revision FROM push p JOIN devices d ON d.id = p.device
         WHERE p.device != ? AND d.revoked = 0 AND p.alerts = 1`,
        from,
      )
      .toArray()
      .filter((r) => now - r.alert_last >= ALERT_EVERY && this.ctx.getWebSockets(r.device).length === 0);
    for (const r of rows) this.sql.exec("UPDATE push SET alert_last = ?, last = ? WHERE device = ?", now, now, r.device);
    return rows.map(({ device, token, env, topic, registered_at, revision }) => ({
      target: { device, token, env, topic }, registeredAt: registered_at, revision, sealed, id,
    }));
  }

  // One immediate wake per question and recipient, even across DO restarts.
  // Both opening and closing use this path; neither waits for the sync minute.
  private withdrawTargets(from: string, id: string): PendingPush[] {
    const now = Date.now();
    this.sql.exec("DELETE FROM approval_withdrawals WHERE at < ?", now - 2 * 86_400_000);
    const rows = this.sql.exec<PushTarget & { registered_at: number; revision: string }>(
      `SELECT p.device, p.token, p.env, p.topic, p.registered_at, p.revision FROM push p JOIN devices d ON d.id = p.device
       WHERE p.device != ? AND d.revoked = 0 AND NOT EXISTS
       (SELECT 1 FROM approval_withdrawals w WHERE w.device = p.device AND w.question = ?)`, from, id,
    ).toArray().filter((r) => this.ctx.getWebSockets(r.device).length === 0);
    for (const r of rows) {
      this.sql.exec("INSERT INTO approval_withdrawals (device, question, at) VALUES (?, ?, ?)", r.device, id, now);
    }
    return rows.map(({ device, token, env, topic, registered_at, revision }) => ({
      target: { device, token, env, topic }, registeredAt: registered_at, revision, id, withdraw: true,
    }));
  }

  private async notify(targets: PendingPush[]) {
    for (const { target, registeredAt, revision, sealed, id, withdraw } of targets) {
      const firebase = target.env === "fcm";
      const sender = firebase ? this.fcm : this.apns;
      if (!sender) {
        if (firebase) console.warn("FCM wake unavailable", { stage: "configuration" });
        continue;
      }
      try {
        const result = sealed !== undefined && sender.alert ? await sender.alert(target, sealed, id) : await sender.silent(target, withdraw ? id : undefined);
        if (firebase && result.status === 200) console.log("FCM wake accepted");
        // A delayed result cannot revoke a later registration of the same token,
        // including two registrations in the same millisecond. Apple's 410 time
        // is milliseconds since epoch; a token registered after it is still usable.
        const staleUnregistration = !firebase && result.status === 410 && result.timestamp !== undefined && result.timestamp < registeredAt;
        if ((firebase ? invalidatesFcmToken(result) : invalidatesToken(result)) && !staleUnregistration) this.sql.exec(
          "DELETE FROM push WHERE device = ? AND token = ? AND env = ? AND topic = ? AND revision = ?",
          target.device, target.token, target.env, target.topic, revision,
        );
        else if (result.status !== 200) console.warn(firebase ? "FCM wake rejected" : "APNs wake rejected", {
          status: result.status,
          reason: ["BadTopic", "BadPriority", "DeviceTokenNotForTopic", "InvalidProviderToken", "ExpiredProviderToken", "TooManyProviderTokenUpdates", "TooManyRequests", "ServiceUnavailable", "Shutdown", "UNREGISTERED", "QUOTA_EXCEEDED", "UNAVAILABLE", "INTERNAL", "SENDER_ID_MISMATCH"].includes(result.reason ?? "") ? result.reason : "Unspecified",
        });
      } catch (error) {
        if (firebase) console.warn("FCM wake failed", { stage: fcmFailureStage(error) });
        // A push is a hint; the next change tries again.
      }
    }
  }

  // Sends to every other socket of the account that has said hello.
  private broadcast(from: WebSocket, message: unknown) {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === from || !(ws.deserializeAttachment() as Attachment | null)?.ready) continue;
      if (!this.touch(ws, (ws.deserializeAttachment() as Attachment).device)) continue;
      try {
        ws.send(text);
      } catch {
        // A socket closing underneath us is fine.
      }
    }
  }

  private hasAndroid(): boolean {
    return this.sql.exec("SELECT 1 FROM devices WHERE revoked = 0 AND platform = 'android' LIMIT 1").toArray().length > 0;
  }
}

const MESSAGES: Record<string, string> = {
  bad: "malformed change",
  "too-big": "blob over 96 KB of base64",
  full: "account over 50 MB",
};

function sendError(ws: WebSocket, code: string, message: string, id?: string) {
  ws.send(JSON.stringify(id ? { t: "error", code, message, id } : { t: "error", code, message }));
}

function close(ws: WebSocket, code: number, reason: string) {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}
