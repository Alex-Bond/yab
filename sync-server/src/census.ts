import { DurableObject } from "cloudflare:workers";

// One instance (idFromName("census")) counts how many Macs and iPhones each
// account syncs, so the site's /admin can tell how many people use Yab on
// more than one device. A row is the account object's own id (a hash of
// the account name, never the name), two counts and when it was last
// heard: no device names, models or anything synced.

export type Census = {
  accounts: number;
  active: number;
  byDevices: Record<string, number>;
  macs: number;
  phones: number;
  androids: number;
  severalMacs: number;
  extraMacs: number;
  withPhone: number;
  since: number | null;
};

export const ACTIVE_FOR = 7 * 24 * 3600 * 1000;

export class Counts extends DurableObject<Cloudflare.Env> {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT PRIMARY KEY, macs INTEGER NOT NULL, phones INTEGER NOT NULL,
        seen INTEGER NOT NULL, first INTEGER NOT NULL, androids INTEGER NOT NULL DEFAULT 0);`);
    const columns = new Set(this.ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(accounts)").toArray().map((row) => row.name));
    if (!columns.has("androids")) this.ctx.storage.sql.exec("ALTER TABLE accounts ADD COLUMN androids INTEGER NOT NULL DEFAULT 0");
  }

  note(id: string, macs: number, phones: number, seen: number, androids = 0) {
    this.ctx.storage.sql.exec(
      `INSERT INTO accounts (id, macs, phones, seen, first, androids) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET macs = excluded.macs, phones = excluded.phones, androids = excluded.androids, seen = max(seen, excluded.seen)`,
      id, macs, phones, seen, Date.now(), androids,
    );
  }

  forget(id: string) {
    this.ctx.storage.sql.exec("DELETE FROM accounts WHERE id = ?", id);
  }

  /** Accounts heard from in the last week, with at least one device. */
  summary(now = Date.now()): Census {
    const sql = this.ctx.storage.sql;
    const all = sql.exec<{ n: number; first: number | null }>("SELECT count(*) AS n, min(first) AS first FROM accounts").toArray()[0];
    const rows = sql
      .exec<{ macs: number; phones: number; androids: number }>("SELECT macs, phones, androids FROM accounts WHERE seen >= ? AND macs + phones > 0", now - ACTIVE_FOR)
      .toArray();
    const byDevices: Record<string, number> = {};
    for (const r of rows) {
      const k = String(Math.min(r.macs + r.phones, 4)) + (r.macs + r.phones >= 4 ? "+" : "");
      byDevices[k] = (byDevices[k] ?? 0) + 1;
    }
    return {
      accounts: all.n,
      active: rows.length,
      byDevices,
      macs: rows.reduce((n, r) => n + r.macs, 0),
      phones: rows.reduce((n, r) => n + r.phones, 0),
      androids: rows.reduce((n, r) => n + r.androids, 0),
      severalMacs: rows.filter((r) => r.macs >= 2).length,
      extraMacs: rows.reduce((n, r) => n + Math.max(0, r.macs - 1), 0),
      withPhone: rows.filter((r) => r.phones > 0).length,
      since: all.first ?? null,
    };
  }
}

/** A device's kind from the model it registered with: hw.machine on an
 *  iPhone or iPad ("iPhone17,1"), hw.model on a Mac ("Mac15,3"). */
export function isPhone(model: string): boolean {
  return /^(iPhone|iPad|iPod)/.test(model);
}

export type DevicePlatform = "ios" | "macos" | "android" | "unknown";

/** Legacy unknown hardware must not become an execution-capable Mac by elimination. */
export function devicePlatform(platform: string | undefined, model: string): DevicePlatform {
  if (platform === "ios" || platform === "macos" || platform === "android") return platform;
  if (isPhone(model)) return "ios";
  if (/^(Mac|iMac)/.test(model)) return "macos";
  return "unknown";
}
