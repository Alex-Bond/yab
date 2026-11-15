(function () {
  if (window.__yabConsole) return;
  var C = window.__yabConsole = { live: [], liveSaid: [], ctx: 0, last: 0, contextKeys: new Map(), nextContext: 1, previews: [], previewing: 0 };
  function W() { return window.__yabWire; }
  function cut(s, n) { s = String(s); return s.length > n ? s.slice(0, n) + '…' : s; }
  function prev(p) {
    if (!p) return undefined;
    var out = { ty: p.type, d: p.description == null ? undefined : cut(p.description, 400), of: !!p.overflow, ll: !!p.lossless };
    if (p.subtype) out.st = p.subtype;
    if (p.size != null) out.sz = p.size;
    if (p.properties) out.ps = p.properties.slice(0, 100).map(function (x) {
      var q = { n: String(x.name), ty: x.type };
      if (x.subtype) q.st = x.subtype;
      if (x.value != null) q.v = cut(x.value, 400);
      if (x.valuePreview) q.pv = x.valuePreview instanceof WI.ObjectPreview ? prevOf(x.valuePreview) : prev(x.valuePreview);
      if (x.internal) q.i = true;
      return q;
    });
    if (p.entries) out.es = p.entries.slice(0, 100).map(function (e) { return { k: e.key ? prev(e.key) : undefined, v: prev(e.value) }; });
    return out;
  }
  // A RemoteObject payload, raw from the protocol or a WI.RemoteObject.
  function val(o, tg) {
    if (!o) return { ty: 'undefined' };
    if (o instanceof WI.RemoteObject) {
      var raw = { type: o.type, subtype: o.subtype, description: o.description, objectId: o.objectId, size: o.size, className: o._className };
      if (o.hasValue && o.hasValue()) raw.value = o.value;
      if (o.preview) raw.preview = o.preview;
      o = raw;
    }
    var v = { ty: o.type };
    if (o.subtype) v.st = o.subtype;
    if (o.className) v.cn = o.className;
    if ('value' in o && o.value !== undefined) v.v = typeof o.value === 'string' ? cut(o.value, 20000) : o.value;
    if (o.description != null) v.d = cut(o.description, 20000);
    if (o.objectId) v.id = o.objectId;
    if (o.size != null) v.sz = o.size;
    if (o.preview) v.pv = o.preview instanceof WI.ObjectPreview ? prevOf(o.preview) : prev(o.preview);
    if (tg) v.tg = tg;
    if (v.id && v.ty === 'object' && !v.pv && C.previews.length < 15000) C.previews.push({ id: v.id, tg: tg || '', v: v });
    return v;
  }
  // A WI.ObjectPreview, as the raw payload would have it.
  function prevOf(p) { return p ? prev(prevPayload(p)) : undefined; }
  function prevPayload(p) {
    return { type: p.type, subtype: p.subtype, description: p.description, overflow: p.overflow, lossless: p.lossless, size: p.size,
      properties: (p.propertyPreviews || []).map(function (x) { return { name: x.name, type: x.type, subtype: x.subtype, value: x.value, valuePreview: x.valuePreview ? prevPayload(x.valuePreview) : undefined, internal: x.internal }; }),
      entries: (p.collectionEntryPreviews || []).map(function (e) { return { key: e.keyPreview ? prevPayload(e.keyPreview) : undefined, value: e.valuePreview ? prevPayload(e.valuePreview) : undefined }; }) };
  }
  function frames(stack) {
    var list = Array.isArray(stack) ? stack : (stack && stack.callFrames) || [];
    var out = list.slice(0, 40).map(function (f) { return { f: f.functionName || '', u: f.url || '', l: f.lineNumber || 0, c: f.columnNumber || 0 }; });
    var parent = stack && !Array.isArray(stack) ? stack.parentStackTrace : null;
    if (parent && parent.callFrames && parent.callFrames.length) {
      out.push({ f: '', u: '', l: 0, c: 0, async: parent.parentCallFrameName || 'async' });
      out = out.concat(parent.callFrames.slice(0, 20).map(function (f) { return { f: f.functionName || '', u: f.url || '', l: f.lineNumber || 0, c: f.columnNumber || 0 }; }));
    }
    return out;
  }
  function targetId(target) { try { return target && target !== WI.mainTarget ? target.identifier : ''; } catch (e) { return ''; } }
  function hook() {
    if (!window.WI || !WI.ConsoleManager || !window.__yabWire) { setTimeout(hook, 5); return; }
    var P = WI.ConsoleManager.prototype;
    if (P.__yabConsole) return;
    P.__yabConsole = true;
    var added = P.messageWasAdded, repeated = P.messageRepeatCountUpdated, cleared = P.messagesCleared;
    P.messageWasAdded = function (target, source, level, text, type, url, line, column, repeatCount, parameters, stackTrace, requestId, timestamp) {
      try {
        var tg = targetId(target);
        W().post('console', { t: 'm', tg: tg, src: source || '', lv: level || 'log', ty: type || 'log', x: cut(text == null ? '' : text, 20000),
          u: url || '', l: line || 0, c: column || 0, n: repeatCount || 1, ts: +timestamp || 0,
          p: (parameters || []).slice(0, 50).map(function (x) { return val(x, tg); }), s: frames(stackTrace), r: requestId || '' });
      } catch (e) {}
      return added.apply(this, arguments);
    };
    if (repeated) P.messageRepeatCountUpdated = function (target, count, timestamp) {
      try { W().post('console', { t: 'r', tg: targetId(target), n: count, ts: +timestamp || 0 }); } catch (e) {}
      return repeated.apply(this, arguments);
    };
    if (cleared) P.messagesCleared = function (reason) {
      var url = '';
      try { url = WI.networkManager.mainFrame ? WI.networkManager.mainFrame.url : ''; } catch (e) {}
      try { W().post('console', { t: 'clear', why: String(reason || ''), u: url }); } catch (e) {}
      return cleared.apply(this, arguments);
    };
    W().beats.push(beat);
    try { WI.runtimeManager.addEventListener(WI.RuntimeManager.Event.ActiveExecutionContextChanged, function () { W().post('console', { t: 'ctx' }); }); } catch (e) {}
    try { WI.Frame.addEventListener(WI.Frame.Event.ExecutionContextsCleared, function () { W().post('console', { t: 'ctx' }); }); } catch (e) {}
    try { WI.Frame.addEventListener(WI.Frame.Event.ExecutionContextAdded, function () { W().post('console', { t: 'ctx' }); }); } catch (e) {}
    try { WI.targetManager.addEventListener(WI.TargetManager.Event.TargetAdded, function () { W().post('console', { t: 'ctx' }); }); } catch (e) {}
    try { WI.targetManager.addEventListener(WI.TargetManager.Event.TargetRemoved, function () { W().post('console', { t: 'ctx' }); }); } catch (e) {}
    install();
  }
  // The execution contexts Console can run in: the top frame's page,
  // each frame's, each extension world's, each worker's.
  function contexts() {
    var out = [];
    function key(target, id) {
      var name = targetId(target) + ':' + id;
      if (!C.contextKeys.has(name)) C.contextKeys.set(name, C.nextContext++);
      return C.contextKeys.get(name);
    }
    try {
      WI.networkManager.frames.forEach(function (frame) {
        var list = frame.executionContextList ? frame.executionContextList.contexts : [];
        list.forEach(function (x) {
          out.push({ id: key(x.target, x.id), name: x.name || '', type: x.type || 'normal', frame: frame.isMainFrame() ? 'top' : (frame.name || frame.url || 'frame'), main: frame.isMainFrame(), url: frame.url || '', x: x });
        });
      });
      WI.targets.forEach(function (t) {
        if (t === WI.mainTarget || !t.executionContext || !t.RuntimeAgent || t.type !== WI.TargetType.Worker) return;
        out.push({ id: key(t, t.executionContext.id), name: t.displayName || t.name || 'worker', type: 'worker', frame: t.displayName || t.name || 'worker', main: false, url: t.name || '', tg: t.identifier, x: t.executionContext });
      });
    } catch (e) {}
    return out;
  }
  function context(id) {
    var list = contexts();
    return list.find(function (c) { return c.id === id; }) || list.find(function (c) { return c.main && c.type === 'normal'; }) || list[0] || null;
  }
  function targetOf(c) { return c && c.tg ? W().target(c.tg) : WI.mainTarget; }
  // An expression, in the context asked for, or on the paused frame.
  async function evaluate(p, silent) {
    var expression = String(p.expr || '');
    if (!expression) expression = 'undefined';
    if (/^\s*\{/.test(expression) && /\}\s*$/.test(expression)) expression = '(' + expression + ')';
    var awaiting = /^\s*await\s+/.test(expression);
    if (awaiting) expression = '(async function () { return (' + expression.trim().replace(/;\s*$/, '') + '); })()';
    try { if (window.appendWebInspectorSourceURL) expression = appendWebInspectorSourceURL(expression); } catch (e) {}
    var frame = WI.debuggerManager && WI.debuggerManager.activeCallFrame;
    var group = silent ? 'yab-silent' : 'console';
    var r;
    if (frame && !p.ctxForced) {
      r = await frame.target.DebuggerAgent.evaluateOnCallFrame.invoke({ callFrameId: frame.id, expression: expression, objectGroup: group,
        includeCommandLineAPI: true, doNotPauseOnExceptionsAndMuteConsole: !!silent, returnByValue: false, generatePreview: true, saveResult: !silent, emulateUserGesture: !!p.gesture });
      r.tg = targetId(frame.target);
    } else {
      var c = context(p.ctx || C.ctx);
      if (!c) throw new Error('no context');
      var t = targetOf(c);
      r = await t.RuntimeAgent.evaluate.invoke({ expression: expression, objectGroup: group, includeCommandLineAPI: true, doNotPauseOnExceptionsAndMuteConsole: !!silent,
        contextId: c.x.id, returnByValue: false, generatePreview: true, saveResult: !silent, emulateUserGesture: !!p.gesture });
      r.tg = c.tg || '';
    }
    if (awaiting && !r.wasThrown && r.result && r.result.objectId) {
      var tg = r.tg;
      r = await W().target(tg).RuntimeAgent.awaitPromise.invoke({ promiseObjectId: r.result.objectId, generatePreview: true, saveResult: !silent });
      r.tg = tg;
    }
    return r;
  }
  function install() {
    var F = W().fn;
    F['console.contexts'] = function () {
      var active = context(C.ctx);
      return contexts().map(function (c) { return { id: c.id, name: c.name, type: c.type, frame: c.frame, main: c.main, url: c.url, on: !!active && active.id === c.id }; });
    };
    F['console.setContext'] = function (p) {
      C.ctx = +p.id || 0;
      try { var c = context(C.ctx); if (c && c.x && !c.tg) WI.runtimeManager.activeExecutionContext = c.x; } catch (e) {}
      return true;
    };
    F['console.eval'] = async function (p) {
      var r = await evaluate(p, false);
      return { v: val(r.result, r.tg), thrown: !!r.wasThrown, saved: r.savedResultIndex == null ? -1 : r.savedResultIndex,
        paused: !!(WI.debuggerManager && WI.debuggerManager.activeCallFrame) };
    };
    F['console.eager'] = async function (p) {
      try {
        var r = await evaluate(p, true);
        if (r.wasThrown) return null;
        return val(r.result, r.tg);
      } catch (e) { return null; } finally { W().forget('yab-silent'); }
    };
    F['console.clear'] = function () { try { WI.consoleManager.requestClearMessages(); return true; } catch (e) { return false; } };
    // An object's own properties as WebKit's console lists them, getters
    // not run, [[Prototype]] and internal ones too.
    F['console.props'] = async function (p) {
      var t = W().target(p.tg), r;
      try { r = await t.RuntimeAgent.getDisplayableProperties.invoke({ objectId: p.id, generatePreview: true }); }
      catch (e) { r = await t.RuntimeAgent.getProperties.invoke({ objectId: p.id, ownProperties: true, generatePreview: true }); }
      var out = (r.properties || []).map(function (d) {
        var q = { n: String(d.name), own: !!d.isOwn, en: !!d.enumerable, w: !!d.writable };
        if ('value' in d) q.v = val(d.value, p.tg);
        if (d.get) q.g = true;
        if (d.symbol) q.sym = true;
        if (d.wasThrown) q.x = true;
        if (d.nativeGetter) q.ng = true;
        if (d.isPrivate) q.pr = true;
        return q;
      });
      (r.internalProperties || []).forEach(function (d) { out.push({ n: String(d.name), v: val(d.value, p.tg), i: true }); });
      return out;
    };
    F['console.entries'] = async function (p) {
      var t = W().target(p.tg);
      var r = await t.RuntimeAgent.getCollectionEntries.invoke({ objectId: p.id, objectGroup: 'console', fetchStart: 0, fetchCount: 200 });
      return (r.entries || []).map(function (e) { return { k: e.key ? val(e.key, p.tg) : null, v: val(e.value, p.tg) }; });
    };
    F['console.getter'] = async function (p) {
      var t = W().target(p.tg);
      var r = await t.RuntimeAgent.callFunctionOn.invoke({ objectId: p.id, functionDeclaration: 'function (n) { return this[n]; }', arguments: [{ value: p.name }], generatePreview: true });
      return { v: val(r.result, p.tg), thrown: !!r.wasThrown };
    };
    // Names for the prompt: of what `base` is, or of the global scope
    // with the command line's own.
    F['console.complete'] = async function (p) {
      var c = context(p.ctx || C.ctx), t = targetOf(c);
      var path = String(p.base || '');
      if (path && !/^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(path)) return [];
      try {
        var g = await t.RuntimeAgent.evaluate.invoke({ expression: 'this', objectGroup: 'yab-complete', contextId: c && c.x.id,
          doNotPauseOnExceptionsAndMuteConsole: true });
        var object = g.result;
        async function props(o) {
          if (!o || !o.objectId || o.subtype === 'proxy') return [];
          var r = await t.RuntimeAgent.getDisplayableProperties.invoke({ objectId: o.objectId, generatePreview: false });
          return (r.properties || []).concat(r.internalProperties || []);
        }
        var pieces = path ? path.split('.') : [];
        if (pieces[0] === 'this') pieces.shift();
        for (var piece of pieces) {
          var list = await props(object);
          var d = list.find(function (x) { return x.name === piece; });
          // Protocol property descriptors don't execute JavaScript getters.
          if (!d || !d.value || (d.get && !d.nativeGetter)) return [];
          object = d.value;
        }
        var names = new Set();
        for (var i = 0; object && object.objectId && i < 40; i++) {
          var list = await props(object);
          list.forEach(function (x) { if (x.name && !/^\[\[/.test(x.name)) names.add(x.name); });
          var prototype = list.find(function (x) { return x.name === '__proto__' || x.name === '[[Prototype]]'; });
          object = prototype && prototype.value;
        }
        return Array.from(names);
      } catch (e) { return []; }
      finally { try { t.RuntimeAgent.releaseObjectGroup('yab-complete'); } catch (e) {} }
    };
    // Live expressions, run on the beat at most four times a second.
    F['console.live'] = function (p) { C.live = (p.list || []).map(String); C.liveSaid = []; return true; };
    F['console.node'] = async function (p) {
      var t = W().target(p.tg);
      var r = await t.DOMAgent.requestNode.invoke({ objectId: p.id });
      if (p.show) { try { WI.domManager.inspectElement(r.nodeId); } catch (e) {} }
      return r.nodeId || 0;
    };
    F['console.highlight'] = async function (p) {
      var t = W().target(p.tg);
      try {
        // Drawn as Elements draws it, Chrome's way (DevHighlight.swift).
        var own = W().fn['elements.highlight'];
        if (own) {
          if (!p.id) return await own({ id: 0 });
          var n = await t.DOMAgent.requestNode.invoke({ objectId: p.id });
          return await own({ id: n.nodeId || 0 });
        }
        if (!p.id) { await t.DOMAgent.hideHighlight.invoke({}); return true; }
        await t.DOMAgent.highlightNode.invoke({ objectId: p.id, highlightConfig: { showInfo: true, contentColor: { r: 111, g: 168, b: 220, a: 0.66 }, paddingColor: { r: 147, g: 196, b: 125, a: 0.55 }, borderColor: { r: 255, g: 229, b: 153, a: 0.66 }, marginColor: { r: 246, g: 178, b: 107, a: 0.66 } } });
        return true;
      } catch (e) { return false; }
    };
    // Where a function was written: its script's address and line.
    F['console.where'] = async function (p) {
      var t = W().target(p.tg);
      var r = await t.DebuggerAgent.getFunctionDetails.invoke({ functionId: p.id });
      var d = r.details || r, loc = d.location || {};
      var script = WI.debuggerManager.scriptForIdentifier(loc.scriptId, t);
      return { u: script ? (script.url || script.sourceURL || '') : '', l: (loc.lineNumber || 0) + 1, c: (loc.columnNumber || 0) + 1, name: d.name || d.displayName || '' };
    };
    F['console.store'] = async function (p) {
      var t = W().target(p.tg);
      await t.RuntimeAgent.callFunctionOn.invoke({ objectId: p.id, functionDeclaration: 'function (n) { globalThis[n] = this; }', arguments: [{ value: p.name }] });
      return p.name;
    };
    F['console.json'] = async function (p) {
      var t = W().target(p.tg);
      var r = await t.RuntimeAgent.callFunctionOn.invoke({ objectId: p.id, functionDeclaration: 'function () { try { var seen = new WeakSet(); return JSON.stringify(this, function (k, v) { if (v && typeof v === "object") { if (seen.has(v)) return "[Circular]"; seen.add(v); } return v; }, 2); } catch (e) { return String(this); } }', returnByValue: true });
      return r.result ? r.result.value : '';
    };
    F['console.release'] = function () { W().forget('console'); return true; };
    // Log XMLHttpRequests: a line for each fetch and XHR that finishes.
    F['console.prefs'] = function (p) { C.xhr = !!p.xhr; return true; };
    try {
      WI.Resource.addEventListener(WI.Resource.Event.LoadingDidFinish, function (e) {
        var r = e.target;
        if (!C.xhr || !r) return;
        if (r.type !== WI.Resource.Type.XHR && r.type !== WI.Resource.Type.Fetch) return;
        W().post('console', { t: 'xhr', k: r.type === WI.Resource.Type.Fetch ? 'Fetch' : 'XHR', m: r.requestMethod || 'GET', u: r.url, st: r.statusCode || 0 });
      });
    } catch (e) {}
  }
  function beat() {
    while (C.previews.length && C.previewing < 4) {
      var entry = C.previews.shift();
      C.previewing++;
      (function (entry) {
        W().target(entry.tg).RuntimeAgent.getPreview.invoke({ objectId: entry.id }).then(function (r) {
          var value = Object.assign({}, entry.v, { pv: prev(r.preview) });
          W().post('console', { t: 'preview', v: value });
        }, function () {}).finally(function () { C.previewing--; });
      })(entry);
    }
    if (!C.live.length) return;
    var now = Date.now();
    if (now - C.last < 250) return;
    C.last = now;
    C.live.forEach(function (expr, i) {
      if (!expr.trim()) return;
      evaluate({ expr: expr }, true).then(function (r) {
        var v = r.wasThrown ? { ty: 'error', d: (r.result && r.result.description) || 'error' } : val(r.result, r.tg);
        var said = JSON.stringify(v);
        if (C.liveSaid[i] !== said) { C.liveSaid[i] = said; W().post('console', { t: 'live', i: i, x: expr, v: v }); }
      }, function () {}).finally(function () { W().forget('yab-silent'); });
    });
  }
  hook();
})();
