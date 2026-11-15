import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_ACCOUNT, MAX_BLOB } from "../src/account";
import { blob, call, connect, newAccount, register, upgrade } from "./helpers";

describe("router", () => {
  it("answers health", async () => {
    const res = await call("/v1/health");
    expect(await res.json()).toEqual({ ok: true, v: 1, androidSync: 1 });
  });

  it("rejects bad account ids", async () => {
    expect((await call("/v1/accounts/short/devices", { method: "POST", body: {} })).status).toBe(400);
    expect((await call(`/v1/accounts/${"a".repeat(65)}/devices`, { method: "POST", body: {} })).status).toBe(400);
  });
});

describe("devices", () => {
  it("register creates the account and lists devices", async () => {
    const account = newAccount();
    const token = await register(account, "mac1");
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    await register(account, "mac2");

    const res = await call(`/v1/accounts/${account}/devices`, { token });
    expect(res.status).toBe(200);
    const { devices } = (await res.json()) as any;
    expect(devices.map((d: any) => d.id)).toEqual(["mac1", "mac2"]);
    expect(devices[0]).toMatchObject({ name: "Mac mac1", model: "Mac15,3", revoked: false });
    expect(typeof devices[0].lastSeen).toBe("number");
  });

  it("rejects a wrong secret with 403 secret", async () => {
    const account = newAccount();
    await register(account, "mac1", "right");
    const res = await call(`/v1/accounts/${account}/devices`, {
      method: "POST",
      body: { secret: "wrong", device: { id: "mac2", name: "x", model: "y" } },
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "secret" });
  });

  it("validates device fields", async () => {
    const account = newAccount();
    const bad = [
      { id: "has space", name: "x", model: "y" },
      { id: "a".repeat(65), name: "x", model: "y" },
      { id: "ok", name: "x".repeat(201), model: "y" },
    ];
    for (const device of bad) {
      const res = await call(`/v1/accounts/${account}/devices`, { method: "POST", body: { secret: "s", device } });
      expect(res.status).toBe(400);
    }
  });

  it("re-registering a live device replaces its token", async () => {
    const account = newAccount();
    const first = await register(account, "mac1");
    const second = await register(account, "mac1");
    expect(second).not.toBe(first);
    expect((await call(`/v1/accounts/${account}/devices`, { token: first })).status).toBe(401);
    expect((await call(`/v1/accounts/${account}/devices`, { token: second })).status).toBe(200);
  });

  it("needs a valid bearer token", async () => {
    const account = newAccount();
    await register(account);
    expect((await call(`/v1/accounts/${account}/devices`)).status).toBe(401);
    expect((await call(`/v1/accounts/${account}/devices`, { token: "nope" })).status).toBe(401);
    // A token from another account does not open this one.
    const other = await register(newAccount());
    expect((await call(`/v1/accounts/${account}/devices`, { token: other })).status).toBe(401);
  });

  it("a socket upgrade with an unknown token answers 401", async () => {
    const account = newAccount();
    await register(account);
    expect((await upgrade(account)).status).toBe(401);
    expect((await upgrade(account, "unknown")).status).toBe(401);
  });

  it("revoke closes the device's socket with 4003, then 401, and blocks re-registering", async () => {
    const account = newAccount();
    const a = await register(account, "mac1");
    const b = await register(account, "mac2");
    const sb = await connect(account, b);
    await sb.hello();

    const res = await call(`/v1/accounts/${account}/devices/mac2`, { method: "DELETE", token: a });
    expect(res.status).toBe(204);
    expect((await sb.closed).code).toBe(4003);

    expect((await call(`/v1/accounts/${account}/devices`, { token: b })).status).toBe(401);
    expect((await upgrade(account, b)).status).toBe(401);

    const again = await call(`/v1/accounts/${account}/devices`, {
      method: "POST",
      body: { secret: "s3cret", device: { id: "mac2", name: "x", model: "y" } },
    });
    expect(again.status).toBe(403);
    expect(await again.json()).toEqual({ error: "revoked" });

    const { devices } = (await (await call(`/v1/accounts/${account}/devices`, { token: a })).json()) as any;
    expect(devices.find((d: any) => d.id === "mac2").revoked).toBe(true);
  });

  it("delete account removes everything and closes sockets", async () => {
    const account = newAccount();
    const a = await register(account, "mac1", "first");
    const sa = await connect(account, a);
    await sa.hello();
    await sa.push("p", [{ name: "r", base: 0, blob: blob("x") }]);

    expect((await call(`/v1/accounts/${account}`, { method: "DELETE", token: a })).status).toBe(204);
    expect((await sa.closed).code).toBe(4003);
    expect((await call(`/v1/accounts/${account}/devices`, { token: a })).status).toBe(401);

    // The address is free again: a new secret makes a fresh, empty account.
    const fresh = await register(account, "mac1", "second");
    const s = await connect(account, fresh);
    expect(await s.hello()).toEqual({ t: "changes", items: [], cursor: 0, more: false });
  });
});

