import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { isPhone } from "../src/census";
import { call, newAccount, register } from "./helpers";

// The census counts each account's Macs and iPhones (src/census.ts) and
// sums them for /admin; no names leave an account.
const counts = () => env.CENSUS.get(env.CENSUS.idFromName("census"));

async function settle() {
  // The account tells the census after it answers; give that a turn.
  for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 10));
}

describe("census", () => {
  it("tells phones from Macs by model", () => {
    expect(isPhone("iPhone17,1")).toBe(true);
    expect(isPhone("iPad14,3")).toBe(true);
    expect(isPhone("Mac15,3")).toBe(false);
    expect(isPhone("MacBookPro18,1")).toBe(false);
  });

  it("counts devices as they are added and removed, the account by its hashed id", async () => {
    const before = await counts().summary();
    const account = newAccount();
    const token = await register(account, "mac1");
    await register(account, "mac2");
    const phone = await call(`/v1/accounts/${account}/devices`, {
      method: "POST",
      body: { secret: "s3cret", device: { id: "phone1", name: "iPhone", model: "iPhone17,1" } },
    });
    expect(phone.status).toBe(200);
    await settle();
    const after = await counts().summary();
    expect(after.active - before.active).toBe(1);
    expect(after.severalMacs - before.severalMacs).toBe(1);
    expect(after.extraMacs - before.extraMacs).toBe(1);
    expect(after.withPhone - before.withPhone).toBe(1);
    expect((after.byDevices["3"] ?? 0) - (before.byDevices["3"] ?? 0)).toBe(1);

    expect((await call(`/v1/accounts/${account}/devices/mac2`, { method: "DELETE", token })).status).toBe(204);
    await settle();
    const fewer = await counts().summary();
    expect(fewer.severalMacs - before.severalMacs).toBe(0);
    expect((fewer.byDevices["2"] ?? 0) - (before.byDevices["2"] ?? 0)).toBe(1);

    expect((await call(`/v1/accounts/${account}`, { method: "DELETE", token })).status).toBe(204);
    await settle();
    expect((await counts().summary()).accounts).toBe(before.accounts);
  });

  it("answers /v1/census only with the token", async () => {
    expect((await call("/v1/census")).status).toBe(404);
    expect((await call("/v1/census", { token: "wrong" })).status).toBe(404);
  });
});
