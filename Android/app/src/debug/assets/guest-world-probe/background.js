/* Handwritten debug code. No downloaded package is installed or executed. */
"use strict";
const worlds = ["probe-guest-a", "probe-guest-b"];
const records = new Map([[worlds[0], "record-a"], [worlds[1], "record-b"]]);
let nativePort;
let target;
let hostCanary = false;
function emit(value) { nativePort?.postMessage(value); }

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.kind !== "host-canary" || !target || sender.url !== target || sender.frameId !== 0) return;
  hostCanary = true;
  emit({kind: "host-canary", storage: message.storage});
});

// Ownership comes exclusively from Gecko metadata, never from a payload's claim.
function broker(message, sender) {
  const actual = sender.userScriptWorldId;
  const authorized = worlds.includes(actual) && sender.url === target && sender.frameId === 0 &&
    sender.tab && sender.tab.incognito !== true && typeof sender.documentId === "string";
  const requested = message?.requestedWorld;
  const denied = !authorized || requested !== actual;
  const reply = {actual, denied};
  if (!denied) reply.value = records.get(actual);
  emit({kind: "decision", actual, claimed: message?.userScriptWorldId, requested,
    denied, value: reply.value, documentId: sender.documentId, tabId: sender.tab?.id,
    frameId: sender.frameId, url: sender.url});
  return reply;
}

function guestCode(world) {
  // JSON.stringify is JavaScript source encoding, not shell interpolation.
  return `void (async () => {
    const world = ${JSON.stringify(world)};
    const before = typeof globalThis.__yabGuestCanary;
    globalThis.__yabGuestCanary = world;
    const inspect = {
      kind: "inspection", requestedWorld: world, userScriptWorldId: world,
      before, hostCanary: typeof globalThis.__yabHostCanary,
      native: typeof chrome.runtime.sendNativeMessage,
      nativePort: typeof chrome.runtime.connectNative,
      storage: typeof chrome.storage, tabs: typeof chrome.tabs,
      scripting: typeof chrome.scripting,
      componentClasses: typeof Components === "undefined" ? "undefined" : typeof Components.classes,
      componentImport: typeof Components === "undefined" || !Components.utils ? "undefined" : typeof Components.utils.import,
      services: typeof Services, chromeUtils: typeof ChromeUtils
    };
    const own = await chrome.runtime.sendMessage(inspect);
    const other = world === "probe-guest-a" ? "probe-guest-b" : "probe-guest-a";
    const spoof = await chrome.runtime.sendMessage({kind: "spoof", requestedWorld: other, userScriptWorldId: other});
    await chrome.runtime.sendMessage({kind: "finished", requestedWorld: world, userScriptWorldId: other,
      inspection: inspect, own, spoof});
  })().catch(error => chrome.runtime.sendMessage({kind: "guest-error", error: String(error)}));`;
}

async function configure(message) {
  target = message.url;
  hostCanary = false;
  // Normal optional permission grant may update the bindings asynchronously.
  for (let count = 0; count < 50 && !browser.userScripts; count++) await new Promise(resolve => setTimeout(resolve, 20));
  if (!browser.userScripts || typeof browser.userScripts.configureWorld !== "function" ||
      typeof browser.userScripts.register !== "function") {
    emit({kind: "unavailable", reason: "userScripts namespace or configureWorld/register unavailable after normal permission grant"});
    return;
  }
  browser.runtime.onUserScriptMessage.addListener((payload, sender) => {
    if (payload?.kind === "guest-error") { emit({kind: "guest-error", actual: sender.userScriptWorldId, error: payload.error}); return; }
    const answer = broker(payload, sender);
    if (payload?.kind === "finished") emit({kind: "finished", actual: sender.userScriptWorldId,
      inspection: payload.inspection, own: payload.own, spoof: payload.spoof, hostCanary});
    return Promise.resolve(answer);
  });
  await browser.userScripts.unregister();
  for (const worldId of worlds) await browser.userScripts.configureWorld({worldId, messaging: true});
  await browser.userScripts.register(worlds.map(worldId => ({
    id: worldId, worldId, world: "USER_SCRIPT", matches: ["http://127.0.0.1/article"],
    runAt: "document_end", js: [{code: guestCode(worldId)}]
  })));
  emit({kind: "configured", available: true, worlds});
}

// The native delegate is attached after Gecko finishes installing our APK fixture.
let attempts = 0;
function connect() {
  if (++attempts > 100) return;
  try {
    nativePort = browser.runtime.connectNative("guest_probe");
    nativePort.onMessage.addListener(message => {
      if (message?.command === "configure") configure(message).catch(error => emit({kind: "error", error: String(error)}));
    });
    nativePort.onDisconnect.addListener(() => { nativePort = null; setTimeout(connect, 100); });
    emit({kind: "hello", userScriptsBeforeGrant: !!browser.userScripts});
  } catch (error) {
    setTimeout(connect, 100);
  }
}
connect();
