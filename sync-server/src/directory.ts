import { DurableObject } from "cloudflare:workers";
import { base64url, newToken, sha256hex } from "./util";

// One instance (idFromName("directory")) holds every OAuth client, link
// code, authorization code and token. Rows are small; tokens are kept only
// as SHA-256 hashes.

export const LINK_LIFE = 10 * 60 * 1000;
export const CODE_LIFE = 60 * 1000;
export const ACCESS_LIFE = 30 * 24 * 3600 * 1000;
export const REFRESH_LIFE = 180 * 24 * 3600 * 1000;
export const DEVICE_INTERVAL = 2;
// Expired links stay this long so a late poll hears expired_token, not invalid_grant.
const LINK_GRACE = 60 * 60 * 1000;
// A registered client that never got a token goes after a week, so
// registering in a loop can't grow the one Directory without end.
const UNUSED_CLIENT_LIFE = 7 * 24 * 3600 * 1000;
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ASSISTANT_ID = /^[A-Za-z0-9_-]{8,64}$/;
const CLIENT_NAME_ID = /^[A-Za-z0-9._-]{1,64}$/;
const VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;
const MAX_REDIRECTS = 10;
const MAX_URI = 2000;
const MAX_NAME = 200;

export type Out = { status: number; body: Record<string, any> };
export type TokenSet = {
  access_token: string;
  token_type: "Bearer";
  expires_in: number;
  refresh_token: string;
};

type LinkRow = {
  id: string;
  code: string;
  kind: "oauth" | "device";
  client: string;
  redirect: string | null;
  challenge: string | null;
  state: string | null;
  status: "pending" | "allowed" | "denied";
  host: string | null;
  assistant: string | null;
  created: number;
  expires: number;
  device_hash: string | null;
  interval: number;
  last_poll: number | null;
  issued: string | null;
};

type ClientRow = { id: string; name: string; redirects: string };

function oauthError(status: number, error: string, description?: string): Out {
  return { status, body: description ? { error, error_description: description } : { error } };
}

export function newLinkCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let s = "";
  for (const b of bytes) s += ALPHABET[b & 31];
  return s;
}

// The Mac sends codes in any case, with or without the dash (or spaces).
export function normalizeCode(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function showCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]"]);

export function validRedirect(uri: unknown): uri is string {
  if (typeof uri !== "string" || uri.length === 0 || uri.length > MAX_URI) return false;
  let url: URL;
  try {
    url = new URL(uri);
  } catch {
    return false;
  }
  if (url.hash) return false;
  if (url.protocol === "https:") return true;
  return url.protocol === "http:" && LOOPBACK.has(url.hostname);
}

// Exact match, except that a loopback redirect may use any port (RFC 8252 7.3).
function sameRedirect(registered: string, given: string): boolean {
  if (registered === given) return true;
  try {
    const a = new URL(registered);
    const b = new URL(given);
    if (a.protocol !== "http:" || !LOOPBACK.has(a.hostname)) return false;
    return (
      a.protocol === b.protocol && a.hostname === b.hostname &&
      a.pathname === b.pathname && a.search === b.search
    );
  } catch {
    return false;
  }
}

async function s256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

function withParams(uri: string, params: Record<string, string | null>): string {
  const url = new URL(uri);
  for (const [k, v] of Object.entries(params)) if (v != null) url.searchParams.set(k, v);
  return url.toString();
}

