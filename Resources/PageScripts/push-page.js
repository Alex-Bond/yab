(function () {
  // Yab's pushManager (WebPush.swift): WebKit's needs Apple's push daemon,
  // which only Safari may use, and Chromium's Google's push service, so
  // without this a page had none, or one Yab couldn't carry from engine to
  // engine. In the page's own world, before anything of the site's runs;
  // requests go to yab's side as events on the window, and come back the
  // same way.
  if (!window.isSecureContext || !window.ServiceWorkerRegistration || !navigator.serviceWorker) return;
  if ('PushManager' in window && !__YAB_OVERRIDE__) return;
  var mark = Symbol.for('yab.push');
  if (window[mark]) return;
  try { Object.defineProperty(window, mark, { value: true }); } catch (e) { return; }

  var asked = '__YAB_ASKED__', answered = '__YAB_ANSWERED__';
  var waiting = Object.create(null), counter = 0;
  window.addEventListener(answered, function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message.token !== 'string' || !waiting[message.token]) return;
    var done = waiting[message.token];
    delete waiting[message.token];
    done(message.reply);
  });
  function ask(kind, fields) {
    return new Promise(function (resolve) {
      counter += 1;
      var token = 'p' + counter + '.' + Math.random().toString(36).slice(2);
      waiting[token] = resolve;
      var message = { kind: kind, token: token };
      for (var name in fields) message[name] = fields[name];
      window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify(message) }));
    });
  }
  function failure(reply) {
    var name = reply && typeof reply.error === 'string' ? reply.error : 'AbortError';
    return new DOMException(reply && reply.message ? reply.message : 'Push service not available.', name);
  }

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected a BufferSource.');
  }
  function encode(source) {
    var b = bytes(source), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(text) {
    var s = String(text || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  function illegal() { throw new TypeError('Illegal constructor'); }
  function define(target, name, value) {
    Object.defineProperty(target, name, { value: value, writable: true, configurable: true, enumerable: false });
  }
  function getter(target, name, read) {
    Object.defineProperty(target, name, { get: read, configurable: true, enumerable: true });
  }

  var PushSubscriptionOptions = function PushSubscriptionOptions() { illegal(); };
  var PushSubscription = function PushSubscription() { illegal(); };
  var PushManager = function PushManager() { illegal(); };
  var inside = new WeakMap();

  function own(object, kind) {
    var fields = inside.get(object);
    if (!fields || fields.kind !== kind) throw new TypeError('Illegal invocation');
    return fields;
  }

  getter(PushSubscriptionOptions.prototype, 'userVisibleOnly', function () { return own(this, 'options').userVisibleOnly; });
  getter(PushSubscriptionOptions.prototype, 'applicationServerKey', function () {
    var key = own(this, 'options').key;
    return key ? decode(key) : null;
  });

  function subscription(reply, registration) {
    var object = Object.create(PushSubscription.prototype);
    var options = Object.create(PushSubscriptionOptions.prototype);
    inside.set(options, { kind: 'options', userVisibleOnly: true, key: reply.key || '' });
    inside.set(object, { kind: 'subscription', reply: reply, registration: registration, options: options });
    return object;
  }
  getter(PushSubscription.prototype, 'endpoint', function () { return own(this, 'subscription').reply.endpoint; });
  getter(PushSubscription.prototype, 'expirationTime', function () { own(this, 'subscription'); return null; });
  getter(PushSubscription.prototype, 'options', function () { return own(this, 'subscription').options; });
  define(PushSubscription.prototype, 'getKey', function getKey(name) {
    var reply = own(this, 'subscription').reply;
    if (name === 'p256dh') return decode(reply.p256dh);
    if (name === 'auth') return decode(reply.auth);
    return null;
  });
  define(PushSubscription.prototype, 'toJSON', function toJSON() {
    var reply = own(this, 'subscription').reply;
    return { endpoint: reply.endpoint, expirationTime: null, keys: { p256dh: reply.p256dh, auth: reply.auth } };
  });
  define(PushSubscription.prototype, 'unsubscribe', function unsubscribe() {
    var fields = own(this, 'subscription');
    return ask('unsubscribe', { scope: fields.registration.scope }).then(function (reply) { return !!(reply && reply.ok); });
  });

  var managers = new WeakMap();
  function registrationOf(manager) {
    var fields = inside.get(manager);
    if (!fields || fields.kind !== 'manager') throw new TypeError('Illegal invocation');
    return fields.registration;
  }
  function state() {
    var said = window.Notification ? Notification.permission : 'denied';
    return said === 'default' ? 'prompt' : said;
  }

  define(PushManager.prototype, 'subscribe', function subscribe(options) {
    var registration;
    try { registration = registrationOf(this); } catch (e) { return Promise.reject(e); }
    options = options || {};
    if (!options.userVisibleOnly) {
      return Promise.reject(new DOMException('Push notifications must be visible to the user: subscribe with userVisibleOnly: true.', 'NotAllowedError'));
    }
    var key = '';
    if (options.applicationServerKey != null) {
      try {
        key = typeof options.applicationServerKey === 'string'
          ? encode(decode(options.applicationServerKey)) : encode(options.applicationServerKey);
      } catch (e) {
        return Promise.reject(new DOMException('The provided applicationServerKey is not valid.', 'InvalidAccessError'));
      }
      if (new Uint8Array(decode(key)).length !== 65) {
        return Promise.reject(new DOMException('The provided applicationServerKey is not valid.', 'InvalidAccessError'));
      }
    }
    // Asked right away, while the click that called this still counts.
    var asking = window.Notification && Notification.permission === 'default'
      ? Notification.requestPermission() : Promise.resolve(window.Notification ? Notification.permission : 'denied');
    return asking.then(function (said) {
      if (said !== 'granted') throw new DOMException('Permission denied.', 'NotAllowedError');
      if (!registration.active && !registration.waiting && !registration.installing) {
        throw new DOMException('Subscription failed - no active Service Worker', 'AbortError');
      }
      return ask('subscribe', { scope: registration.scope, key: key });
    }).then(function (reply) {
      if (!reply || reply.error) throw failure(reply);
      return subscription(reply, registration);
    });
  });
  define(PushManager.prototype, 'getSubscription', function getSubscription() {
    var registration;
    try { registration = registrationOf(this); } catch (e) { return Promise.reject(e); }
    return ask('get', { scope: registration.scope }).then(function (reply) {
      return reply && !reply.error ? subscription(reply, registration) : null;
    });
  });
  define(PushManager.prototype, 'permissionState', function permissionState() {
    try { registrationOf(this); } catch (e) { return Promise.reject(e); }
    return Promise.resolve(state());
  });
  Object.defineProperty(PushManager, 'supportedContentEncodings', {
    value: Object.freeze(['aes128gcm', 'aesgcm']), configurable: true, enumerable: true,
  });

  getter(ServiceWorkerRegistration.prototype, 'pushManager', function () {
    var manager = managers.get(this);
    if (!manager) {
      manager = Object.create(PushManager.prototype);
      inside.set(manager, { kind: 'manager', registration: this });
      managers.set(this, manager);
    }
    return manager;
  });

  [['PushManager', PushManager], ['PushSubscription', PushSubscription], ['PushSubscriptionOptions', PushSubscriptionOptions]]
    .forEach(function (pair) {
      Object.defineProperty(pair[1].prototype, Symbol.toStringTag, { value: pair[0], configurable: true });
      define(window, pair[0], pair[1]);
    });
})();
