(function () {
  // The page's EyeDropper, which Chrome has and WebKit doesn't: open()
  // shows the Mac's own color sampler, its magnifier under the pointer,
  // and gives the color picked as "#rrggbb" (EyeDropper.swift). As
  // Chrome's: only in a secure context, only with a user's gesture, one
  // at a time, and a signal or Escape ends it with an AbortError.
  // An extension's own pages count as secure, as in Chromium.
  var extensionPage = /^(chrome|webkit)-extension:$/.test(location.protocol);
  if (typeof window === 'undefined' || 'EyeDropper' in window || !(window.isSecureContext || extensionPage)) return;
  var asked = '__YAB_ASKED__', answered = '__YAB_ANSWERED__';
  var waiting = new Map(), open = null;
  function abort(text) { return new DOMException(text, 'AbortError'); }
  window.addEventListener(answered, function (event) {
    var m;
    try { m = JSON.parse(event.detail); } catch (e) { return; }
    var w = m && waiting.get(m.id);
    if (!w) return;
    waiting.delete(m.id);
    if (open === m.id) open = null;
    if (m.hex) w.resolve({ sRGBHex: m.hex });
    else if (m.error === 'NotAllowedError') w.reject(new DOMException(m.message || 'EyeDropper.open() needs a user gesture.', 'NotAllowedError'));
    else if (m.error === 'InvalidStateError') w.reject(new DOMException(m.message || 'An eye dropper is already open.', 'InvalidStateError'));
    else w.reject(abort(m.message || 'The user canceled the selection.'));
  });
  function EyeDropper() {
    if (!(this instanceof EyeDropper)) throw new TypeError("Failed to construct 'EyeDropper': Please use the 'new' operator.");
  }
  Object.defineProperty(EyeDropper.prototype, 'open', { configurable: true, writable: true, value: function (options) {
    var signal = options && options.signal;
    if (signal && signal.aborted) return Promise.reject(signal.reason !== undefined ? signal.reason : abort('The operation was aborted.'));
    if (open) return Promise.reject(new DOMException('An eye dropper is already open.', 'InvalidStateError'));
    if (navigator.userActivation && !navigator.userActivation.isActive) {
      return Promise.reject(new DOMException('EyeDropper.open() needs a user gesture.', 'NotAllowedError'));
    }
    var id = Math.random().toString(36).slice(2) + Date.now().toString(36);
    open = id;
    return new Promise(function (resolve, reject) {
      waiting.set(id, { resolve: resolve, reject: reject });
      if (signal) signal.addEventListener('abort', function () {
        if (!waiting.delete(id)) return;
        if (open === id) open = null;
        window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: 'cancel', id: id }) }));
        reject(signal.reason !== undefined ? signal.reason : abort('The operation was aborted.'));
      }, { once: true });
      window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: 'open', id: id }) }));
    });
  } });
  Object.defineProperty(EyeDropper.prototype, Symbol.toStringTag, { value: 'EyeDropper', configurable: true });
  Object.defineProperty(window, 'EyeDropper', { value: EyeDropper, configurable: true, writable: true, enumerable: false });
})();
