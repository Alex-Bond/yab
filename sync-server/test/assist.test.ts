import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Directory } from "../src/directory";
import { Host, offlineSince, outcomeOf } from "../src/host";
import { call } from "./helpers";
import {
  ORIGIN,
  authorize,
  connectHost,
  decide,
  directorySql,
  directoryStub,
  flush,
  form,
  hello,
  hostStub,
  linkAssistant,
  mcp,
  newHostId,
  pkce,
  registerClient,
  registerHost,
  toolText,
} from "./assist-helpers";

const REDIRECT = "https://claude.ai/api/mcp/auth_callback";

async function setHost(id: string, fn: (host: Host) => void) {
  await runInDurableObject(hostStub(id), async (instance: Host) => fn(instance));
}

describe("metadata and CORS", () => {
  it("serves RFC 9728 and RFC 8414 metadata on the request's origin", async () => {
    const res = await call("/.well-known/oauth-protected-resource");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    expect(await res.json()).toMatchObject({ resource: `${ORIGIN}/mcp`, authorization_servers: [ORIGIN] });

    const meta = (await (await call("/.well-known/oauth-authorization-server")).json()) as any;
    expect(meta).toMatchObject({
      issuer: ORIGIN,
      authorization_endpoint: `${ORIGIN}/oauth/authorize`,
      token_endpoint: `${ORIGIN}/oauth/token`,
      registration_endpoint: `${ORIGIN}/oauth/register`,
      device_authorization_endpoint: `${ORIGIN}/oauth/device`,
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
    });
    expect(meta.grant_types_supported).toEqual([
      "authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code",
    ]);
  });

  it("answers preflights with 204", async () => {
    for (const path of ["/mcp", "/oauth/token", "/oauth/register", "/.well-known/oauth-authorization-server"]) {
      const res = await call(path, { method: "OPTIONS" });
      expect(res.status).toBe(204);
      expect(res.headers.get("access-control-allow-origin")).toBe("*");
      expect(res.headers.get("access-control-allow-headers")).toMatch(/mcp-protocol-version/i);
    }
  });

  it("keeps the sync routes as they were", async () => {
    expect(await (await call("/v1/health")).json()).toEqual({ ok: true, v: 1, androidSync: 1 });
    expect((await call("/nowhere")).status).toBe(404);
  });
});

describe("hosts", () => {
  it("registers, checks the secret and replaces the token", async () => {
    const id = newHostId();
    const first = await registerHost(id, "right");
    const wrong = await call("/v1/hosts", { method: "POST", body: { id, secret: "wrong", name: "x" } });
    expect(wrong.status).toBe(403);
    expect(await wrong.json()).toEqual({ error: "secret" });

    const second = await registerHost(id, "right");
    expect(second).not.toBe(first);
    const lookup = (token: string) => call(`/v1/hosts/${id}/links/lookup`, { method: "POST", token, body: { code: "AAAAAAAA" } });
    expect((await lookup(first)).status).toBe(401);
    expect((await lookup(second)).status).toBe(404);
  });

  it("validates ids", async () => {
    for (const body of [
      { id: "short", secret: "s", name: "x" },
      { id: "has space in it here", secret: "s", name: "x" },
      { id: newHostId(), secret: "", name: "x" },
      { id: newHostId(), secret: "s", name: "x".repeat(201) },
    ]) {
      expect((await call("/v1/hosts", { method: "POST", body })).status).toBe(400);
    }
  });

  it("needs the host token for the socket", async () => {
    const id = newHostId();
    await registerHost(id);
    const res = await call(`/v1/hosts/${id}/socket`, { token: "nope", headers: { upgrade: "websocket" } });
    expect(res.status).toBe(401);
  });

  it("deleting a host closes its socket with 4003 and stops its tokens", async () => {
    const id = newHostId();
    const token = await registerHost(id);
    const { access } = await linkAssistant(id, token, "asst_delete1");
    const mac = await connectHost(id, token);
    await hello(mac, ["asst_delete1"]);
    expect((await call(`/v1/hosts/${id}`, { method: "DELETE", token })).status).toBe(204);
    expect((await mac.closed).code).toBe(4003);
    expect((await mcp(access, { jsonrpc: "2.0", id: 1, method: "tools/list" })).status).toBe(401);
  });
});

