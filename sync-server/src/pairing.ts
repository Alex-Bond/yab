import { DurableObject } from "cloudflare:workers";
import { empty, fail, isString, json, readJson } from "./util";

const TTL = 10 * 60 * 1000;
// Reads that carry the envelope away. Reading only the public key tells a
// reader nothing it could use, so the new device may wait out its ten
// minutes (and the Mac look up the code) without spending these.
const MAX_READS = 20;
const MAX_PUB = 200;
const MAX_ENVELOPE = 4096;
const CODE = /^[0-9a-f]{64}$/;
// One address hammering the pairing door, whatever it wants there. A
// pairing is a handful of requests from one or two addresses in ten
// minutes; a hundred a minute is not a device joining, it is noise, and
// every one of its codes would cost the asker a PBKDF2 round anyway.
const HITS = 100;
const HITS_WINDOW = 60 * 1000;
export { HITS, HITS_WINDOW };

// One instance holds every pairing box: entries are tiny and short-lived.
export class Pairing extends DurableObject<Cloudflare.Env> {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS boxes (
      code TEXT PRIMARY KEY, pub TEXT NOT NULL, envelope TEXT,
      reads INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL)`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS hits (
      ip TEXT PRIMARY KEY, at INTEGER NOT NULL, n INTEGER NOT NULL)`);
  }

  async fetch(request: Request): Promise<Response> {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    sql.exec("DELETE FROM boxes WHERE expires <= ?", now);

    // The one door everyone shares, asked no faster than a person joins.
    const ip = request.headers.get("cf-connecting-ip");
    if (ip && ip.length <= 64) {
      const hit = sql.exec<{ at: number; n: number }>("SELECT at, n FROM hits WHERE ip = ?", ip).toArray()[0];
      if (hit && now - hit.at < HITS_WINDOW) {
        if (hit.n >= HITS) return fail(429, "later", "Too many requests; a code is stretched to make guessing slow already.");
        sql.exec("UPDATE hits SET n = n + 1 WHERE ip = ?", ip);
      } else {
        sql.exec("INSERT INTO hits (ip, at, n) VALUES (?, ?, 1) ON CONFLICT (ip) DO UPDATE SET at = excluded.at, n = 1", ip, now);
      }
    }
    sql.exec("DELETE FROM hits WHERE at <= ?", now - HITS_WINDOW);

    const path = new URL(request.url).pathname;
    if (path === "/v1/pair") {
      if (request.method !== "POST") return fail(405, "bad");
      const body = await readJson(request);
      if (!isString(body?.code, 64) || !CODE.test(body.code)) return fail(400, "bad", "bad code");
      if (!isString(body.pub, MAX_PUB) || body.pub.length === 0) return fail(400, "bad", "bad pub");
      // A live code belongs to whoever posted it first.
      if (sql.exec("SELECT 1 FROM boxes WHERE code = ?", body.code).toArray().length) {
        return fail(409, "taken");
      }
      sql.exec("INSERT INTO boxes (code, pub, expires) VALUES (?, ?, ?)", body.code, body.pub, now + TTL);
      await this.scheduleCleanup(now + TTL);
      return empty();
    }

    const code = path.slice("/v1/pair/".length);
    if (!CODE.test(code)) return fail(400, "bad", "bad code");
    const row = sql
      .exec<{ pub: string; envelope: string | null; reads: number }>(
        "SELECT pub, envelope, reads FROM boxes WHERE code = ?",
        code,
      )
      .toArray()[0];
    if (!row) return fail(404, "not-found");

    if (request.method === "GET") {
      if (row.envelope == null) return json({ pub: row.pub });
      if (row.reads >= MAX_READS) {
        sql.exec("DELETE FROM boxes WHERE code = ?", code);
        return fail(404, "not-found");
      }
      sql.exec("UPDATE boxes SET reads = reads + 1 WHERE code = ?", code);
      return json({ pub: row.pub, envelope: row.envelope });
    }

    if (request.method === "PUT") {
      const body = await readJson(request);
      if (!isString(body?.envelope, MAX_ENVELOPE) || body.envelope.length === 0) {
        return fail(400, "bad", "bad envelope");
      }
      if (row.envelope != null) return fail(409, "taken");
      sql.exec("UPDATE boxes SET envelope = ? WHERE code = ?", body.envelope, code);
      return empty();
    }

    return fail(405, "bad");
  }

  async alarm(): Promise<void> {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM boxes WHERE expires <= ?", Date.now());
    const next = sql.exec<{ e: number | null }>("SELECT MIN(expires) AS e FROM boxes").one().e;
    if (next != null) await this.ctx.storage.setAlarm(next);
  }

  private async scheduleCleanup(at: number) {
    const current = await this.ctx.storage.getAlarm();
    if (current == null || current > at) await this.ctx.storage.setAlarm(at);
  }
}
