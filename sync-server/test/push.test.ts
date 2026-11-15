import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { Account } from "../src/account";
import { ALERT_BLOB, alertBody } from "../src/push";
import type { PushResult, PushTarget, Sealed } from "../src/push";
import { blob, call, connect, newAccount, register } from "./helpers";

const TOKEN = "a1".repeat(32);

// Puts a recorder where the account's Durable Object sends its pushes.
async function record(account: string): Promise<PushTarget[]> {
  const sent: PushTarget[] = [];
  const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
  await runInDurableObject(stub, (instance: Account) => {
    instance.apns = { silent: async (target) => (sent.push(target), { status: 200 }) };
  });
  return sent;
}

async function settled(ms = 100) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

describe("approval withdrawal", () => {
  it("bypasses the minute, sends no alert and deduplicates opening and closing", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone", alerts: true },
    });
    const sent: (string | undefined)[] = [];
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.apns = { silent: async (_, id) => (sent.push(id), { status: 200 }),
        alert: async () => { throw new Error("A withdrawal must never ring"); } };
    });
    await mac.push("plain", [{ name: "plain", base: 0, blob: blob("plain") }]);
    await settled();
    const id = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10";
    await mac.push("seen", [{ name: "question", base: 0, blob: blob("seen") }], "question", id, true);
    await settled();
    expect(sent).toEqual([undefined, id]);
    await mac.push("closed", [{ name: "question", base: 1, blob: blob("gone") }], "question", id, true);
    await settled();
    expect(sent).toEqual([undefined, id]);
    // A different question gets its own wake immediately.
    const next = "4f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10";
    await mac.push("next", [{ name: "next", base: 0, blob: blob("gone") }], "next", next, true);
    await settled();
    expect(sent).toEqual([undefined, id, next]);
  });

  it("does not withdraw rejected or conflicting changes", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
    });
    const sent = await record(account);
    const id = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10";
    await mac.push("bad", [{ name: "missing", base: 1, blob: blob("gone") }], "missing", id, true);
    await settled();
    expect(sent).toHaveLength(0);
  });
});

