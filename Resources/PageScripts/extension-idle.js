/* yab: requestIdleCallback for an extension's script in a page's own world (ExtensionShims.idle) */
(() => {
  // WebKit took requestIdleCallback out again (bug 287681). Proton Pass's
  // elements.js and NordPass's passkeys.js, which run in the page's own
  // world, call it as Chromium has it, and threw "Can't find variable". This
  // goes before only such a script, and only where the page has none: a
  // timer, nothing of the extension's, as harmless to a page as Chromium's
  // own. Chrome's deadline is at most 50 ms; this gives the whole of it,
  // after the caller finishes. The page's timers are taken as they are now.
  if (typeof window === "undefined") return;
  if (typeof window.requestIdleCallback === "function" && typeof window.cancelIdleCallback === "function") return;
  const later = window.setTimeout.bind(window), stop = window.clearTimeout.bind(window), now = Date.now;
  const waiting = new Map();
  let last = 0;
  const requestIdleCallback = function requestIdleCallback(callback) {
    if (typeof callback !== "function") throw new TypeError("Argument 1 ('callback') to Window.requestIdleCallback must be a function");
    const id = ++last;
    waiting.set(id, later(() => {
      if (!waiting.delete(id)) return;
      const start = now();
      callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (now() - start)) });
    }, 1));
    return id;
  };
  const cancelIdleCallback = function cancelIdleCallback(id) {
    if (!waiting.has(id)) return;
    stop(waiting.get(id));
    waiting.delete(id);
  };
  for (const [name, value] of [["requestIdleCallback", requestIdleCallback], ["cancelIdleCallback", cancelIdleCallback]]) {
    try { Object.defineProperty(window, name, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
  }
})();
