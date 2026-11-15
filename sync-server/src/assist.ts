import { showCode } from "./directory";
import { authorizePage, connectPage, messagePage } from "./pages";
import { HOST_ID, bearer, fail, json, readJson } from "./util";

// Routes for assistants in the cloud (docs/assistants.md, "Server"). Every
// address is on the request's own origin, so the same code answers on
// localhost and in production.

type Env = Cloudflare.Env;

const CORS_PATHS = /^\/(mcp|oauth\/token|oauth\/register|oauth\/device|\.well-known\/.*)$/;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "access-control-allow-headers": "Authorization, Content-Type, mcp-protocol-version",
  "access-control-expose-headers": "WWW-Authenticate",
  "access-control-max-age": "86400",
};

const PAGE_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
  "content-security-policy":
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; " +
    "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

export function html(body: string, status = 200): Response {
  return new Response(body, { status, headers: PAGE_HEADERS });
}

export function unauthorizedMcp(request: Request): Response {
  const origin = new URL(request.url).origin;
  return new Response(JSON.stringify({ error: "invalid_token" }), {
    status: 401,
    headers: {
      "content-type": "application/json",
      "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"`,
    },
  });
}

function directory(env: Env) {
  return env.DIRECTORY.get(env.DIRECTORY.idFromName("directory"));
}

function host(env: Env, id: string) {
  return env.HOST.get(env.HOST.idFromName(id));
}

function withCors(response: Response): Response {
  // A WebSocket upgrade or an immutable response can't take new headers.
  if (response.webSocket) return response;
  const copy = new Response(response.body, response);
  for (const [k, v] of Object.entries(CORS)) copy.headers.set(k, v);
  return copy;
}

function noStore(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", pragma: "no-cache" },
  });
}

// OAuth endpoints take a form (RFC 6749) or, for convenience, JSON.
async function readParams(request: Request): Promise<Record<string, string>> {
  const type = request.headers.get("content-type") ?? "";
  const out: Record<string, string> = {};
  if (type.includes("application/json")) {
    const body = await readJson(request);
    if (body && typeof body === "object") {
      for (const [k, v] of Object.entries(body)) if (typeof v === "string") out[k] = v;
    }
    return out;
  }
  const text = new TextDecoder().decode(await request.arrayBuffer());
  for (const [k, v] of new URLSearchParams(text)) out[k] = v;
  return out;
}

export function protectedResource(origin: string) {
  return {
    resource: `${origin}/mcp`,
    authorization_servers: [origin],
    bearer_methods_supported: ["header"],
    resource_name: "Yab",
  };
}

export function authorizationServer(origin: string) {
  return {
    issuer: origin,
    authorization_endpoint: `${origin}/oauth/authorize`,
    token_endpoint: `${origin}/oauth/token`,
    registration_endpoint: `${origin}/oauth/register`,
    device_authorization_endpoint: `${origin}/oauth/device`,
    response_types_supported: ["code"],
    code_challenge_methods_supported: ["S256"],
    grant_types_supported: ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"],
    token_endpoint_auth_methods_supported: ["none"],
  };
}

// Answers the assistant routes, or null for a path that isn't one.
export async function assist(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (CORS_PATHS.test(path)) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    const response = await route(request, env, url);
    return response ? withCors(response) : null;
  }
  return route(request, env, url);
}

async function route(request: Request, env: Env, url: URL): Promise<Response | null> {
  const path = url.pathname;
  const method = request.method;
  const origin = url.origin;

  // Some clients append the resource's path to the well-known address.
  if (path === "/.well-known/oauth-protected-resource" || path === "/.well-known/oauth-protected-resource/mcp") {
    return method === "GET" ? json(protectedResource(origin)) : fail(405, "bad");
  }
  if (path === "/.well-known/oauth-authorization-server" || path === "/.well-known/oauth-authorization-server/mcp") {
    return method === "GET" ? json(authorizationServer(origin)) : fail(405, "bad");
  }

  if (path === "/oauth/register") {
    if (method !== "POST") return fail(405, "bad");
    const out = await directory(env).register(await readJson(request));
    return json(out.body, out.status);
  }

  if (path === "/oauth/authorize") {
    if (method !== "GET") return fail(405, "bad");
    const params = Object.fromEntries(url.searchParams);
    const result = await directory(env).authorize(params);
    if (!result.ok) {
      if (result.redirect) return Response.redirect(result.redirect, 302);
      return html(messagePage("Can't connect", result.message), result.status);
    }
    return html(authorizePage({ client: result.client, code: showCode(result.code), link: result.link }));
  }

  const link = /^\/oauth\/link\/([A-Za-z0-9_-]{1,128})$/.exec(path);
  if (link) {
    if (method !== "GET") return fail(405, "bad");
    const status = await directory(env).linkStatus(link[1]);
    return noStore(status, status.status === "expired" ? 404 : 200);
  }

  if (path === "/oauth/device") {
    if (method !== "POST") return fail(405, "bad");
    const params = await readParams(request);
    const out = await directory(env).device(params.client_id, origin, params.nonce);
    return noStore(out.body, out.status);
  }

  if (path === "/oauth/token") {
    if (method !== "POST") return fail(405, "bad");
    const out = await directory(env).token(await readParams(request));
    const status = out.status === 400 && (out.body as any)?.error === "invalid_client" ? 401 : out.status;
    return noStore(out.body, status);
  }

  if (path === "/connect") {
    return method === "GET" ? html(connectPage()) : fail(405, "bad");
  }

  if (path === "/mcp") {
    if (method === "GET") return new Response(null, { status: 405, headers: { allow: "POST, DELETE" } });
    if (method === "DELETE") return new Response(null, { status: 204 });
    if (method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST, DELETE" } });
    const token = bearer(request);
    const owner = token ? await directory(env).resolve(token) : null;
    if (!owner) return unauthorizedMcp(request);
    const headers = new Headers(request.headers);
    headers.set("x-yab-assistant", owner.assistant);
    return host(env, owner.host).fetch(new Request(request.url, { method: "POST", headers, body: request.body }));
  }

  if (path === "/v1/hosts") {
    if (method !== "POST") return fail(405, "bad");
    const body = await readJson(request);
    if (typeof body?.id !== "string" || !HOST_ID.test(body.id)) return fail(400, "bad", "bad host id");
    return host(env, body.id).fetch(
      new Request(request.url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }),
    );
  }

  const hosts = /^\/v1\/hosts\/([^/]+)(\/.*)?$/.exec(path);
  if (hosts) {
    if (!HOST_ID.test(hosts[1])) return fail(400, "bad", "bad host id");
    // Buffer these small host-control POSTs before proxying them to the DO.
    // An unauthorized DO reply may happen before it reads the body; forwarding
    // the original network stream lets Wrangler try to read it after the 401.
    if (method === "POST") {
      const body = await request.arrayBuffer();
      if (body.byteLength > 16_384) return fail(413, "too-large");
      return host(env, hosts[1]).fetch(new Request(request, { body }));
    }
    return host(env, hosts[1]).fetch(request);
  }

  return null;
}
