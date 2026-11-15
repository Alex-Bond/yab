import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { sha256hex } from "../src/util";
import { call } from "./helpers";

const pairing = () => env.PAIRING.get(env.PAIRING.idFromName("pairing"));

async function newCode() {
  return sha256hex(crypto.randomUUID().slice(0, 8));
}

describe("pairing", () => {
  it("passes a public key one way and an envelope back", async () => {
    const code = await newCode();
    expect((await call("/v1/pair", { method: "POST", body: { code, pub: "cHVi" } })).status).toBe(204);

    const first = await call(`/v1/pair/${code}`);
    expect(await first.json()).toEqual({ pub: "cHVi" });

    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "ZW52" } })).status).toBe(204);
    expect(await (await call(`/v1/pair/${code}`)).json()).toEqual({ pub: "cHVi", envelope: "ZW52" });

    // Neither the code nor the envelope can be taken over.
    expect((await call("/v1/pair", { method: "POST", body: { code, pub: "b3RoZXI=" } })).status).toBe(409);
    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "b3RoZXI=" } })).status).toBe(409);
  });

  it("validates codes and sizes", async () => {
    const code = await newCode();
    expect((await call("/v1/pair", { method: "POST", body: { code: "abc", pub: "x" } })).status).toBe(400);
    expect((await call("/v1/pair", { method: "POST", body: { code, pub: "x".repeat(201) } })).status).toBe(400);
    await call("/v1/pair", { method: "POST", body: { code, pub: "x" } });
    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "e".repeat(4097) } })).status).toBe(400);
    expect((await call(`/v1/pair/${await newCode()}`)).status).toBe(404);
  });

  it("waits its ten minutes however often the public key is read", async () => {
    const code = await newCode();
    await call("/v1/pair", { method: "POST", body: { code, pub: "x" } });
    // A new device polling every 2 s for five minutes, and the Mac's look.
    for (let i = 0; i < 151; i++) expect((await call(`/v1/pair/${code}`)).status).toBe(200);
    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "ZW52" } })).status).toBe(204);
    expect(await (await call(`/v1/pair/${code}`)).json()).toEqual({ pub: "x", envelope: "ZW52" });
  });

  it("allows at most 20 reads of the envelope", async () => {
    const code = await newCode();
    await call("/v1/pair", { method: "POST", body: { code, pub: "x" } });
    for (let i = 0; i < 30; i++) expect((await call(`/v1/pair/${code}`)).status).toBe(200);
    await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "ZW52" } });
    for (let i = 0; i < 20; i++) {
      const read = await call(`/v1/pair/${code}`);
      expect(read.status).toBe(200);
      expect(await read.json()).toEqual({ pub: "x", envelope: "ZW52" });
    }
    // Read out: the box and the key in it are gone.
    expect((await call(`/v1/pair/${code}`)).status).toBe(404);
    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "b3RoZXI=" } })).status).toBe(404);
  });

  it("expires after ten minutes", async () => {
    const code = await newCode();
    await call("/v1/pair", { method: "POST", body: { code, pub: "x" } });
    await runInDurableObject(pairing(), (_, state) => {
      state.storage.sql.exec("UPDATE boxes SET expires = ? WHERE code = ?", Date.now() - 1, code);
    });
    expect((await call(`/v1/pair/${code}`)).status).toBe(404);
    expect((await call(`/v1/pair/${code}`, { method: "PUT", body: { envelope: "e" } })).status).toBe(404);
  });

  it("the alarm sweeps expired boxes", async () => {
    const code = await newCode();
    await call("/v1/pair", { method: "POST", body: { code, pub: "x" } });
    const stub = pairing();
    await runInDurableObject(stub, async (_, state) => {
      state.storage.sql.exec("UPDATE boxes SET expires = ? WHERE code = ?", Date.now() - 1, code);
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const left = await runInDurableObject(stub, (_, state) =>
      state.storage.sql.exec("SELECT COUNT(*) AS n FROM boxes WHERE code = ?", code).one().n,
    );
    expect(left).toBe(0);
  });
});
