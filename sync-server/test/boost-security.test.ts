import { describe, expect, it } from "vitest";
import { blob, call, connect, newAccount, register, upgrade } from "./helpers";

// Entirely local Worker fixtures. No production accounts or credentials.
describe("boost sync account isolation", () => {
  it("knowing the victim account and device cannot grant a foreign token write access", async () => {
    const victim = newAccount(), attacker = newAccount();
    const victimToken = await register(victim, "victim-mac", "victim-secret");
    const attackerToken = await register(attacker, "attacker-mac", "attacker-secret");
    const victimSocket = await connect(victim, victimToken);
    await victimSocket.hello();
    const marker = blob("synthetic encrypted boost placeholder");
    const saved = await victimSocket.push("save", [{ name: "boost-marker", base: 0, blob: marker }]);
    expect(saved.t).toBe("pushed");

    expect((await upgrade(victim, attackerToken)).status).toBe(401);
    expect((await call(`/v1/accounts/${victim}/devices`, { token: attackerToken })).status).toBe(401);
    expect((await call(`/v1/accounts/${victim}/devices/victim-mac`, { method: "DELETE", token: attackerToken })).status).toBe(401);
    expect((await call(`/v1/accounts/${victim}`, { method: "DELETE", token: attackerToken })).status).toBe(401);
    const join = await call(`/v1/accounts/${victim}/devices`, {
      method: "POST", token: attackerToken,
      body: { secret: "attacker-secret", device: { id: "victim-mac", name: "foreign", model: "Mac" } },
    });
    expect(join.status).toBe(403);

    const reread = await victimSocket.hello();
    expect(reread.items).toEqual([expect.objectContaining({ name: "boost-marker", blob: marker, version: 1 })]);
    victimSocket.ws.close();
  });

  it("even an identical record name in another account does not overwrite a victim boost", async () => {
    const victim = newAccount(), attacker = newAccount();
    const victimToken = await register(victim, "victim-mac");
    const attackerToken = await register(attacker, "attacker-mac");
    const victimSocket = await connect(victim, victimToken), attackerSocket = await connect(attacker, attackerToken);
    await victimSocket.hello();
    await attackerSocket.hello();
    await victimSocket.push("keep", [{ name: "same-record-name", base: 0, blob: blob("victim") }]);
    await attackerSocket.push("replace", [{ name: "same-record-name", base: 0, blob: blob("attacker") }]);
    expect((await victimSocket.hello()).items).toEqual([
      expect.objectContaining({ name: "same-record-name", blob: blob("victim"), version: 1 }),
    ]);
    expect((await attackerSocket.hello()).items).toEqual([
      expect.objectContaining({ name: "same-record-name", blob: blob("attacker"), version: 1 }),
    ]);
    victimSocket.ws.close();
    attackerSocket.ws.close();
  });
});
