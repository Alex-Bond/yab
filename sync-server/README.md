# yab-sync

The sync server for Yab: a Cloudflare Worker with Durable Objects on
the SQLite storage backend. It keeps sealed blobs under names it can't read
and never decrypts anything. The protocol is "Protocol v1" in
[`docs/sync.md`](../docs/sync.md).

- `src/index.ts`: the router. `/v1/accounts/{account}/…` goes to the
  `Account` object named after the account, `/v1/pair…` to the single
  `Pairing` object, `GET /v1/health` answers `{"ok":true,"v":1,"androidSync":1}`.
- `src/account.ts`: devices, tokens, records, each device's last presence
  and push token, and the WebSocket (Hibernation API).
- `src/push.ts`: silent pushes to a device with no socket open (APNs,
  ES256 provider token made with WebCrypto).
- `src/pairing.ts`: the ten-minute pairing boxes.
- `src/webpush.ts`: Web Push for sites (`PushBox`, one per Yab, no account
  needed, at `/v1/webpush/…`): sites post RFC 8030 pushes, sealed to keys
  only that Yab has, to `/v1/webpush/p/{box}.{sub}`; Yab takes them over a
  WebSocket. How it fits together is in
  [`docs/site-notifications.md`](../docs/site-notifications.md), "Closed sites".
- Assistants in the cloud ([`docs/assistants.md`](../docs/assistants.md),
  "Server"): `src/assist.ts` routes them, `src/directory.ts` is the single
  `Directory` object (OAuth clients, link codes, authorization and device
  codes, token hashes), `src/host.ts` one `Host` object per Mac (its socket,
  assistants, cached tool lists, queued tasks, approvals, passkey setups),
  `src/pages.ts` the HTML pages.

## Assistant routes

Every address is on the request's own origin.

- `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-authorization-server`
  (also with `/mcp` appended).
- `POST /oauth/register` (RFC 7591, public clients), `GET /oauth/authorize`
  (the page with the code), `GET /oauth/link/{link}` (what that page polls),
  `POST /oauth/device` (RFC 8628), `POST /oauth/token` (code with PKCE S256,
  device code, refresh with rotation), `GET /connect`.
- `POST /mcp` with an access token: forwarded to the Mac's socket (28 s), or
  answered for it while it is away. `GET /mcp` 405, `DELETE /mcp` 204.
- `POST /v1/hosts`, and with the host token `GET /v1/hosts/{id}/socket`,
  `DELETE /v1/hosts/{id}`, `POST /v1/hosts/{id}/links/lookup`,
  `POST /v1/hosts/{id}/links/decide`, `DELETE /v1/hosts/{id}/assistants/{assistant}`.
- `GET`/`POST /yes/{host}/{approval}` (the yes page) and
  `GET`/`POST /yes/{host}/setup/{setup}` (making a passkey).

`/mcp`, `/oauth/token`, `/oauth/register`, `/oauth/device` and `/.well-known/*`
answer CORS preflights. Pages are served with a strict CSP and no referrer.

## Test

```sh
npm install
npm test        # vitest inside the Workers runtime
npm run typecheck
```

## Run and deploy

```sh
npx wrangler dev      # local server on http://localhost:8787
npx wrangler deploy   # publishes "yab-sync" to the signed-in Cloudflare account
```

Silent pushes need the team's APNs auth key (Certificates, Identifiers &
Profiles › Keys, with Apple Push Notifications service) as secrets; without
them the server sends none:

```sh
npx wrangler secret put APNS_KEY      # the .p8 file's text
npx wrangler secret put APNS_KEY_ID   # its ten-character key id
npx wrangler secret put APNS_TEAM     # the APNs key's team id
```

`APNS_HOST` (a var) sends every push to one address instead of Apple's;
`Phone/tools/sync-e2e` points it at a local stand-in. APNs speaks HTTP/2
only: whether a Worker's `fetch` reaches it is the first thing to check
with the real key.

## Limits

- A blob is at most 96 KB of base64; a larger one is rejected with
  `too-big`, the rest of the push still goes through.
- An account holds at most 50 MB of blobs (`full`).
- A push carries at most 500 changes; catch-up batches hold at most 500
  items and 4 MB.
- Pairing: `pub` up to 200 characters, `envelope` up to 4096, ten minutes,
  20 reads of the envelope (reading only `pub` is not counted).

## Beyond the spec

- A rejected change is also listed in `pushed` as
  `"rejected": [{"name", "code"}]`, after an `error` message per code.
- Re-registering a revoked device id answers 403 `{"error":"revoked"}`; a
  wrong secret answers 403 `{"error":"secret"}`.
- A socket gets live changes and presence only after its `hello`; right
  after its catch-up it gets each other device's last presence.
- A push token is the device's own to set (`not-yours` otherwise).

A delayed APNs token rejection is scoped to its registration revision. Re-registering the same token preserves the new registration, even within one millisecond. APNs 410 timestamps use milliseconds since Epoch; an older confirmation does not revoke a newer registration. Existing SQLite push tables gain registered_at and revision without removing tokens.
