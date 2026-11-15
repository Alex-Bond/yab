import { describe, expect, it } from "vitest";
import { FCM_BLOB_LIMIT, GoogleFcm, fcmBody, fcmFailureStage, fcmFromEnv, invalidatesFcmToken } from "../src/fcm";

const target = { device: "android", token: "opaque_fcm:token", env: "fcm", topic: "dev.yab.android" };

describe("FCM sealed wakeup transport", () => {
  it("reports fixed failure stages without exposing provider text or credentials", () => {
    expect(fcmFailureStage(new Error("FCM authorization is unavailable"))).toBe("authorization");
    expect(fcmFailureStage(new Error("FCM authorization returned an invalid token"))).toBe("authorization");
    for (const secret of [new Error("private credential text"), { message: "FCM authorization is unavailable" }, "private token", null]) {
      expect(fcmFailureStage(secret)).toBe("transport-or-key");
    }
  });
  it("does not configure itself without actual provider credentials", () => {
    expect(fcmFromEnv({})).toBeNull();
    expect(fcmFromEnv({ FCM_PROJECT_ID: "project-only" })).toBeNull();
  });
  it("carries only opaque sealed approval bytes and a routing identity", () => {
    const body = JSON.parse(fcmBody(target, "approval", { name: "opaque-name", blob: "sealed-blob" }, "approval-id"));
    expect(body.message.data).toEqual({ v: "1", kind: "approval", approval: "approval-id", n: "opaque-name", b: "sealed-blob" });
    expect(body.message.notification).toBeUndefined();
    expect(body.message.android.priority).toBe("HIGH");
    expect(body.message.android.restricted_package_name).toBe(target.topic);
  });
  it("omits oversized sealed bytes and withdraws without ringing", () => {
    expect(JSON.parse(fcmBody(target, "approval", { name: "name", blob: "a".repeat(FCM_BLOB_LIMIT + 1) }, "id")).message.data).toEqual({ v: "1", kind: "approval", approval: "id" });
    expect(JSON.parse(fcmBody(target, "withdraw", null, "id")).message.data).toEqual({ v: "1", kind: "withdraw", approval: "id" });
  });
  it("only invalidates an explicit unregistered token, never malformed payload or credentials", () => {
    expect(invalidatesFcmToken({ status: 404, reason: "UNREGISTERED" })).toBe(true);
    for (const result of [{ status: 400, reason: "INVALID_ARGUMENT" }, { status: 403, reason: "SENDER_ID_MISMATCH" }, { status: 401, reason: "UNAUTHENTICATED" }, { status: 404, reason: "NOT_FOUND" }]) expect(invalidatesFcmToken(result)).toBe(false);
  });
  it("uses a real signed OAuth assertion and caches the access token for subsequent messages", async () => {
    const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey) as ArrayBuffer);
    let binary = ""; for (const byte of der) binary += String.fromCharCode(byte);
    const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(binary)}\n-----END PRIVATE KEY-----`;
    const calls: string[] = [];
    const provider = new GoogleFcm({ project: "test-project", email: "sender@test-project.iam.gserviceaccount.com", privateKey: pem }, async (url, init) => {
      calls.push(String(url));
      if (String(url).includes("oauth2")) {
        const assertion = new URLSearchParams(init?.body as string).get("assertion")!;
        const [header, claims, signature] = assertion.split(".");
        const decode = (value: string) => Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), char => char.charCodeAt(0));
        expect(JSON.parse(new TextDecoder().decode(decode(claims))).scope).toBe("https://www.googleapis.com/auth/firebase.messaging");
        expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", keys.publicKey, decode(signature), new TextEncoder().encode(`${header}.${claims}`))).toBe(true);
        return Response.json({ access_token: "test-access-token", expires_in: 3600 });
      }
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer test-access-token");
      return Response.json({ name: "projects/test-project/messages/1" });
    });
    expect(await provider.alert(target, null, "id")).toEqual({ status: 200 });
    expect(await provider.silent(target)).toEqual({ status: 200 });
    expect(calls.filter(url => url.includes("oauth2"))).toHaveLength(1);
    expect(calls.filter(url => url.includes("messages:send"))).toHaveLength(2);
  });
});