describe("authorization code flow", () => {
  it("links an assistant with PKCE through the Mac's code", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const client = await registerClient("Claude", REDIRECT);
    expect(client).toMatchObject({ client_name: "Claude", redirect_uris: [REDIRECT], token_endpoint_auth_method: "none" });

    const { verifier, challenge } = await pkce();
    const { res, page, code, link } = await authorize(client.client_id, REDIRECT, challenge, "xyz");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/text\/html/);
    expect(page).toContain("Connect Claude to Yab");
    expect(page).toContain("Settings › AI › Assistants › Enter Code");
    expect(code).toMatch(/^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
    expect(page).not.toContain("\u2014");

    expect(await (await call(`/oauth/link/${link}`)).json()).toEqual({ status: "pending" });

    // The Mac types it in lower case without the dash.
    const typed = code.replace("-", "").toLowerCase();
    const look = await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code: typed } });
    expect(look.status).toBe(200);
    expect(await look.json()).toMatchObject({ link, client: "Claude", kind: "oauth", redirect: REDIRECT });

    expect((await decide(hostId, hostToken, link, true, { id: "asst_claude1", name: "Claude" })).status).toBe(204);
    // Decided once is decided.
    expect((await decide(hostId, hostToken, link, false)).status).toBe(409);
    // A decided link is no longer found by its code.
    expect((await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code } })).status).toBe(404);

    const status = (await (await call(`/oauth/link/${link}`)).json()) as any;
    expect(status.status).toBe("allowed");
    const back = new URL(status.redirect);
    expect(back.origin + back.pathname).toBe(REDIRECT);
    expect(back.searchParams.get("state")).toBe("xyz");
    const authCode = back.searchParams.get("code")!;
    // Polling again gives the same address.
    expect(((await (await call(`/oauth/link/${link}`)).json()) as any).redirect).toBe(status.redirect);

    const bad = await call("/oauth/token", form({
      grant_type: "authorization_code", code: authCode, code_verifier: "x".repeat(43), redirect_uri: REDIRECT, client_id: client.client_id,
    }));
    expect(bad.status).toBe(400);
    expect(((await bad.json()) as any).error).toBe("invalid_grant");
    // The code was spent by the wrong try.
    const again = await call("/oauth/token", form({
      grant_type: "authorization_code", code: authCode, code_verifier: verifier, redirect_uri: REDIRECT, client_id: client.client_id,
    }));
    expect(((await again.json()) as any).error).toBe("invalid_grant");
  });

  it("issues tokens for a right verifier, once", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const client = await registerClient("ChatGPT", REDIRECT);
    const { verifier, challenge } = await pkce();
    const { code, link } = await authorize(client.client_id, REDIRECT, challenge);
    await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code } });
    await decide(hostId, hostToken, link, true, { id: "asst_chatgpt", name: "ChatGPT" });
    const status = (await (await call(`/oauth/link/${link}`)).json()) as any;
    const authCode = new URL(status.redirect).searchParams.get("code")!;
    const params = { grant_type: "authorization_code", code: authCode, code_verifier: verifier, redirect_uri: REDIRECT, client_id: client.client_id };
    const res = await call("/oauth/token", form(params));
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const tokens = (await res.json()) as any;
    expect(tokens).toMatchObject({ token_type: "Bearer", expires_in: 2592000 });
    expect(typeof tokens.access_token).toBe("string");
    expect(typeof tokens.refresh_token).toBe("string");
    expect(((await (await call("/oauth/token", form(params))).json()) as any).error).toBe("invalid_grant");
  });

  it("a no from the Mac sends access_denied back", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const client = await registerClient("Grok", REDIRECT);
    const { challenge } = await pkce();
    const { link } = await authorize(client.client_id, REDIRECT, challenge, "s1");
    expect((await decide(hostId, hostToken, link, false)).status).toBe(204);
    const status = (await (await call(`/oauth/link/${link}`)).json()) as any;
    expect(status.status).toBe("denied");
    const back = new URL(status.redirect);
    expect(back.searchParams.get("error")).toBe("access_denied");
    expect(back.searchParams.get("state")).toBe("s1");
  });

  it("rejects bad clients, redirects and missing PKCE", async () => {
    expect((await call("/oauth/register", { method: "POST", body: { client_name: "x", redirect_uris: ["http://evil.example/cb"] } })).status).toBe(400);
    expect((await call("/oauth/register", { method: "POST", body: { client_name: "x", redirect_uris: [] } })).status).toBe(400);
    const local = await call("/oauth/register", { method: "POST", body: { client_name: "x", redirect_uris: ["http://127.0.0.1:3000/cb"] } });
    expect(local.status).toBe(201);

    const client = await registerClient("X", REDIRECT);
    const unknown = await authorize("nobody", REDIRECT, "a".repeat(43));
    expect(unknown.res.status).toBe(400);
    const elsewhere = await authorize(client.client_id, "https://evil.example/cb", "a".repeat(43));
    expect(elsewhere.res.status).toBe(400);
    const noPkce = await call(`/oauth/authorize?response_type=code&client_id=${client.client_id}&redirect_uri=${encodeURIComponent(REDIRECT)}&state=q`, { redirect: "manual" });
    expect(noPkce.status).toBe(302);
    const to = new URL(noPkce.headers.get("location")!);
    expect(to.searchParams.get("error")).toBe("invalid_request");
    expect(to.searchParams.get("state")).toBe("q");
  });

  it("prefers a live code over an expired link that used the same letters", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const client = await registerClient("Muse", REDIRECT);
    const { challenge } = await pkce();
    const old = await authorize(client.client_id, REDIRECT, challenge);
    const fresh = await authorize(client.client_id, REDIRECT, challenge);
    await directorySql("UPDATE links SET expires = ? WHERE id = ?", Date.now() - 1, old.link);
    await directorySql("UPDATE links SET code = ? WHERE id = ?", old.code.replace(/-/g, ""), fresh.link);
    const lookup = await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code: old.code } });
    expect(lookup.status).toBe(200);
    expect(await lookup.json()).toMatchObject({ link: fresh.link });
  });

  it("an expired link is gone for the page and the Mac", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const client = await registerClient("Muse", REDIRECT);
    const { challenge } = await pkce();
    const { code, link } = await authorize(client.client_id, REDIRECT, challenge);
    await directorySql("UPDATE links SET expires = ? WHERE id = ?", Date.now() - 1, link);
    const status = await call(`/oauth/link/${link}`);
    expect(status.status).toBe(404);
    expect(await status.json()).toEqual({ status: "expired" });
    expect((await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code } })).status).toBe(410);
    expect((await decide(hostId, hostToken, link, true, { id: "asst_muse01", name: "Muse" })).status).toBe(404);
  });
});