describe("socket", () => {
  it("accepts pushes and returns conflicts", async () => {
    const account = newAccount();
    const s = await connect(account, await register(account));
    await s.hello();

    const first = await s.push("p1", [
      { name: "a", base: 0, blob: blob("a1") },
      { name: "b", base: 0, blob: blob("b1") },
    ]);
    expect(first).toEqual({
      t: "pushed",
      id: "p1",
      accepted: [
        { name: "a", version: 1, seq: 1 },
        { name: "b", version: 1, seq: 2 },
      ],
      conflicts: [],
    });

    const second = await s.push("p2", [
      { name: "a", base: 1, blob: blob("a2") },
      { name: "b", base: 0, blob: blob("stale") },
    ]);
    expect(second.accepted).toEqual([{ name: "a", version: 2, seq: 3 }]);
    expect(second.conflicts).toEqual([{ name: "b", version: 1, blob: blob("b1") }]);

    // A change based on a version the server never had is a conflict at version 0.
    const third = await s.push("p3", [{ name: "c", base: 4, blob: blob("c") }]);
    expect(third.conflicts).toEqual([{ name: "c", version: 0, blob: null }]);
  });

  it("hello catches up in batches of 500 with more", async () => {
    const account = newAccount();
    const token = await register(account);
    const writer = await connect(account, token);
    await writer.hello();
    for (let p = 0; p < 3; p++) {
      const changes = Array.from({ length: 400 }, (_, i) => ({ name: `r${p}-${i}`, base: 0, blob: blob(`v${i}`) }));
      expect((await writer.push(`p${p}`, changes)).accepted).toHaveLength(400);
    }

    const reader = await connect(account, token);
    reader.send({ t: "hello", cursor: 0, v: 1 });
    const batches = [await reader.next(), await reader.next(), await reader.next()];
    expect(batches.map((b) => b.items.length)).toEqual([500, 500, 200]);
    expect(batches.map((b) => b.more)).toEqual([true, true, false]);
    expect(batches.map((b) => b.cursor)).toEqual([500, 1000, 1200]);
    expect(batches[0].items[0]).toEqual({ name: "r0-0", version: 1, seq: 1, blob: blob("v0") });
    expect(await reader.quiet()).toBeNull();

    const tail = await connect(account, token);
    const rest = await tail.hello(1150);
    expect(rest.items.map((i: any) => i.seq)).toEqual(Array.from({ length: 50 }, (_, i) => 1151 + i));
    expect(rest.more).toBe(false);
  });

  it("broadcasts accepted changes to other sockets, not the sender", async () => {
    const account = newAccount();
    const a = await connect(account, await register(account, "mac1"));
    const b = await connect(account, await register(account, "mac2"));
    await a.hello();
    await b.hello();

    const pushed = await a.push("p", [
      { name: "x", base: 0, blob: blob("x") },
      { name: "y", base: 7, blob: blob("conflict") },
    ]);
    expect(pushed.accepted).toHaveLength(1);

    expect(await b.next()).toEqual({
      t: "changes",
      items: [{ name: "x", version: 1, seq: 1, blob: blob("x") }],
      cursor: 1,
      more: false,
    });
    expect(await a.quiet()).toBeNull();
  });

  it("relays presence and keeps each device's last for those who come later", async () => {
    const account = newAccount();
    const token = await register(account, "mac1");
    const a = await connect(account, token);
    const b = await connect(account, await register(account, "mac2"));
    await a.hello();
    await b.hello();

    a.send({ t: "presence", blob: blob("here") });
    expect(await b.next()).toEqual({ t: "presence", device: "mac1", blob: blob("here") });
    expect(await a.quiet()).toBeNull();
    a.send({ t: "presence", blob: blob("asleep") });
    expect(await b.next()).toEqual({ t: "presence", device: "mac1", blob: blob("asleep") });

    // The same device again hears no presence of its own, and no records.
    const late = await connect(account, token);
    expect((await late.hello()).items).toEqual([]);
    expect(await late.quiet()).toBeNull();

    // A phone that just connected: the Mac's last word right after the catch-up.
    const phone = await connect(account, await register(account, "iphone1"));
    expect(await phone.hello()).toMatchObject({ t: "changes", more: false });
    expect(await phone.next()).toEqual({ t: "presence", device: "mac1", blob: blob("asleep") });
    expect(await phone.quiet()).toBeNull();

    // A removed device's word goes with it.
    expect((await call(`/v1/accounts/${account}/devices/mac1`, { method: "DELETE", token: await register(account, "mac3") })).status).toBe(204);
    const another = await connect(account, await register(account, "iphone2"));
    await another.hello();
    expect(await another.quiet()).toBeNull();
  });

  it("rejects a blob over 96 KB and still takes the rest", async () => {
    const account = newAccount();
    const s = await connect(account, await register(account));
    await s.hello();
    s.send({
      t: "push",
      id: "big",
      changes: [
        { name: "huge", base: 0, blob: "A".repeat(MAX_BLOB + 4) },
        { name: "small", base: 0, blob: blob("ok") },
        { name: "edge", base: 0, blob: "A".repeat(MAX_BLOB) },
      ],
    });
    const error = await s.next();
    expect(error).toMatchObject({ t: "error", code: "too-big", id: "big" });
    const pushed = await s.next();
    expect(pushed.accepted.map((a: any) => a.name)).toEqual(["small", "edge"]);
    expect(pushed.rejected).toEqual([{ name: "huge", code: "too-big" }]);
  });

  it("takes a chat project at its largest as one more sealed record", async () => {
    // SyncProject: 200 characters of name, 16 of emoji and 8000 of
    // instructions, each up to 4 bytes in UTF-8, sealed and in base64.
    const fields = JSON.stringify({
      name: "名".repeat(200), emoji: "🧳".repeat(8), tint: "purple", instructions: "𝄞".repeat(8000),
      memoryOn: true, pinned: true, archived: null, order: "m".repeat(40), created: 1.8e9, updated: 1.8e9,
    });
    const sealed = Math.ceil((new TextEncoder().encode(fields).length + 64) / 3) * 4;
    expect(sealed).toBeLessThan(MAX_BLOB);
    const account = newAccount();
    const s = await connect(account, await register(account));
    await s.hello();
    const pushed = await s.push("project", [{ name: "project-record", base: 0, blob: "A".repeat(sealed) }]);
    expect(pushed.accepted).toEqual([{ name: "project-record", version: 1, seq: 1 }]);
  });

  it("rejects changes once the account is over 50 MB", async () => {
    const account = newAccount();
    const s = await connect(account, await register(account));
    await s.hello();
    await s.push("p", [{ name: "a", base: 0, blob: blob("a") }]);
    // Pretend the account is nearly full instead of uploading 250 MB.
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(account));
    await runInDurableObject(stub, (_, state) => {
      state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'bytes'", String(MAX_ACCOUNT - 10));
    });
    s.send({ t: "push", id: "f", changes: [{ name: "b", base: 0, blob: "A".repeat(100) }] });
    expect(await s.next()).toMatchObject({ t: "error", code: "full" });
    expect((await s.next()).rejected).toEqual([{ name: "b", code: "full" }]);
  });

  it("answers malformed messages with a bad error", async () => {
    const account = newAccount();
    const s = await connect(account, await register(account));
    s.ws.send("not json");
    expect(await s.next()).toMatchObject({ t: "error", code: "bad" });
    s.send({ t: "hello", cursor: -1, v: 1 });
    expect(await s.next()).toMatchObject({ t: "error", code: "bad" });
    s.send({ t: "nope" });
    expect(await s.next()).toMatchObject({ t: "error", code: "bad" });
  });
});
