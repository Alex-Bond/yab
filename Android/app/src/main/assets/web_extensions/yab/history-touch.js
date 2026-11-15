(() => {
  "use strict";
  if (window !== top) return;
  // This property belongs to the extension's isolated world. No page CustomEvent,
  // wrappedJSObject, second native port or page-readable nonce is involved.
  const key = "__yabHistoryTouchLedgerV1";
  if (Object.prototype.hasOwnProperty.call(globalThis, key)) return;
  const max = Number.MAX_SAFE_INTEGER;
  let sequence = 0, contacts = 0, lastSerial = 0, armed = null, active = null;
  let held = true, broken = false, sender = null;
  let navigationChanged = null;
  const safe = value => Number.isSafeInteger(value) && value >= 0 && value <= max;
  const tokenOK = value => typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
  const navigationKey = (() => {
    // Firefox's normal content-script sandbox uses DOM Xrays. Capture native
    // getters before author scripts, never waived/page-provided JS properties.
    let changes = 0, usable = false, navigation = null, current = null, keyGet = null, idGet = null;
    const apply = Reflect.apply;
    const uuid = value => typeof value === "string" && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
    const read = () => {
      if (!usable) return null;
      try {
        const entry = apply(current, navigation, []);
        if (!entry) return null;
        const key = apply(keyGet, entry, []), id = apply(idGet, entry, []);
        return uuid(key) && uuid(id) ? {key:key.toLowerCase(), id:id.toLowerCase()} : null;
      } catch (_) { return null; }
    };
    try {
      navigation = window.navigation;
      current = Object.getOwnPropertyDescriptor(window.Navigation.prototype, "currentEntry")?.get;
      keyGet = Object.getOwnPropertyDescriptor(window.NavigationHistoryEntry.prototype, "key")?.get;
      idGet = Object.getOwnPropertyDescriptor(window.NavigationHistoryEntry.prototype, "id")?.get;
      const listen = window.EventTarget.prototype.addEventListener;
      usable = !!navigation && [current, keyGet, idGet, listen].every(fn => typeof fn === "function");
      if (usable) apply(listen, navigation, ["currententrychange", event => {
        if (event.isTrusted !== true) return;
        if (changes === max) usable = false;
        else changes++;
        navigationChanged?.();
      }, {capture:true, passive:true}]);
    } catch (_) { usable = false; }
    const initial = read();
    return () => {
      const value = read();
      return value && initial ? {known:true, initialKey:initial.key, initialId:initial.id,
        key:value.key, id:value.id, changes} : {known:false};
    };
  })();
  const emit = (phase, permit = active, accepted = false) => {
    if (!sender) return;
    try { sender({phase, sequence, contacts, serial:permit?.serial || 0, token:permit?.token || null,
      accepted, held:broken || held}); } catch (_) { /* A disconnected bridge cannot stop the touch ledger. */ }
  };
  const pageHolds = event => {
    try {
      const path = event.composedPath();
      if (!Array.isArray(path) || path.length < 2 || path.length > 130 || !path.includes(document)) return true;
      let element = event.target;
      if (element?.nodeType === 3) element = element.parentElement;
      if (!element || element.nodeType !== 1) return true;
      let count = 0;
      for (; element; element = element.parentElement) {
        if (++count > 128 || element.nodeType !== 1 || element.ownerDocument !== document || !element.isConnected ||
            element.getRootNode() !== document || element.shadowRoot || element.tagName.includes("-")) return true;
        if (element.tagName === "INPUT" && element.type === "range") return true;
        const style = getComputedStyle(element), action = style.touchAction, overflow = style.overflowX;
        if (typeof action !== "string" || typeof overflow !== "string") return true;
        if (action && action !== "auto" && action !== "manipulation" && !action.includes("pan-x")) return true;
        const width = element.scrollWidth, client = element.clientWidth;
        if (!Number.isFinite(width) || !Number.isFinite(client) || width < 0 || client < 0) return true;
        if ((overflow === "auto" || overflow === "scroll") && width > client + 1) return true;
      }
      // A retargeted or shadow-contained origin is not a proven free page.
      return path.some(node => node && node !== window && node !== document &&
        node.nodeType !== 1 && node.nodeType !== 3 || node?.nodeType === 1 && node.getRootNode() !== document);
    } catch (_) { return true; }
  };
  const onTouch = event => {
    if (event.isTrusted !== true || !(event instanceof TouchEvent)) return;
    const next = event.touches?.length;
    if (!Number.isInteger(next) || next < 0 || next > 10) {
      broken = true; held = true; armed = null; contacts = 10; emit("change"); return;
    }
    const start = event.type === "touchstart", end = event.type === "touchend", cancel = event.type === "touchcancel";
    if (start && contacts === 0) {
      if (sequence === max || next === 0) { broken = true; armed = null; held = true; return; }
      sequence++;
      active = armed; armed = null;
      held = broken || next !== 1 || pageHolds(event);
    } else if (start || next > 1) held = true;
    contacts = next;
    emit(start ? "start" : cancel ? "cancel" : end ? "end" : "change");
    if ((end || cancel) && next === 0) { active = null; held = true; }
  };
  for (const type of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
    addEventListener(type, onTouch, {capture:true, passive:true});
  }
  const attach = (port, documentID) => {
    if (sender || !port || typeof port.postMessage !== "function" || typeof documentID !== "string") return false;
    sender = value => port.postMessage({kind:"history-touch", documentID, ...value});
    navigationChanged = () => port.postMessage({kind:"history-key-invalidated", documentID});
    port.onMessage.addListener(message => {
      if (!message || typeof message !== "object" || message.expectedDocument !== documentID) return;
      if (message.command === "history-key") {
        if (tokenOK(message.request)) port.postMessage({kind:"history-key", documentID,
          request:message.request, ...navigationKey()});
        return;
      }
      if (message.command === "history-sync") { emit("sync", null); return; }
      if (message.command === "history-disarm") {
        if (armed && message.serial === armed.serial) armed = null;
        return;
      }
      if (message.command !== "history-arm" || !safe(message.serial) || message.serial < 1 ||
          !safe(message.afterSequence) || !tokenOK(message.token)) return;
      const permit = {serial:message.serial, token:message.token};
      const fresh = message.serial > lastSerial;
      lastSerial = Math.max(lastSerial, message.serial);
      const accepted = fresh && !broken && contacts === 0 && active === null && armed === null && sequence === message.afterSequence;
      if (accepted) armed = permit;
      emit("armed", permit, accepted);
    });
    emit("sync", null);
    return true;
  };
  Object.defineProperty(globalThis, key, {value:Object.freeze({attach}), enumerable:false, writable:false, configurable:false});
})();