describe("device flow", () => {
  async function start(clientId = "yab-mcp") {
    const res = await call("/oauth/device", form({ client_id: clientId }));
    expect(res.status).toBe(200);
    return (await res.json()) as any;
  }
  const poll = (deviceCode: string, clientId = "yab-mcp") =>
    call("/oauth/token", form({ grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: deviceCode, client_id: clientId }));

  it("pending, slow_down, then tokens", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const d = await start();
    expect(d).toMatchObject({ verification_uri: `${ORIGIN}/connect`, expires_in: 600, interval: 2 });
    expect(d.user_code).toMatch(/^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);

    const first = await poll(d.device_code);
    expect(first.status).toBe(400);
    expect(((await first.json()) as any).error).toBe("authorization_pending");
    const fast = (await (await poll(d.device_code)).json()) as any;
    expect(fast.error).toBe("slow_down");
    expect(fast.interval).toBe(7);

    const look = await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code: d.user_code } });
    const found = (await look.json()) as any;
    expect(found).toMatchObject({ client: "yab-mcp", kind: "device", redirect: null });
    expect((await decide(hostId, hostToken, found.link, true, { id: "asst_hermes", name: "Hermes" })).status).toBe(204);

    await directorySql("UPDATE links SET last_poll = 0 WHERE id = ?", found.link);
    const done = await poll(d.device_code);
    expect(done.status).toBe(200);
    const tokens = (await done.json()) as any;
    expect(tokens).toMatchObject({ token_type: "Bearer", expires_in: 2592000 });
    // Spent.
    expect(((await (await poll(d.device_code)).json()) as any).error).toBe("invalid_grant");
    // The token reaches the host (offline: answered from the cache).
    const res = await mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(await res.json()).toEqual({ jsonrpc: "2.0", id: 1, result: { tools: [] } });
  });

  it("a second connection of the same bot is its own, the first keeps working", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const connect = async (assistant: string) => {
      const d = await start("grok-bot");
      const found = (await (await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code: d.user_code } })).json()) as any;
      expect(found).toMatchObject({ client_id: "grok-bot", kind: "device" });
      expect((await decide(hostId, hostToken, found.link, true, { id: assistant, name: "Grok Bot" })).status).toBe(204);
      await directorySql("UPDATE links SET last_poll = 0 WHERE id = ?", found.link);
      const done = await poll(d.device_code, "grok-bot");
      expect(done.status).toBe(200);
      return ((await done.json()) as any).access_token as string;
    };
    const first = await connect("asst_grokwork");
    const second = await connect("asst_grokhome");
    expect(second).not.toBe(first);
    for (const token of [first, second]) {
      const res = await mcp(token, { jsonrpc: "2.0", id: 1, method: "tools/list" });
      expect(await res.json()).toEqual({ jsonrpc: "2.0", id: 1, result: { tools: [] } });
    }
  });

  it("access_denied and expired_token", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const denied = await start("dots");
    const found = (await (await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code: denied.user_code } })).json()) as any;
    await decide(hostId, hostToken, found.link, false);
    expect(((await (await poll(denied.device_code, "dots")).json()) as any).error).toBe("access_denied");

    const late = await start("dots");
    await directorySql("UPDATE links SET expires = ? WHERE kind = 'device' AND code = ?", Date.now() - 1, late.user_code.replace("-", ""));
    expect(((await (await poll(late.device_code, "dots")).json()) as any).error).toBe("expired_token");
    // Another client can't poll this device code.
    const other = await start("dots");
    expect(((await (await poll(other.device_code, "someone-else")).json()) as any).error).toBe("invalid_grant");
  });

  it("accepts JSON too", async () => {
    const res = await call("/oauth/device", { method: "POST", body: { client_id: "openclaw" } });
    expect(res.status).toBe(200);
  });

  it("carries a connection nonce to the Mac without accepting a guessed one", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const nonce = "Qe7aC1jYwR2uK5sT";
    const issued = await call("/oauth/device", form({ client_id: "dots", nonce }));
    expect(issued.status).toBe(200);
    const code = ((await issued.json()) as any).user_code;
    const found = await call(`/v1/hosts/${hostId}/links/lookup`, { method: "POST", token: hostToken, body: { code } });
    expect(await found.json()).toMatchObject({ client: "dots", kind: "device", nonce });
    expect((await call("/oauth/device", form({ client_id: "dots", nonce: "short" }))).status).toBe(400);
  });
});