describe("silent push", () => {
  it("takes a device's own token, checked", async () => {
    const account = newAccount();
    const mac = await register(account, "mac1");
    const phone = await register(account, "iphone1");
    const put = (who: string, token: string, body: unknown) =>
      call(`/v1/accounts/${account}/devices/${who}/push`, { method: "PUT", token, body });
    expect((await put("iphone1", phone, { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" })).status).toBe(204);
    expect((await put("iphone1", mac, { token: TOKEN, env: "sandbox", topic: "x" })).status).toBe(403);
    expect((await put("iphone1", phone, { token: "not hex", env: "sandbox", topic: "x" })).status).toBe(400);
    expect((await put("iphone1", phone, { token: TOKEN, env: "staging", topic: "x" })).status).toBe(400);
    expect((await put("iphone1", phone, { token: TOKEN, env: "production", topic: "" })).status).toBe(400);
  });

  it("wakes a device with no socket when another changes something, once a minute", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
    });
    const sent = await record(account);

    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
    await settled();
    expect(sent).toEqual([{ device: "iphone1", token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" }]);

    // A burst is one push.
    await mac.push("p2", [{ name: "b", base: 0, blob: blob("b") }]);
    await settled();
    expect(sent).toHaveLength(1);
  });

  it("leaves a device with its socket open, the sender, and one that took its token back", async () => {
    const account = newAccount();
    const phoneToken = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phoneToken, body: { token: TOKEN, env: "production", topic: "dev.serafim.fast.iphone" },
    });
    const sent = await record(account);
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();

    // Open: it hears the change on its socket.
    const phone = await connect(account, phoneToken);
    await phone.hello();
    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
    await phone.next();
    // Its own change wakes nobody else either: no other device has a token.
    await phone.push("p2", [{ name: "b", base: 0, blob: blob("b") }]);
    await settled();
    expect(sent).toEqual([]);

    phone.ws.close();
    await settled(50);
    await call(`/v1/accounts/${account}/devices/iphone1/push`, { method: "DELETE", token: phoneToken });
    await mac.push("p3", [{ name: "c", base: 0, blob: blob("c") }]);
    await settled();
    expect(sent).toEqual([]);
  });

  it.each(["BadTopic", "BadPriority", "DeviceTokenNotForTopic"])("keeps a registration after configuration failure %s", async (reason) => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
    });
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.apns = { silent: async () => ({ status: 400, reason }) };
    });
    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
    await settled();
    const left = await runInDurableObject(stub, (_: Account, state) => state.storage.sql.exec("SELECT device FROM push").toArray());
    expect(left).toEqual([{ device: "iphone1" }]);
  });

  it.each([
    { status: 410, reason: "Unregistered" },
    { status: 400, reason: "BadDeviceToken" },
  ])("keeps a same-token registration made while APNs $status is in flight", async (result) => {
    // Registration revision, rather than clock resolution, separates these PUTs.
    const clock = vi.spyOn(Date, "now").mockReturnValue(1_728_217_123_456);
    let release!: (result: PushResult) => void;
    let started!: () => void;
    const response = new Promise<PushResult>((resolve) => { release = resolve; });
    const sending = new Promise<void>((resolve) => { started = resolve; });
    const account = newAccount();
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    try {
      const mac = await connect(account, await register(account, "mac1"));
      await mac.hello();
      const phone = await register(account, "iphone1");
      const put = () => call(`/v1/accounts/${account}/devices/iphone1/push`, {
        method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
      });
      expect((await put()).status).toBe(204);
      await runInDurableObject(stub, (instance: Account) => {
        instance.apns = { silent: async () => { started(); return response; } };
      });
      await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
      await sending;
      // Same device, token, environment and topic, even within one millisecond.
      expect((await put()).status).toBe(204);
      release(result);
      await settled();
      const left = await runInDurableObject(stub, (_: Account, state) => state.storage.sql.exec("SELECT device, token FROM push").toArray());
      expect(left).toEqual([{ device: "iphone1", token: TOKEN }]);
    } finally {
      release({ status: 200 });
      clock.mockRestore();
    }
  });

  it.each([true, false])("uses APNs millisecond unregistration time, older=%s", async (older) => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    const beforeRegistration = Date.now();
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
    });
    const timestamp = older ? beforeRegistration - 1 : Date.now() + 60_000;
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.apns = { silent: async () => ({ status: 410, reason: "Unregistered", timestamp }) };
    });
    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
    await settled();
    const left = await runInDurableObject(stub, (_: Account, state) => state.storage.sql.exec("SELECT device FROM push").toArray());
    expect(left).toEqual(older ? [{ device: "iphone1" }] : []);
  });

  it("adds registration identity to existing SQLite accounts without losing tokens", async () => {
    const account = newAccount();
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    const left = await runInDurableObject(stub, (_: Account, state) => {
      state.storage.sql.exec("DROP TABLE push");
      state.storage.sql.exec(`CREATE TABLE push (
        device TEXT PRIMARY KEY, token TEXT NOT NULL, env TEXT NOT NULL, topic TEXT NOT NULL,
        last INTEGER NOT NULL DEFAULT 0)`);
      state.storage.sql.exec("INSERT INTO push (device, token, env, topic, last) VALUES (?, ?, ?, ?, ?)",
        "iphone1", TOKEN, "sandbox", "dev.serafim.fast.iphone", 123);
      // Constructing a later instance is how an existing account meets new code.
      new Account(state, env);
      return state.storage.sql.exec("SELECT device, token, last, registered_at, revision FROM push").toArray();
    });
    expect(left).toEqual([{ device: "iphone1", token: TOKEN, last: 123, registered_at: 0, revision: "" }]);
  });

  it("forgets a token APNs says is gone", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    const phone = await register(account, "iphone1");
    await call(`/v1/accounts/${account}/devices/iphone1/push`, {
      method: "PUT", token: phone, body: { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" },
    });
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.apns = { silent: async () => ({ status: 410, reason: "Unregistered" }) };
    });
    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }]);
    await settled();
    const left = await runInDurableObject(stub, (_: Account, state) => state.storage.sql.exec("SELECT device FROM push").toArray());
    expect(left).toEqual([]);
  });
});

