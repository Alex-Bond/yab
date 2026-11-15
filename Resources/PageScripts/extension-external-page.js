(function () {
  // Chrome's externally_connectable for web pages (ExtensionExternal.swift).
  // WebKit gives a page an extension lets in no chrome.runtime at all, so a
  // site that signs its extension in this way (claude.ai for Claude, the
  // 1Password and Bitwarden apps) found none. In the page's own world,
  // before anything of the site's runs, and only on a page some installed
  // extension's matches name: chrome.runtime.sendMessage and connect, to an
  // extension by its id. Each request goes to Yab's world as an event on the
  // window, from there to Yab, which checks the frame's origin itself and
  // hands it to the extension's worker as runtime.onMessageExternal or
  // onConnectExternal; answers come back the same way.
  var table = __YAB_TABLE__;
  var asked = '__YAB_ASKED__', answered = '__YAB_ANSWERED__';
  var mark = Symbol.for('yab.external');
  if (window[mark]) return;

  function matches(pattern, href) {
    var m = /^(\*|https?|wss?|file|ftp|urn):\/\/([^/]*)(\/.*)$/.exec(pattern);
    var url;
    try { url = new URL(href); } catch (e) { return false; }
    if (!m) return false;
    var scheme = url.protocol.slice(0, -1);
    if (m[1] === '*' ? !(scheme === 'http' || scheme === 'https') : scheme !== m[1]) return false;
    var host = m[2], port = null;
    var colon = /^(.*):(\d+|\*)$/.exec(host);
    if (colon) { host = colon[1]; port = colon[2] === '*' ? null : colon[2]; }
    if (port !== null && url.port !== port) return false;
    var name = url.hostname.toLowerCase();
    host = host.toLowerCase();
    if (host !== '*') {
      if (host.indexOf('*.') === 0) {
        var base = host.slice(2);
        if (name !== base && name.slice(-(base.length + 1)) !== '.' + base) return false;
      } else if (name !== host) return false;
    }
    var glob = m[3].replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
    return new RegExp('^' + glob + '$').test(url.pathname + url.search);
  }
  var href = location.href;
  var reachable = Object.keys(table).filter(function (id) {
    return (table[id] || []).some(function (p) { return matches(p, href); });
  });
  if (!reachable.length) return;
  try { Object.defineProperty(window, mark, { value: true }); } catch (e) { return; }

  var noReceiver = 'Could not establish connection. Receiving end does not exist.';
  var closedPort = 'The message port closed before a response was received.';
  var waiting = Object.create(null), ports = Object.create(null), counter = 0;
  function token(prefix) {
    counter += 1;
    return prefix + counter + '.' + Math.random().toString(36).slice(2);
  }
  function ask(fields) {
    return new Promise(function (resolve) {
      var t = token('x');
      waiting[t] = resolve;
      fields.token = t;
      window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify(fields) }));
    });
  }
  window.addEventListener(answered, function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message !== 'object') return;
    if (typeof message.token === 'string' && waiting[message.token]) {
      var done = waiting[message.token];
      delete waiting[message.token];
      done(message.reply || {});
      return;
    }
    // What the extension's side of a port says, sent here by Yab.
    var port = typeof message.port === 'string' && ports[message.port];
    if (!port) return;
    if (message.disconnect) port._gone(message.error);
    else if ('message' in message) port._hear(message.message);
  });

  var chrome = window.chrome;
  if (!chrome || typeof chrome !== 'object') {
    chrome = {};
    try { Object.defineProperty(window, 'chrome', { value: chrome, writable: true, configurable: true, enumerable: true }); } catch (e) { return; }
  }
  var runtime = chrome.runtime;
  if (!runtime || typeof runtime !== 'object') {
    runtime = {};
    try { chrome.runtime = runtime; } catch (e) { return; }
  }
  if (typeof runtime.sendMessage === 'function' && typeof runtime.connect === 'function') return;

  // runtime.lastError holds only while the callback runs, as in Chromium.
  var lastError;
  try {
    Object.defineProperty(runtime, 'lastError', { get: function () { return lastError; }, configurable: true, enumerable: true });
  } catch (e) {}
  function withError(message, callback, args) {
    lastError = message ? { message: message } : undefined;
    try { callback.apply(null, args); } finally { lastError = undefined; }
  }
  function event() {
    var listeners = [];
    return {
      addListener: function (f) { if (typeof f === 'function' && listeners.indexOf(f) < 0) listeners.push(f); },
      removeListener: function (f) { var i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
      hasListener: function (f) { return listeners.indexOf(f) >= 0; },
      hasListeners: function () { return listeners.length > 0; },
      _fire: function () {
        var args = arguments;
        listeners.slice().forEach(function (f) { try { f.apply(null, args); } catch (e) { setTimeout(function () { throw e; }); } });
      },
    };
  }
  function checkID(id, name) {
    if (typeof id !== 'string' || !id) throw new TypeError('Error in invocation of runtime.' + name + '(): chrome.runtime.' + name + '() called from a webpage must specify an Extension ID (string) for its first argument.');
  }
  function plain(message) {
    // What Chrome sends is JSON; what can't be said in it can't be sent.
    return message === undefined ? null : JSON.parse(JSON.stringify(message));
  }

  function sendMessage(id, message, options, callback) {
    checkID(id, 'sendMessage');
    var args = Array.prototype.slice.call(arguments, 1);
    callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    message = args[0];
    var sent;
    try { sent = plain(message); } catch (e) { throw new TypeError('Error in invocation of runtime.sendMessage(): could not serialize message.'); }
    var answer = ask({ kind: 'send', id: id, message: sent });
    if (callback) {
      answer.then(function (reply) {
        withError(reply.error || (reply.none ? closedPort : null), callback, [reply.error || reply.none ? undefined : reply.value]);
      });
      return;
    }
    return answer.then(function (reply) {
      if (reply.error) throw new Error(reply.error);
      return reply.none ? undefined : reply.value;
    });
  }

  function connect(id, info) {
    checkID(id, 'connect');
    var name = info && typeof info.name === 'string' ? info.name : '';
    var key = token('p');
    var onMessage = event(), onDisconnect = event();
    var held = [], open = false, gone = false;
    var port = {
      name: name,
      onMessage: onMessage,
      onDisconnect: onDisconnect,
      postMessage: function (message) {
        if (gone) throw new Error('Attempting to use a disconnected port object');
        var sent = plain(message);
        if (!open) { held.push(sent); return; }
        window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: 'post', id: id, port: key, message: sent }) }));
      },
      disconnect: function () {
        if (gone) return;
        gone = true;
        delete ports[key];
        window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: 'disconnect', id: id, port: key }) }));
      },
    };
    Object.defineProperty(port, '_hear', { value: function (m) { if (!gone) onMessage._fire(m, port); } });
    Object.defineProperty(port, '_gone', { value: function (error) {
      if (gone) return;
      gone = true;
      delete ports[key];
      lastError = error ? { message: error } : undefined;
      try { onDisconnect._fire(port); } finally { lastError = undefined; }
    } });
    ports[key] = port;
    ask({ kind: 'connect', id: id, port: key, name: name }).then(function (reply) {
      if (reply.error) { port._gone(reply.error); return; }
      if (gone) return;
      open = true;
      var list = held;
      held = [];
      list.forEach(function (m) { port.postMessage(m); });
    });
    return port;
  }

  function define(name, value) {
    if (typeof runtime[name] === 'function') return;
    try { Object.defineProperty(runtime, name, { value: value, writable: true, configurable: true, enumerable: true }); } catch (e) {}
  }
  define('sendMessage', sendMessage);
  define('connect', connect);
  // A port open when the page goes: the extension hears it close, as in Chromium.
  window.addEventListener('pagehide', function (event) {
    if (event.persisted) return;
    Object.keys(ports).forEach(function (key) { try { ports[key].disconnect(); } catch (e) {} });
  });
})();