describe("refresh tokens", () => {
  it("rotate", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { clientId, refresh } = await linkAssistant(hostId, hostToken, "asst_rotate1");
    const res = await call("/oauth/token", form({ grant_type: "refresh_token", refresh_token: refresh, client_id: clientId }));
    expect(res.status).toBe(200);
    const next = (await res.json()) as any;
    expect(next.refresh_token).not.toBe(refresh);
    expect((await mcp(next.access_token, { jsonrpc: "2.0", id: 1, method: "tools/list" })).status).toBe(200);
    const reuse = await call("/oauth/token", form({ grant_type: "refresh_token", refresh_token: refresh, client_id: clientId }));
    expect(((await reuse.json()) as any).error).toBe("invalid_grant");
    const wrongClient = await call("/oauth/token", form({ grant_type: "refresh_token", refresh_token: next.refresh_token, client_id: "other" }));
    expect(((await wrongClient.json()) as any).error).toBe("invalid_grant");
    expect(((await (await call("/oauth/token", form({ grant_type: "password" }))).json()) as any).error).toBe("unsupported_grant_type");
  });
});

describe("/mcp", () => {
  it("401 with WWW-Authenticate without a valid token", async () => {
    for (const token of [undefined, "nope"]) {
      const res = await mcp(token, { jsonrpc: "2.0", id: 1, method: "initialize" });
      expect(res.status).toBe(401);
      expect(res.headers.get("www-authenticate")).toBe(`Bearer resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource"`);
      expect(res.headers.get("access-control-expose-headers")).toMatch(/WWW-Authenticate/i);
    }
    expect((await call("/mcp")).status).toBe(405);
    expect((await call("/mcp", { method: "DELETE" })).status).toBe(204);
  });

  it("forwards a call to the Mac and answers with its reply", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_round1");
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, ["asst_round1"]);

    const pending = mcp(access, { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "tabs", arguments: {} } });
    const msg = await mac.next();
    expect(msg).toMatchObject({ t: "call", assistant: "asst_round1", body: { id: 7, method: "tools/call" } });
    expect(msg.queued).toBeUndefined();
    mac.send({ t: "reply", id: msg.id, body: { jsonrpc: "2.0", id: 7, result: { content: [{ type: "text", text: "ok" }] } } });
    const res = await pending;
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(await res.json()).toEqual({ jsonrpc: "2.0", id: 7, result: { content: [{ type: "text", text: "ok" }] } });
  });

  it("forwards a batch and answers -32001 past the wait", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_slow01");
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, ["asst_slow01"]);
    await setHost(hostId, (h) => (h.callWait = 100));
    const res = await mcp(access, [
      { jsonrpc: "2.0", id: 1, method: "tools/list" },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "ping" },
    ]);
    const msg = await mac.next();
    expect(Array.isArray(msg.body)).toBe(true);
    expect(await res.json()).toEqual([
      { jsonrpc: "2.0", id: 1, error: { code: -32001, message: "Yab on the Mac took too long" } },
      { jsonrpc: "2.0", id: 2, error: { code: -32001, message: "Yab on the Mac took too long" } },
    ]);
  });

  it("notifications get 202 and reach the Mac", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_notify");
    // Offline: 202, nothing kept.
    expect((await mcp(access, { jsonrpc: "2.0", method: "notifications/initialized" })).status).toBe(202);
    const mac = await connectHost(hostId, hostToken);
    expect(await hello(mac, ["asst_notify"])).toEqual([]);
    const res = await mcp(access, { jsonrpc: "2.0", method: "notifications/initialized" });
    expect(res.status).toBe(202);
    const msg = await mac.next();
    expect(msg).toMatchObject({ t: "call", assistant: "asst_notify", body: { method: "notifications/initialized" } });
  });

  it("bad JSON is a parse error", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_parse1");
    const res = await call("/mcp", { method: "POST", token: access, body: "{nope", headers: { "content-type": "application/json" } });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe(-32700);
  });
});

