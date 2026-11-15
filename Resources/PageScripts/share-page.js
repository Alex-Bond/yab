(function () {
  var M = window.MediaDevices, proto = M && M.prototype;
  if (!proto || !proto.getDisplayMedia) return;
  var mark = Symbol.for('__YAB_MARK__');
  if (proto[mark]) return;
  var own = proto.getDisplayMedia;
  var waiting = new Map(), live = new Map(), system = new Map(), quiet = new WeakSet();
  // A page that asks for the shown tab not to come forward: the box's
  // answer reads this, the engine's own method still runs.
  var Controller = window.CaptureController, focus = Controller && Controller.prototype.setFocusBehavior;
  if (focus) Controller.prototype.setFocusBehavior = function (behavior) {
    if (behavior === 'no-focus-change' || behavior === 'focus-capturing-application') quiet.add(this);
    else quiet.delete(this);
    return focus.apply(this, arguments);
  };
  function token() { return Math.random().toString(36).slice(2) + Date.now().toString(36); }
  function ask(message) { window.dispatchEvent(new CustomEvent('__YAB_ASKED__', { detail: JSON.stringify(message) })); }
  // Only JSON crosses script worlds. The native MediaStream crosses
  // through a media element's srcObject, which WebKit wraps in this world.
  // The decoder and canvas belong to Yab's isolated world.
  function CaptureSource(id) {
    var self = this;
    function receive(event) {
      var m;
      try { m = JSON.parse(event.detail); } catch (e) { return; }
      if (!m || m.id !== id) return;
      if (m.error) { if (self.onerror) self.onerror({ message: m.error }); return; }
      if (m.track) {
        try {
          var stream = event.target.srcObject, track = stream && stream.getVideoTracks()[0];
          if (!track) throw new Error('Capture track unavailable');
          if (self.onmessage) self.onmessage({ data: { track: track } });
        } catch (e) { if (self.onerror) self.onerror(e); }
      }
    }
    window.addEventListener('yab-share-track', receive);
    this.postMessage = function (message) {
      window.dispatchEvent(new CustomEvent('yab-share-worker', { detail: JSON.stringify({ id: id, message: message }) }));
    };
    this.terminate = function () {
      window.removeEventListener('yab-share-track', receive);
      self.postMessage({ type: 'end' });
    };
  }
  function ended(track) {
    MediaStreamTrack.prototype.stop.call(track);
    track.dispatchEvent(new Event('ended'));
  }
  function dispose(share) {
    clearTimeout(share.timer);
    if (share.worker) { try { share.worker.terminate(); } catch (e) {} share.worker = null; }
  }
  function stream(id, said, t, w) {
    var share = { worker: null, track: null, ended: false, timer: null, token: t };
    w.id = id;
    live.set(id, share);
    // A selected browser tab must stay a tab. Only window and screen
    // requests may continue through WebKit's own picker on failure.
    function failed(error) {
      if (share.ended) return;
      share.ended = true;
      dispose(share);
      if (share.track) ended(share.track);
      // An extension's stream has nowhere else to go: it ends.
      if (waiting.has(t) && said.surface !== 'browser' && !w.stream) ask({ kind: 'fallback', token: t, id: id });
      else {
        live.delete(id);
        if (waiting.delete(t)) {
          var reason = error && (error.message || String(error)) || 'Capture source unavailable';
          w.reject(new DOMException('Could not capture the selected browser tab: ' + reason + '. Try sharing the tab again.', 'AbortError'));
        }
        ask({ kind: 'stop', id: id });
      }
    }
    share.fail = failed;
    try {
      var worker = share.worker = new CaptureSource(id);
      worker.onerror = worker.onmessageerror = failed;
      share.timer = setTimeout(function () { failed(new Error('Capture source timed out')); }, 5000);
      worker.onmessage = function (event) {
        if (share.ended) return;
        try {
          var m = event.data;
          if (m.track && !share.track) {
            var track = m.track, settings = track.getSettings.bind(track), stop = MediaStreamTrack.prototype.stop;
            share.track = track;
            // A screen, a window or a still tab is words and edges: a call
            // keeps its size and lets its frames go first, as it does for
            // Safari's and Chrome's own (without the hint a canvas track
            // is a camera's to WebRTC, and a text tab reached the far end
            // at a third of its size). A tab playing a video goes without
            // it, and the call keeps its frames coming (with 'detail', a
            // YouTube tab reached Meet at 5 frames a second).
            if (said.surface !== 'browser' || !said.motion) try { track.contentHint = 'detail'; } catch (e) {}
            Object.defineProperty(track, 'label', { configurable: true, value: said.label || '' });
            track.getSettings = function () {
              var s = settings();
              s.displaySurface = said.surface;
              s.logicalSurface = true;
              s.cursor = 'always';
              s.frameRate = 30;
              if (said.width && !s.width) { s.width = said.width; s.height = said.height; }
              return s;
            };
            track.stop = function () {
              if (!share.ended) { share.ended = true; live.delete(id); dispose(share); ask({ kind: 'stop', id: id }); }
              return stop.call(this);
            };
            var made = new MediaStream([track]);
            clearTimeout(share.timer);
            waiting.delete(t);
            w.resolve(made);
          } else if (m.error) {
            failed(new Error(m.error));
          }
        } catch (e) { failed(e); }
      };
      worker.postMessage({ type: 'start', width: said.width, height: said.height });
    } catch (e) { failed(e); }
  }
  // A tab's sound for an extension (ExtensionTabAudio.swift): Yab's side
  // makes the track (share-bridge.js `soundStart`) and hands it over
  // through an element's srcObject, as the picture's.
  function sound(id, said, t, w) {
    var share = { worker: null, track: null, ended: false, timer: null, token: t };
    w.id = id;
    live.set(id, share);
    function tell(type) {
      window.dispatchEvent(new CustomEvent('yab-share-worker', { detail: JSON.stringify({ id: id, message: { type: type } }) }));
    }
    function failed(error) {
      if (share.ended) return;
      share.ended = true;
      dispose(share);
      live.delete(id);
      if (waiting.delete(t)) {
        w.reject(new DOMException("Could not capture the tab's sound: " + (error || 'unavailable'), 'AbortError'));
      }
      ask({ kind: 'stop', id: id });
    }
    function receive(event) {
      var m;
      try { m = JSON.parse(event.detail); } catch (e) { return; }
      if (!m || m.id !== id) return;
      window.removeEventListener('yab-share-track', receive);
      clearTimeout(share.timer);
      if (m.error || !m.audio) return failed(m.error);
      var stream = event.target.srcObject, track = stream && stream.getAudioTracks()[0];
      if (!track) return failed('no track');
      var stop = MediaStreamTrack.prototype.stop;
      share.track = track;
      Object.defineProperty(track, 'label', { configurable: true, value: said.label || '' });
      track.stop = function () {
        if (!share.ended) { share.ended = true; live.delete(id); dispose(share); ask({ kind: 'stop', id: id }); }
        return stop.call(this);
      };
      waiting.delete(t);
      w.resolve(new MediaStream([track]));
    }
    share.worker = { terminate: function () { window.removeEventListener('yab-share-track', receive); tell('end'); } };
    window.addEventListener('yab-share-track', receive);
    share.timer = setTimeout(function () { failed('timed out'); }, 5000);
    tell('sound');
  }
  var api = {
    // A frame or a format from yab: strings, so they cross cheaply.
    feed: function (id, type, b64, a, b, c) {
      var share = live.get(id);
      if (!share) {
        var held = system.get(id);
        if (held && type === 'end') { system.delete(id); held.getTracks().forEach(ended); return true; }
        return false;
      }
      // Startup failed; let native code consume the fallback before
      // late frames can make it discard the session that owns it.
      if (share.ended && type !== 'end') return true;
      if (type === 'chunk') {
        share.worker.postMessage({ type: 'chunk', data: b64, key: a, time: b });
      } else if (type === 'format') {
        share.worker.postMessage({ type: 'format', codec: a, description: b64, width: b, height: c });
      } else if (type === 'end') {
        var wasEnded = share.ended;
        share.ended = true;
        live.delete(id);
        dispose(share);
        if (share.track && !wasEnded) ended(share.track);
        var w = waiting.get(share.token);
        waiting.delete(share.token);
        if (w) w.reject(new DOMException('Screen capture ended', 'AbortError'));
      }
      return true;
    },
    // Yab could not start taking the picture (ScreenCaptureKit refused):
    // the same way on as frames that never came, a window or a screen
    // still waiting to macOS's picker, anything else ended.
    fail: function (id, why) {
      var share = live.get(id);
      if (!share || !share.fail) return false;
      share.fail(new Error(why || 'Capture source unavailable'));
      return true;
    },
    // Native can end a share while its worker is still being prepared,
    // before answer has associated the waiting request with this id.
    end: function (id, t) {
      var found = api.feed(id, 'end'), w = waiting.get(t);
      if (w && (!w.id || w.id === id)) {
        waiting.delete(t);
        w.reject(new DOMException('Screen capture ended', 'AbortError'));
        return true;
      }
      return found;
    },
    // The system's picker: WebKit's own getDisplayMedia, called while
    // yab's call into the page counts as the click the page's came from.
    system: function (t) {
      var w = waiting.get(t);
      if (!w) return false;
      waiting.delete(t);
      if (w.id) live.delete(w.id);
      try { own.apply(w.self, [w.constraints]).then(function (s) {
        var id = 'system-' + t, track = s.getVideoTracks()[0];
        system.set(id, s);
        ask({ kind: 'started', id: id });
        function over() { if (system.delete(id)) ask({ kind: 'stop', id: id }); }
        if (track) {
          track.addEventListener('ended', over);
          var stop = track.stop;
          track.stop = function () { over(); return stop.call(this); };
        }
        w.resolve(s);
      }, w.reject); } catch (e) { w.reject(e); }
      return true;
    },
    // Chromium's own capture of what Yab's box chose (Share.swift): the
    // browser already holds the source, so this asks nobody. The track, its
    // sound and its stop are the engine's own. The page's constraints go
    // as they came; Yab's call into the page counts as the click.
    native: function (t, id) {
      var w = waiting.get(t);
      if (!w) return false;
      waiting.delete(t);
      try { own.apply(w.self, [w.constraints]).then(function (s) {
        var track = s.getVideoTracks()[0];
        system.set(id, s);
        function over() { if (system.delete(id)) ask({ kind: 'stop', id: id }); }
        if (track) {
          track.addEventListener('ended', over);
          var stop = track.stop;
          track.stop = function () { over(); return stop.call(this); };
        }
        var controller = w.constraints && w.constraints.controller;
        ask({ kind: 'native', id: id, stay: !!controller && quiet.has(controller) });
        w.resolve(s);
      }, function (e) { ask({ kind: 'stop', id: id }); w.reject(e); }); } catch (e) { ask({ kind: 'stop', id: id }); w.reject(e); }
      return true;
    },
    // An extension's page with a stream id it was given
    // (chromeMediaSourceId, ExtensionCapture.swift): no picker and no
    // click; Yab checks the id belongs to this page's extension.
    stream: function (streamId, width, height) {
      var t = token();
      return new Promise(function (resolve, reject) {
        waiting.set(t, { resolve: resolve, reject: reject, constraints: null, self: navigator.mediaDevices, stream: true });
        ask({ kind: 'ask', token: t, stream: String(streamId), width: width || 0, height: height || 0 });
      });
    },
    // The sound of the tab a stream id names (tabCapture with audio):
    // its own question, the picture's goes on as before.
    sound: function (streamId) {
      var t = token();
      return new Promise(function (resolve, reject) {
        waiting.set(t, { resolve: resolve, reject: reject, constraints: null, self: navigator.mediaDevices, stream: true });
        ask({ kind: 'sound', token: t, stream: String(streamId) });
      });
    },
    answer: function (t, reply) {
      var w = waiting.get(t);
      if (!w) return false;
      if (reply.choice === 'own') stream(reply.id, reply, t, w);
      else if (reply.choice === 'sound') sound(reply.id, reply, t, w);
      else {
        waiting.delete(t);
        if (w.id) live.delete(w.id);
        w.reject(new DOMException('Permission denied', 'NotAllowedError'));
      }
      return true;
    }
  };
  Object.defineProperty(proto, mark, { value: api });
  Object.defineProperty(proto, 'getDisplayMedia', { configurable: true, writable: true, value: function getDisplayMedia(constraints) {
    if (!(this instanceof M)) return own.apply(this, arguments);
    if (navigator.userActivation && !navigator.userActivation.isActive)
      return Promise.reject(new DOMException('getDisplayMedia must be called from a user gesture handler.', 'InvalidStateError'));
    var self = this, t = token(), c = constraints || {};
    if (c.video === false) return Promise.reject(new TypeError('getDisplayMedia needs video.'));
    return new Promise(function (resolve, reject) {
      waiting.set(t, { resolve: resolve, reject: reject, constraints: constraints, self: self });
      // The largest picture the page takes: a call names it, and gets
      // more frames a second for a smaller one.
      var v = c.video && typeof c.video === 'object' ? c.video : {};
      function most(x) { return typeof x === 'number' ? x : x && (x.max || x.exact || x.ideal) || 0; }
      function word(x) { return typeof x === 'string' ? x : x && (x.exact || x.ideal) || ''; }
      ask({ kind: 'ask', token: t, audio: !!c.audio, width: most(v.width), height: most(v.height),
            surface: word(v.displaySurface), own: c.selfBrowserSurface || '', screens: c.monitorTypeSurfaces || '',
            current: !!c.preferCurrentTab });
    });
  } });
})();