describe("alert push for a question", () => {
  type Sent = { kind: "silent" | "alert"; device: string; sealed?: Sealed | null; id?: string };

  async function recordBoth(account: string): Promise<Sent[]> {
    const sent: Sent[] = [];
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (instance: Account) => {
      instance.apns = {
        silent: async (target) => (sent.push({ kind: "silent", device: target.device }), { status: 200 }),
        alert: async (target, sealed, id) => (sent.push({ kind: "alert", device: target.device, sealed, ...(id ? { id } : {}) }), { status: 200 }),
      };
    });
    return sent;
  }

  async function phone(account: string, id: string, alerts?: boolean) {
    const token = await register(account, id);
    const body: Record<string, unknown> = { token: TOKEN, env: "sandbox", topic: "dev.serafim.fast.iphone" };
    if (alerts !== undefined) body.alerts = alerts;
    expect((await call(`/v1/accounts/${account}/devices/${id}/push`, { method: "PUT", token, body })).status).toBe(204);
  }

  it("alerts a device that asked for alerts with the question's sealed record, at once", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    await phone(account, "iphone1", true);
    await phone(account, "iphone2");
    const sent = await recordBoth(account);

    const qid = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10";
    await mac.push("p1", [{ name: "other", base: 0, blob: blob("o") }, { name: "q1", base: 0, blob: blob("question") }], "q1", qid);
    await settled();
    expect(sent).toEqual([
      { kind: "alert", device: "iphone1", sealed: { name: "q1", blob: blob("question") }, id: qid },
      { kind: "silent", device: "iphone2" },
    ]);

    // A second question seconds later is not held for the minute; a plain
    // change is (the alert counted as this minute's wake).
    await runInDurableObject(env.ACCOUNT.get(env.ACCOUNT.idFromName(account)), (_: Account, state) => {
      state.storage.sql.exec("UPDATE push SET alert_last = alert_last - 6000");
    });
    await mac.push("p2", [{ name: "q2", base: 0, blob: blob("again") }], "q2", "not a uuid");
    await mac.push("p3", [{ name: "plain", base: 0, blob: blob("p") }]);
    await settled();
    expect(sent.slice(2)).toEqual([{ kind: "alert", device: "iphone1", sealed: { name: "q2", blob: blob("again") } }]);
  });

  it("names only a change of the push, and is refused a bad flag", async () => {
    const account = newAccount();
    const mac = await connect(account, await register(account, "mac1"));
    await mac.hello();
    await phone(account, "iphone1", true);
    const sent = await recordBoth(account);
    await mac.push("p1", [{ name: "a", base: 0, blob: blob("a") }], "not-in-it");
    await settled();
    expect(sent).toEqual([{ kind: "silent", device: "iphone1" }]);
    const token = await register(account, "iphone3");
    const bad = await call(`/v1/accounts/${account}/devices/iphone3/push`, {
      method: "PUT", token, body: { token: TOKEN, env: "sandbox", topic: "x", alerts: "yes" },
    });
    expect(bad.status).toBe(400);
  });

  it("says generic words, and leaves out a record too big for APNs", () => {
    const small = JSON.parse(alertBody({ name: "n", blob: "QUJD" }));
    expect(small.aps.alert).toEqual({ title: "Yab", body: "Needs your answer" });
    expect(small.aps["mutable-content"]).toBe(1);
    expect(small.aps.sound).toBe("ask.caf");
    expect(small.aps["interruption-level"]).toBe("time-sensitive");
    expect(small.yab).toEqual({ n: "n", b: "QUJD" });
    const big = JSON.parse(alertBody({ name: "n", blob: "A".repeat(ALERT_BLOB + 4) }));
    expect(big.yab).toBeUndefined();
    expect(new TextEncoder().encode(alertBody({ name: "n".repeat(64), blob: "A".repeat(ALERT_BLOB) })).length).toBeLessThanOrEqual(4096);
  });

  it("adds the alert columns to an existing account", async () => {
    const account = newAccount();
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    const left = await runInDurableObject(stub, (_: Account, state) => {
      state.storage.sql.exec("DROP TABLE push");
      state.storage.sql.exec(`CREATE TABLE push (
        device TEXT PRIMARY KEY, token TEXT NOT NULL, env TEXT NOT NULL, topic TEXT NOT NULL,
        last INTEGER NOT NULL DEFAULT 0, registered_at INTEGER NOT NULL DEFAULT 0, revision TEXT NOT NULL DEFAULT '')`);
      state.storage.sql.exec("INSERT INTO push (device, token, env, topic) VALUES (?, ?, ?, ?)", "iphone1", TOKEN, "sandbox", "t");
      new Account(state, env);
      return state.storage.sql.exec("SELECT device, alerts, alert_last FROM push").toArray();
    });
    expect(left).toEqual([{ device: "iphone1", alerts: 0, alert_last: 0 }]);
  });
});