describe("Mac away", () => {
  it("initialize and tools/list come from the last tools message", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_cache1");
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, ["asst_cache1"]);
    const tools = [{ name: "tabs", description: "Your tabs", inputSchema: { type: "object" } }];
    mac.send({ t: "tools", assistant: "asst_cache1", tools, instructions: "Use Yab." });
    await flush(mac);
    mac.ws.close(1000, "bye");
    await mac.closed;
    await new Promise((r) => setTimeout(r, 50));

    const init = (await (await mcp(access, {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "c", version: "1" } },
    })).json()) as any;
    expect(init.result).toMatchObject({
      protocolVersion: "2025-06-18",
      serverInfo: { name: "yab-browser" },
      capabilities: { tools: {} },
      instructions: "Use Yab.",
    });
    const list = (await (await mcp(access, { jsonrpc: "2.0", id: 2, method: "tools/list" })).json()) as any;
    expect(list.result.tools).toEqual(tools);
  });

  it("a task waits for the Mac and arrives after hello", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_queue1");
    const body = { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "task", arguments: { task: "Find a flight" } } };
    const before = Date.now();
    const answer = (await (await mcp(access, body)).json()) as any;
    expect(answer.result.isError).toBeUndefined();
    const status = toolText(answer);
    expect(status).toMatchObject({ status: "mac_offline", queued: true, last_seen: null });
    expect(status.until).toBeGreaterThanOrEqual(before + 12 * 3600 * 1000);
    expect(status.says).toMatch(/12 hours/);

    const mac = await connectHost(hostId, hostToken);
    const queued = await hello(mac, ["asst_queue1"]);
    expect(queued).toHaveLength(1);
    expect(queued[0]).toMatchObject({ t: "call", assistant: "asst_queue1", queued: true, body });
    // Delivered once.
    mac.ws.close(1000, "bye");
    await mac.closed;
    const again = await connectHost(hostId, hostToken);
    expect(await hello(again, ["asst_queue1"])).toEqual([]);
  });

  it("any other tool says mac_offline with isError", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access } = await linkAssistant(hostId, hostToken, "asst_off001");
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, ["asst_off001"]);
    mac.ws.close(1000, "bye");
    await mac.closed;
    await new Promise((r) => setTimeout(r, 50));
    const answer = (await (await mcp(access, {
      jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "open", arguments: { url: "https://example.com" } },
    })).json()) as any;
    expect(answer.result.isError).toBe(true);
    const status = toolText(answer);
    expect(status.status).toBe("mac_offline");
    expect(typeof status.last_seen).toBe("number");
    expect(status.says).toMatch(/^Yab on the Mac is offline since \d\d:\d\d UTC, so nothing was done\. Ask the user to wake it\.$/);
  });

  it("formats the time it was last seen", () => {
    const now = Date.UTC(2026, 9, 10, 18, 0);
    expect(offlineSince(Date.UTC(2026, 9, 10, 14, 5), now)).toBe("Yab on the Mac is offline since 14:05 UTC");
    expect(offlineSince(Date.UTC(2026, 9, 9, 9, 30), now)).toBe("Yab on the Mac is offline since Oct 9, 09:30 UTC");
    expect(offlineSince(null, now)).toBe("Yab on the Mac has not connected yet");
  });
});

