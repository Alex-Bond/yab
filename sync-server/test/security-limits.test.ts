import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { call, newAccount, register } from "./helpers";

describe("security request limits", () => {
  it("throttles wrong secrets without locking out a valid registration", async () => {
    const account = newAccount();
    await register(account, "owner", "right");
    const wrong = () => call(`/v1/accounts/${account}/devices`, {
      method: "POST", body: { secret: "wrong", device: { id: "other", name: "x", model: "y" } },
    });
    for (let i = 0; i < 5; i++) expect((await wrong()).status).toBe(403);
    expect((await wrong()).status).toBe(429);
    expect((await call(`/v1/accounts/${account}/devices`, {
      method: "POST", body: { secret: "right", device: { id: "new", name: "New Mac", model: "Mac15,3" } },
    })).status).toBe(200);
    expect((await wrong()).status).toBe(403);
  });

  it("expires the failed-secret window from its first failure", async () => {
    const account = newAccount();
    await register(account, "owner", "right");
    const wrong = () => call(`/v1/accounts/${account}/devices`, {
      method: "POST", body: { secret: "wrong", device: { id: "other", name: "x", model: "y" } },
    });
    for (let i = 0; i < 6; i++) await wrong();
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (_, state) => {
      state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'register_misses_at'", String(Date.now() - 10 * 60 * 1000 - 1));
    });
    expect((await wrong()).status).toBe(403);
    for (let i = 0; i < 4; i++) expect((await wrong()).status).toBe(403);
    expect((await wrong()).status).toBe(429);
  });

  it("limits pairing by source IP and releases the limit after a minute", async () => {
    const code = "a".repeat(64);
    const request = (ip: string) => call(`/v1/pair/${code}`, { headers: { "cf-connecting-ip": ip } });
    for (let i = 0; i < 100; i++) expect((await request("192.0.2.1")).status).toBe(404);
    expect((await request("192.0.2.1")).status).toBe(429);
    expect((await request("192.0.2.2")).status).toBe(404);
    const stub = env.PAIRING.get(env.PAIRING.idFromName("pairing"));
    await runInDurableObject(stub, (_, state) => {
      state.storage.sql.exec("UPDATE hits SET at = ? WHERE ip = ?", Date.now() - 60_001, "192.0.2.1");
    });
    expect((await request("192.0.2.1")).status).toBe(404);
  });
});
