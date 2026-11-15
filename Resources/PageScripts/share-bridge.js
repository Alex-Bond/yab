(function () {
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.__YAB_NAME__;
  if (!handler || window.__yabShareBridged) return;
  window.__yabShareBridged = true;
  window.addEventListener('__YAB_ASKED__', function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message !== 'object' || typeof message.kind !== 'string') return;
    handler.postMessage(message);
  });
  var shares = new Map();
  function bytes(b64) {
    if (Uint8Array.fromBase64) return Uint8Array.fromBase64(b64);
    var s = atob(b64), out = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  }
  function whole(share) {
    var now = Date.now();
    if (now - (share.askedKey || 0) < 300) return;
    share.askedKey = now;
    handler.postMessage({ kind: 'key', id: share.id });
  }
  function reply(id, error) {
    window.dispatchEvent(new CustomEvent('yab-share-track', { detail: JSON.stringify({ id: id, error: error }) }));
  }
  function failed(share, error) {
    if (shares.get(share.id) !== share || share.failed) return;
    share.failed = true;
    share.error = error && (error.message || String(error)) || 'Capture decoder failed';
    reply(share.id, share.error);
  }
  function end(id) {
    var share = shares.get(id);
    if (!share) return false;
    shares.delete(id);
    clearTimeout(share.redraw);
    share.redraw = null;
    try { if (share.decoder && share.decoder.state !== 'closed') share.decoder.close(); } catch (e) {}
    if (share.track) MediaStreamTrack.prototype.stop.call(share.track);
    return true;
  }
  function handoff(share) {
    if (share.delivered) return;
    var carrier;
    try {
      carrier = document.createElement('video');
      carrier.hidden = true;
      carrier.srcObject = share.stream;
      document.documentElement.appendChild(carrier);
      share.delivered = true;
      carrier.dispatchEvent(new CustomEvent('yab-share-track', {
        bubbles: true, detail: JSON.stringify({ id: share.id, track: true })
      }));
    } finally { if (carrier) { carrier.srcObject = null; carrier.remove(); } }
    if (shares.get(share.id) !== share || share.failed) return;
    // Let the page attach the track before WebKit captures the retained
    // first picture. requestFrame alone does not emit an unchanged canvas.
    share.redraw = setTimeout(function () {
      share.redraw = null;
      if (shares.get(share.id) !== share || share.failed || !share.delivered) return;
      try {
        if (typeof share.track.requestFrame === 'function') share.track.requestFrame();
        share.context.drawImage(share.canvas, 0, 0);
      } catch (e) { failed(share, e); }
    }, 0);
  }
  function prepare(id, images) {
    if (typeof id !== 'string' || shares.has(id)) return false;
    var share = { id: id, canvas: null, context: null, stream: null, track: null, decoder: null,
                  format: null, images: images === true, imagePending: false, imageTime: -1,
                  waitKey: true, failed: false, started: false, delivered: false, error: null, redraw: null };
    shares.set(id, share);
    try {
      if (share.images ? typeof createImageBitmap !== 'function' :
          typeof VideoDecoder !== 'function' || typeof EncodedVideoChunk !== 'function')
        throw new Error('Video decoding unavailable');
      share.canvas = document.createElement('canvas');
      share.canvas.width = share.canvas.height = 2;
      share.context = share.canvas.getContext('2d', { alpha: false });
      if (!share.context || typeof share.canvas.captureStream !== 'function')
        throw new Error('Canvas capture unavailable');
      share.stream = share.canvas.captureStream(30);
      share.track = share.stream.getVideoTracks()[0];
      if (!share.track) throw new Error('Canvas capture track unavailable');
      return true;
    } catch (e) {
      // Keep the original reason until the page proxy starts.
      share.failed = true;
      share.error = String(e);
      return false;
    }
  }
  function image(share, message) {
    // Keep at most one image decode in flight. An ended/replaced source
    // must never deliver a late bitmap or resolve its old request.
    if (share.imagePending || message.time <= share.imageTime) return;
    share.imagePending = true;
    createImageBitmap(new Blob([bytes(message.data)], { type: 'image/jpeg' })).then(function (bitmap) {
      try {
        if (shares.get(share.id) !== share || share.failed || !share.started) return;
        if (share.canvas.width !== bitmap.width) share.canvas.width = bitmap.width;
        if (share.canvas.height !== bitmap.height) share.canvas.height = bitmap.height;
        share.context.drawImage(bitmap, 0, 0);
        share.imageTime = message.time;
        if (typeof share.track.requestFrame === 'function') share.track.requestFrame();
        handoff(share);
      } catch (e) { failed(share, e); }
      finally { bitmap.close(); share.imagePending = false; }
    }, function (error) { share.imagePending = false; failed(share, error); });
  }
  function open(share) {
    if (share.decoder && share.decoder.state !== 'closed') share.decoder.close();
    var decoder = new VideoDecoder({
      output: function (frame) {
        try {
          if (shares.get(share.id) !== share || share.failed || share.decoder !== decoder || !share.started) return;
          var width = frame.displayWidth || share.format.width, height = frame.displayHeight || share.format.height;
          if (share.canvas.width !== width) share.canvas.width = width;
          if (share.canvas.height !== height) share.canvas.height = height;
          share.context.drawImage(frame, 0, 0, width, height);
          if (typeof share.track.requestFrame === 'function') share.track.requestFrame();
          // Resolve the request only when real pixels were decoded.
          handoff(share);
        } catch (e) { failed(share, e); }
        finally { frame.close(); }
      },
      error: function (error) { if (share.decoder === decoder) failed(share, error); }
    });
    share.decoder = decoder;
    decoder.configure({ codec: share.format.codec, description: share.format.description,
                        codedWidth: share.format.width, codedHeight: share.format.height,
                        optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
    share.waitKey = true;
  }
  // A tab's sound for an extension (tab-audio.js, ExtensionTabAudio.swift):
  // what the tab's frames hear comes in as 16-bit stereo at their rate, is
  // kept a little ahead (a tenth of a second, at most half a second) per
  // source, resampled and mixed into one track of this page's own, handed
  // over as the picture is, through an element's srcObject.
  var sounds = new Map(), allowed = new Set();
  function prepareSound(id) {
    if (typeof id !== 'string' || sounds.has(id)) return false;
    allowed.add(id);
    return true;
  }
  function soundStart(id) {
    if (sounds.has(id) || !allowed.delete(id)) return;
    var Context = window.AudioContext || window.webkitAudioContext;
    var sound = { context: null, out: null, node: null, sources: new Map() };
    try {
      sound.context = new Context();
      sound.out = sound.context.createMediaStreamDestination();
      sound.node = sound.context.createScriptProcessor(2048, 0, 2);
      var hush = sound.context.createGain();
      hush.gain.value = 0;
      sound.node.onaudioprocess = function (event) { mix(sound, event.outputBuffer); };
      sound.node.connect(sound.out);
      sound.node.connect(hush);
      hush.connect(sound.context.destination);
      sound.context.resume().catch(function () {});
    } catch (e) { reply(id, String(e)); return; }
    sounds.set(id, sound);
    var carrier;
    try {
      carrier = document.createElement('audio');
      carrier.hidden = true;
      carrier.srcObject = sound.out.stream;
      document.documentElement.appendChild(carrier);
      carrier.dispatchEvent(new CustomEvent('yab-share-track', { bubbles: true, detail: JSON.stringify({ id: id, audio: true }) }));
    } finally { if (carrier) { carrier.srcObject = null; carrier.remove(); } }
  }
  function soundFeed(id, from, rate, b64) {
    var sound = sounds.get(id);
    if (!sound) return false;
    var source = sound.sources.get(from);
    if (!source) sound.sources.set(from, source = { rate: rate, queue: [], at: 0, frames: 0, playing: false });
    var raw = bytes(b64), pcm = new Int16Array(raw.buffer, raw.byteOffset, raw.byteLength >> 1);
    source.rate = rate;
    source.queue.push(pcm);
    source.frames += pcm.length / 2;
    while (source.frames > rate / 2 && source.queue.length > 1) {
      source.frames -= source.queue.shift().length / 2 - source.at;
      source.at = 0;
    }
    return true;
  }
  function mix(sound, out) {
    var left = out.getChannelData(0), right = out.getChannelData(1), n = left.length, rate = sound.context.sampleRate;
    left.fill(0);
    right.fill(0);
    sound.sources.forEach(function (source) {
      if (!source.playing) {
        if (source.frames < source.rate / 10) return;
        source.playing = true;
      }
      var step = source.rate / rate;
      for (var i = 0; i < n; i++) {
        var head = source.queue[0];
        if (!head) { source.playing = false; break; }
        var at = Math.floor(source.at), part = source.at - at, length = head.length / 2;
        var l0 = head[2 * at], r0 = head[2 * at + 1], l1 = l0, r1 = r0;
        if (at + 1 < length) { l1 = head[2 * at + 2]; r1 = head[2 * at + 3]; }
        else if (source.queue[1]) { l1 = source.queue[1][0]; r1 = source.queue[1][1]; }
        left[i] += (l0 + (l1 - l0) * part) / 32768;
        right[i] += (r0 + (r1 - r0) * part) / 32768;
        source.at += step;
        source.frames -= step;
        while (source.queue[0] && source.at >= source.queue[0].length / 2) {
          source.at -= source.queue[0].length / 2;
          source.queue.shift();
        }
      }
      if (source.frames < 0) source.frames = 0;
    });
  }
  function soundEnd(id) {
    allowed.delete(id);
    var sound = sounds.get(id);
    if (!sound) return false;
    sounds.delete(id);
    try { sound.out.stream.getTracks().forEach(function (track) { MediaStreamTrack.prototype.stop.call(track); }); } catch (e) {}
    try { sound.node.disconnect(); } catch (e) {}
    try { sound.context.close(); } catch (e) {}
    return true;
  }
  // Kept stable for native handoff and cleanup calls.
  Object.defineProperty(window, Symbol.for('yab.share.worker'), { value: { prepare: prepare, end: end, prepareSound: prepareSound, sound: soundFeed, soundEnd: soundEnd } });
  window.addEventListener('yab-share-worker', function (event) {
    var envelope;
    try { envelope = JSON.parse(event.detail); } catch (e) { return; }
    if (!envelope || typeof envelope.id !== 'string' || !envelope.message) return;
    var id = envelope.id, m = envelope.message, share = shares.get(id);
    if (m.type === 'end') { end(id); soundEnd(id); return; }
    if (m.type === 'sound') { soundStart(id); return; }
    if (!share) { reply(id, 'Capture source unavailable'); return; }
    if (share.failed) { reply(id, share.error || 'Capture decoder failed'); return; }
    try {
      if (m.type === 'start') {
        if (share.started) return;
        share.started = true;
        if (m.width) share.canvas.width = m.width;
        if (m.height) share.canvas.height = m.height;
      } else if (m.type === 'format') {
        share.format = { codec: m.codec, description: bytes(m.description), width: m.width, height: m.height };
        if (share.images) {
          if (m.codec !== 'image/jpeg') throw new Error('Unexpected capture image format');
        } else open(share);
      } else if (m.type === 'chunk') {
        if (!share.started || !share.format) return;
        if (share.images) { image(share, m); return; }
        if (!share.decoder || share.decoder.state === 'closed') open(share);
        // Behind, or lost: the next whole frame now, not at the next
        // key frame ten seconds on, a still picture until then.
        if (share.waitKey && !m.key) { whole(share); return; }
        if (share.decoder.decodeQueueSize > 6 && !m.key) { share.waitKey = true; whole(share); return; }
        share.decoder.decode(new EncodedVideoChunk({ type: m.key ? 'key' : 'delta', timestamp: m.time, data: bytes(m.data) }));
        share.waitKey = false;
      }
    } catch (e) { failed(share, e); }
  });
})();