describe("assistants", () => {
  it("hello deletes assistants the Mac doesn't have, tokens too", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const kept = await linkAssistant(hostId, hostToken, "asst_keep01");
    const gone = await linkAssistant(hostId, hostToken, "asst_gone01");
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, ["asst_keep01", "asst_unknown"]);
    expect((await mcp(gone.access, { jsonrpc: "2.0", method: "notifications/initialized" })).status).toBe(401);
    expect((await mcp(kept.access, { jsonrpc: "2.0", method: "notifications/initialized" })).status).toBe(202);
    const refresh = await call("/oauth/token", form({ grant_type: "refresh_token", refresh_token: gone.refresh, client_id: gone.clientId }));
    expect(((await refresh.json()) as any).error).toBe("invalid_grant");
  });

  it("disconnect stops its tokens at once", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const { access, refresh, clientId } = await linkAssistant(hostId, hostToken, "asst_disc01");
    expect((await mcp(access, { jsonrpc: "2.0", id: 1, method: "tools/list" })).status).toBe(200);
    const res = await call(`/v1/hosts/${hostId}/assistants/asst_disc01`, { method: "DELETE", token: hostToken });
    expect(res.status).toBe(204);
    const after = await mcp(access, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(after.status).toBe(401);
    expect(after.headers.get("www-authenticate")).toContain("resource_metadata=");
    const r = await call("/oauth/token", form({ grant_type: "refresh_token", refresh_token: refresh, client_id: clientId }));
    expect(((await r.json()) as any).error).toBe("invalid_grant");
  });
});

