(function () {
  if (window.__yabNet) return;
  var N = window.__yabNet = { ready: false };
  function post(m) { try { webkit.messageHandlers.yabInspector.postMessage(m); } catch (e) {} }
  var ids = new WeakMap(), refs = new Map(), next = 1;
  var dirty = new Set(), frames = [], timer = null, nav = null, page = { dcl: 0, load: 0 };
  var said = new WeakMap(), marks = new Map();
  function idOf(r) {
    var i = ids.get(r);
    if (!i) { i = next++; ids.set(r, i); refs.set(i, new WeakRef(r)); }
    return i;
  }
  function resourceFor(id) { var w = refs.get(id); return w ? w.deref() : null; }
  N.resourceFor = resourceFor;
  function n(v) { return typeof v === 'number' && isFinite(v) && v > 0 ? v : 0; }
  function sym(v) { return v && typeof v === 'symbol' ? v.description : (v == null ? '' : String(v)); }
  function kind(t) {
    var s = String(t || '').replace('resource-type-', '');
    return s === 'style-sheet' ? 'stylesheet' : s || 'other';
  }
  function pairs(h) {
    var out = [];
    if (!h) return out;
    Object.keys(h).forEach(function (k) { out.push([k, String(h[k])]); });
    return out;
  }
  function initiator(r) {
    var o = { k: 'other', s: [] };
    try {
      var st = r.initiatorStackTrace, calls = st && st.callFrames ? st.callFrames : [];
      o.s = calls.map(function (f) {
        var l = f.sourceCodeLocation, sc = l && l.sourceCode;
        return [f.functionName || '(anonymous)', (sc && sc.url) || f.url || '', l ? l.lineNumber + 1 : (f.line || 0) + 1, l ? l.columnNumber + 1 : (f.column || 0) + 1];
      }).filter(function (f) { return (f[1] || f[0] !== '(anonymous)') && String(f[1]).indexOf('user-script') !== 0; });
      // Yab's own listener wraps fetch on a local page: its frame is no
      // place of the page's, and never the initiator.
      var loc = r.initiatorSourceCodeLocation;
      var mine = loc && loc.sourceCode && String(loc.sourceCode.url || '').indexOf('user-script') === 0;
      if (mine) loc = null;
      if (o.s.length) o.k = 'script';
      else if (loc || r.initiatorNode) o.k = 'parser';
      if (loc) {
        var code = loc.sourceCode;
        o.u = (code && code.url) || '';
        o.l = loc.lineNumber + 1;
        o.c = loc.columnNumber + 1;
        if (code && code instanceof WI.Resource) o.r = idOf(code);
      } else if (o.s.length) {
        o.u = o.s[0][1]; o.l = o.s[0][2]; o.c = o.s[0][3];
      }
    } catch (e) {}
    return o;
  }
  function timing(t) {
    if (!t) return null;
    return { s: n(t.startTime), rs: n(t.redirectStart), re: n(t.redirectEnd), f: n(t.fetchStart), ds: n(t.domainLookupStart), de: n(t.domainLookupEnd),
             cs: n(t.connectStart), ce: n(t.connectEnd), ss: n(t.secureConnectionStart), qs: n(t.requestStart), ps: n(t.responseStart), pe: n(t.responseEnd) };
  }
  // A resource's fields; headers, the request's body and the redirects
  // only when they are new since the last time it was said.
  function record(r) {
    var id = idOf(r), was = said.get(r) || {};
    var o = { i: id };
    try {
      o.tg = r.target && r.target.identifier || '';
      o.fr = r.parentFrame && r.parentFrame.id || '';
      o.ld = r.loaderIdentifier || '';
      var main = WI.networkManager.mainFrame;
      o.mn = !!(main && main.mainResource === r);
      o.u = r.url; o.m = r.requestMethod || 'GET'; o.y = kind(r.type); o.mt = r.mimeType || '';
      o.st = r.statusCode || 0; o.sx = r.statusText || '';
      o.rs = sym(r.responseSource) || 'unknown'; o.pr = r.protocol || ''; o.pi = sym(r.priority);
      if (o.pi === 'unknown') o.pi = '';
      o.ra = r.displayRemoteAddress || r.remoteAddress || ''; o.ci = r.connectionIdentifier != null ? String(r.connectionIdentifier) : '';
      o.sz = n(r.size) || n(r.networkDecodedSize);
      var total = r.networkTotalTransferSize;
      o.tt = isFinite(total) && total >= 0 ? total : n(r.estimatedTotalTransferSize);
      o.qh = n(r.requestHeadersTransferSize); o.qb = n(r.requestBodyTransferSize);
      o.ph = n(r.responseHeadersTransferSize); o.pb = n(r.responseBodyTransferSize);
      o.ts = n(r.requestSentTimestamp); o.wt = n(r.requestSentWalltime);
      o.rr = n(r.responseReceivedTimestamp); o.en = n(r.finishedOrFailedTimestamp);
      o.dn = !!r.finished; o.fl = !!r.failed; o.cn = !!r.canceled; o.why = r.failureReasonText || '';
      o.rp = r.referrerPolicy || '';
      o.tm = timing(r.timingData);
      if (r.requestHeaders !== was.qhd) { o.qhd = pairs(r.requestHeaders); was.qhd = r.requestHeaders; }
      if (r.responseHeaders !== was.phd) { o.phd = pairs(r.responseHeaders); was.phd = r.responseHeaders; }
      if (r.requestData !== was.pd) {
        var data = r.requestData;
        o.pd = data == null ? null : String(data);
        o.pdt = r.requestDataContentType || '';
        was.pd = data;
      }
      var hops = r.redirects || [];
      if (hops.length !== was.rd) {
        o.rd = hops.map(function (h) {
          return { u: h.url, m: h.requestMethod || 'GET', st: h.responseStatusCode || 0, sx: h.responseStatusText || '',
                   qhd: pairs(h.requestHeaders), phd: pairs(h.responseHeaders), at: n(h.timestamp) };
        });
        was.rd = hops.length;
      }
      var sec = r.security && r.security.connection;
      if (sec && !was.sec) { o.sec = { protocol: sec.protocol || '', cipher: sec.cipher || '' }; was.sec = true; }
      if (!was.in || r.initiatorStackTrace || r.initiatorSourceCodeLocation) {
        if (!was.in) { o.in = initiator(r); was.in = true; }
      }
      if (r instanceof WI.WebSocketResource) o.so = r.readyState === WI.WebSocketResource.ReadyState.Open;
      var mark = r.requestIdentifier && marks.get(r.requestIdentifier);
      if (mark) { if (mark.thr) o.thr = mark.thr; if (mark.blk) o.blk = mark.blk; }
      else if (o.fl && /content blocker/i.test(o.why)) o.blk = 'content';
    } catch (e) {}
    said.set(r, was);
    return o;
  }
  function touch(r) {
    if (!r || !(r instanceof WI.Resource) || r instanceof WI.LocalResource) return;
    dirty.add(r);
    soon();
  }
  // Passed on a quarter of a second after the first change, whatever
  // came between: a page in a loop of requests costs four messages a
  // second. A timer, not a frame: the page is hidden behind yab's panel.
  function soon() {
    if (timer) return;
    timer = setTimeout(flush, 250);
  }
  // Yab's beat while the card is out: what changed passed on, and held
  // requests whose time has come let go. Answers when the next one is.
  N.tick = function () {
    if (timer) { clearTimeout(timer); timer = null; }
    flush();
    return N.release ? N.release() : -1;
  };
  function flush() {
    timer = null;
    var out = {};
    if (dirty.size) {
      out.r = [];
      dirty.forEach(function (r) { out.r.push(record(r)); });
      dirty.clear();
    }
    if (frames.length) { out.w = frames; frames = []; }
    if (nav) { out.nav = nav; nav = null; }
    try {
      var main = WI.networkManager.mainFrame;
      var dcl = main ? n(main.domContentReadyEventTimestamp) : 0, load = main ? n(main.loadEventTimestamp) : 0;
      if (dcl !== page.dcl || load !== page.load) { page = { dcl: dcl, load: load }; out.pg = page; }
    } catch (e) {}
    if (Object.keys(out).length) post({ k: 'net', j: JSON.stringify(out) });
  }
  function everything() {
    var all = new Set();
    try {
      WI.networkManager.frames.forEach(function (frame) {
        if (frame.mainResource) all.add(frame.mainResource);
        if (frame.provisionalMainResource) all.add(frame.provisionalMainResource);
        for (var r of frame.resourceCollection) all.add(r);
      });
      WI.targets.forEach(function (target) {
        if (target.resourceCollection) for (var r of target.resourceCollection) all.add(r);
      });
    } catch (e) {}
    return all;
  }
  function start() {
    if (!window.WI || !WI.networkManager || !WI.Resource || !WI.Frame) { setTimeout(start, 50); return; }
    try {
      WI.Frame.addEventListener(WI.Frame.Event.ResourceWasAdded, function (e) { touch(e.data.resource); });
      WI.Frame.addEventListener(WI.Frame.Event.ProvisionalResourceWasAdded, function (e) { touch(e.data.resource); });
      WI.Frame.addEventListener(WI.Frame.Event.MainResourceDidChange, function (e) {
        var frame = e.target;
        if (frame && frame.isMainFrame && frame.isMainFrame() && frame.mainResource) {
          nav = frame.mainResource.loaderIdentifier || '';
          page = { dcl: 0, load: 0 };
          if (N.offline) N.goOffline();
        }
        touch(frame && frame.mainResource);
      });
      WI.Target.addEventListener(WI.Target.Event.ResourceAdded, function (e) { touch(e.data.resource); });
      // DOMContentLoaded and Load are marked on the frame, with no event
      // of their own: said with the next batch.
      var F = WI.Frame.prototype;
      ['markDOMContentReadyEvent', 'markLoadEvent'].forEach(function (name) {
        var own = F[name];
        if (!own || own.__yab) return;
        F[name] = function () { var out = own.apply(this, arguments); soon(); return out; };
        F[name].__yab = true;
      });
      var R = WI.Resource.Event;
      [R.URLDidChange, R.MIMETypeDidChange, R.TypeDidChange, R.RequestHeadersDidChange, R.RequestDataDidChange, R.ResponseReceived,
       R.LoadingDidFinish, R.LoadingDidFail, R.TimestampsDidChange, R.SizeDidChange, R.TransferSizeDidChange, R.CacheStatusDidChange,
       R.MetricsDidChange, R.RedirectsDidChange].forEach(function (type) {
        if (type) WI.Resource.addEventListener(type, function (e) { touch(e.target); });
      });
      WI.WebSocketResource.addEventListener(WI.WebSocketResource.Event.FrameAdded, function (e) {
        var f = e.data || {}, r = e.target;
        frames.push([idOf(r), !!f.isOutgoing, f.opcode || 1, f.data == null ? null : String(f.data).slice(0, 65536), f.data == null ? 0 : String(f.data).length, n(f.walltime)]);
        touch(r);
      });
      WI.WebSocketResource.addEventListener(WI.WebSocketResource.Event.ReadyStateChanged, function (e) { touch(e.target); });
      everything().forEach(touch);
      hookInterception();
      N.ready = true;
    } catch (e) {
      post({ k: 'net', j: JSON.stringify({ x: true }) });
    }
  }

  // MARK: what yab asks

  // A body as WebKit has it: words, or bytes in base64.
  N.body = function (id) {
    var r = resourceFor(id);
    if (!r) return Promise.resolve({ e: 'gone' });
    return r.requestContent().then(function (c) {
      return { t: c.rawContent == null ? '' : String(c.rawContent), b: !!c.rawBase64Encoded, e: c.error || '' };
    }, function (e) { return { e: String(e && e.message || e || 'failed') }; });
  };
  // Every resource's body for Search, words only, small enough to read.
  N.text = function (id) {
    return N.body(id).then(function (b) { return b.b ? '' : (b.t || '').slice(0, 1048576); });
  };
  // Asked again from the page, as the page would: its method, its
  // headers (those a page may set) and its body, with its cookies.
  N.resend = function (id) {
    var r = resourceFor(id);
    if (!r) return false;
    var forbidden = /^(accept-charset|accept-encoding|access-control-request-|connection|content-length|cookie|cookie2|date|dnt|expect|host|keep-alive|origin|referer|te|trailer|transfer-encoding|upgrade|via|proxy-|sec-|user-agent)/i;
    var headers = {};
    Object.keys(r.requestHeaders || {}).forEach(function (k) { if (!forbidden.test(k) && k[0] !== ':') headers[k] = r.requestHeaders[k]; });
    var init = { method: r.requestMethod || 'GET', headers: headers, credentials: 'include' };
    if (r.requestData != null && init.method !== 'GET' && init.method !== 'HEAD') init.body = r.requestData;
    var expression = 'fetch(' + JSON.stringify(r.url) + ', ' + JSON.stringify(init) + ').catch(function () {}); 0';
    try { WI.mainTarget.RuntimeAgent.evaluate.invoke({ expression: expression, objectGroup: 'yab', includeCommandLineAPI: false, doNotPauseOnExceptionsAndMuteConsole: true }); return true; } catch (e) { return false; }
  };
  // Edit and Resend as Fetch: the request as fetch() in the console's
  // prompt, Return sends it.
  N.editResend = function (id) {
    var r = resourceFor(id);
    if (!r) return false;
    try {
      var code = WI.ResourceUtilities.generateFetchCode(r);
      WI.showConsoleTab();
      WI.quickConsole.prompt.text = '// Make any edits, then Return to resend\n' + code;
      return true;
    } catch (e) { return false; }
  };
  // Open in Sources panel.
  N.reveal = function (id) {
    var r = resourceFor(id);
    if (!r) return false;
    try { WI.showSourceCode(r); return true; } catch (e) { return false; }
  };
  // Override content: WebKit's local override of the response, with
  // what came back in it, shown in Sources to be edited.
  N.overrideContent = function (id) {
    var r = resourceFor(id);
    if (!r) return Promise.resolve(false);
    return r.createLocalResourceOverride(WI.LocalResourceOverride.InterceptType.Response).then(function (o) {
      WI.networkManager.addLocalResourceOverride(o);
      WI.showLocalResourceOverride(o, { overriddenResource: r });
      return true;
    }, function () { return false; });
  };
  // Override headers: the same, with these response headers in place
  // of what came (an empty value takes one away). The body is kept as
  // it came this time: WebKit's override always answers with one.
  N.overrideHeaders = function (id, headers) {
    var r = resourceFor(id);
    if (!r) return Promise.resolve(false);
    var existing = WI.networkManager.localResourceOverridesForURL ? WI.networkManager.localResourceOverridesForURL(r.url) : [];
    existing.forEach(function (o) { if (o.type === WI.LocalResourceOverride.InterceptType.Response) WI.networkManager.removeLocalResourceOverride(o); });
    return r.createLocalResourceOverride(WI.LocalResourceOverride.InterceptType.Response).then(function (o) {
      var merged = Object.assign({}, r.responseHeaders || {});
      Object.keys(headers).forEach(function (k) {
        Object.keys(merged).forEach(function (m) { if (m.toLowerCase() === k.toLowerCase()) delete merged[m]; });
        if (headers[k] !== '') merged[k] = headers[k];
      });
      o.localResource._responseHeaders = merged;
      WI.networkManager.addLocalResourceOverride(o);
      return true;
    }, function () { return false; });
  };
  // Which addresses have overrides: content, headers, or both.
  N.overrides = function () {
    var out = [];
    try {
      WI.networkManager.localResourceOverrides.forEach(function (o) {
        if (!o.disabled) out.push([o.url, o.isRegex ? 1 : 0, sym(o.type)]);
      });
    } catch (e) {}
    return out;
  };
  N.showOverrides = function () { try { WI.showSourcesTab(); return true; } catch (e) { return false; } };
  // Disable cache, while the card is out.
  N.cache = function (off) {
    try { WI.settings.resourceCachingDisabled.value = !!off; } catch (e) {}
    try { WI.targets.forEach(function (t) { if (t.hasCommand && t.hasCommand('Network.setResourceCachingDisabled')) t.NetworkAgent.setResourceCachingDisabled(!!off); }); } catch (e) {}
    return true;
  };
  // Keep log: WebKit keeps the bodies of a page gone too.
  N.keep = function (on) {
    try { WI.settings.clearNetworkOnNavigate.value = !on; } catch (e) {}
    try { WI.targets.forEach(function (t) { if (t.hasCommand && t.hasCommand('Network.setClearResourceDataOnNavigate')) t.NetworkAgent.setClearResourceDataOnNavigate(!on); }); } catch (e) {}
    return true;
  };
  // Network conditions' User agent, null for the browser's own.
  N.userAgent = function (value) {
    try { WI.mainTarget.PageAgent.overrideUserAgent(value || undefined); return true; } catch (e) { return false; }
  };
  // Headers sent with every request: Save-Data.
  N.extraHeaders = function (headers) {
    try { WI.targets.forEach(function (t) { if (t.hasCommand && t.hasCommand('Network.setExtraHTTPHeaders')) t.NetworkAgent.setExtraHTTPHeaders(headers || {}); }); return true; } catch (e) { return false; }
  };
  // What is listed now, as WebKit's HAR builder writes it, for a
  // request's bodies in an export.
  N.all = function () { var out = []; everything().forEach(function (r) { out.push(idOf(r)); }); return out; };

  // MARK: throttling and Request conditions
  //
  // WebKit's throttling isn't in this Mac's WebKit, so yab holds
  // requests back itself: every request is intercepted while a rule or
  // a preset is on, kept for the preset's latency and its upload, and
  // its response kept for as long as its body takes at the preset's
  // speed. A rule that blocks answers with an error at once. Rules are
  // tried in order; the first that matches wins over the preset.
  N.rules = [];
  N.preset = null;
  N.offline = false;
  var intercepting = false;
  // Which of WebKit's stages are held: the request for latency and
  // upload, the response for the body's time.
  N.stages = ['request', 'response'];
  N.state = function () {
    return { intercepting: intercepting, stages: N.stages, preset: N.preset, offline: N.offline, rules: N.rules.length,
             enabled: !!(WI.networkManager && WI.networkManager.interceptionEnabled), held: held, waiting: holds.length,
             due: holds.map(function (h) { return h.due - Date.now(); }),
             rulesSeen: N.rules.map(function (r) { return [r.p, r.c, r.preset ? r.preset.latency : null]; }) };
  };
  var held = { request: 0, response: 0, released: 0 };
  function compile(p) {
    try { return new RegExp('^' + p.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$', 'i'); } catch (e) { return null; }
  }
  function ruleFor(url) {
    for (var i = 0; i < N.rules.length; i++) {
      var r = N.rules[i];
      if (!r.on) continue;
      if (r.re ? r.re.test(url) : url.indexOf(r.p) >= 0) return r;
    }
    return null;
  }
  function conditionFor(url) {
    var rule = ruleFor(url);
    if (rule) return { block: rule.c === 'block', preset: rule.c === 'block' ? null : rule.preset, name: rule.name, rule: true };
    if (N.offline) return { offline: true };
    if (N.preset) return { preset: N.preset, name: N.preset.name, rule: false };
    return null;
  }
  // A request or a response held for `ms`, then `go`. WebKit lets the
  // timers of a page it thinks hidden, as this one behind Yab's panel,
  // wait up to a minute, so Yab's beat lets them go (N.tick); a timer
  // stands in for when it is quicker.
  var holds = [];
  function hold(ms, go) {
    return new Promise(function (done) {
      ms = Math.max(0, Number(ms) || 0);
      holds.push({ due: Date.now() + ms, go: function () { done(go()); } });
      setTimeout(N.release, ms);
    });
  }
  N.release = function () {
    var now = Date.now(), due = holds.filter(function (h) { return h.due <= now; });
    holds = holds.filter(function (h) { return h.due > now; });
    due.forEach(function (h) { try { h.go(); } catch (e) {} });
    var next = holds.reduce(function (m, h) { return Math.min(m, h.due - now); }, Infinity);
    return isFinite(next) ? Math.max(0, next) : -1;
  };
  function mark(requestId, what) {
    if (!requestId) return;
    var m = marks.get(requestId) || {};
    Object.assign(m, what);
    marks.set(requestId, m);
    var r = WI.networkManager.resourceForRequestIdentifier && WI.networkManager.resourceForRequestIdentifier(requestId);
    if (r) touch(r);
  }
  function setIntercepting(on) {
    if (on === intercepting) return;
    intercepting = on;
    try {
      WI.targets.forEach(function (t) {
        if (!t.hasCommand || !t.hasCommand('Network.addInterception')) return;
        N.stages.forEach(function (stage) {
          var call = on ? t.NetworkAgent.addInterception : t.NetworkAgent.removeInterception;
          call.invoke({ url: '.*', stage: stage, isRegex: true });
        });
      });
      // WebKit's own switch for its local overrides, on unless turned off
      // in its Sources: left on, or overrides would stop applying.
      if (on) WI.networkManager.interceptionEnabled = true;
    } catch (e) {}
  }
  // The last interceptions, for the bench: when, which stage, which
  // address, and what was done.
  N.trace = [];
  function trace(stage, url, c) {
    N.trace.push([Date.now(), stage, String(url).slice(-60), c ? (c.block ? 'block' : c.offline ? 'offline' : c.preset ? c.preset.name || 'preset' : '') : '']);
    if (N.trace.length > 200) N.trace.shift();
  }
  function hookInterception() {
    var M = WI.NetworkManager.prototype;
    if (M.__yab) return;
    M.__yab = true;
    var request = M.requestIntercepted, response = M.responseIntercepted;
    M.requestIntercepted = function (target, requestId, req) {
      var self = this, args = arguments, c = intercepting && conditionFor(req.url);
      trace('request', req.url, c);
      if (c && (c.block || c.offline)) {
        mark(requestId, { blk: c.offline ? 'offline' : 'devtools' });
        target.NetworkAgent.interceptRequestWithError.invoke({ requestId: requestId, errorType: c.offline ? 'General' : 'Cancellation' });
        return;
      }
      if (c && c.preset) {
        if (c.rule) mark(requestId, { thr: c.name });
        var up = req.postData ? String(req.postData).length * 8 / Math.max(1, c.preset.up) : 0;
        held.request++;
        return hold(c.preset.latency + up, function () { held.released++; return request.apply(self, args); });
      }
      return request.apply(self, args);
    };
    M.responseIntercepted = function (target, requestId, res) {
      var self = this, args = arguments, c = intercepting && conditionFor(res.url);
      trace('response', res.url, c);
      if (c && c.preset) {
        var length = 0, h = res.headers || {};
        Object.keys(h).forEach(function (k) { if (k.toLowerCase() === 'content-length') length = +h[k] || 0; });
        held.response++;
        return hold(length * 8 / Math.max(1, c.preset.down), function () { held.released++; return response.apply(self, args); });
      }
      return response.apply(self, args);
    };
  }
  // The interceptions put again, as the stages now are.
  N.reapply = function () {
    var on = intercepting;
    setIntercepting(false);
    setIntercepting(on);
    return N.state();
  };
  // Offline: no request goes, and the page is told it is offline.
  N.goOffline = function () {
    try {
      WI.mainTarget.RuntimeAgent.evaluate.invoke({ expression: "Object.defineProperty(Navigator.prototype, 'onLine', { get: function () { return false; }, configurable: true }); window.dispatchEvent(new Event('offline')); 0", objectGroup: 'yab', doNotPauseOnExceptionsAndMuteConsole: true });
    } catch (e) {}
  };
  function backOnline() {
    try {
      WI.mainTarget.RuntimeAgent.evaluate.invoke({ expression: "delete Navigator.prototype.onLine; window.dispatchEvent(new Event('online')); 0", objectGroup: 'yab', doNotPauseOnExceptionsAndMuteConsole: true });
    } catch (e) {}
  }
  // From yab: the rules in order, the preset (latency in ms, download
  // and upload in kbit/s) or null, and whether it is Offline.
  N.conditions = function (rules, preset, offline) {
    var was = N.offline;
    N.rules = (rules || []).map(function (r) {
      return { on: !!r.on, p: r.p, re: compile(r.p), c: r.c, preset: r.preset || null, name: r.name || '' };
    });
    N.preset = preset || null;
    N.offline = !!offline;
    setIntercepting(N.offline || !!N.preset || N.rules.some(function (r) { return r.on; }));
    if (N.offline && !was) N.goOffline();
    if (!N.offline && was) backOnline();
    return true;
  };
  start();
})();
