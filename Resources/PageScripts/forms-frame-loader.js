(function () {
  if (window === window.top || window.__yabForms || window.__yabFormsSoon) return;
  var asked = false, pending = null, expiry = null;
  var LOGIN = 'input[type="password"], input[type="email"], input[autocomplete~="username" i], input[autocomplete~="current-password" i], input[autocomplete~="new-password" i]';
  function post(message) {
    try { window.webkit.messageHandlers.yabForms.postMessage(message); } catch (e) {}
  }
  function ask() {
    if (asked) return;
    asked = true;
    post({ kind: 'load' });
  }
  function target(event) { return event.composedPath ? event.composedPath()[0] : event.target; }
  function login(box) {
    if (!box || box.tagName !== 'INPUT') return false;
    if (box.matches(LOGIN)) return true;
    if (/user|login|email|e-mail|identifier|account/i.test((box.name || '') + ' ' + (box.id || ''))) return true;
    // An unlabelled username in a native form still belongs to its password.
    return !!(box.form && box.form.querySelector('input[type="password"]'));
  }
  function focused(event) { if (login(target(event))) ask(); }
  function scopeOf(node) {
    if (!node) return null;
    if (node.matches && node.matches('form, [role="form"]')) return node;
    if (node.form) return node.form;
    return (node.closest && node.closest('[role="form"], dialog')) || node.parentElement;
  }
  function sent(node) {
    if (window.__yabForms) return;
    var scope = scopeOf(node);
    if (!scope) return;
    if (!scope.querySelector('input[type="password"]')) return;
    // One typed query at submission intent, never on mutations or each input.
    var boxes = scope.querySelectorAll('input'), pass = null, fresh = null, user = null, named = null;
    for (var i = 0; i < boxes.length; i++) {
      var box = boxes[i];
      if (box.type !== 'password' || !box.value || (box.maxLength > 0 && box.maxLength <= 3)) continue;
      var rect = box.getBoundingClientRect();
      if (!rect.width || !rect.height) continue;
      var words = [box.name, box.id, box.placeholder, box.getAttribute('aria-label'),
        box.labels && box.labels[0] && box.labels[0].textContent].join(' ');
      if (/memorable|\b(\d+(st|nd|rd|th)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(character|letter|char)\b|\b(character|letter|char)\s*\d/i.test(words)) continue;
      pass = box;
      if ((box.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('new-password') >= 0) fresh = box;
    }
    pass = fresh || pass;
    if (!pass) return;
    for (var j = 0; j < boxes.length && boxes[j] !== pass; j++) {
      var box = boxes[j], type = (box.type || 'text').toLowerCase();
      if (!/^(text|email|tel)$/.test(type)) continue;
      var r = box.getBoundingClientRect(), style = getComputedStyle(box);
      var visible = r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && style.visibility !== 'hidden' && style.opacity !== '0';
      if ((box.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('username') >= 0 && (visible || box.value)) named = box;
      if (visible || box.value) user = box;
    }
    user = named || user;
    var form = pass.form;
    var single = scope === document.body || scope === document.documentElement;
    var own = single ? pass : scope;
    // Swift injection is asynchronous. Capture before the page clears fields,
    // and retain the original local scope for the loaded relay's short watch.
    pending = { anchor: pass, state: { anchor: pass, scope: own, root: own.getRootNode(),
      single: single, id: own.id, parent: own.parentElement,
      index: own.parentElement ? Array.prototype.indexOf.call(own.parentElement.children, own) : -1,
      at: Date.now() } };
    post({ kind: 'submit', user: user ? user.value : '', password: pass.value,
      action: form && form.getAttribute('action') ? form.action : '' });
    clearTimeout(expiry);
    expiry = setTimeout(function () { pending = null; }, 45000);
    ask();
  }
  function submitted(event) { sent(event.target); }
  function entered(event) {
    if (event.key === 'Enter' && login(target(event))) sent(target(event));
  }
  function clicked(event) {
    var path = event.composedPath ? event.composedPath() : [event.target];
    // This sees every click, including each checkbox in a large application.
    // Keep the composed path (slotted/shadow controls included), but don't
    // run a four-part CSS selector on every ancestor just to identify a button.
    var button = null;
    for (var i = 0; i < path.length; i++) {
      var node = path[i];
      if (!node || node.nodeType !== 1) continue;
      var name = node.localName;
      var type = name === 'input' ? (node.namespaceURI === 'http://www.w3.org/1999/xhtml'
        ? node.type : node.getAttribute('type')) : '';
      if (name === 'button' || (name === 'input' && (type === 'submit' || type === 'image')) ||
          node.getAttribute('role') === 'button') {
        button = node;
        break;
      }
    }
    if (!button) return;
    var words = [button.textContent, button.value, button.getAttribute('aria-label')].join(' ');
    if (/cancel|back|close|show|hide|forgot/i.test(words)) return;
    if (!(button.form && /^(submit|image)$/i.test(button.type || '')) &&
        !/sign\s*in|log\s*in|sign\s*up|register|create.*(?:account|password)|continue|next|submit|(?:change|reset|save).*password|confirm|verify/i.test(words)) return;
    sent(button);
  }
  window.__yabFormsSoon = { take: function () {
    document.removeEventListener('focusin', focused, true);
    document.removeEventListener('submit', submitted, true);
    document.removeEventListener('keydown', entered, true);
    document.removeEventListener('click', clicked, true);
    clearTimeout(expiry);
    var held = pending; pending = null;
    delete window.__yabFormsSoon;
    return held;
  } };
  document.addEventListener('focusin', focused, true);
  document.addEventListener('submit', submitted, true);
  document.addEventListener('keydown', entered, true);
  document.addEventListener('click', clicked, true);
  if (document.querySelector(LOGIN)) ask();
})();