export class Directory extends DurableObject<Cloudflare.Env> {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS clients (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, redirects TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS links (
        id TEXT PRIMARY KEY, code TEXT NOT NULL, kind TEXT NOT NULL, client TEXT NOT NULL,
        redirect TEXT, challenge TEXT, state TEXT, status TEXT NOT NULL,
        host TEXT, assistant TEXT, created INTEGER NOT NULL, expires INTEGER NOT NULL,
        device_hash TEXT, interval INTEGER NOT NULL, last_poll INTEGER, issued TEXT);
      CREATE INDEX IF NOT EXISTS links_code ON links (code);
      CREATE INDEX IF NOT EXISTS links_device ON links (device_hash);
      CREATE TABLE IF NOT EXISTS codes (
        hash TEXT PRIMARY KEY, client TEXT NOT NULL, redirect TEXT NOT NULL, challenge TEXT NOT NULL,
        host TEXT NOT NULL, assistant TEXT NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens (
        hash TEXT PRIMARY KEY, kind TEXT NOT NULL, host TEXT NOT NULL, assistant TEXT NOT NULL,
        client TEXT NOT NULL, expires INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS tokens_owner ON tokens (host, assistant);`);
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  private client(id: string): ClientRow | null {
    return this.sql.exec<ClientRow>("SELECT id, name, redirects FROM clients WHERE id = ?", id).toArray()[0] ?? null;
  }

  private link(id: string): LinkRow | null {
    return this.sql.exec<LinkRow>("SELECT * FROM links WHERE id = ?", id).toArray()[0] ?? null;
  }

  // RFC 7591, public clients only.
  async register(body: any): Promise<Out> {
    const name = body?.client_name ?? "An assistant";
    const redirects = body?.redirect_uris;
    if (typeof name !== "string" || name.length === 0 || name.length > MAX_NAME) {
      return oauthError(400, "invalid_client_metadata", "client_name is up to 200 characters");
    }
    if (!Array.isArray(redirects) || redirects.length === 0 || redirects.length > MAX_REDIRECTS) {
      return oauthError(400, "invalid_redirect_uri", "redirect_uris needs 1 to 10 addresses");
    }
    for (const uri of redirects) {
      if (!validRedirect(uri)) {
        return oauthError(400, "invalid_redirect_uri", "redirects are https:, or http://localhost or 127.0.0.1");
      }
    }
    const id = "yc_" + newToken().slice(0, 22);
    const now = Date.now();
    this.sql.exec(
      "INSERT INTO clients (id, name, redirects, created) VALUES (?, ?, ?, ?)",
      id, name, JSON.stringify(redirects), now,
    );
    await this.scheduleCleanup(now + UNUSED_CLIENT_LIFE);
    return {
      status: 201,
      body: {
        client_id: id,
        client_id_issued_at: Math.floor(now / 1000),
        client_name: name,
        redirect_uris: redirects,
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
      },
    };
  }

  private freshCode(now: number): string {
    for (;;) {
      const code = newLinkCode();
      const taken = this.sql.exec("SELECT 1 FROM links WHERE code = ? AND expires > ?", code, now).toArray().length;
      if (!taken) return code;
    }
  }

  private async insertLink(link: Omit<LinkRow, "id" | "code" | "created" | "expires" | "status" | "host" | "assistant" | "last_poll" | "issued">) {
    const now = Date.now();
    const id = newToken();
    const code = this.freshCode(now);
    this.sql.exec(
      `INSERT INTO links (id, code, kind, client, redirect, challenge, state, status, host, assistant,
         created, expires, device_hash, interval, last_poll, issued)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, ?, ?, ?, ?, NULL, NULL)`,
      id, code, link.kind, link.client, link.redirect, link.challenge, link.state,
      now, now + LINK_LIFE, link.device_hash, link.interval,
    );
    await this.scheduleCleanup(now + LINK_LIFE + LINK_GRACE);
    return { id, code };
  }

  // GET /oauth/authorize. An error with `redirect` goes back to the client;
  // one without is shown on the page (an unknown client or redirect).
  async authorize(p: Record<string, string>): Promise<
    | { ok: true; link: string; code: string; client: string }
    | { ok: false; status: number; message: string; redirect?: string }
  > {
    const client = p.client_id ? this.client(p.client_id) : null;
    if (!client) return { ok: false, status: 400, message: "This assistant is not known here. Start again from the assistant." };
    const redirects = JSON.parse(client.redirects) as string[];
    let redirect = p.redirect_uri;
    if (!redirect && redirects.length === 1) redirect = redirects[0];
    if (!redirect || !redirects.some((r) => sameRedirect(r, redirect))) {
      return { ok: false, status: 400, message: "The address to return to is not one this assistant registered." };
    }
    const back = (error: string, description: string) => ({
      ok: false as const, status: 302, message: description,
      redirect: withParams(redirect, { error, error_description: description, state: p.state ?? null }),
    });
    if (p.response_type !== "code") return back("unsupported_response_type", "response_type must be code");
    if (!p.code_challenge || !/^[A-Za-z0-9_-]{43}$/.test(p.code_challenge)) {
      return back("invalid_request", "code_challenge (S256) is required");
    }
    if ((p.code_challenge_method ?? "") !== "S256") return back("invalid_request", "code_challenge_method must be S256");
    if (p.state && p.state.length > 1000) return back("invalid_request", "state is too long");
    const { id, code } = await this.insertLink({
      kind: "oauth", client: client.id, redirect, challenge: p.code_challenge, state: p.state ?? null,
      device_hash: null, interval: DEVICE_INTERVAL,
    });
    return { ok: true, link: id, code, client: client.name };
  }

  // What the authorize page polls. Once the Mac said yes, the first poll
  // makes the authorization code; later polls get the same address back.
  async linkStatus(id: string): Promise<{ status: string; redirect?: string }> {
    const now = Date.now();
    const link = this.link(id);
    if (!link || link.kind !== "oauth" || link.expires <= now) return { status: "expired" };
    if (link.status === "pending") return { status: "pending" };
    if (link.status === "denied") {
      return { status: "denied", redirect: withParams(link.redirect!, { error: "access_denied", state: link.state }) };
    }
    if (link.issued) return { status: "allowed", redirect: link.issued };
    const code = newToken();
    this.sql.exec(
      "INSERT INTO codes (hash, client, redirect, challenge, host, assistant, expires) VALUES (?, ?, ?, ?, ?, ?, ?)",
      await sha256hex(code), link.client, link.redirect!, link.challenge!, link.host!, link.assistant!, now + CODE_LIFE,
    );
    const redirect = withParams(link.redirect!, { code, state: link.state });
    this.sql.exec("UPDATE links SET issued = ? WHERE id = ?", redirect, id);
    return { status: "allowed", redirect };
  }

  // POST /oauth/device (RFC 8628). An unknown client_id is a CLI's own
  // short name, registered on the spot with no redirects.
  async device(clientId: string | undefined, origin: string, nonce?: string): Promise<Out> {
    if (!clientId || !CLIENT_NAME_ID.test(clientId)) return oauthError(400, "invalid_client", "client_id is required");
    if (nonce !== undefined && !/^[A-Za-z0-9_-]{16,64}$/.test(nonce)) return oauthError(400, "invalid_request", "nonce is invalid");
    if (!this.client(clientId)) {
      this.sql.exec(
        "INSERT INTO clients (id, name, redirects, created) VALUES (?, ?, '[]', ?)",
        clientId, clientId, Date.now(),
      );
      await this.scheduleCleanup(Date.now() + UNUSED_CLIENT_LIFE);
    }
    const deviceCode = newToken();
    const { code } = await this.insertLink({
      kind: "device", client: clientId, redirect: null, challenge: null, state: nonce ?? null,
      device_hash: await sha256hex(deviceCode), interval: DEVICE_INTERVAL,
    });
    return {
      status: 200,
      body: {
        device_code: deviceCode,
        user_code: showCode(code),
        verification_uri: `${origin}/connect`,
        expires_in: LINK_LIFE / 1000,
        interval: DEVICE_INTERVAL,
      },
    };
  }

  // POST /v1/hosts/{id}/links/lookup: any host may look up a live code.
  async lookup(code: string): Promise<{ link: string; client: string; client_id: string; kind: string; redirect: string | null; nonce: string | null } | { expired: true } | null> {
    const normal = normalizeCode(code);
    if (normal.length !== 8) return null;
    const link = this.sql
      .exec<LinkRow>("SELECT * FROM links WHERE code = ? AND status = 'pending' ORDER BY expires DESC LIMIT 1", normal)
      .toArray()[0];
    if (!link) return null;
    if (link.expires <= Date.now()) return { expired: true };
    const client = this.client(link.client);
    return { link: link.id, client: client?.name ?? link.client, client_id: link.client, kind: link.kind,
      redirect: link.redirect, nonce: link.kind === "device" ? link.state : null };
  }

  async decide(host: string, id: string, allow: boolean, assistant: string | null): Promise<{ ok: true; client: string } | { ok: false; status: number }> {
    const link = this.link(id);
    if (!link || link.expires <= Date.now()) return { ok: false, status: 404 };
    if (link.status !== "pending") return { ok: false, status: 409 };
    if (allow && (!assistant || !ASSISTANT_ID.test(assistant))) return { ok: false, status: 400 };
    this.sql.exec(
      "UPDATE links SET status = ?, host = ?, assistant = ? WHERE id = ?",
      allow ? "allowed" : "denied", host, allow ? assistant : null, id,
    );
    const client = this.client(link.client);
    return { ok: true, client: client?.name ?? link.client };
  }

  private async issue(host: string, assistant: string, client: string): Promise<TokenSet> {
    const now = Date.now();
    const access = newToken();
    const refresh = newToken();
    this.sql.exec(
      "INSERT INTO tokens (hash, kind, host, assistant, client, expires) VALUES (?, 'access', ?, ?, ?, ?)",
      await sha256hex(access), host, assistant, client, now + ACCESS_LIFE,
    );
    this.sql.exec(
      "INSERT INTO tokens (hash, kind, host, assistant, client, expires) VALUES (?, 'refresh', ?, ?, ?, ?)",
      await sha256hex(refresh), host, assistant, client, now + REFRESH_LIFE,
    );
    await this.scheduleCleanup(now + LINK_LIFE + LINK_GRACE);
    return { access_token: access, token_type: "Bearer", expires_in: ACCESS_LIFE / 1000, refresh_token: refresh };
  }

  // POST /oauth/token.
  async token(p: Record<string, string>): Promise<Out> {
    const now = Date.now();
    switch (p.grant_type) {
      case "authorization_code": {
        if (!p.code || !p.code_verifier || !p.client_id) return oauthError(400, "invalid_request", "code, code_verifier and client_id are required");
        const hash = await sha256hex(p.code);
        const row = this.sql
          .exec<{ client: string; redirect: string; challenge: string; host: string; assistant: string; expires: number }>(
            "SELECT client, redirect, challenge, host, assistant, expires FROM codes WHERE hash = ?", hash,
          )
          .toArray()[0];
        // Single use: gone on the first try, right or wrong.
        if (row) this.sql.exec("DELETE FROM codes WHERE hash = ?", hash);
        if (!row || row.expires <= now) return oauthError(400, "invalid_grant", "the code is unknown, used or expired");
        if (row.client !== p.client_id) return oauthError(400, "invalid_grant", "the code was issued to another client");
        if (p.redirect_uri && p.redirect_uri !== row.redirect) return oauthError(400, "invalid_grant", "redirect_uri does not match");
        if (!VERIFIER.test(p.code_verifier) || (await s256(p.code_verifier)) !== row.challenge) {
          return oauthError(400, "invalid_grant", "code_verifier does not match");
        }
        return { status: 200, body: await this.issue(row.host, row.assistant, row.client) };
      }
      case "urn:ietf:params:oauth:grant-type:device_code": {
        if (!p.device_code || !p.client_id) return oauthError(400, "invalid_request", "device_code and client_id are required");
        const link = this.sql
          .exec<LinkRow>("SELECT * FROM links WHERE device_hash = ?", await sha256hex(p.device_code))
          .toArray()[0];
        if (!link || link.client !== p.client_id) return oauthError(400, "invalid_grant", "unknown device_code");
        if (link.expires <= now) {
          this.sql.exec("DELETE FROM links WHERE id = ?", link.id);
          return oauthError(400, "expired_token");
        }
        if (link.status === "denied") {
          this.sql.exec("DELETE FROM links WHERE id = ?", link.id);
          return oauthError(400, "access_denied");
        }
        if (link.status === "allowed") {
          this.sql.exec("DELETE FROM links WHERE id = ?", link.id);
          return { status: 200, body: await this.issue(link.host!, link.assistant!, link.client) };
        }
        // Pending. Polling faster than the interval (with half a second of
        // slack for the network) adds five seconds to it (RFC 8628 3.5).
        const early = link.last_poll != null && now - link.last_poll < link.interval * 1000 - 500;
        const interval = early ? link.interval + 5 : link.interval;
        this.sql.exec("UPDATE links SET last_poll = ?, interval = ? WHERE id = ?", now, interval, link.id);
        if (early) return { status: 400, body: { error: "slow_down", interval } };
        return oauthError(400, "authorization_pending");
      }
      case "refresh_token": {
        if (!p.refresh_token || !p.client_id) return oauthError(400, "invalid_request", "refresh_token and client_id are required");
        const hash = await sha256hex(p.refresh_token);
        const row = this.sql
          .exec<{ host: string; assistant: string; client: string; expires: number }>(
            "SELECT host, assistant, client, expires FROM tokens WHERE hash = ? AND kind = 'refresh'", hash,
          )
          .toArray()[0];
        if (!row || row.expires <= now || row.client !== p.client_id) {
          return oauthError(400, "invalid_grant", "the refresh token is unknown, used or expired");
        }
        this.sql.exec("DELETE FROM tokens WHERE hash = ?", hash);
        return { status: 200, body: await this.issue(row.host, row.assistant, row.client) };
      }
      default:
        return oauthError(400, "unsupported_grant_type");
    }
  }

  // The one call /mcp makes before going to the Host.
  async resolve(token: string): Promise<{ host: string; assistant: string } | null> {
    const row = this.sql
      .exec<{ host: string; assistant: string; expires: number }>(
        "SELECT host, assistant, expires FROM tokens WHERE hash = ? AND kind = 'access'", await sha256hex(token),
      )
      .toArray()[0];
    if (!row || row.expires <= Date.now()) return null;
    return { host: row.host, assistant: row.assistant };
  }

  async revokeAssistant(host: string, assistant: string): Promise<void> {
    this.sql.exec("DELETE FROM tokens WHERE host = ? AND assistant = ?", host, assistant);
    this.sql.exec("DELETE FROM codes WHERE host = ? AND assistant = ?", host, assistant);
    this.sql.exec("DELETE FROM links WHERE host = ? AND assistant = ?", host, assistant);
  }

  async revokeHost(host: string): Promise<void> {
    this.sql.exec("DELETE FROM tokens WHERE host = ?", host);
    this.sql.exec("DELETE FROM codes WHERE host = ?", host);
    this.sql.exec("DELETE FROM links WHERE host = ?", host);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.sql.exec("DELETE FROM links WHERE expires <= ?", now - LINK_GRACE);
    this.sql.exec("DELETE FROM codes WHERE expires <= ?", now);
    this.sql.exec("DELETE FROM tokens WHERE expires <= ?", now);
    const unused = "id NOT IN (SELECT client FROM tokens) AND id NOT IN (SELECT client FROM codes) AND id NOT IN (SELECT client FROM links)";
    this.sql.exec(`DELETE FROM clients WHERE created <= ? AND ${unused}`, now - UNUSED_CLIENT_LIFE);
    const link = this.sql.exec<{ e: number | null }>("SELECT MIN(expires) AS e FROM links").one().e;
    const client = this.sql.exec<{ c: number | null }>(`SELECT MIN(created) AS c FROM clients WHERE ${unused}`).one().c;
    const next = Math.min(link != null ? link + LINK_GRACE : Infinity, client != null ? client + UNUSED_CLIENT_LIFE : Infinity);
    if (next !== Infinity) await this.ctx.storage.setAlarm(next);
  }

  private async scheduleCleanup(at: number) {
    const current = await this.ctx.storage.getAlarm();
    if (current == null || current > at) await this.ctx.storage.setAlarm(at);
  }
}
