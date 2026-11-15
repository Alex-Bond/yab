import { describe, expect, it, vi } from "vitest";
import { apnsFromEnv, invalidatesToken, readPushResult } from "../src/push";

describe("APNs response handling", () => {
  it("retains Apple's reason while handling empty and malformed responses", async () => {
    expect(await readPushResult(new Response(null, { status: 200 }))).toEqual({ status: 200 });
    expect(await readPushResult(Response.json({ reason: "BadTopic" }, { status: 400 }))).toEqual({ status: 400, reason: "BadTopic" });
    expect(await readPushResult(new Response("not JSON", { status: 410 }))).toEqual({ status: 410 });
    expect(await readPushResult(Response.json({ reason: 42 }, { status: 400 }))).toEqual({ status: 400 });
  });
  it("reads APNs 410 timestamps in milliseconds without coercing malformed values", async () => {
    const timestamp = 1_728_217_123_456;
    expect(await readPushResult(Response.json({ reason: "Unregistered", timestamp }, { status: 410 }))).toEqual({ status: 410, reason: "Unregistered", timestamp });
    for (const timestamp of ["1728217123456", null, true, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
      expect(await readPushResult(Response.json({ reason: "Unregistered", timestamp }, { status: 410 }))).toEqual({ status: 410, reason: "Unregistered" });
    }
    expect(await readPushResult(Response.json({ reason: "BadDeviceToken", timestamp }, { status: 400 }))).toEqual({ status: 400, reason: "BadDeviceToken" });
  });
  it("invalidates known bad tokens without dropping configuration errors or unknown failures", () => {
    expect(invalidatesToken({ status: 400, reason: "BadDeviceToken" })).toBe(true);
    expect(invalidatesToken({ status: 410, reason: "Unregistered" })).toBe(true);
    for (const reason of ["BadTopic", "BadPriority", "DeviceTokenNotForTopic", "InvalidProviderToken"]) {
      expect(invalidatesToken({ status: 400, reason })).toBe(false);
    }
    expect(invalidatesToken({ status: 410 })).toBe(false);
    expect(invalidatesToken({ status: 403, reason: "Unregistered" })).toBe(false);
  });
});


describe("withdrawal APNs headers", () => {
  it("uses the question collapse id with a silent priority-5 payload", async () => {
    const key = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", key.privateKey) as ArrayBuffer);
    const pem = "-----BEGIN PRIVATE KEY-----\n" + btoa(String.fromCharCode(...der)) + "\n-----END PRIVATE KEY-----";
    const fetcher = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 200 }));
    try {
      const apns = apnsFromEnv({ APNS_KEY: pem, APNS_KEY_ID: "test", APNS_TEAM: "test", APNS_HOST: "https://apns.test" })!;
      const target = { device: "phone", token: "a1".repeat(32), env: "sandbox", topic: "dev.serafim.fast.iphone" };
      const id = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10";
      await apns.silent(target, id);
      const init = fetcher.mock.calls[0][1]!;
      const headers = new Headers(init.headers);
      expect(headers.get("apns-collapse-id")).toBe(id);
      expect(headers.get("apns-push-type")).toBe("background");
      expect(headers.get("apns-priority")).toBe("5");
      expect(JSON.parse(init.body as string)).toEqual({ aps: { "content-available": 1 } });
      await apns.silent(target);
      expect(new Headers(fetcher.mock.calls[1][1]!.headers).get("apns-collapse-id")).toBe("sync");
    } finally { fetcher.mockRestore(); }
  });
});
