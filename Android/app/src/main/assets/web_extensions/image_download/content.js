"use strict";
(() => {
  // A separate APK extension hosts this script. It never registers guest USER_SCRIPT worlds.
  const G = globalThis.YabOwnedImage;
  if (window !== top || !G.url(location.href) || typeof browser.runtime.getFrameId !== "function" ||
      typeof browser.runtime.getDocumentId !== "function") return;
  const bridge = G.randomToken();
  const documentId = browser.runtime.getDocumentId(window);
  let native = null, background = null, attempt = null, stopped = false, retries = 0;
  function sourceCurrent() {
    return !stopped && document.isConnected && document.visibilityState === "visible" &&
      browser.runtime.getDocumentId(window) === documentId && !!G.url(location.href);
  }
  function current(value, edge = false) {
    if (!value || attempt !== value || stopped || !value.frame.isConnected || value.frame.ownerDocument !== document ||
        browser.runtime.getDocumentId(window) !== documentId || browser.runtime.getFrameId(value.frame) !== value.frameId ||
        value.frame.getAttribute("sandbox") !== "allow-downloads" || value.frame.getAttribute("data-yab-owned-image") !== value.token) return false;
    return (value.delivered || sourceCurrent()) && G.frameSource(value, edge);
  }
  function nativeSend(value) { try { native?.postMessage({v: 1, bridge, document: documentId, ...value}); } catch (_) {} }
  function backgroundSend(value) { try { background?.postMessage({v: 1, bridge, document: documentId, ...value}); } catch (_) {} }
  function finish(reason, notify = true) {
    const value = attempt; if (!value) return;
    attempt = null; value.observer.disconnect(); clearTimeout(value.timer);
    if (notify) { nativeSend({kind: "failed", token: value.token, reason}); backgroundSend({kind: "cancel", token: value.token}); }
    value.frame.remove();
  }
  function prepare(message) {
    if (!sourceCurrent() || attempt || !G.token(message.token) || !G.url(message.target) || message.document !== documentId || message.bridge !== bridge)
      return nativeSend({kind: "failed", token: message.token, reason: "source_changed"});
    const frame = document.createElement("iframe");
    frame.setAttribute("sandbox", "allow-downloads");
    frame.setAttribute("data-yab-owned-image", message.token);
    frame.setAttribute("aria-hidden", "true"); frame.tabIndex = -1;
    frame.style.cssText = "display:none!important;width:0!important;height:0!important;border:0!important";
    document.documentElement.append(frame);
    const frameId = browser.runtime.getFrameId(frame);
    if (!Number.isSafeInteger(frameId) || frameId <= 0) { frame.remove(); return nativeSend({kind: "failed", token: message.token, reason: "frame_unavailable"}); }
    const value = {token: message.token, target: G.url(message.target), frame, frameId, started: false, navigated: false, delivered: false,
      observer: new MutationObserver(() => { if (attempt === value && !current(value)) finish("source_changed"); }), timer: null};
    attempt = value;
    value.observer.observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["sandbox", "src", "data-yab-owned-image"]});
    value.timer = setTimeout(() => { if (attempt === value && !value.delivered) finish("request_timeout"); }, 30000);
    nativeSend({kind: "prepared", token: value.token, frame: value.frameId});
  }
  function connect() {
    if (stopped) return;
    try {
      const source = browser.runtime.connectNative(G.native); native = source;
      source.onMessage.addListener(message => {
        if (native !== source || message?.v !== 1) return;
        if (message.command === "retire") {
          native = null; finish("bridge_closed"); source.disconnect();
          if (!stopped && ++retries < 20) setTimeout(connect, Math.min(2000, retries * 200));
          return;
        }
        if (message.command === "prepare") return prepare(message);
        const value = attempt;
        if (!value || message.token !== value.token) return;
        if (message.command === "bind") {
          if (!current(value)) return finish("source_changed");
          backgroundSend({kind: "prepare", token: value.token, frame: value.frameId, target: value.target});
        } else if (message.command === "check") {
          nativeSend({kind: "checked", token: value.token, check: message.check, valid: current(value, true)});
        } else if (message.command === "delivered") { value.delivered = true; clearTimeout(value.timer); backgroundSend({kind: "delivered", token: value.token}); }
        else if (message.command === "finish") { backgroundSend({kind: "cancel", token: value.token}); finish("finished", false); }
      });
      source.onDisconnect.addListener(() => {
        if (native !== source) return; native = null; finish("bridge_closed");
        if (!stopped && ++retries < 20) setTimeout(connect, Math.min(2000, retries * 200));
      });
      source.postMessage({v: 1, kind: "hello", bridge, document: documentId});
    } catch (_) { if (!stopped && ++retries < 20) setTimeout(connect, Math.min(2000, retries * 200)); }
  }
  try {
    background = browser.runtime.connect({name: G.port});
    background.onMessage.addListener(message => {
      const value = attempt;
      if (!value || message?.v !== 1 || message.token !== value.token) return;
      if (message.command === "go") {
        if (!current(value) || value.started) return finish("source_changed");
        value.started = true;
        backgroundSend({kind: "start", token: value.token});
      } else if (message.command === "failed") finish(G.failure(message.reason));
    });
    background.onDisconnect.addListener(() => { background = null; finish("bridge_closed"); });
    backgroundSend({kind: "hello"});
    connect();
  } catch (_) { stopped = true; finish("bridge_closed"); }
  addEventListener("pagehide", () => {
    stopped = true; finish("source_changed");
    const old = native; native = null; old?.disconnect();
    const oldBackground = background; background = null; oldBackground?.disconnect();
  }, {once: true});
  // Pending requests are rechecked by the native foreground lease and every blocking edge.
  // Do not remove the retargeted channel merely because its own native file dialog hides the WebView.
})();
