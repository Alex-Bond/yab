import { DurableObject } from "cloudflare:workers";
import { unauthorizedMcp } from "./assist";
import {
  HOST_ID,
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

export const ASSISTANT_ID = /^[A-Za-z0-9_-]{8,64}$/;
export const QUEUE_LIFE = 12 * 3600 * 1000;
const MAX_MCP = 1024 * 1024;
const MAX_TOOLS = 512 * 1024;

type Attachment = { ready: boolean; since: number };
export class Host extends DurableObject<Cloudflare.Env> {
  // How long /mcp waits for a reply. Tests shorten it.
  callWait = 28_000;
  private waiters = new Map<string, (value: any) => void>();
  /** When this Mac last typed a code nobody had: kept in memory, a minute back. */
  private misses: number[] = [];

  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.schema();
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  private schema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS assistants (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, client TEXT NOT NULL,
        tools TEXT, instructions TEXT, created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS queue (
        n INTEGER PRIMARY KEY AUTOINCREMENT, assistant TEXT NOT NULL, body TEXT NOT NULL, until INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS log (
        n INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, assistant TEXT NOT NULL, tool TEXT NOT NULL, outcome TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS log_at ON log (at);
      DROP TABLE IF EXISTS approvals;
      DROP TABLE IF EXISTS setups;`);
  }

  private meta(key: string): string | null {
    const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row ? row.value : null;
  }

  private setMeta(key: string, value: string | number) {
    this.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, String(value));
  }

  private get directory() {
    return this.env.DIRECTORY.get(this.env.DIRECTORY.idFromName("directory"));
  }

  private get hostId(): string | null {
    return this.meta("id");
  }

  lastSeen(): number | null {
    const v = this.meta("last_seen");
    return v == null ? null : Number(v);
  }

  // HTTP

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    this.purge();

    if (path === "/v1/hosts" && method === "POST") return this.register(request);
    if (path === "/mcp") return this.mcp(request);

    const rest = path.replace(/^\/v1\/hosts\/[^/]+/, "");
    if (!(await this.authenticate(request))) return fail(401, "unauthorized");
    const host = this.hostId!;

    if (rest === "/socket" && method === "GET") return this.upgrade(request);
    if (rest === "" && method === "DELETE") return this.deleteHost(host);
    if (rest === "/links/lookup" && method === "POST") {
      const body = await readJson(request);
      if (!isString(body?.code, 64)) return fail(400, "bad", "code is required");
      // Codes are guessed one at a time: ten wrong ones a minute per Mac.
      const now = Date.now();
      this.misses = this.misses.filter((t) => now - t < 60_000);
      if (this.misses.length >= 10) return fail(429, "slow-down", "Too many wrong codes. Wait a minute.");
      const found = await this.directory.lookup(body.code);
      if (!found || "expired" in found) this.misses.push(now);
      if (found && "expired" in found) return fail(410, "expired-code", "This code has expired. Ask your assistant for a new one.");
      return found ? json(found) : fail(404, "not-found");
    }
    if (rest === "/links/decide" && method === "POST") return this.decide(request, host);
    if (rest === "/log" && method === "GET") {
      const url = new URL(request.url);
      const who = url.searchParams.get("assistant");
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), 500);
      const rows = who
        ? this.sql.exec("SELECT at, assistant, tool, outcome FROM log WHERE assistant = ? ORDER BY n DESC LIMIT ?", who, limit).toArray()
        : this.sql.exec("SELECT at, assistant, tool, outcome FROM log ORDER BY n DESC LIMIT ?", limit).toArray();
      return json({ entries: rows });
    }
    const removal = /^\/assistants\/([^/]+)$/.exec(rest);
    if (removal && method === "DELETE") {
      const assistant = decodeURIComponent(removal[1]);
      await this.forget([assistant]);
      return empty();
    }
    return fail(404, "not-found");
  }

  private async register(request: Request): Promise<Response> {
    const body = await readJson(request);
    if (
      !isString(body?.id, 64) || !HOST_ID.test(body.id) ||
      !isString(body.secret, 512) || body.secret.length === 0 ||
      !isString(body.name, MAX_NAME)
    ) {
      return fail(400, "bad");
    }
    const digest = await sha256hex(body.secret);
    const verifier = this.meta("verifier");
    if (verifier == null) {
      this.setMeta("verifier", digest);
      this.setMeta("id", body.id);
    } else if (!sameDigest(verifier, digest)) {
      return fail(403, "secret");
    }
    const token = newToken();
    this.setMeta("token", await sha256hex(token));
    this.setMeta("name", body.name);
    return json({ token });
  }

  private async authenticate(request: Request): Promise<boolean> {
    const token = bearer(request);
    const stored = this.meta("token");
    if (!token || stored == null) return false;
    return sameDigest(stored, await sha256hex(token));
  }

  private async decide(request: Request, host: string): Promise<Response> {
    const body = await readJson(request);
    if (!isString(body?.link, 128) || typeof body.allow !== "boolean") return fail(400, "bad", "link and allow are required");
    const assistant = body.assistant;
    if (body.allow && (!isString(assistant?.id, 64) || !ASSISTANT_ID.test(assistant.id) || !isString(assistant.name, MAX_NAME))) {
      return fail(400, "bad", "allowing needs assistant {id, name}");
    }
    const result = await this.directory.decide(host, body.link, body.allow, body.allow ? assistant.id : null);
    if (!result.ok) return fail(result.status, result.status === 404 ? "not-found" : result.status === 409 ? "decided" : "bad");
    if (body.allow) {
      this.sql.exec(
        `INSERT INTO assistants (id, name, client, created) VALUES (?, ?, ?, ?)
         ON CONFLICT (id) DO UPDATE SET name = excluded.name, client = excluded.client`,
        assistant.id, assistant.name, result.client, Date.now(),
      );
    }
    return empty();
  }

  // Assistants go with their tokens and queued calls.
  private async forget(assistants: string[]) {
    for (const a of assistants) {
      await this.directory.revokeAssistant(this.hostId!, a);
      this.sql.exec("DELETE FROM assistants WHERE id = ?", a);
      this.sql.exec("DELETE FROM queue WHERE assistant = ?", a);
      this.sql.exec("DELETE FROM log WHERE assistant = ?", a);
    }
  }

  private async deleteHost(host: string): Promise<Response> {
    await this.directory.revokeHost(host);
    for (const ws of this.ctx.getWebSockets()) close(ws, 4003, "deleted");
    await this.ctx.storage.deleteAll();
    this.schema();
    return empty();
  }

  private upgrade(request: Request): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return fail(426, "bad", "expected a WebSocket upgrade");
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ ready: false, since: Date.now() } satisfies Attachment);
    this.setMeta("last_seen", Date.now());
    return new Response(null, { status: 101, webSocket: client });
  }

  // The newest socket that said hello: the Mac. An older one is a line
  // that died without closing.
  private live(): WebSocket | null {
    let best: WebSocket | null = null;
    let since = -1;
    for (const ws of this.ctx.getWebSockets()) {
      const at = ws.deserializeAttachment() as Attachment | null;
      if (!at?.ready || ws.readyState !== 1) continue;
      if (at.since > since) {
        best = ws;
        since = at.since;
      }
    }
    return best;
  }

  private wait(key: string, ms: number): Promise<any | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiters.delete(key);
        resolve(null);
      }, ms);
      this.waiters.set(key, (value) => {
        clearTimeout(timer);
        this.waiters.delete(key);
        resolve(value);
      });
    });
  }

  private settle(key: string, value: unknown) {
    this.waiters.get(key)?.(value);
  }

  // MCP

  private async mcp(request: Request): Promise<Response> {
    const assistant = request.headers.get("x-yab-assistant") ?? "";
    const known = this.sql.exec("SELECT 1 FROM assistants WHERE id = ?", assistant).toArray().length > 0;
    if (!known) return unauthorizedMcp(request);

    const text = await request.text();
    if (text.length > MAX_MCP) return json(rpcError(null, -32600, "Request too large"), 413);
    let body: any;
    try {
      body = JSON.parse(text);
    } catch {
      return json(rpcError(null, -32700, "Parse error"), 400);
    }
    const messages: any[] = Array.isArray(body) ? body : [body];
    if (messages.length === 0 || messages.some((m) => !m || typeof m !== "object" || Array.isArray(m))) {
      return json(rpcError(null, -32600, "Invalid Request"), 400);
    }
    const requests = messages.filter(isRequest);

    const ws = this.live();
    if (ws) {
      const id = crypto.randomUUID();
      if (requests.length === 0) {
        send(ws, { t: "call", id, assistant, body });
        return new Response(null, { status: 202 });
      }
      const reply = this.wait(`call:${id}`, this.callWait);
      if (!send(ws, { t: "call", id, assistant, body })) this.settle(`call:${id}`, null);
      const answer = await reply;
      if (answer == null) {
        const errors = requests.map((r) => rpcError(r.id, -32001, "Yab on the Mac took too long"));
        this.journal(assistant, requests, errors, "timeout");
        return json(Array.isArray(body) ? errors : errors[0]);
      }
      this.journal(assistant, requests, Array.isArray(answer) ? answer : [answer]);
      return json(answer);
    }

    if (requests.length === 0) return new Response(null, { status: 202 });
    const answers = requests.map((r) => this.offline(assistant, r));
    this.journal(assistant, requests, answers);
    return json(Array.isArray(body) ? answers : answers[0]);
  }

  // The journal: which tool, when, and how it went; never arguments or
  // answers. Kept 30 days, for the user's Settings on the Mac.
  private journal(assistant: string, requests: any[], answers: any[], fallback?: string) {
    const now = Date.now();
    for (const r of requests) {
      if (r.method !== "tools/call" || typeof r.params?.name !== "string") continue;
      const a = answers.find((x) => x && x.id === r.id);
      this.sql.exec("INSERT INTO log (at, assistant, tool, outcome) VALUES (?, ?, ?, ?)",
        now, assistant, r.params.name.slice(0, 64), fallback ?? outcomeOf(a));
    }
    this.sql.exec("DELETE FROM log WHERE at < ?", now - LOG_LIFE);
  }

  // What an assistant hears while the Mac is away.
  private offline(assistant: string, req: any): unknown {
    const row = this.sql
      .exec<{ tools: string | null; instructions: string | null }>("SELECT tools, instructions FROM assistants WHERE id = ?", assistant)
      .toArray()[0] ?? { tools: null, instructions: null };
    const tools = row.tools ? JSON.parse(row.tools) : [];
    switch (req.method) {
      case "initialize": {
        const asked = req.params?.protocolVersion;
        const result: Record<string, unknown> = {
          protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
          capabilities: { tools: {} },
          serverInfo: { name: "yab-browser", version: "1" },
        };
        if (row.instructions) result.instructions = row.instructions;
        return { jsonrpc: "2.0", id: req.id, result };
      }
      case "tools/list":
        return { jsonrpc: "2.0", id: req.id, result: { tools } };
      case "ping":
        return { jsonrpc: "2.0", id: req.id, result: {} };
      case "tools/call": {
        const lastSeen = this.lastSeen();
        if (req.params?.name === "task") {
          const until = Date.now() + QUEUE_LIFE;
          this.sql.exec("INSERT INTO queue (assistant, body, until) VALUES (?, ?, ?)", assistant, JSON.stringify(req), until);
          void this.scheduleCleanup(until);
          const status = {
            status: "mac_offline",
            queued: true,
            last_seen: lastSeen,
            until,
            says: `${offlineSince(lastSeen)}. The task is saved and starts as soon as it is back, if that is within 12 hours.`,
          };
          return { jsonrpc: "2.0", id: req.id, result: { content: [{ type: "text", text: JSON.stringify(status) }] } };
        }
        const status = {
          status: "mac_offline",
          last_seen: lastSeen,
          says: `${offlineSince(lastSeen)}, so nothing was done. Ask the user to wake it.`,
        };
        return {
          jsonrpc: "2.0", id: req.id,
          result: { content: [{ type: "text", text: JSON.stringify(status) }], isError: true },
        };
      }
      default:
        return rpcError(req.id, -32001, "Yab on the Mac is offline");
    }
  }

  // Socket

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (this.hostId == null) return close(ws, 4003, "deleted");
    this.setMeta("last_seen", Date.now());
    let msg: any;
    try {
      msg = typeof raw === "string" ? JSON.parse(raw) : null;
    } catch {
      msg = null;
    }
    if (!msg || typeof msg !== "object") return sendError(ws, "bad", "expected a JSON object");
    const at = ws.deserializeAttachment() as Attachment;

    switch (msg.t) {
      case "hello": {
        if (msg.v !== 1 || !Array.isArray(msg.assistants) || !msg.assistants.every((a: unknown) => typeof a === "string")) {
          return sendError(ws, "bad", "hello needs v 1 and assistants: [id]");
        }
        const mine = new Set<string>(msg.assistants);
        const gone = this.sql
          .exec<{ id: string }>("SELECT id FROM assistants")
          .toArray()
          .map((r) => r.id)
          .filter((id) => !mine.has(id));
        await this.forget(gone);
        ws.serializeAttachment({ ...at, ready: true } satisfies Attachment);
        const queued = this.sql
          .exec<{ n: number; assistant: string; body: string }>(
            "SELECT n, assistant, body FROM queue WHERE until > ? ORDER BY n", Date.now(),
          )
          .toArray();
        for (const q of queued) {
          if (!send(ws, { t: "call", id: crypto.randomUUID(), assistant: q.assistant, body: JSON.parse(q.body), queued: true })) return;
          this.sql.exec("DELETE FROM queue WHERE n = ?", q.n);
        }
        return;
      }
      case "reply":
        if (!isString(msg.id, 200)) return sendError(ws, "bad", "reply needs an id");
        return this.settle(`call:${msg.id}`, msg.body ?? null);
      case "tools": {
        if (!isString(msg.assistant, 64) || !Array.isArray(msg.tools)) return sendError(ws, "bad", "tools needs assistant and tools");
        const tools = JSON.stringify(msg.tools);
        if (tools.length > MAX_TOOLS) return sendError(ws, "bad", "tools over 512 KB");
        const instructions = isString(msg.instructions, 64 * 1024) ? msg.instructions : null;
        this.sql.exec("UPDATE assistants SET tools = ?, instructions = ? WHERE id = ?", tools, instructions, msg.assistant);
        return;
      }
      case "ping":
        send(ws, { t: "pong" });
        return;
      default:
        return sendError(ws, "bad", "unknown message");
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.setMeta("last_seen", Date.now());
    close(ws, code === 1005 ? 1000 : code, reason);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.setMeta("last_seen", Date.now());
  }

  // Cleanup

  private purge() {
    const now = Date.now();
    this.sql.exec("DELETE FROM queue WHERE until <= ?", now);
  }

  async alarm(): Promise<void> {
    this.purge();
    const next = this.sql
      .exec<{ e: number | null }>(
        `SELECT MIN(until) AS e FROM queue`,
      )
      .one().e;
    if (next != null) await this.ctx.storage.setAlarm(next);
  }

  private async scheduleCleanup(at: number) {
    const current = await this.ctx.storage.getAlarm();
    if (current == null || current > at) await this.ctx.storage.setAlarm(at);
  }
}

const LOG_LIFE = 30 * 24 * 60 * 60 * 1000;

/** ok, the status an answer's text starts with ("status: needs_user"), failed, or error. */
export function outcomeOf(answer: any): string {
  if (!answer || answer.error) return "error";
  const text = answer.result?.content?.[0]?.text;
  if (typeof text === "string") {
    const said = /^status: ([a-z_]+)/.exec(text) ?? /"status":"([a-z_]+)"/.exec(text);
    if (said) return said[1];
  }
  return answer.result?.isError ? "failed" : "ok";
}

const PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];

function isRequest(m: any): boolean {
  return typeof m.method === "string" && "id" in m && m.id !== null && m.id !== undefined;
}

function rpcError(id: unknown, code: number, message: string) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// The server doesn't know the user's time zone, so times are in UTC.
export function offlineSince(lastSeen: number | null, now = Date.now()): string {
  if (lastSeen == null) return "Yab on the Mac has not connected yet";
  const d = new Date(lastSeen);
  const time = `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")} UTC`;
  const today = new Date(now).toISOString().slice(0, 10) === d.toISOString().slice(0, 10);
  return `Yab on the Mac is offline since ${today ? "" : `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, `}${time}`;
}

function send(ws: WebSocket, message: unknown): boolean {
  try {
    ws.send(JSON.stringify(message));
    return true;
  } catch {
    return false;
  }
}

function sendError(ws: WebSocket, code: string, message: string) {
  send(ws, { t: "error", code, message });
}

function close(ws: WebSocket, code: number, reason: string) {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}
