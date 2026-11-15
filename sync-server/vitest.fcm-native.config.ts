import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Mock below the Worker runtime, preserving the real native fetch receiver.
// No production account, key, token or external network is used.
export default defineConfig({
  test: { include: ["qa/fcm-native-fetch.ts"] },
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      outboundService: async (request: Request) => {
        const url = new URL(request.url);
        if (request.method === "POST" && url.origin === "https://oauth2.googleapis.com" && url.pathname === "/token") {
          return Response.json({ access_token: "fixture-only-access-token", expires_in: 3600 });
        }
        if (request.method === "POST" && url.origin === "https://fcm.googleapis.com" && url.pathname === "/v1/projects/test-project/messages:send" &&
            request.headers.get("authorization") === "Bearer fixture-only-access-token") {
          return Response.json({ name: "projects/test-project/messages/native-fetch" });
        }
        return new Response("Unexpected outbound request in isolated FCM regression", { status: 502 });
      },
    },
  })],
});
