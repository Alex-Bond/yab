declare namespace Cloudflare {
  interface Env {
    ACCOUNT: DurableObjectNamespace<import("./account").Account>;
    PAIRING: DurableObjectNamespace<import("./pairing").Pairing>;
    DIRECTORY: DurableObjectNamespace<import("./directory").Directory>;
    HOST: DurableObjectNamespace<import("./host").Host>;
    WEBPUSH: DurableObjectNamespace<import("./webpush").PushBox>;
    CENSUS: DurableObjectNamespace<import("./census").Counts>;
    // Lets the site's /admin read GET /v1/census; without it the route is 404.
    CENSUS_TOKEN?: string;
    // Silent pushes (src/push.ts): the team's APNs auth key, as secrets.
    APNS_KEY?: string;
    APNS_KEY_ID?: string;
    APNS_TEAM?: string;
    APNS_HOST?: string;
  }
}
