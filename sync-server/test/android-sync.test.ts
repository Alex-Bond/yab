import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { devicePlatform } from "../src/census";
import type { Account } from "../src/account";
import { blob, call, Client, newAccount, register, upgrade } from "./helpers";

async function capable(account: string, id: string, platform: "macos" | "ios" | "android" = "macos", version = 1) {
  return call(`/v1/accounts/${account}/devices`, { method: "POST", body: { secret: "s3cret", device: {
    id, name: id, model: platform === "macos" ? "Mac15,3" : platform === "ios" ? "iPhone17,1" : "Pixel 9",
    platform, formFactor: platform === "macos" ? "desktop" : "phone", androidSync: version,
  } } });
}

async function token(response: Response) {
  expect(response.status).toBe(200);
  return ((await response.json()) as { token: string }).token;
}

async function socket(account: string, auth: string, version = 1) {
  return call(`/v1/accounts/${account}/socket`, { token: auth, headers: { upgrade: "websocket", "X-Yab-Android-Sync": String(version) } });
}

describe("Android compatibility admission", () => {
  it("serializes a legacy join racing the first Android admission", async () => {
    const account = newAccount();
    await token(await capable(account, "modern"));
    const [android, legacy] = await Promise.all([
      capable(account, "android", "android"),
      call(`/v1/accounts/${account}/devices`, { method: "POST", body: { secret: "s3cret", device: { id: "legacy", name: "Old", model: "Mac15,3" } } }),
    ]);
    expect([android.status, legacy.status].sort()).toEqual([200, 409]);
  });

  it("keeps legacy registrations at version zero until they re-register", async () => {
    const account = newAccount();
    const legacy = await register(account, "old-mac");
    const list = await call(`/v1/accounts/${account}/devices`, { token: legacy });
    expect(((await list.json()) as any).devices[0]).toMatchObject({ platform: "macos", androidSync: 0 });
    const rejected = await capable(account, "android", "android");
    expect(rejected.status).toBe(409);
    expect((await rejected.json() as any).error).toBe("android-sync-upgrade-required");
    const modern = await token(await capable(account, "old-mac"));
    expect((await call(`/v1/accounts/${account}/devices`, { token: legacy })).status).toBe(401);
    await token(await capable(account, "android", "android"));
    const peers = ((await (await call(`/v1/accounts/${account}/devices`, { token: modern })).json()) as any).devices;
    expect(peers.map((peer: any) => [peer.platform, peer.androidSync])).toEqual([["android", 1], ["macos", 1]]);
  });

  it("blocks cached legacy tokens and software downgrades after Android joins", async () => {
    const account = newAccount();
    const mac = await token(await capable(account, "mac"));
    await token(await capable(account, "android", "android"));
    // The token is valid, but a binary without the handshake version must not read the account.
    expect((await upgrade(account, mac)).status).toBe(409);
    expect((await socket(account, mac, 0)).status).toBe(409);
    const accepted = await socket(account, mac);
    expect(accepted.status).toBe(101);
    const client = new Client(accepted.webSocket!);
    expect((await client.hello()).t).toBe("changes");
    client.ws.close();
    expect((await capable(account, "mac", "macos", 0)).status).toBe(409);
    const newcomer = await call(`/v1/accounts/${account}/devices`, { method: "POST", body: { secret: "s3cret", device: { id: "old-phone", name: "Old", model: "iPhone17,1" } } });
    expect(newcomer.status).toBe(409);
    // Refused re-registration does not revoke the good token.
    expect((await call(`/v1/accounts/${account}/devices`, { token: mac })).status).toBe(200);
  });

  it("an offline legacy peer blocks admission even with no open socket", async () => {
    const account = newAccount();
    const mac = await token(await capable(account, "modern"));
    const legacy = await register(account, "offline");
    expect((await capable(account, "android", "android")).status).toBe(409);
    expect((await call(`/v1/accounts/${account}/devices/offline`, { method: "DELETE", token: mac })).status).toBe(204);
    await token(await capable(account, "android", "android"));
    expect((await upgrade(account, legacy)).status).toBe(401);
  });

  it("a cached-token legacy socket cannot receive Android records after a metadata refresh", async () => {
    const account = newAccount();
    const mac = await token(await capable(account, "mac"));
    const old = await upgrade(account, mac);
    const legacy = new Client(old.webSocket!);
    await legacy.hello();
    // Persisted capability alone is insufficient while an old binary's socket remains open.
    expect((await capable(account, "android", "android")).status).toBe(409);
    const refreshed = await token(await capable(account, "mac"));
    expect((await legacy.closed).code).toBe(4004);
    const android = await token(await capable(account, "android", "android"));
    expect((await upgrade(account, refreshed)).status).toBe(409);
    const writer = new Client((await socket(account, android)).webSocket!);
    await writer.hello();
    expect((await writer.push("one", [{ name: "android-record", base: 0, blob: blob("sealed") }])).accepted).toHaveLength(1);
    writer.ws.close();
  });

  it("migrates an existing device row without treating its token as upgraded", async () => {
    const account = newAccount();
    const legacy = await register(account, "legacy");
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec("ALTER TABLE devices DROP COLUMN android_sync");
      state.storage.sql.exec("ALTER TABLE devices DROP COLUMN form_factor");
      state.storage.sql.exec("ALTER TABLE devices DROP COLUMN platform");
      (_instance as any).schema();
      const rows = state.storage.sql.exec<{ android_sync: number; platform: string }>("SELECT android_sync, platform FROM devices WHERE id = 'legacy'").toArray();
      expect(rows[0].android_sync).toBe(0);
      expect(rows[0].platform).toBe("");
    });
    const pending = await socket(account, legacy);
    expect(pending.status).toBe(101);
    const oldClient = new Client(pending.webSocket!);
    oldClient.ws.close();
    expect((await capable(account, "android", "android")).status).toBe(409);
  });

  it("does not classify unknown or Android hardware as a Mac", () => {
    expect(devicePlatform(undefined, "iPad14,3")).toBe("ios");
    expect(devicePlatform(undefined, "Mac15,3")).toBe("macos");
    expect(devicePlatform(undefined, "Pixel 9")).toBe("unknown");
    expect(devicePlatform("android", "Mac15,3")).toBe("android");
  });

  it("accepts opaque FCM tokens only for Android and routes them separately from APNs", async () => {
    const account = newAccount();
    const mac = await token(await capable(account, "mac"));
    const android = await token(await capable(account, "android", "android"));
    const registration = { token: `fcm:${"A_-".repeat(100)}`, env: "fcm", topic: "dev.yab.android.dev", alerts: true };
    expect((await call(`/v1/accounts/${account}/devices/android/push`, { method: "PUT", token: android, body: registration })).status).toBe(204);
    expect((await call(`/v1/accounts/${account}/devices/mac/push`, { method: "PUT", token: mac, body: registration })).status).toBe(400);
    expect((await call(`/v1/accounts/${account}/devices/android/push`, { method: "PUT", token: android, body: { ...registration, token: "contains\nnewline" } })).status).toBe(400);
    const sent: string[] = [];
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.fcm = {
        silent: async (target) => { sent.push(target.env); return { status: 200 }; },
        alert: async (target) => { sent.push(target.env); return { status: 200 }; },
      };
      instance.apns = { silent: async () => { throw new Error("FCM must not reach APNs"); } };
    });
    const writer = new Client((await socket(account, mac)).webSocket!);
    await writer.hello();
    await writer.push("one", [{ name: "a", base: 0, blob: blob("ciphertext") }]);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(sent).toEqual(["fcm"]);
    writer.ws.close();
  });
});
