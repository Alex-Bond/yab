import { expect, it } from "vitest";
import { GoogleFcm } from "../src/fcm";

it("authorizes and sends using the Worker native fetch transport", async () => {
  const keys = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey) as ArrayBuffer);
  let binary = ""; for (const byte of der) binary += String.fromCharCode(byte);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(binary)}\n-----END PRIVATE KEY-----`;
  const provider = new GoogleFcm({ project: "test-project", email: "sender@test-project.iam.gserviceaccount.com", privateKey: pem });
  const target = { device: "android", token: "fixture_only_fcm_token", env: "fcm", topic: "dev.yab.android" };
  expect(await provider.silent(target)).toEqual({ status: 200 });
});
