import { ACCOUNT_ID, bearer, fail, json, sameDigest } from "./util";
import { Counts } from "./census";
import { Account } from "./account";
import { Pairing } from "./pairing";
import { Directory } from "./directory";
import { Host } from "./host";
import { assist } from "./assist";
import { BOX_ID, PushBox } from "./webpush";

export { Account, Pairing, PushBox, Directory, Host, Counts };

type Env = Cloudflare.Env;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;

    if (path === "/v1/health" && request.method === "GET") return json({ ok: true, v: 1, androidSync: 1 });

    // How many Macs and iPhones accounts sync, summed (src/census.ts), for
    // the site's /admin with the census token.
    if (path === "/v1/census" && request.method === "GET") {
      if (!env.CENSUS_TOKEN || !sameDigest(bearer(request) ?? "", env.CENSUS_TOKEN)) return fail(404, "not-found");
      return json(await env.CENSUS.get(env.CENSUS.idFromName("census")).summary());
    }

    if (path === "/v1/pair" || path.startsWith("/v1/pair/")) {
      return env.PAIRING.get(env.PAIRING.idFromName("pairing")).fetch(request);
    }

    // Web Push (src/webpush.ts): Yab's box by its id, and a site's endpoint,
    // {box}.{sub}, to the same box.
    const box = /^\/v1\/webpush\/(?:boxes\/([^/]+)(?:\/.*)?|p\/([^/.]+)\.[^/]+)$/.exec(path);
    if (box) {
      const id = box[1] ?? box[2];
      if (!BOX_ID.test(id)) return fail(box[2] ? 404 : 400, box[2] ? "not-found" : "bad", "bad box id");
      return env.WEBPUSH.get(env.WEBPUSH.idFromName(id)).fetch(request);
    }

    const match = /^\/v1\/accounts\/([^/]+)(\/.*)?$/.exec(path);
    if (match) {
      if (!ACCOUNT_ID.test(match[1])) return fail(400, "bad", "bad account id");
      return env.ACCOUNT.get(env.ACCOUNT.idFromName(match[1])).fetch(request);
    }

    // Assistants in the cloud: /mcp, /oauth/*, /.well-known/*, /connect,
    // /v1/hosts/* (src/assist.ts).
    const assisted = await assist(request, env);
    if (assisted) return assisted;

    return fail(404, "not-found");
  },
} satisfies ExportedHandler<Env>;
