// The sound of a tab an extension captures (tabCapture with audio,
// ExtensionTabAudio.swift), taken in the page's own world, in each of its
// frames, only once it is captured: Yab calls this body with `id` (the
// capture) and `on`. Chrome takes a tab's sound from its output; WebKit
// gives no app one tab's output, so it is taken where the page makes it:
//
// - what the page's own AudioContexts send to their destination goes
//   through a tap of Yab's in that context instead (AudioNode.connect and
//   disconnect, from now on);
// - its audio and video elements playing a plain file play through an
//   AudioContext of Yab's, made inside this call (Yab's call counts as a
//   click, so it runs), the element routed into it and so through the
//   same tap. A call's voices (an element playing a MediaStream) are
//   listened to from the stream. Elements whose sound WebKit would hand
//   Web Audio as silence, and quiet the tab with it, are left alone, heard
//   and not captured: another site's file without CORS, and any blob:
//   address, as a MediaSource's (YouTube's) can't be told from a file's.
//
// While captured, the taps send what they hear to Yab and let nothing
// through, as Chromium mutes a captured tab (the extension plays it back if
// it wants it heard). When the capture ends, everything they took goes
// straight to the speakers again and the taps stop: nothing of this runs
// in a tab that isn't captured. A call's voices aren't muted: their
// element plays them itself. What is heard goes as 16-bit stereo, base64,
// to Yab's side by the share's event (share-bridge.js), and only when it
// isn't silence.
const K = Symbol.for('yab.tabAudio');
let tap = window[K];
if (!tap) {
  const asked = '__YAB_ASKED__';
  const proto = window.AudioNode && AudioNode.prototype;
  if (!proto || !window.AudioContext) return false;
  const connect = proto.connect, disconnect = proto.disconnect;
  const Destination = window.AudioDestinationNode;
  const Offline = window.OfflineAudioContext;
  const frame = Math.random().toString(36).slice(2);
  // Per context, its tap: `through` (the page's graph and the elements,
  // kept from the speakers while captured) and `listen` (calls' streams).
  const taps = new WeakMap(), ours = new WeakSet(), routed = new WeakSet();
  const made = new Set();
  // What the page sent to a destination: [node, output, input], connected
  // to the destination or, while captured, to its context's tap.
  const sent = [];
  // Calls' streams listened to: [source node].
  const streams = [];
  let own = null, next = 1;
  tap = { id: null, on: false };
  const encode = (bytes) => {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };
  const send = (context, from, input) => {
    const n = input.length, ch = input.numberOfChannels;
    const left = input.getChannelData(0), right = ch > 1 ? input.getChannelData(1) : left;
    const out = new Int16Array(n * 2);
    let heard = false;
    for (let i = 0; i < n; i++) {
      const l = left[i] > 1 ? 1 : left[i] < -1 ? -1 : left[i], r = right[i] > 1 ? 1 : right[i] < -1 ? -1 : right[i];
      if (l || r) heard = true;
      out[2 * i] = l * 32767;
      out[2 * i + 1] = r * 32767;
    }
    if (!heard || !tap.id) return;
    window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({
      kind: 'tap', id: tap.id, src: frame + '.' + from, rate: context.sampleRate, data: encode(new Uint8Array(out.buffer)),
    }) }));
  };
  const tapsOf = (context) => {
    let found = taps.get(context);
    if (found) return found;
    found = {};
    for (const kind of ['through', 'listen']) {
      const node = context.createScriptProcessor(4096, 2, 2), from = next++;
      ours.add(node);
      // Silent out: what it hears goes to Yab, not to the speakers.
      node.onaudioprocess = (event) => {
        for (let c = 0; c < event.outputBuffer.numberOfChannels; c++) event.outputBuffer.getChannelData(c).fill(0);
        if (tap.on) send(context, from, event.inputBuffer);
      };
      found[kind] = node;
    }
    found.context = context;
    found.live = false;
    taps.set(context, found);
    made.add(found);
    return found;
  };
  // Taps run only while captured.
  const wake = (found, on) => {
    if (found.live === on) return;
    found.live = on;
    for (const node of [found.through, found.listen]) {
      try { if (on) connect.call(node, found.context.destination); else disconnect.call(node); } catch (e) {}
    }
  };
  const into = (entry, captured) => {
    const [node, ...rest] = entry, context = node.context;
    const target = captured ? tapsOf(context).through : context.destination;
    if (captured) wake(tapsOf(context), true);
    connect.call(node, target, ...rest);
  };
  const out = (entry, captured) => {
    const [node, ...rest] = entry, context = node.context;
    const target = captured ? tapsOf(context).through : context.destination;
    try { disconnect.call(node, target, ...rest); } catch (e) {}
  };
  const toDestination = (node, target) =>
    Destination && target instanceof Destination && !ours.has(node) && !(Offline && node.context instanceof Offline);
  proto.connect = function (target, ...rest) {
    if (!toDestination(this, target)) return connect.call(this, target, ...rest);
    const entry = [this, ...rest];
    if (!sent.some((e) => e.length === entry.length && e.every((v, i) => v === entry[i]))) sent.push(entry);
    try { into(entry, tap.on); } catch (e) {
      sent.splice(sent.indexOf(entry), 1);
      throw e;
    }
    return target;
  };
  proto.disconnect = function (...args) {
    const [target] = args;
    // All of its connections, or all from one output: the tap's with them.
    if (!args.length || typeof target === 'number') {
      for (let i = sent.length - 1; i >= 0; i--) {
        if (sent[i][0] === this && (!args.length || sent[i][1] === target || sent[i][1] === undefined)) sent.splice(i, 1);
      }
      return disconnect.apply(this, args);
    }
    if (!toDestination(this, target)) return disconnect.apply(this, args);
    const mine = sent.filter((e) => e[0] === this && args.slice(1).every((v, i) => e[1 + i] === v));
    if (!mine.length) return disconnect.apply(this, args);
    for (const entry of mine) {
      out(entry, tap.on);
      sent.splice(sent.indexOf(entry), 1);
    }
  };
  // An element whose sound WebKit hands Web Audio whole: a plain file of
  // this site or one asked for with CORS, or a data address. Not a blob:
  // one made from a MediaSource (YouTube's) gives Web Audio silence and
  // the tab goes quiet with it, and nothing tells the two kinds apart.
  const plain = (element) => {
    const address = element.currentSrc || element.src || '';
    if (!address || /^blob:/.test(address)) return false;
    if (/^data:/.test(address)) return true;
    try { if (new URL(address, location.href).origin === location.origin) return true; } catch (e) { return false; }
    return element.crossOrigin != null;
  };
  const route = (element) => {
    if (!tap.on || routed.has(element)) return;
    const live = element.srcObject instanceof MediaStream ? element.srcObject : null;
    if (!live && !plain(element)) return;
    if (!own) own = new AudioContext();
    if (own.state !== 'running') { own.resume().catch(() => {}); return; }
    if (live && !live.getAudioTracks().length) return;
    routed.add(element);
    try {
      if (live) {
        // A call's voices: taken from the stream, and still heard, as
        // the element's own way out can't be turned down from here.
        const source = own.createMediaStreamSource(live);
        streams.push(source);
        wake(tapsOf(own), true);
        connect.call(source, tapsOf(own).listen);
      } else {
        // Through the patched connect: to the tap now, to the speakers
        // once the capture ends.
        own.createMediaElementSource(element).connect(own.destination);
      }
    } catch (e) {
      // Already the page's own Web Audio source: its graph is tapped.
    }
  };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    try { route(this); } catch (e) {}
    return play.apply(this, arguments);
  };
  document.addEventListener('play', (event) => {
    if (event.target instanceof HTMLMediaElement) try { route(event.target); } catch (e) {}
  }, true);
  tap.arm = (id, on) => {
    tap.id = id;
    if (tap.on !== on) {
      for (const entry of sent) {
        try { out(entry, tap.on); into(entry, on); } catch (e) {}
      }
      for (const source of streams) {
        try { if (on) connect.call(source, tapsOf(source.context).listen); else disconnect.call(source); } catch (e) {}
      }
      tap.on = on;
      for (const found of made) wake(found, on && sent.some((e) => e[0].context === found.context) ||
                                                 on && streams.some((s) => s.context === found.context));
    }
    if (!on) return;
    // Started here, inside Yab's call, for the elements there are now (an
    // element played later is played by a click, which starts it then): a
    // context starts a moment after it is let, so they are routed once it
    // runs.
    if (!own && !document.querySelector('audio, video')) return;
    if (!own) own = new AudioContext();
    const all = () => { for (const element of document.querySelectorAll('audio, video')) try { route(element); } catch (e) {} };
    if (own.state === 'running') all();
    else own.resume().then(all, () => {});
  };
  Object.defineProperty(window, K, { value: tap });
}
tap.arm(id, !!on);
return true;
