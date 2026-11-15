(function () {
  // Yab's world: the page's EyeDropper asks here, and the sampler's color
  // goes back as an event (eyedropper-page.js). The gesture is checked
  // here too, where the page can't fake it: a page dispatching the event
  // itself, with no click behind it, is refused.
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.__YAB_NAME__;
  if (!handler || window.__yabEyeDropperBridged) return;
  window.__yabEyeDropperBridged = true;
  function answer(reply) {
    window.dispatchEvent(new CustomEvent('__YAB_ANSWERED__', { detail: JSON.stringify(reply) }));
  }
  window.addEventListener('__YAB_ASKED__', function (event) {
    var m;
    try { m = JSON.parse(event.detail); } catch (e) { return; }
    if (!m || typeof m.id !== 'string') return;
    if (m.kind === 'cancel') { handler.postMessage({ kind: 'cancel', id: m.id }).catch(function () {}); return; }
    if (m.kind !== 'open') return;
    if (navigator.userActivation && !navigator.userActivation.isActive) {
      answer({ id: m.id, error: 'NotAllowedError' });
      return;
    }
    handler.postMessage({ kind: 'open', id: m.id }).then(function (reply) {
      answer(Object.assign({ id: m.id }, reply || { error: 'AbortError' }));
    }, function () { answer({ id: m.id, error: 'AbortError' }); });
  });
})();
