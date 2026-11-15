(function () {
  if (window.__yabWire) return;
  var W = window.__yabWire = { fn: {}, ready: false, q: {}, refs: new Map(), next: 1, monitorOn: false };
  var resolveReady;
  W.whenReady = new Promise(function (resolve) { resolveReady = resolve; });
  function post(m) { try { webkit.messageHandlers.yabInspector.postMessage(m); } catch (e) {} }
  W.post = function (channel, item) {
    var q = W.q[channel] || (W.q[channel] = []);
    q.push(item);
    if (q.length > 20000) q.splice(0, q.length - 20000);
  };
  // Sent at once, not on the beat: the node pointed at, drawn on the page.
  W.highlight = function (data) { post({ k: 'highlight', j: JSON.stringify(data || null) }); };
  W.flush = function () {
    for (var c in W.q) {
      var q = W.q[c];
      if (!q.length) continue;
      W.q[c] = [];
      post({ k: 'wire', c: c, j: JSON.stringify(q) });
    }
  };
  // Yab's beat (netTick): what is queued goes out, and each module's
  // own beat runs (live expressions, polls).
  W.beats = [];
  W.tick = function () {
    for (var i = 0; i < W.beats.length; i++) { try { W.beats[i](); } catch (e) {} }
    W.flush();
    return 0;
  };
  // A remote object kept for Yab by a number, so it can ask for more
  // of it later (properties, a node, a function's place).
  W.keep = function (object) {
    if (!object) return 0;
    var id = W.next++;
    W.refs.set(id, object);
    return id;
  };
  W.ref = function (id) { return W.refs.get(+id) || null; };
  W.forget = function (group) {
    try { WI.mainTarget.RuntimeAgent.releaseObjectGroup(group); } catch (e) {}
  };
  W.target = function (id) {
    if (!id) return WI.mainTarget;
    try { return WI.targets.find(function (t) { return t.identifier === id; }) || WI.mainTarget; } catch (e) { return WI.mainTarget; }
  };
  // A protocol command by its name, or a module's function.
  W.call = async function (method, params) {
    // Network can connect while mainTarget is still WebKit's placeholder.
    // Panel commands need the inspected page's protocol agents.
    await W.whenReady;
    params = params || {};
    var own = W.fn[method];
    if (own) return await own(params);
    var dot = method.indexOf('.');
    if (dot < 0) throw new Error('no such call: ' + method);
    var target = W.target(params.__target);
    delete params.__target;
    var agent = target[method.slice(0, dot) + 'Agent'];
    var command = agent && agent[method.slice(dot + 1)];
    if (!command || !command.invoke) throw new Error('no such command: ' + method);
    return await command.invoke(params);
  };
  // The protocol monitor: every message both ways, while it is open.
  W.events = [];
  W.monitor = function (on) {
    W.monitorOn = !!on;
    try {
      if (!W.tracer && WI.ProtocolTracer) {
        var T = class extends WI.ProtocolTracer {
          logFrontendRequest(connection, message) { W.trace('send', connection, message); }
          logWillHandleResponse(connection, message) { W.trace('response', connection, message); }
          logWillHandleEvent(connection, message) { W.trace('event', connection, message); }
        };
        W.tracer = new T();
      }
      InspectorBackend.customTracer = W.tracer;
      return true;
    } catch (e) { return false; }
  };
  W.trace = function (kind, connection, message) {
    if (kind === 'event') {
      for (var listener of W.events) { try { listener(message, connection && connection.target); } catch (e) {} }
    }
    if (!W.monitorOn) return;
    try {
      var target = connection && connection.target ? connection.target.identifier || connection.target.type || '' : '';
      var text = JSON.stringify(message.params || message.result || message.error || {});
      W.post('protocol', { k: kind, id: message.id || 0, m: message.method || '', t: Date.now(), p: text.length > 4000 ? text.slice(0, 4000) + '…' : text, e: message.error ? message.error.message || 'error' : '', g: target });
    } catch (e) {}
  };
  W.fn['wire.monitorSet'] = function (p) { return W.monitor(p.on); };
  // Raw, as the monitor's command field sends it: {"method", "params"}.
  W.fn['wire.raw'] = async function (p) {
    var r = await W.call(p.method, p.params || {});
    return JSON.stringify(r === undefined ? null : r);
  };
  function start() {
    if (!window.WI || !WI.mainTarget?.PageAgent?.getResourceTree?.invoke || !WI.mainTarget?.RuntimeAgent?.evaluate?.invoke) { setTimeout(start, 50); return; }
    W.ready = true;
    resolveReady();
    W.monitor(false);
    post({ k: 'wire', c: 'wire', j: JSON.stringify([{ ready: true }]) });
  }
  start();
})();