describe("approvals stay on the person's Sync devices", () => {
  it("has no relay approval or passkey page", async () => {
    const hostId = newHostId();
    const hostToken = await registerHost(hostId);
    const mac = await connectHost(hostId, hostToken);
    await hello(mac, []);
    expect((await call(`/yes/${hostId}/anything`)).status).toBe(404);
    expect((await call(`/yes/${hostId}/anything`, { method: "POST", body: { deny: true } })).status).toBe(404);
    mac.send({ t: "approval", id: "appr_00001", assistant: "asst_test01", title: "Pay", lines: [], expires: Date.now() + 60_000 });
    expect(await mac.next()).toMatchObject({ t: "error", code: "bad" });
  });
});

describe("pages", () => {
  it("/connect explains where the code goes", async () => {
    const res = await call("/connect");
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("Settings › AI › Assistants › Enter Code");
    expect(text).not.toContain("\u2014");
  });
});

describe("link lookup limits", () => {
  it("answers 429 after ten wrong codes in a minute", async () => {
    const id = newHostId();
    const token = await registerHost(id);
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) {
      const response = await call(`/v1/hosts/${id}/links/lookup`, { method: "POST", token, body: { code: "ZZZZZZZZ" } });
      statuses.push(response.status);
    }
    expect(statuses.slice(0, 10).every((s) => s === 404)).toBe(true);
    expect(statuses[10]).toBe(429);
  });
});

describe("journal", () => {
  it("keeps which tool and how it went, never arguments, and the Mac reads it", async () => {
    const id = newHostId();
    const token = await registerHost(id);
    const { access } = await linkAssistant(id, token, "asst-journal-1");
    // The Mac is away: a call is offline, a task is queued.
    await mcp(access, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "open", arguments: { url: "https://secret.example/x" } } });
    await mcp(access, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "task", arguments: { prompt: "a secret plan" } } });
    const response = await call(`/v1/hosts/${id}/log?assistant=asst-journal-1`, { token });
    expect(response.status).toBe(200);
    const { entries } = (await response.json()) as any;
    expect(entries.map((e: any) => [e.tool, e.outcome])).toEqual([["task", "mac_offline"], ["open", "mac_offline"]]);
    expect(JSON.stringify(entries)).not.toContain("secret");
  });

  it("outcomeOf reads the status line, an error, or plain success", () => {
    expect(outcomeOf({ result: { content: [{ text: "status: needs_user\napproval: x" }] } })).toBe("needs_user");
    expect(outcomeOf({ error: { code: -32001 } })).toBe("error");
    expect(outcomeOf({ result: { content: [{ text: "tab: 1" }] } })).toBe("ok");
    expect(outcomeOf({ result: { content: [{ text: "nope" }], isError: true } })).toBe("failed");
  });
});

describe("directory cleanup", () => {
  it("drops a registered client that never got a token after a week", async () => {
    const { client_id: unused } = await registerClient("Unused", REDIRECT);
    const { client_id: kept } = await registerClient("Kept", REDIRECT);
    const week = 7 * 24 * 3600 * 1000;
    await directorySql("UPDATE clients SET created = ? WHERE id IN (?, ?)", Date.now() - week - 1, unused, kept);
    await directorySql(
      "INSERT INTO tokens (hash, kind, host, assistant, client, expires) VALUES ('h', 'refresh', 'x', 'y', ?, ?)",
      kept, Date.now() + week,
    );
    let left: string[] = [];
    await runInDurableObject(directoryStub(), async (instance: Directory, state) => {
      await instance.alarm();
      const rows = state.storage.sql.exec("SELECT id FROM clients WHERE id IN (?, ?)", unused, kept).toArray();
      left = rows.map((r) => String(r.id));
    });
    expect(left).toEqual([kept]);
  });
});
