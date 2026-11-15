(function () {
  var h = location.hostname;
  if (!(h === 'localhost' || /\.localhost$/.test(h) || /\.test$/.test(h) || h === '127.0.0.1' || h === '[::1]' || h === '::1')) return;
  if (window.top !== window) return;
  var EVT = 'yab:dev', MAX = 500, KEEP = 8192;
  var groups = new Map(), dirty = [], reqs = [], streams = [], dropped = 0, timer = 0;
  var now = Date.now.bind(Date);
  var nativeSetTimeout = window.setTimeout.bind(window);
  function cut(s, n) { s = String(s); return s.length > n ? s.slice(0, n) : s; }
  function word(a) {
    if (typeof a === 'string') return a;
    if (a instanceof Error) return a.name + ': ' + a.message;
    if (a && typeof a === 'object') { try { return cut(JSON.stringify(a), 500); } catch (e) { return Object.prototype.toString.call(a); } }
    return String(a);
  }
  function stackOf(skip) {
    var s = (new Error()).stack || '';
    return cut(s.split('\n').slice(skip).join('\n'), 4000);
  }
  var lastText = null, lastLevel = '', lastGroup = null;
  function add(level, text, stack, source) {
    // The same words again, the commonest case in a loop: no key to make.
    var g = null;
    if (text === lastText && level === lastLevel) g = lastGroup;
    if (!g) {
      var key = level + '|' + cut(text, 300).replace(/[0-9]+/g, '#');
      g = groups.get(key);
    }
    if (g) {
      g.n++; g.l = now();
      if (!g.d) { g.d = 1; dirty.push(g); }
    } else if (groups.size >= MAX) {
      dropped++;
    } else {
      g = { k: key, v: level, t: cut(text, 4000), s: stack === undefined ? stackOf(3) : stack, o: source || '', n: 1, l: now(), d: 1, sent: 0 };
      groups.set(key, g);
      dirty.push(g);
    }
    if (g) { lastText = text; lastLevel = level; lastGroup = g; }
    schedule();
  }
  function schedule() { if (!timer) timer = nativeSetTimeout(flush, 250); }
  function flush() {
    timer = 0;
    var g = [];
    for (var i = 0; i < dirty.length; i++) {
      var one = dirty[i];
      one.d = 0;
      if (one.sent) g.push({ k: one.k, v: one.v, n: one.n, l: one.l });
      else { one.sent = 1; g.push({ k: one.k, v: one.v, n: one.n, l: one.l, t: one.t, s: one.s, o: one.o }); }
    }
    dirty = [];
    var r = reqs; reqs = [];
    var st = streams; streams = [];
    if (!g.length && !r.length && !st.length) return;
    try { window.dispatchEvent(new CustomEvent(EVT, { detail: JSON.stringify({ g: g, r: r, x: dropped, s: st }) })); } catch (e) {}
  }
  ['error', 'warn'].forEach(function (name) {
    var was = console[name];
    console[name] = function () {
      var parts = [];
      for (var i = 0; i < arguments.length && i < 4; i++) parts.push(word(arguments[i]));
      var err = null;
      for (var j = 0; j < arguments.length; j++) if (arguments[j] instanceof Error) { err = arguments[j]; break; }
      add(name === 'error' ? 'error' : 'warning', parts.join(' '), err ? cut(err.stack || '', 4000) : undefined);
      return was.apply(this, arguments);
    };
  });
  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && (t.src || t.href)) {
      add('error', 'Failed to load ' + (t.tagName || '').toLowerCase() + ': ' + (t.src || t.href), '', '');
      return;
    }
    var err = e.error;
    add('error', err ? (err.name + ': ' + err.message) : String(e.message), err ? cut(err.stack || '', 4000) : '', e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : '');
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var why = e.reason;
    add('error', 'Unhandled rejection: ' + (why instanceof Error ? why.name + ': ' + why.message : word(why)), why instanceof Error ? cut(why.stack || '', 4000) : '');
  });
  function heard(rec) {
    reqs.push(rec);
    if (reqs.length > 300) reqs.shift();
    schedule();
  }
  function whole(u) { try { return new URL(u, location.href).href; } catch (e) { return String(u); } }
  function headersOf(h) {
    var out = {};
    try {
      if (!h) return out;
      if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function (v, k) { out[k.toLowerCase()] = cut(v, 500); });
      else if (Array.isArray(h)) h.forEach(function (p) { out[String(p[0]).toLowerCase()] = cut(p[1], 500); });
      else Object.keys(h).forEach(function (k) { out[k.toLowerCase()] = cut(h[k], 500); });
    } catch (e) {}
    return out;
  }
  // An EventSource's events, for Network's EventStream: WebKit's
  // protocol carries none. Every type the page listens for, and plain
  // messages, as they come.
  var OwnSource = window.EventSource;
  if (OwnSource) {
    var Source = function (url, init) {
      var es = new OwnSource(url, init), u = whole(url), types = {};
      function heardEvent(e) {
        streams.push({ u: u, i: String(e.lastEventId || ''), t: e.type, d: cut(e.data, KEEP), w: now() / 1000 });
        if (streams.length > 1000) streams.shift();
        schedule();
      }
      OwnSource.prototype.addEventListener.call(es, 'message', heardEvent);
      es.addEventListener = function (type, listener, options) {
        if (type !== 'message' && type !== 'open' && type !== 'error' && !types[type]) {
          types[type] = 1;
          OwnSource.prototype.addEventListener.call(es, type, heardEvent);
        }
        return OwnSource.prototype.addEventListener.call(es, type, listener, options);
      };
      return es;
    };
    Source.prototype = OwnSource.prototype;
    Source.CONNECTING = 0; Source.OPEN = 1; Source.CLOSED = 2;
    window.EventSource = Source;
  }
  var ownFetch = window.fetch;
  if (ownFetch) {
    window.fetch = function (input, init) {
      // When it was sent, by the wall's clock as WebKit's Network has
      // it: what tells it there from others to the same address.
      var t0 = performance.now(), at = now();
      var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
      var url = whole(typeof input === 'string' ? input : (input && input.url) || String(input));
      var body = init && typeof init.body === 'string' ? cut(init.body, KEEP) : null;
      var headers = headersOf(init && init.headers);
      var p = ownFetch.apply(this, arguments);
      p.then(function (res) {
        var rec = { m: method, u: url, st: res.status, ms: Math.round(performance.now() - t0), t: at, k: 'fetch', q: body, h: headers };
        if (res.status >= 400) {
          res.clone().text().then(function (t) { rec.r = cut(t, KEEP); heard(rec); }, function () { heard(rec); });
        } else heard(rec);
      }, function (err) {
        heard({ m: method, u: url, st: 0, ms: Math.round(performance.now() - t0), t: at, k: 'fetch', q: body, h: headers, e: cut(err && err.message || err, 500) });
      });
      return p;
    };
  }
  var X = window.XMLHttpRequest && XMLHttpRequest.prototype;
  if (X) {
    var ownOpen = X.open, ownSend = X.send, ownSet = X.setRequestHeader;
    X.open = function (method, url) { this.__yab = { m: String(method || 'GET').toUpperCase(), u: whole(url), h: {} }; return ownOpen.apply(this, arguments); };
    X.setRequestHeader = function (k, v) { if (this.__yab) this.__yab.h[String(k).toLowerCase()] = cut(v, 500); return ownSet.apply(this, arguments); };
    X.send = function (body) {
      var x = this, rec = x.__yab;
      if (rec) {
        var t0 = performance.now(), at = now();
        rec.q = typeof body === 'string' ? cut(body, KEEP) : null;
        x.addEventListener('loadend', function () {
          var out = { m: rec.m, u: rec.u, st: x.status, ms: Math.round(performance.now() - t0), t: at, k: 'xhr', q: rec.q, h: rec.h };
          if (!x.status) out.e = 'Network error';
          else if (x.status >= 400 && (x.responseType === '' || x.responseType === 'text')) out.r = cut(x.responseText || '', KEEP);
          heard(out);
        });
      }
      return ownSend.apply(this, arguments);
    };
  }
  try {
    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (e) {
        if (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest') return;
        heard({ m: 'GET', u: e.name, st: e.responseStatus || 0, ms: Math.round(e.duration), t: Math.round(now() - performance.now() + e.startTime), k: e.initiatorType || 'other' });
      });
    }).observe({ type: 'resource', buffered: true });
  } catch (e) {}
})();
