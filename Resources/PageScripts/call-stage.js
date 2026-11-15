if (!window.__yabCall) window.__yabCall = (function () {
  var host = null, root = null, stage = null, empty = null, timer = null, gliding = 0;
  var view = 352, names = false, band = false, lift = 0;
  var tiles = new Map();          // key → { box, video, face, label }
  var slots = [];                 // keys on the grid, in their places
  var spoke = new Map();          // key → when its level last stirred
  var since = new Map();          // key → when it began speaking
  var heard = new WeakSet();      // level elements already watched
  var mine = null;                // your key, once your mirrored video showed it
  var minePid = null;             // and your person on Meet, whose share is yours
  var winH = 198;                 // the window's height in points, as last laid out
  // The window's own things over the stage (CallAsk.overlay): the
  // island where it is heading, in points from the top left, and how
  // much of the foot the corner's marks take with the buttons away.
  var island = { x: 0, y: 0, w: 0, h: 0 }, marksFoot = 0;
  var looks = 0, lastKeys = '', settling = {};
  var picture = null;             // your picture in the corner, as laid out
  var admittedAt = new Map();     // name → when the window let them in
  var handOrder = [];             // keys with a hand up, in the order raised: Meet's queue
  var echoed = null;              // your reaction from the window, shown before Meet says so

  // A class on the stage for one move's time: what it names glides.
  function settle(name, ms) {
    if (!stage) return;
    stage.classList.add(name);
    clearTimeout(settling[name]);
    settling[name] = setTimeout(function () { if (stage) stage.classList.remove(name); }, ms || 380);
  }
  function still() { return matchMedia('(prefers-reduced-motion: reduce)').matches; }

  var SPEAKING = 1500, TAKEOVER = 2000;

  // The part of the page the window shows (it fills the window, cut at
  // the sides or the top and bottom), in the page's px: the stage is
  // laid out in it, for the window's own shape. All of it until told.
  var crop = null;
  function pageW() { return crop ? crop.cw : innerWidth; }
  function pageH() { return crop ? crop.ch : innerHeight; }
  function placeHost() {
    if (!host) return;
    var at = crop ? ['left:' + crop.x + 'px !important', 'top:' + crop.y + 'px !important',
                     'width:' + crop.cw + 'px !important', 'height:' + crop.ch + 'px !important']
                  : ['inset:0 !important', 'width:100vw !important', 'height:100vh !important'];
    host.setAttribute('style', [
      'position:fixed !important', 'z-index:2147483647 !important',
      'display:block !important', 'background:#000 !important', 'margin:0 !important',
      'pointer-events:none !important'
    ].concat(at).join(';'));
  }
  function pt(n) { return n * pageW() / Math.max(view, 1) + 'px'; }
  function stream(v) {
    var s = v && v.srcObject;
    return (s && typeof s.getVideoTracks === 'function') ? s : null;
  }
  function live(v) {
    var s = stream(v);
    if (!s || !(v.videoWidth > 0)) return false;
    return s.getVideoTracks().some(function (t) { return t.readyState === 'live' && t.enabled; });
  }
  function mirrored(v) { return (getComputedStyle(v).transform || '').indexOf('matrix(-1') === 0; }
  // Your own screen, as the page previews it: a capture of this Mac's
  // display has a surface, a stream from someone else never does. It is
  // never put on the stage, the call looking at itself.
  function ownScreen(v) {
    var s = stream(v), t = s && s.getVideoTracks()[0];
    try { return !!(t && t.getSettings && t.getSettings().displaySurface); } catch (e) { return false; }
  }
  // Muted, as a Meet tile marks it: its mic-off icon by name, or a
  // label that says so, whatever the language Meet speaks in.
  var MUTED = /mic_off|microphone (is )?(off|muted)|is muted|muted/i;
  function silent(t) {
    if (t.querySelector('[data-is-muted="true"]')) return true;
    var marks = t.querySelectorAll('i, [aria-label], [data-tooltip]');
    for (var i = 0; i < marks.length; i++) {
      var e = marks[i];
      if (e.closest('button')) continue;
      var said = e.tagName === 'I' ? e.textContent.trim() : (e.getAttribute('aria-label') || e.getAttribute('data-tooltip') || '');
      if (MUTED.test(said)) return true;
    }
    return false;
  }
  function speaking(key, now) { return now - (spoke.get(key) || -1e9) < SPEAKING; }

  // ---- Zoom's web client (app.zoom.us/wc) ----
  // Zoom draws everyone's video into one canvas, in the open shadow root
  // of a video-player-container, and marks each one's place over it
  // with a video-player that has a node id; a screen shared with you is
  // a second such container (sharee-container__canvas). Names, mute and
  // the faces are in the tiles' avatars, hands in the participants
  // list's labels: "Ann (Guest),computer audio muted,video on,hand raised".
  var ZOOM = /(^|\.)zoom\.us$/i.test(location.hostname);
  // A Slack huddle's window: its thread is its chat (Slack's editor), its
  // hand and reactions in its toolbar.
  var SLACK = location.hostname === 'app.slack.com';
  var feeds = new Map();          // canvas → its captureStream
  function feed(canvas) {
    if (!canvas || !(canvas.width > 0)) return null;
    var f = feeds.get(canvas);
    if (f && f.getVideoTracks().some(function (t) { return t.readyState === 'live'; })) return f;
    try { f = canvas.captureStream(24); } catch (e) { return null; }
    feeds.set(canvas, f);
    return f;
  }
  function dropFeeds() {
    feeds.forEach(function (f) { f.getTracks().forEach(function (t) { t.stop(); }); });
    feeds.clear();
  }
  function zoomCanvas(container) {
    var c = container && container.shadowRoot && container.shadowRoot.querySelector('canvas');
    return c && visible(c) ? c : null;
  }
  // Where one place is in its canvas, as fractions of it.
  function cropOf(place, canvas) {
    var c = canvas.getBoundingClientRect(), r = place.getBoundingClientRect();
    if (!(c.width > 0 && c.height > 0 && r.width > 0)) return null;
    return { x: (r.left - c.left) / c.width, y: (r.top - c.top) / c.height,
             w: r.width / c.width, h: r.height / c.height, aspect: r.width / r.height };
  }
  function overlap(a, b) {
    var w = Math.min(a.right, b.right) - Math.max(a.left, b.left), h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    return w > 0 && h > 0 ? w * h / Math.max(1, Math.min(a.width * a.height, b.width * b.height)) : 0;
  }
  var zoomMe = '';                 // your name, once the participants list said "(me)"
  var zoomHands = new Set();
  function zoomRoster() {
    var list = document.querySelectorAll('.participants-li[aria-label]');
    if (!list.length) return null;
    var out = {};
    zoomHands = new Set();
    list.forEach(function (li) {
      // "Name (Host, me),states": the role's own comma is in its brackets.
      var m = /^(.*?)\s*(?:\(([^)]*)\))?\s*(?:,(.*))?$/.exec(li.getAttribute('aria-label')) || [];
      var name = (m[1] || '').trim(), rest = m[3] || '';
      if (/(^|,)\s*me\s*$/i.test(m[2] || '')) zoomMe = name;
      out[name] = { muted: /audio muted|no audio/i.test(rest), hand: /hand raised/i.test(rest) };
      if (out[name].hand) zoomHands.add(name);
    });
    return out;
  }
  function zoomPeople() {
    var roster = zoomRoster() || {};
    var gallery = null, screen = null;
    document.querySelectorAll('video-player-container').forEach(function (e) {
      var c = zoomCanvas(e);
      if (!c) return;
      if (e.classList.contains('sharee-container__canvas')) screen = screen || c; else gallery = gallery || c;
    });
    var places = [];
    document.querySelectorAll('video-player[node-id]').forEach(function (v) {
      if (v.getAttribute('node-id') && v.closest('video-player-container:not(.sharee-container__canvas)')) places.push(v);
    });
    var out = [], used = {};
    document.querySelectorAll('.video-avatar__avatar').forEach(function (a) {
      var r = a.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) return;
      var img = a.querySelector('img.video-avatar__avatar-img');
      var label = a.querySelector('.video-avatar__avatar-footer span[role="none"], .video-avatar__avatar-name');
      var name = ((label && label.textContent) || (img && img.alt) || '').trim();
      var n = used[name] = (used[name] || 0) + 1;
      var key = 'zoom:' + name + (n > 1 ? '#' + n : '');
      var place = null;
      places.forEach(function (v) { if (!place && overlap(v.getBoundingClientRect(), r) > 0.5) place = v; });
      var crop = place && gallery ? cropOf(place, gallery) : null;
      var said = roster[name] || {};
      var self = !!zoomMe && name === zoomMe;
      if (self) mine = key;
      out.push({ key: key, name: name, face: img && /^https?:/.test(img.src) ? img.src : null, video: null,
                 feed: crop ? feed(gallery) : null, crop: crop, self: self, shared: false,
                 muted: said.muted !== undefined ? said.muted : !!a.querySelector('[class*="view-mute"]'),
                 hand: !!said.hand || !!a.querySelector('[class*="lazy-icon-nvf/270b"]') });
    });
    if (screen) {
      var whole = { x: 0, y: 0, w: 1, h: 1, aspect: screen.width / Math.max(1, screen.height) };
      out.push({ key: 'zoom:screen', name: '', face: null, video: null, feed: feed(screen), crop: whole, self: false, shared: true });
    }
    return out;
  }
  function hasPicture(p) { return !!(p.video || p.feed); }

  // Who is on the call, as the page shows them.
  function people() {
    if (ZOOM) return zoomPeople();
    var meet = document.querySelectorAll('div[data-participant-id]');
    if (meet.length) {
      var out = [];
      meet.forEach(function (t) {
        var pid = t.getAttribute('data-participant-id') || '';
        var media = t.getAttribute('data-tile-media-id') || pid;
        // Your own presentation's tile, whatever marks it: its video is
        // this Mac's screen.
        if (Array.prototype.some.call(t.querySelectorAll('video'), ownScreen)) return;
        var video = null;
        t.querySelectorAll('video').forEach(function (v) { if (!video && live(v)) video = v; });
        var name = (t.querySelector('span.notranslate') || {}).textContent || '';
        var face = null, best = 0;
        t.querySelectorAll('img').forEach(function (i) {
          if (/googleusercontent/.test(i.src) && i.naturalWidth > best) { best = i.naturalWidth; face = i.src; }
        });
        // Someone's screen: its media is not its person's, or, as Meet
        // shows it beside them now, a playing tile with no name of its own.
        var isShare = media !== pid || (!name.trim() && !!video && !mirrored(video));
        var key = isShare && media === pid ? media + '#share' : media;
        if (!isShare && video && mirrored(video)) { mine = key; minePid = pid; }
        // Your own presentation's tile: not someone else's screen.
        if (isShare && pid === minePid) return;
        var level = t.querySelector('[jsname="QgSmzd"]');
        if (level && !heard.has(level)) {
          heard.add(level);
          new MutationObserver(function () {
            var now = performance.now();
            if (!speaking(key, now)) since.set(key, now);
            spoke.set(key, now);
            ring(key, now);
          }).observe(level, { attributes: true, attributeFilter: ['class'] });
        }
        out.push({ key: key, name: name.trim(), face: face, video: video,
                   self: key === mine, shared: isShare, muted: !isShare && silent(t),
                   hand: !isShare && raised(t) });
      });
      // A screen Meet plays outside anyone's tile: the biggest such video.
      if (!out.some(function (p) { return p.shared && hasPicture(p); })) {
        var loose = null, most = 0;
        document.querySelectorAll('video').forEach(function (v) {
          if (v.closest('div[data-participant-id]') || !live(v) || ownScreen(v) || mirrored(v)) return;
          var r = v.getBoundingClientRect();
          if (r.width * r.height > most) { most = r.width * r.height; loose = v; }
        });
        if (loose) out.push({ key: 'share:' + stream(loose).id, name: '', face: null, video: loose, self: false, shared: true });
      }
      return out;
    }
    var seen = new Set(), found = [];
    document.querySelectorAll('video').forEach(function (v) {
      var s = stream(v);
      if (!live(v) || seen.has(s) || ownScreen(v)) return;
      seen.add(s);
      var r = v.getBoundingClientRect();
      found.push({ key: s.id, name: '', face: null, video: v, self: mirrored(v), shared: false, area: r.width * r.height });
    });
    found.sort(function (a, b) { return b.area - a.area; });
    return found;
  }

  function build() {
    host = document.createElement('yab-call');
    placeHost();
    root = host.attachShadow({ mode: 'closed' });
    var style = document.createElement('style');
    style.textContent = [
      ':host { all: initial; }',
      '.stage { position:absolute; inset:0; overflow:hidden; }',
      '.tile { position:absolute; overflow:hidden; background:#262624; }',
      '.tile video { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }',
      // A screen shared is shown whole, letterboxed on black, as every
      // call app shows one: its edges are what was shown, not a crop.
      '.tile.screen { background:#000; }',
      '.tile.screen video { object-fit:contain; }',
      '.face { position:absolute; left:50%; top:50%; transform:translate(-50%,-50%); border-radius:50%;',
      '        background:#5f5e5a center/cover no-repeat; color:#f1efe8; display:flex; align-items:center;',
      '        justify-content:center; font-family:-apple-system,system-ui; font-weight:500; }',
      '.label { position:absolute; left:0; bottom:0; color:#f1efe8; font-family:-apple-system,system-ui; background:rgba(0,0,0,.45);',
      '         white-space:nowrap; overflow:hidden; text-overflow:ellipsis; opacity:0; transition:opacity .16s; }',
      '.named .label { opacity:1; }',
      '.label { display:flex; align-items:center; }',
      '.label span { overflow:hidden; text-overflow:ellipsis; }',
      '.label svg { flex:none; }',
      '.mic { position:absolute; z-index:2; border-radius:50%; background:rgba(0,0,0,.5); display:none;',
      '       align-items:center; justify-content:center; transition:opacity .16s; }',
      '.muted .mic { display:flex; }',
      '.named .tile:not(.dot) .mic { opacity:0; }',
      '.dot .mic { background:#e5484d; }',
      '.dot .label { display:none; }',
      '.dot.tile { overflow:visible; }',
      '.dot video, .dot .face { border-radius:50%; overflow:hidden; }',
      '.ring { position:absolute; inset:0; pointer-events:none; opacity:0; transition:opacity .15s; }',
      '.speaking .ring { opacity:1; }',
      '.glide .tile.corner { transition:top .16s cubic-bezier(.2,.8,.2,1); }',
      '.glide .label { transition:opacity .16s, bottom .16s cubic-bezier(.2,.8,.2,1); }',
      // Someone come or gone: the grid makes room, the faces over a
      // screen go under the island and back, at one pace.
      '.regrid .tile { transition:left .32s cubic-bezier(.2,.8,.2,1), top .32s cubic-bezier(.2,.8,.2,1),',
      '                width .32s cubic-bezier(.2,.8,.2,1), height .32s cubic-bezier(.2,.8,.2,1); }',
      '.regrid .face { transition:width .32s cubic-bezier(.2,.8,.2,1), height .32s cubic-bezier(.2,.8,.2,1), margin-top .24s; }',
      // A face lifted with its bubble, and back.
      '.face { transition:margin-top .24s cubic-bezier(.2,.8,.2,1); }',
      '.face.fly { z-index:5; }',
      // A bubble on a tile is its name: the tile's own goes meanwhile.
      '.tile.quoted .label { opacity:0; }',
      '@media (prefers-reduced-motion: reduce) { .glide .tile.corner, .glide .label, .regrid .tile, .regrid .face, .face { transition:none; } }',
      '.more { color:#d3d1c7; font-family:-apple-system,system-ui; display:flex; align-items:center; justify-content:center; }',
      '.empty { position:absolute; left:0; right:0; z-index:3; color:rgba(255,255,255,.75); text-align:center; text-shadow:0 1px 2px rgba(0,0,0,.6);',
      '         font-family:-apple-system,system-ui; opacity:0; transition:opacity .16s; }',
      '.named .empty { opacity:1; }',
      // A hand up: a white mark in the tile's top left, the ring warm.
      '.hand { position:absolute; z-index:3; background:#fff; color:#111; display:flex; align-items:center; box-sizing:border-box;',
      '        justify-content:center; font-family:-apple-system,system-ui; font-weight:600; transform-origin:50% 90%; }',
      '.hand i { display:block; flex:none; }',
      '.raised .ring { opacity:1; }',
      // Raised: the hand comes up from the tile's foot and waves once.
      '.hand.up { animation:rise .42s cubic-bezier(.2,.9,.25,1.15) both, wave .7s .36s ease-out; }',
      '@keyframes rise { from { transform:translateY(var(--rise, 40px)); opacity:0; } 30% { opacity:1; } to { transform:none; opacity:1; } }',
      '@keyframes wave { 0% { transform:rotate(0); } 30% { transform:rotate(16deg); } 65% { transform:rotate(-9deg); } 100% { transform:rotate(0); } }',
      // A reaction stands on the face it came from for a moment.
      '.react { position:absolute; z-index:3; display:flex; align-items:center; justify-content:center; line-height:1;',
      '         transform:translate(-50%,-50%); pointer-events:none; }',
      // The face gives way to the emoji for its moment and comes back:
      // the one shrinks as the other grows past whole and settles.
      '.react.on { animation:become var(--life, 1200ms) linear both; }',
      '@keyframes become { 0% { transform:translate(-50%,-50%) scale(0); animation-timing-function:cubic-bezier(.2,.9,.3,1.3); }',
      '  22% { transform:translate(-50%,-50%) scale(1); } 84% { transform:translate(-50%,-50%) scale(1); animation-timing-function:cubic-bezier(.5,0,.8,.4); }',
      '  100% { transform:translate(-50%,-50%) scale(0); } }',
      '.face.yield { animation:yield var(--life, 1200ms) linear both; }',
      '@keyframes yield { 0% { transform:translate(-50%,-50%) scale(1); } 12% { transform:translate(-50%,-50%) scale(0); }',
      '  88% { transform:translate(-50%,-50%) scale(0); } 100% { transform:translate(-50%,-50%) scale(1); } }',
      '.cheer { display:inline-block; line-height:1; }',
      '.cheer.on { animation:cheer .3s cubic-bezier(.2,.9,.3,1.3); }',
      '@keyframes cheer { from { transform:scale(0); } to { transform:none; } }',
      '.times { position:absolute; right:-4px; bottom:-2px; background:#fff; color:#111; font-weight:700;',
      '         font-family:-apple-system,system-ui; display:flex; align-items:center; }',
      // What someone wrote, on them: light, so it reads over any picture.
      '.bubble { position:absolute; z-index:4; background:#f4f4f6; color:#121214; font-family:-apple-system,system-ui;',
      '          box-shadow:0 4px 14px rgba(0,0,0,.35); box-sizing:border-box; overflow-wrap:anywhere; }',
      '.bubble b { display:flex; align-items:center; color:#6b6a72; font-weight:600; }',
      '.bubble .mini { display:inline-flex; flex:none; align-items:center; justify-content:center; border-radius:50%;',
      '                background:#e7dcf7 center/cover no-repeat; color:#5a2f99; font-weight:600; }',
      '.bubble .tail { position:absolute; background:#f4f4f6; transform:rotate(45deg); }',
      '.bubble hr { border:0; border-top:1px solid #dddde2; }',
      '.bubble.in { animation:grow .24s cubic-bezier(.2,.8,.2,1); transform-origin:var(--from, 20px 0); }',
      '@keyframes grow { from { transform:scale(.3); opacity:0; } to { transform:none; opacity:1; } }',
      // Pushed out by a third, or old: back into the face it came from.
      '.bubble.out { animation:retire .2s cubic-bezier(.4,0,1,1) forwards; transform-origin:var(--from, 20px 0); }',
      '@keyframes retire { to { transform:scale(.2); opacity:0; } }',
      // Clicked: the bubble itself comes down to be the field.
      '.bubble.becomes { transition:left .26s cubic-bezier(.2,.8,.2,1), top .26s cubic-bezier(.2,.8,.2,1), width .26s cubic-bezier(.2,.8,.2,1),',
      '                  height .26s cubic-bezier(.2,.8,.2,1), border-radius .26s, background-color .2s, color .12s, box-shadow .2s; overflow:hidden; }',
      '@media (prefers-reduced-motion: reduce) { .react.on, .face.yield, .cheer.on, .hand.up, .bubble.in, .bubble.out { animation:none; } }',
      // The captions: Meet's, two lines along the bottom, the latest words.
      '.caps { position:absolute; z-index:3; text-align:center; overflow:hidden; display:flex;',
      '        flex-direction:column; justify-content:flex-end; color:#fff; font-family:-apple-system,system-ui; font-weight:500; }',
      '.caps span { background:rgba(0,0,0,.72); -webkit-box-decoration-break:clone; box-decoration-break:clone; }',
      '.caps em { font-style:normal; color:rgba(255,255,255,.62); }',
      // The field open: the people blur under the thread over it.
      '.veil { position:absolute; left:0; right:0; bottom:0; z-index:5; pointer-events:none; opacity:0;',
      '        -webkit-backdrop-filter:blur(12px); backdrop-filter:blur(12px); background:rgba(0,0,0,.3);',
      '        -webkit-mask-image:linear-gradient(to bottom, transparent, #000 var(--fade, 28px));',
      '        mask-image:linear-gradient(to bottom, transparent, #000 var(--fade, 28px)); transition:opacity .2s; }',
      '.veil.on { opacity:1; }',
      '.thread { position:absolute; z-index:6; display:flex; flex-direction:column; pointer-events:none; opacity:0;',
      '          transform:translateY(6px); transition:opacity .18s, transform .22s cubic-bezier(.2,.8,.2,1); }',
      '.thread.on { opacity:1; transform:none; }',
      '.thread .m { align-self:flex-start; max-width:80%; box-sizing:border-box; background:#f4f4f6; color:#121214;',
      '             font-family:-apple-system,system-ui; box-shadow:0 2px 8px rgba(0,0,0,.25); overflow-wrap:anywhere; }',
      '.thread .m b { display:block; color:#6b6a72; font-weight:600; }',
      '.thread .m.mine { align-self:flex-end; background:#7a6cff; color:#fff; }',
      '.stage.threading .bubble { opacity:0; transition:opacity .15s; }',
      '@media (prefers-reduced-motion: reduce) { .veil, .thread { transition:none; } }'
    ].join('\n');
    root.appendChild(style);
    stage = document.createElement('div');
    stage.className = 'stage';
    root.appendChild(stage);
    empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = 'Waiting for others';
    stage.appendChild(empty);
    caps = document.createElement('div');
    caps.className = 'caps';
    stage.appendChild(caps);
    document.documentElement.appendChild(host);
  }

  // Meet's mic-off mark, drawn here: the page's own may not be there.
  function micOff() {
    var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', '#fff');
    svg.setAttribute('stroke-width', '2.2');
    svg.setAttribute('stroke-linecap', 'round');
    ['M9 9v2a3 3 0 0 0 5.1 2.1M15 10V6a3 3 0 0 0-5.7-1.3',
     'M19 11a7 7 0 0 1-1.2 3.9M5 11a7 7 0 0 0 11.3 5.5M12 18v3M3 3l18 18'].forEach(function (d) {
      var path = document.createElementNS(ns, 'path');
      path.setAttribute('d', d);
      svg.appendChild(path);
    });
    return svg;
  }

  function tile(p) {
    var t = tiles.get(p.key);
    if (!t) {
      var box = document.createElement('div');
      box.className = 'tile';
      var face = document.createElement('div');
      face.className = 'face';
      var label = document.createElement('div');
      label.className = 'label';
      var edge = document.createElement('div');
      edge.className = 'ring';
      var mic = document.createElement('div');
      mic.className = 'mic';
      mic.appendChild(micOff());
      box.appendChild(mic);
      box.appendChild(face);
      box.appendChild(label);
      box.appendChild(edge);
      stage.appendChild(box);
      var words = document.createElement('span');
      label.appendChild(words);
      var said = micOff();
      label.appendChild(said);
      var handMark = document.createElement('div');
      handMark.className = 'hand';
      handMark.innerHTML = HAND;
      handMark.style.display = 'none';
      box.appendChild(handMark);
      var react = document.createElement('div');
      react.className = 'react';
      react.style.display = 'none';
      box.appendChild(react);
      t = { box: box, face: face, label: label, edge: edge, words: words, said: said, mic: mic, video: null, src: null,
            hand: handMark, react: react, fresh: true, shift: 0, lifted: 0 };
      tiles.set(p.key, t);
    }
    var s = p.feed || stream(p.video);
    t.crop = p.feed ? p.crop : null;
    if (s !== t.src) {
      if (t.video) { t.video.srcObject = null; t.video.remove(); t.video = null; }
      if (s) {
        var v = document.createElement('video');
        v.muted = true; v.autoplay = true; v.playsInline = true;
        v.srcObject = s;
        v.play().catch(function () {});
        t.box.insertBefore(v, t.face);
        t.video = v;
      }
      t.src = s;
    }
    if (t.video) t.video.style.transform = !p.feed && (p.self || (p.video && mirrored(p.video))) ? 'scaleX(-1)' : '';
    t.face.style.display = t.video ? 'none' : 'flex';
    if (!t.video) {
      t.face.style.backgroundImage = p.face ? 'url("' + p.face + '")' : '';
      t.face.textContent = p.face ? '' : (p.name.charAt(0) || '·').toUpperCase();
    }
    t.words.textContent = p.self ? 'You' : p.name;
    t.said.style.display = p.muted ? 'block' : 'none';
    t.box.classList.toggle('muted', !!p.muted);
    t.box.classList.toggle('screen', !!p.shared);
    return t;
  }

  // Corners, as the design draws them in the window's 20 (Floater.corner):
  // a tile 4 in is 10, your picture 8 in is 6, a screen shared from edge
  // to edge is the window's own 20; a tag on a tile (a name, the count
  // of the rest) is 6; a circle, a capsule or a badge is half its height.
  var WINDOW = 20, TILE = 10, PICTURE = 6, TAG = 6, GAP = 4, CORNER = 8;
  // The window's row of buttons and the room over it: your picture in
  // the corner steps up over it while the row, or a word in its place,
  // takes the band along the bottom, as FaceTime's does, and back down.
  var ROW = 14 + 38 + 6, OVER = 14 + 38 + 8;
  function put(t, x, y, w, h, corner, round) {
    var b = t.box.style;
    b.left = pt(x); b.top = pt(y); b.width = pt(w); b.height = pt(h);
    b.borderRadius = pt(round);
    b.boxShadow = corner === 'dot' ? '0 0 0 ' + pt(1.5) + ' rgba(255,255,255,.25)' : corner ? '0 0 0 ' + pt(1) + ' rgba(255,255,255,.22)' : 'none';
    b.display = 'block';
    cut(t, parseFloat(pt(w)), parseFloat(pt(h)));
    var side = Math.min(w, h);
    var f = t.face.style;
    var full = corner === 'dot';
    f.width = f.height = pt(full ? side : Math.min(96, side * 0.42));
    f.fontSize = pt(full ? side * 0.42 : Math.min(40, side * 0.2));
    // A tall tile's face sits a little over its middle, clear of the name.
    t.shift = !corner && h > 120 ? -6 : 0;
    f.marginTop = pt(t.shift - (t.lifted || 0));
    t.box.classList.toggle('corner', !!corner);
    var dot = corner === 'dot';
    t.box.classList.toggle('dot', dot);
    if (t.mic) {
      // Muted: 18 at 5 in on a tile, 15 at 3 in and red on your
      // picture, 13 over the edge of a circle, as the design has them.
      var small = corner === true, m = t.mic.style, ms = dot ? 13 : small ? 15 : 18;
      m.width = m.height = pt(ms);
      m.top = dot ? 'auto' : pt(small ? 3 : 5); m.bottom = dot ? pt(-2) : 'auto'; m.right = dot ? pt(-2) : pt(small ? 3 : 5);
      m.background = small ? '#d93129' : '';
      var g = t.mic.firstChild;
      g.style.width = g.style.height = pt(dot ? 8 : small ? 9 : 11);
      t.said.style.width = t.said.style.height = pt(11);
      t.said.style.marginLeft = pt(4);
    }
    var l = t.label.style;
    l.fontSize = pt(11); l.padding = pt(2) + ' ' + pt(6); l.maxWidth = pt(w - 12);
    l.borderRadius = pt(Math.max(round - 4, 2));
    // Names come with the buttons: on a tile along the bottom they sit
    // over the row (14 up, 38 tall, 6 clear), not under its buttons.
    l.margin = '0';
    l.left = pt(4);
    var over = Math.max(ROW, lift) + capsTall();
    var lb = y + h > winH - over ? y + h - (winH - over) : 4;
    l.bottom = pt(lb);
    // A name never runs under your picture: it stops 6 short of it.
    var foot = y + h - lb, room = w - 12;
    if (picture && !corner && foot > picture.y && foot - 19 < picture.y + picture.h && x + 4 < picture.x && x + w > picture.x) {
      room = Math.min(room, picture.x - 6 - (x + 4));
    }
    l.maxWidth = pt(Math.max(24, room));
    t.edge.style.boxShadow = 'inset 0 0 0 ' + pt(2) + ' rgba(255,255,255,.92)';
    t.edge.style.borderRadius = pt(round);
  }

  // One person's part of a canvas the page draws everyone into (Zoom):
  // the whole canvas in the tile, sized and moved so their part covers
  // it, or a screen's fits it.
  function cut(t, tw, th) {
    var v = t.video, c = t.crop;
    if (!v) return;
    var st = v.style;
    if (!c) { st.inset = st.left = st.top = st.width = st.height = st.objectFit = ''; return; }
    var a = c.aspect * c.h / Math.max(c.w, 1e-6);
    var fit = t.box.classList.contains('screen') ? Math.min : Math.max;
    var vw = fit(tw / c.w, th * a / c.h), vh = vw / a;
    st.inset = 'auto'; st.objectFit = 'fill';
    st.width = vw + 'px'; st.height = vh + 'px';
    st.left = (-c.x * vw + (tw - c.w * vw) / 2) + 'px';
    st.top = (-c.y * vh + (th - c.h * vh) / 2) + 'px';
  }

  function ring(key, now) {
    var t = tiles.get(key);
    if (t) t.box.classList.toggle('speaking', speaking(key, now));
  }

  // The places: three at most, kept whatever is showing now (a screen
  // shared, a small window), filled in order of who spoke last.
  var PLACES = 3;
  function seat(others, count, now) {
    var here = new Set(others.map(function (p) { return p.key; }));
    slots = slots.filter(function (k) { return here.has(k); });
    count = Math.min(count, PLACES);
    var room = PLACES;
    var order = others.slice().sort(function (a, b) { return (spoke.get(b.key) || 0) - (spoke.get(a.key) || 0); });
    order.forEach(function (p) {
      if (slots.length < room && slots.indexOf(p.key) < 0) slots.push(p.key);
    });
    // Someone off the grid talking for two seconds: the quietest place.
    order.forEach(function (p) {
      // A hand up takes a place at once, as two seconds of talking does.
      if (slots.indexOf(p.key) >= 0 || !(speaking(p.key, now) || p.hand)) return;
      if (!p.hand && now - (since.get(p.key) || now) < TAKEOVER) return;
      var quiet = -1, oldest = Infinity;
      slots.forEach(function (k, i) {
        var at = spoke.get(k) || 0;
        if (!speaking(k, now) && at < oldest) { oldest = at; quiet = i; }
      });
      if (quiet >= 0) slots[quiet] = p.key;
    });
    return slots.slice(0, count).map(function (k) { return others.find(function (p) { return p.key === k; }); });
  }

  function scan() {
    if (!host || !host.isConnected) build();
    var now = performance.now();
    var all = people();
    var me = all.find(function (p) { return p.self; }) || null;
    var shared = all.find(function (p) { return p.shared && hasPicture(p); }) || null;
    var others = all.filter(function (p) { return !p.self && !p.shared; });
    var W = view, H = view * pageH() / Math.max(pageW(), 1), g = GAP;
    winH = H;
    // Too small for more than one: the one who talks. By area and the
    // shorter side, as the window takes any shape.
    var compact = Math.min(W, H) < 170 || W * H < 300 * 150;
    var shown = [];                // [person, x, y, w, h, corner]
    var corner = function (p) {
      var w = Math.round(Math.max(64, Math.min(130, Math.min(W, H * 1.6) * 0.28))), h = Math.round(w * 9 / 16);
      shown.push([p, W - w - CORNER, H - h - pictureFoot(), w, h, true]);
    };
    var talker = others.filter(function (p) { return speaking(p.key, now); })
      .sort(function (a, b) { return (spoke.get(b.key) || 0) - (spoke.get(a.key) || 0); })[0] || null;

    if (shared) {
      // The screen fills the window; everyone else is a row of faces
      // along its top, from the right, who spoke last nearest the edge.
      shown.push([shared, 0, 0, W, H, false]);
      var D = 30, room = Math.max(1, Math.min(compact ? 3 : 6, Math.floor((W * 0.6 - CORNER) / (D + 6))));
      var row = others.slice().sort(function (a, b) { return (spoke.get(b.key) || 0) - (spoke.get(a.key) || 0); });
      var extra = row.length > room ? row.length - (room - 1) : 0;
      row = row.slice(0, extra ? room - 1 : room);
      // Your reaction over a screen: your circle joins the row for it.
      var yours = me && reacting.get(me.key);
      if (yours && yours.until > now) row.push(me);
      // 8 down; 40 with the buttons up, under the corner buttons; under
      // the island, 6 clear, where it reaches over them.
      var n = row.length + (extra ? 1 : 0), far = W - CORNER - D - (n - 1) * (D + 6), dotsY = names ? 40 : CORNER;
      if (island.h > 0 && island.x < W - CORNER && island.x + island.w > far && island.y < dotsY + D && island.y + island.h > dotsY) {
        dotsY = island.y + island.h + 6;
      }
      row.forEach(function (p, i) { shown.push([p, W - CORNER - D - i * (D + 6), dotsY, D, D, 'dot']); });
      if (extra) shown.push([{ key: '+more', name: '', more: extra, badge: true, dot: true }, W - CORNER - D - row.length * (D + 6), dotsY, D, D, false]);
    } else if (compact) {
      var one = talker || seat(others, 1, now)[0] || me;
      if (one) shown.push([one, g, g, W - 2 * g, H - 2 * g, false]);
    } else if (!others.length) {
      if (me) shown.push([me, g, g, W - 2 * g, H - 2 * g, false]);
    } else {
      var many = others.length > 3;
      var grid = seat(others, many ? 3 : Math.min(others.length, 3), now);
      var half = function (a) { return (a - 3 * g) / 2; };
      var wide = W >= H * 1.2;
      if (grid.length === 1) {
        shown.push([grid[0], g, g, W - 2 * g, H - 2 * g, false]);
      } else if (grid.length === 2) {
        if (wide) {
          shown.push([grid[0], g, g, half(W), H - 2 * g, false]);
          shown.push([grid[1], 2 * g + half(W), g, half(W), H - 2 * g, false]);
        } else {
          shown.push([grid[0], g, g, W - 2 * g, half(H), false]);
          shown.push([grid[1], g, 2 * g + half(H), W - 2 * g, half(H), false]);
        }
      } else {
        // Four places: a row in a window three times as wide as tall or
        // more, a column in one twice as tall, two by two otherwise.
        var cw = half(W), ch = half(H), cells;
        if (W >= H * 2.4) {
          cw = (W - 5 * g) / 4; ch = H - 2 * g;
          cells = [0, 1, 2, 3].map(function (i) { return [g + i * (cw + g), g]; });
        } else if (H >= W * 1.6) {
          cw = W - 2 * g; ch = (H - 5 * g) / 4;
          cells = [0, 1, 2, 3].map(function (i) { return [g, g + i * (ch + g)]; });
        } else {
          cells = [[g, g], [2 * g + cw, g], [g, 2 * g + ch], [2 * g + cw, 2 * g + ch]];
        }
        grid.forEach(function (p, i) { shown.push([p, cells[i][0], cells[i][1], cw, ch, false]); });
        // The fourth place is yours, with how many more are on the call
        // on it; without you in it, the count is the place.
        if (me) {
          shown.push([me, cells[3][0], cells[3][1], cw, ch, false]);
          me = null;
        }
        if (many) {
          var x = cells[3][0], y = cells[3][1];
          if (shown.length === 4) shown.push([{ key: '+more', name: '', more: others.length - 3, badge: true }, x + 6, y + 6, 32, 20, false]);
          else shown.push([{ key: '+more', name: '', more: others.length - 3 }, x, y, cw, ch, false]);
        }
      }
      if (me) corner(me);
    }

    // Someone come or gone, not the window sized: the grid makes room.
    looks++;
    var keys = shown.map(function (s) { return s[0].key; }).join(',');
    if (lastKeys && keys !== lastKeys) settle('regrid');
    lastKeys = keys;
    var mineAt = shown.find(function (s) { return s[5] === true; });
    picture = mineAt ? { x: mineAt[1], y: mineAt[2], w: mineAt[3], h: mineAt[4] } : null;
    var keep = new Set();
    shown.forEach(function (s) {
      var p = s[0], t;
      if (p.more !== undefined) {
        t = tiles.get('+more');
        if (!t) {
          var box = document.createElement('div');
          box.className = 'tile more';
          var edge = document.createElement('div');
          stage.appendChild(box);
          t = { box: box, face: document.createElement('div'), label: document.createElement('div'), edge: edge, video: null, src: null };
          tiles.set('+more', t);
        }
        // What it says is drawn with the people's news (decorate).
        t.more = p.more;
        t.box.style.fontSize = pt(p.badge ? 11 : 15);
        t.box.style.background = p.badge ? 'rgba(0,0,0,.55)' : '#262624';
      } else {
        t = tile(p);
      }
      var round = s[5] === 'dot' || p.dot ? s[3] / 2 : p.badge ? TAG : s[5] ? PICTURE : s[1] <= 0 ? WINDOW : TILE;
      put(t, s[1], s[2], s[3], s[4], s[5], round);
      if (p.more !== undefined) {
        t.box.style.display = 'flex';
        // The count on a tile: a tag as wide as it says, 7 in, 20 tall.
        if (p.badge && !p.dot) { t.box.style.width = 'auto'; t.box.style.padding = '0 ' + pt(7); t.box.style.gap = pt(4); }
        else { t.box.style.padding = '0'; t.box.style.gap = pt(4); }
      }
      if (t.fresh) { t.fresh = false; if (looks > 1 && p.more === undefined) arrive(t, s, p); }
      t.box.style.zIndex = s[5] || p.badge ? '2' : '1';
      keep.add(p.key);
      ring(p.key, now);
    });
    tiles.forEach(function (t, key) {
      if (keep.has(key)) return;
      if (t.video) t.video.srcObject = null;
      t.box.remove();
      tiles.delete(key);
    });
    decorate(shown, all, now);
    empty.style.display = others.length || shared ? 'none' : 'block';
    empty.style.top = pt(8);
    empty.style.fontSize = pt(12);
    stage.classList.toggle('named', names);
    return shown.length;
  }

  function clear() {
    if (timer) clearInterval(timer);
    timer = null;
    removeEventListener('resize', scan);
    tiles.forEach(function (t) { if (t.video) t.video.srcObject = null; });
    dropFeeds();
    tiles.clear();
    slots = [];
    // The next window starts with its band free and no names up.
    names = band = false;
    lift = 0;
    bubbles.forEach(function (b) { if (b.el) b.el.remove(); });
    bubbles = [];
    reacting.clear();
    handOrder = [];
    looks = 0;
    lastKeys = '';
    capsWords = '';
    capsHigh = 0;
    if (host) host.remove();
    host = root = stage = empty = caps = null;
    started = false;
  }

  // ---- Beyond the people (CallNews.swift) ----
  // Meet's own controls and notices, found by what they are rather than
  // what they say: Material icon names, jsname and data attributes,
  // words only last and in English.
  var HAND = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" style="width:100%;height:100%"><path d="M8 13V6.5a1.5 1.5 0 0 1 3 0V11V4.5a1.5 1.5 0 0 1 3 0V11V5.5a1.5 1.5 0 0 1 3 0V12V8.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-.8a6.5 6.5 0 0 1-4.8-2.4l-3.2-4.25a1.6 1.6 0 0 1 2.5-2.08L8 13.7"/></svg>';
  var ICONS = 'i, .google-symbols, .material-icons-extended, .material-symbols-outlined, .google-material-icons';
  // An icon by its name: in a button (that button), or not in one.
  function icon(names, root, inButton) {
    var all = (root || document).querySelectorAll(ICONS);
    for (var i = 0; i < all.length; i++) {
      if (names.indexOf(all[i].textContent.trim()) < 0) continue;
      var b = all[i].closest('button, [role="button"]');
      if (inButton && b && visible(b)) return b;
      if (!inButton && !b) return all[i];
    }
    return null;
  }
  function labelled(re) {
    var all = document.querySelectorAll('button[aria-label], [role="button"][aria-label], button[data-tooltip]');
    for (var i = 0; i < all.length; i++) {
      var said = all[i].getAttribute('aria-label') || all[i].getAttribute('data-tooltip') || '';
      if (re.test(said) && visible(all[i])) return all[i];
    }
    return null;
  }
  function pressedIs(b) {
    if (!b) return false;
    var on = b.getAttribute('aria-pressed');
    return on === 'true';
  }
  // Zoom's controls, by their labels (the web client's own, in English
  // whatever the page's language so far): the hand is in React's menu.
  // Zoom hides its bar when nobody moves over the page, as in the window
  // always: a hidden one is pressed all the same, a shown one first.
  function zoomButton(re) {
    // By label, or by its words where it has none (React's menu items).
    var all = document.querySelectorAll('button, [role="button"], [role="menuitem"]');
    var hidden = null;
    for (var i = 0; i < all.length; i++) {
      var said = (all[i].getAttribute('aria-label') || all[i].textContent || '').trim();
      if (!re.test(said)) continue;
      if (visible(all[i])) return all[i];
      hidden = hidden || all[i];
    }
    return hidden;
  }
  var zoomRaised = false;
  async function zoomLearnMe() {
    if (zoomRoster()) return;
    var open = zoomButton(/^open the (manage )?participants list/i);
    if (!open) return;
    open.click();
    for (var i = 0; i < 15 && !zoomRoster(); i++) await wait(100);
    var close = zoomButton(/^close the (manage )?participants list/i);
    if (close) close.click();
  }
  async function zoomHand() {
    var item = zoomButton(/^(raise|lower) hand$/i);
    if (!item) {
      var open = zoomButton(/^react$/i);
      if (!open) return false;
      open.click();
      for (var i = 0; i < 10 && !(item = zoomButton(/^(raise|lower) hand$/i)); i++) await wait(80);
      if (!item) { open.click(); return false; }
    }
    zoomRaised = /^raise/i.test((item.getAttribute('aria-label') || item.textContent || '').trim());
    item.click();
    return true;
  }
  // Zoom's reactions by what its menu calls them.
  var ZOOM_REACT = { '👏': 'clapping hands', '👍': 'thumbs up', '😂': 'face with tears of joy', '😮': 'face with open mouth',
                     '❤️': 'red heart', '🎉': 'party popper' };

  // Your hand: its button by jsname, then its icon, then its words.
  // Someone else's: Meet's front_hand in their tile.
  function handButton() {
    if (ZOOM) return zoomButton(/^react$/i);
    var b = document.querySelector('button[jsname="FpSaz"]');
    return (b && visible(b) && b) || icon(['back_hand'], document, true) || labelled(/(raise|lower) hand|hand raise/i);
  }
  function raised(tile) { return !!icon(['front_hand', 'back_hand'], tile, false); }
  function handUp(b) {
    if (ZOOM) return zoomMe ? zoomHands.has(zoomMe) || zoomRaised : zoomRaised;
    if (!b) return false;
    if (b.hasAttribute('aria-pressed')) return pressedIs(b);
    return /lower hand/i.test(b.getAttribute('aria-label') || b.getAttribute('data-tooltip') || '');
  }
  function captionsButton() {
    if (ZOOM) return zoomButton(/^(show|hide) captions$/i);
    var b = document.querySelector('button[jsname="r8qRAd"], button[jsname="Dg9Wp"]');
    if (b && visible(b) && !b.closest('[role="dialog"]')) return b;
    b = icon(['closed_caption', 'closed_caption_off', 'subtitles', 'subtitles_off'], document, true);
    return b && !b.closest('[role="dialog"]') ? b : labelled(/turn (on|off) captions/i);
  }
  function captionsOn() {
    var b = captionsButton();
    if (!b) return false;
    if (ZOOM) return /^hide/i.test(b.getAttribute('aria-label'));
    if (b.hasAttribute('aria-pressed')) return pressedIs(b);
    var i = b.querySelector(ICONS);
    return !!i && !/_off$/.test(i.textContent.trim()) && !!captionsRegion();
  }
  function chatButton() {
    if (ZOOM) return zoomButton(/^(open|close) the chat panel/i);
    if (SLACK) return document.querySelector('button[data-qa="huddle_toolbar_thread_button"]');
    return icon(['chat', 'chat_bubble'], document, true) || labelled(/chat with everyone|in-call messages/i);
  }
  function reactButton() {
    if (SLACK) return document.querySelector('button[data-qa="huddle_toolbar_emoji_menu_button"]');
    return ZOOM ? zoomButton(/^react$/i) : icon(['mood', 'add_reaction', 'sentiment_satisfied', 'emoji_emotions'], document, true) || labelled(/send a reaction|reactions/i);
  }
  // Recorded or transcribed: Meet's REC mark in the window's top left
  // (fiber_manual_record, not the same icon in a side panel), or its Stop.
  function recording() {
    var all = document.querySelectorAll(ICONS);
    for (var i = 0; i < all.length; i++) {
      var word = all[i].textContent.trim();
      if (word !== 'fiber_manual_record' && word !== 'radio_button_checked' && word !== 'speech_to_text') continue;
      if (all[i].closest('button, [role="button"], [data-panel-id], [role="dialog"]')) continue;
      var r = all[i].getBoundingClientRect();
      if (r.width > 0 && r.left < innerWidth / 2) return true;
    }
    return !!labelled(/stop recording|stop transcri/i);
  }
  // What a button says, without the icon names Meet's text carries.
  function said(b) {
    var words = b.getAttribute('aria-label') || b.getAttribute('data-tooltip') || '';
    if (!words) {
      var copy = b.cloneNode(true);
      copy.querySelectorAll(ICONS).forEach(function (i) { i.remove(); });
      words = copy.textContent;
    }
    return words.replace(/\b[a-z]+(_[a-z]+)+\b/g, '').trim();
  }

  // Someone asking to come in: Meet's notice with Admit, or its list of
  // those waiting in People. The name is what is left of the notice's
  // words when its buttons' are taken out.
  function admitButtons() {
    var out = [];
    document.querySelectorAll('button, [role="button"]').forEach(function (b) {
      if (/^admit\b/i.test(said(b)) && visible(b)) out.push(b);
    });
    return out;
  }
  // Each one waiting, with their Admit: the notice's (a dialog or an
  // alert), or a row of People's "Waiting to join". Not Admit all, nor
  // the "Admit 2 guests" pill that only opens the list.
  function waiting() {
    var out = [], names = new Set();
    admitButtons().forEach(function (b) {
      if (/^admit (all|\d)/i.test(said(b))) return;
      var box = b.closest('[role="listitem"], [role="dialog"], [role="alertdialog"], [role="alert"]') || b.parentElement;
      for (var up = 0; box && up < 3 && !/join|waiting room/i.test(box.textContent) && !box.querySelector('span.notranslate'); up++) box = box.parentElement;
      if (!box) return;
      var name = '';
      var named = box.querySelector('span.notranslate');
      if (named) name = named.textContent.trim();
      if (!name) {
        var copy = box.cloneNode(true);
        copy.querySelectorAll('button, [role="button"], ' + ICONS).forEach(function (n) { n.remove(); });
        var text = (copy.innerText || copy.textContent || '').split('\n').map(function (l) { return l.trim(); }).filter(Boolean);
        var line = text.find(function (l) { return /wants? to join|asking to join|waiting room/i.test(l); }) || text[0] || '';
        // Meet: "Ann wants to join"; Zoom: "Ann entered the waiting room".
        name = line.replace(/\s*(wants? to join.*|is asking to join.*|asks to join.*|(has )?(entered|joined|is in) the waiting room.*)$/i, '')
          .replace(/\b[a-z]+(_[a-z]+)+\b/g, '').trim();
      }
      if (!name || names.has(name) || /^\d+ (people|others)/i.test(name)) return;
      names.add(name);
      var img = box.querySelector('img');
      out.push({ name: name, face: img && /^https?:/.test(img.src) ? img.src : '' , button: b, box: box });
    });
    return out;
  }
  function denyIn(box) {
    var all = box ? box.querySelectorAll('button, [role="button"]') : [];
    for (var i = 0; i < all.length; i++) {
      if (/^(deny|deny entry|decline)\b/i.test(said(all[i]))) return all[i];
    }
    return null;
  }

  // The chat: messages as Meet lists them, each by its id, sender and
  // words; those come since the stage went up are news.
  // The chat as Meet lists it while its panel is open (the window keeps
  // it open under the stage, `readChat`): groups by sender (Ypafjf, the
  // name .poVWob, none for your own), each message by its id, its words
  // in dTKtvb. The pin button carries the id too: one per id.
  function messages() {
    var out = [], seen = new Set();
    if (ZOOM) {
      // Each message a container with Zoom's id; the sender heads a run
      // of them and is said again in its label: "Ann to Everyone, 06:43 PM, …".
      var from = '';
      document.querySelectorAll('.chat-item-container[data-id]').forEach(function (m) {
        var id = m.getAttribute('data-id');
        var who = m.querySelector('.chat-item__sender');
        if (who) from = (who.getAttribute('data-name') || who.textContent).trim();
        var box = m.querySelector('.new-chat-message__text-content');
        if (!box || seen.has(id)) return;
        seen.add(id);
        var own = !box.classList.contains('new-chat-message__text-box--others');
        out.push({ id: id, from: own ? '' : from, own: own, text: box.textContent.trim() });
      });
      return out;
    }
    var list = chatList() || document;
    list.querySelectorAll('[data-message-id]').forEach(function (m) {
      var id = m.getAttribute('data-message-id');
      if (seen.has(id) || m.closest('button')) return;
      seen.add(id);
      var group = m.closest('div[jsname="Ypafjf"]') || m.parentElement && m.parentElement.parentElement;
      var who = group && group.querySelector('.poVWob');
      var own = !who || (group && group.classList.contains('ydIQ1d'));
      var words = (m.querySelector('[jsname="dTKtvb"]') || m).textContent.trim();
      out.push({ id: id, from: who ? who.textContent.trim() : '', own: own, text: words });
    });
    return out;
  }
  function chatList() { return document.querySelector(ZOOM ? '[aria-label="Chat Message List"]' : 'div[jsname="xySENc"]'); }
  function chatField() {
    if (ZOOM) return document.querySelector('.tiptap[contenteditable="true"]');
    if (SLACK) {
      var fields = document.querySelectorAll('[contenteditable="true"][role="textbox"], .ql-editor[contenteditable="true"]');
      for (var f = 0; f < fields.length; f++) if (visible(fields[f])) return fields[f];
      return null;
    }
    return document.querySelector('textarea[aria-label^="Send a message" i], [data-panel-id="chat"] textarea, textarea[jsname]');
  }
  // Opened by the window while it floats, so messages can be read, and
  // shut again as it goes home if it was the window that opened it.
  var openedChat = false;
  function readChat() {
    if (!host || chatList() && visible(chatList()) || openedChat) return;
    var b = chatButton();
    if (!b) return;
    b.click();
    openedChat = true;
  }
  function unreadChat() {
    if (!openedChat) return;
    openedChat = false;
    var b = chatButton();
    if (b && chatList()) b.click();
  }

  // The captions, as Meet writes them: its region, the last speaker's
  // name and words.
  // Meet's captions: a region of speaker blocks (YSxPC: the speaker
  // r4nke, the words bVV8Bd; or .nMcdL, .NWpY1d, .ygicle). Other live
  // regions say other things: a region counts only with that shape.
  var BLOCK = '[jsname="YSxPC"], .nMcdL';
  function captionsRegion() {
    var all = document.querySelectorAll('[role="region"][tabindex="0"], [role="region"][aria-label*="caption" i], [jsname="tgaKEf"], .vNKgIf.UDinHf');
    for (var i = 0; i < all.length; i++) if (all[i].querySelector(BLOCK)) return all[i];
    return null;
  }
  function captionsNow() {
    var region = captionsRegion();
    if (!region) return null;
    var blocks = region.querySelectorAll(BLOCK);
    for (var i = blocks.length - 1; i >= 0; i--) {
      var who = (blocks[i].querySelector('[jsname="r4nke"], .NWpY1d') || {}).textContent || '';
      var words = (blocks[i].querySelector('[jsname="bVV8Bd"], .ygicle') || {}).textContent || '';
      if (words.trim()) return { who: who.trim(), said: words.trim() };
    }
    return null;
  }

  // Reactions as Meet flies them: an emoji, as text or a picture's alt,
  // and whose it is.
  var reacting = new Map();       // key or name → { emoji, until, n }
  var seenReacts = new WeakSet();
  function reactions() {
    var out = [];
    if (ZOOM) {
      // Zoom flies a reaction over the tile as an icon named by its
      // code point: lazy-icon-nvf/1f44d is 👍 (270b, the hand, stays).
      document.querySelectorAll('.video-avatar__avatar .reaction-pop-up-container [class*="lazy-icon-nvf/"]').forEach(function (r) {
        if (seenReacts.has(r)) return;
        seenReacts.add(r);
        var m = /lazy-icon-nvf\/([0-9a-f-]+)/i.exec(r.getAttribute('class') || '');
        if (!m || m[1] === '270b') return;
        var emoji = m[1].split('-').map(function (h) { return String.fromCodePoint(parseInt(h, 16)); }).join('');
        var tile = r.closest('.video-avatar__avatar');
        var label = tile && tile.querySelector('.video-avatar__avatar-footer span[role="none"], .video-avatar__avatar-img');
        out.push({ emoji: emoji, who: label ? (label.alt || label.textContent || '').trim() : '' });
      });
      return out;
    }
    // No reader of Meet's flying reactions is known: these are the
    // likeliest marks, and the fixture's.
    document.querySelectorAll('[data-reaction-emoji], [jsname="t6Nwye"] img[alt]').forEach(function (r) {
      if (seenReacts.has(r)) return;
      seenReacts.add(r);
      var emoji = r.getAttribute('data-reaction-emoji') || r.getAttribute('data-emoji') || r.getAttribute('alt') || r.textContent.trim();
      var box = r.closest('[data-participant-id]');
      var who = r.getAttribute('data-reaction-from') || (r.closest('[data-reaction-from]') || {}).getAttribute && (r.closest('[data-reaction-from]') || r).getAttribute('data-reaction-from') || '';
      if (!who && box) who = ((box.querySelector('span.notranslate') || {}).textContent || '').trim();
      if (emoji) out.push({ emoji: emoji, who: (who || '').trim() });
    });
    return out;
  }

  var started = false, seenMessages = new Set(), unread = 0, bubbles = [], caps = null, capsLines = 0;
  // The chat as it went, for the thread over the open field: who, what,
  // whether it was you (sent from the window: shown at once, pending
  // until the page's own copy comes).
  var history = [], threading = false, threadEl = null, veilEl = null;
  // For a tucked window's edge: what happened since the window last read.
  var edgeEvents = [], wasRaised = new Set();
  var BUBBLE = 8000, REACT = 1200;
  // Each look: what came since the last, kept for the people it is on.
  function hear(all, now) {
    var mineName = (all.find(function (p) { return p.self; }) || {}).name;
    var list = messages();
    if (!started) { list.forEach(function (m) { seenMessages.add(m.id); }); started = true; }
    list.forEach(function (m) {
      if (seenMessages.has(m.id)) return;
      seenMessages.add(m.id);
      if (m.text) {
        var own = !!(m.own || m.from === mineName || /^you$/i.test(m.from));
        var sent = own && history.find(function (h) { return h.pending && h.text === m.text; });
        if (sent) sent.pending = false;
        else history.push({ name: m.from, text: m.text, mine: own });
        if (history.length > 30) history.shift();
      }
      if (!m.text || m.own || m.from === mineName || /^you$/i.test(m.from)) return;
      unread++;
      var person = all.find(function (p) { return p.name && p.name === m.from; });
      edgeEvents.push({ kind: 'message', name: m.from, text: m.text, face: (person && person.face) || '' });
      var key = person ? person.key : 'name:' + m.from;
      var same = bubbles.find(function (b) { return b.key === key; });
      if (same) { same.lines.push(m.text); same.at = now; same.fresh = false; return; }
      bubbles.push({ key: key, name: m.from, face: person && person.face, lines: [m.text], at: now, fresh: true });
      // Two at most: the oldest goes back into its face.
      while (bubbles.length > 2) retire(bubbles.shift());
    });
    reactions().forEach(function (r) {
      var person = all.find(function (p) { return p.name && p.name === r.who; }) || (/^you$/i.test(r.who) ? all.find(function (p) { return p.self; }) : null);
      var key = person ? person.key : 'name:' + r.who;
      // Yours, already shown as you sent it from the window.
      if (person && person.self && echoed && echoed.emoji === r.emoji && now - echoed.at < 2500) { echoed = null; return; }
      var was = reacting.get(key);
      var n = was && was.emoji === r.emoji && was.until > now ? was.n + 1 : 1;
      reacting.set(key, { emoji: r.emoji, until: now + REACT + (n - 1) * 400, n: n, fresh: true });
      if (n === 1) edgeEvents.push({ kind: 'react', name: r.who, emoji: r.emoji });
    });
  }

  function capsTall() { return capsLines ? capsLines * 17 + 6 : 0; }

  // The band along the foot, bottom up, as the design counts it: the
  // row (or its room, 14), the field, the captions; and what stands on
  // it: your picture 2 over it, a bubble too; with nothing in the band,
  // your picture 8 up and a bubble clear of the corner's marks.
  function bandTall() { return lift || capsLines ? (lift || 14) + capsTall() : 0; }
  function pictureFoot() { var band = bandTall(); return band ? band + 2 : CORNER; }
  function bubbleFoot() { var band = bandTall(); return band ? band + 2 : (marksFoot || 6); }

  // Someone new on the grid. Let in from the window: the island drew in
  // to their face, and that face flies from it to its seat as the grid
  // makes room; anyone else just fades in.
  function arrive(t, s, p) {
    if (still()) return;
    t.box.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 280, delay: 120, easing: 'ease-out', fill: 'backwards' });
    var at = admittedAt.get(p.name);
    if (!at || performance.now() - at > 8000) return;
    admittedAt.delete(p.name);
    var side = Math.min(s[3], s[4]), fs = Math.min(96, side * 0.42);
    var f = document.createElement('div');
    f.className = 'face fly';
    f.textContent = p.face ? '' : (p.name.charAt(0) || '·').toUpperCase();
    if (p.face) f.style.backgroundImage = 'url("' + p.face + '")';
    f.style.background = p.face ? '' : '#e7dcf7';
    f.style.color = '#5a2f99';
    stage.appendChild(f);
    var from = { left: pt(view / 2), top: pt((island.h ? island.y : 8) + 15), width: pt(30), height: pt(30), fontSize: pt(13) };
    var to = { left: pt(s[1] + s[3] / 2), top: pt(s[2] + s[4] / 2 + (t.shift || 0)), width: pt(fs), height: pt(fs), fontSize: pt(Math.min(40, side * 0.2)) };
    if (!t.video) t.face.animate([{ opacity: 0 }, { opacity: 0, offset: 0.99 }, { opacity: 1 }], { duration: 480 });
    f.animate([from, to], { duration: 480, easing: 'cubic-bezier(.2,.9,.25,1.1)', fill: 'forwards' }).onfinish = function () { f.remove(); };
  }

  // The people's news drawn on them: a hand, a reaction, a message;
  // the captions along the bottom, over the band.
  var placed = new Map();
  function decorate(shown, all, now) {
    hear(all, now);
    var raisedNow = new Set();
    all.forEach(function (p) {
      if (!p.hand) return;
      raisedNow.add(p.key);
      if (!p.self && !wasRaised.has(p.key)) edgeEvents.push({ kind: 'hand', name: p.name, face: p.face || '' });
    });
    // Meet's queue: first up, first; a hand down leaves its place.
    handOrder = handOrder.filter(function (k) { return raisedNow.has(k); });
    raisedNow.forEach(function (k) { if (handOrder.indexOf(k) < 0) handOrder.push(k); });
    var othersUp = new Set();
    all.forEach(function (p) { if (p.hand && !p.self) othersUp.add(p.key); });
    wasRaised = othersUp;
    if (edgeEvents.length > 20) edgeEvents.splice(0, edgeEvents.length - 20);
    placed.clear();
    shown.forEach(function (s) { placed.set(s[0].key, { x: s[1], y: s[2], w: s[3], h: s[4], corner: s[5], p: s[0] }); });
    tiles.forEach(function (t, key) {
      var at = placed.get(key);
      if (!at || !t.hand) return;
      var p = at.p, dot = at.corner === 'dot', small = at.corner === true;
      t.lifted = 0;
      // The hand: a badge 8 in on a tile (with its place in the queue
      // while more than one is up), 3 in and 16 on your picture, over
      // the edge of a circle; the ring warm at once.
      var up = !!p.hand;
      var was = t.box.classList.contains('raised');
      t.box.classList.toggle('raised', up);
      t.edge.style.boxShadow = 'inset 0 0 0 ' + pt(2) + (up ? ' #ffc24b' : ' rgba(255,255,255,.92)');
      t.hand.style.display = up ? 'flex' : 'none';
      if (up) {
        var hs = dot ? 14 : small ? 16 : 22, icon = dot ? 9 : small ? 10 : 13, inset = dot ? -5 : small ? 3 : 8;
        var place = handOrder.length > 1 && !dot && !small ? handOrder.indexOf(key) + 1 : 0;
        var said = place + '/' + hs + '/' + view;
        if (t.handSaid !== said) {
          t.handSaid = said;
          t.hand.innerHTML = '<i style="width:' + pt(icon) + ';height:' + pt(icon) + '">' + HAND + '</i>' + (place ? '<span>' + place + '</span>' : '');
        }
        var h = t.hand.style;
        h.height = h.minWidth = pt(hs);
        h.padding = place ? '0 ' + pt(6) + ' 0 ' + pt(5) : '0';
        h.gap = pt(2);
        h.fontSize = pt(11);
        h.borderRadius = pt(hs / 2);
        h.left = h.top = pt(inset);
        h.setProperty('--rise', pt(Math.max(0, at.h - inset - hs)));
        if (!was && looks > 1 && !dot) { t.hand.classList.remove('up'); void t.hand.offsetWidth; t.hand.classList.add('up'); }
      }
      // The reaction: the face gives way to it for its moment.
      var r = reacting.get(key);
      var on = r && r.until > now;
      t.react.style.display = on ? 'flex' : 'none';
      if (on) {
        var side = Math.min(at.w, at.h), size = dot ? side * 0.62 : Math.min(60, side * (t.video ? 0.46 : 0.42) * 0.9);
        t.react.style.left = '50%';
        t.react.style.top = dot ? '50%' : (t.video ? '42%' : 'calc(50% + ' + pt(t.shift || 0) + ')');
        t.react.style.width = t.react.style.height = pt(size * 1.5);
        t.react.style.fontSize = pt(size);
        t.react.style.background = t.video ? 'radial-gradient(closest-side, rgba(0,0,0,.45), transparent)' : 'transparent';
        t.react.innerHTML = r.emoji + (r.n > 1 ? '<span class="times" style="font-size:' + pt(10) + ';padding:0 ' + pt(4) + ';border-radius:' + pt(7) + ';height:' + pt(14) + '">×' + r.n + '</span>' : '');
        if (r.fresh) {
          var life = Math.max(300, r.until - now) + 'ms';
          t.react.style.setProperty('--life', life);
          t.face.style.setProperty('--life', life);
          t.react.classList.remove('on'); t.face.classList.remove('yield');
          void t.react.offsetWidth;
          t.react.classList.add('on');
          if (!t.video) t.face.classList.add('yield');
          r.fresh = false;
        }
      } else {
        t.react.classList.remove('on');
        t.face.classList.remove('yield');
      }
      // Without motion, the face simply gives its place meanwhile.
      if (!t.video) t.face.style.visibility = on && still() ? 'hidden' : 'visible';
      t.box.classList.toggle('quoted', bubbles.some(function (b) { return b.key === key; }));
    });
    // A reaction from someone not in the window: by the count of the rest.
    var more = tiles.get('+more');
    if (more && placed.has('+more')) {
      var off = null;
      reacting.forEach(function (r, key) { if (!off && r.until > now && !placed.has(key) && key !== mine) off = r; });
      var says = (off ? off.emoji : '') + '|' + more.more;
      if (more.said !== says) {
        more.said = says;
        more.box.innerHTML = (off ? '<span class="cheer on" style="font-size:' + pt(14) + '">' + off.emoji + '</span>' : '') + '<span>+' + more.more + '</span>';
      }
    }
    reacting.forEach(function (r, key) { if (r.until <= now) reacting.delete(key); });
    bubbles = bubbles.filter(function (b) { if (now - b.at < BUBBLE) return true; retire(b); return false; });
    bubbles.forEach(drawBubble);
    // Faces lifted with their bubbles, the rest back where they sit.
    tiles.forEach(function (t) { if (t.shift !== undefined && t.face) t.face.style.marginTop = pt((t.shift || 0) - (t.lifted || 0)); });
    stepOver();
    drawCaptions();
    if (threading) drawThread();
  }

  // The field open: the last messages stand over it, the newest at the
  // foot, yours at the right in color, as many as fit under the corner
  // buttons; under them the people blur and darken, the blur coming in
  // over 28 points from the thread's top so there is no edge.
  function drawThread() {
    if (!stage) return;
    if (!veilEl) { veilEl = document.createElement('div'); veilEl.className = 'veil'; stage.appendChild(veilEl); }
    if (!threadEl) { threadEl = document.createElement('div'); threadEl.className = 'thread'; stage.appendChild(threadEl); }
    stage.classList.toggle('threading', threading);
    veilEl.classList.toggle('on', threading);
    threadEl.classList.toggle('on', threading);
    if (!threading) return;
    var fw = Math.min(300, view - 28), foot = lift + 6, roof = 6 + 28 + 10;
    threadEl.style.left = pt((view - fw) / 2); threadEl.style.width = pt(fw);
    threadEl.style.bottom = pt(foot); threadEl.style.gap = pt(4);
    var said = history.map(function (h) { return h.name + '|' + h.text + '|' + h.mine; }).join('\n') + view;
    if (threadEl.dataset.said !== said) {
      threadEl.dataset.said = said;
      threadEl.innerHTML = '';
      history.slice(-6).forEach(function (h) {
        var m = document.createElement('div');
        m.className = 'm' + (h.mine ? ' mine' : '');
        m.style.fontSize = pt(11.5); m.style.lineHeight = '1.3';
        m.style.padding = pt(5) + ' ' + pt(9); m.style.borderRadius = pt(12);
        m.innerHTML = (h.mine ? '' : '<b style="font-size:' + pt(10) + '">' + escape(h.name) + '</b>') + escape(h.text);
        threadEl.appendChild(m);
      });
    }
    // As many as fit, the oldest first to go.
    var k = view / Math.max(pageW(), 1), room = winH - foot - roof;
    var rows = Array.prototype.slice.call(threadEl.children);
    rows.forEach(function (m) { m.style.display = ''; });
    for (var i = 0; i < rows.length - 1 && threadEl.offsetHeight * k > room; i++) rows[i].style.display = 'none';
    var top = winH - foot - threadEl.offsetHeight * k;
    var fade = 28;
    veilEl.style.top = pt(Math.max(0, top - fade));
    veilEl.style.setProperty('--fade', pt(fade));
  }

  // Your picture never sits on a bubble: it steps up over it, as it
  // does over the band.
  function stepOver() {
    var mineAt = null, t = null;
    placed.forEach(function (at, key) { if (at.corner === true) { mineAt = at; t = tiles.get(key); } });
    if (!mineAt || !t) return;
    var y = mineAt.y;
    bubbles.forEach(function (b) {
      var r = b.box;
      if (!r) return;
      if (r.x < mineAt.x + mineAt.w && r.x + r.w > mineAt.x && r.top < y + mineAt.h && r.top + r.h > y) y = Math.min(y, r.top - mineAt.h - 6);
    });
    y = Math.max(CORNER + (island.h && island.x + island.w > mineAt.x ? island.y + island.h : 0), y);
    if (t.stepped !== y) { if (t.stepped !== undefined) settle('glide', 340); t.stepped = y; }
    t.box.style.top = pt(y);
  }

  // A bubble gone: back into the face it came from, then away.
  function retire(b) {
    var el = b.el;
    b.el = null;
    if (!el) return;
    if (still()) return el.remove();
    el.classList.remove('in');
    el.classList.add('out');
    setTimeout(function () { el.remove(); }, 240);
  }

  // A message on whoever wrote it: under the face, its tail to it; out
  // of the name along the bottom of a camera's picture (or of a short
  // tile's, on a grid); under a face in the row over a screen; from the
  // count of the rest, their small face in it, for someone not in the
  // window. One that would run past the band lifts, and the face over
  // it lifts with it.
  function drawBubble(b) {
    if (!b.el) {
      b.el = document.createElement('div');
      b.el.className = 'bubble';
      stage.appendChild(b.el);
    }
    var el = b.el, own = placed.get(b.key), at = own || placed.get('+more');
    var away = !own;
    var face = '';
    if (away) {
      var initial = escape((b.name.charAt(0) || '·').toUpperCase());
      face = '<span class="mini" style="width:' + pt(14) + ';height:' + pt(14) + ';font-size:' + pt(7) + ';margin-right:' + pt(5) +
        (b.face ? ';background-image:url(&quot;' + escape(b.face) + '&quot;)' : '') + '">' + (b.face ? '' : initial) + '</span>';
    }
    var words = '<b style="font-size:' + pt(10.5) + ';margin-bottom:' + pt(1) + '">' + face + escape(b.name) + (b.lines.length > 1 ? ' · ' + b.lines.length : '') + '</b>' +
      b.lines.slice(-2).map(escape).join('<hr style="margin:' + pt(4) + ' 0">');
    if (b.said !== words + view) { el.innerHTML = words; b.said = words + view; }
    el.style.fontSize = pt(12); el.style.lineHeight = '1.3';
    el.style.padding = pt(7) + ' ' + pt(10);
    el.style.borderRadius = pt(14);
    var foot = bubbleFoot();
    var w, x, y = null, bottom = null, tail = null, t = null, above = null;
    if (!at) { w = Math.min(176, view - 16); x = 8; y = (island.h ? island.y + island.h + 6 : 40); }
    else if (at.corner === 'dot') { w = 176; x = Math.max(8, at.x + at.w - w + 6); y = at.y + at.h + 9; tail = { x: at.x + at.w / 2 - x - 5, y: -5 }; }
    else if (at.p.more !== undefined) {
      // Out of "+2": under it, or over it when it is in the lower half.
      w = 170; x = Math.max(8, Math.min(at.x, view - 8 - w)); y = at.y + at.h + 6; tail = { x: at.x + 12 - x, y: -5 };
      if (at.y + at.h / 2 > winH / 2) above = at;
    }
    else {
      w = Math.min(at.w - 12, 176); x = at.x + 6;
      t = tiles.get(b.key);
      if (t && !t.video && at.h >= 120) {
        var side = Math.min(at.w, at.h), fs = Math.min(96, side * 0.42);
        y = at.y + at.h / 2 + (t.shift || 0) + fs / 2 + 8; tail = { x: at.x + at.w / 2 - x - 5, y: -5 };
      } else {
        bottom = Math.max(winH - (at.y + at.h) + 6, foot);
        if (at.y + at.h < winH - 60) bottom = winH - (at.y + at.h) + 6;
      }
    }
    el.style.left = pt(x); el.style.width = pt(w);
    // Its height as laid out: the box's own, not as a grow scales it.
    var k = view / Math.max(pageW(), 1);
    var tall = el.offsetHeight * k;
    if (above) { y = Math.max(8, above.y - 6 - tall); tail.y = tall - 6; }
    if (y !== null) {
      // One that would run past the band lifts, tail and all, and the
      // face over it with it, never above the tile's top or the island.
      var over = y + tall - (winH - foot);
      if (over > 0) {
        y -= over;
        if (t) {
          var fsz = Math.min(96, Math.min(at.w, at.h) * 0.42);
          var faceTop = at.y + at.h / 2 + (t.shift || 0) - fsz / 2;
          var roof = at.y + 6;
          if (island.h && island.x < at.x + at.w && island.x + island.w > at.x) roof = Math.max(roof, island.y + island.h + 4);
          t.lifted = Math.max(0, Math.min(over, faceTop - roof));
        }
      }
      el.style.top = pt(y); el.style.bottom = 'auto';
    } else {
      el.style.top = 'auto'; el.style.bottom = pt(bottom);
    }
    var n = el.querySelector('.tail');
    if (tail) {
      if (!n) { n = document.createElement('div'); n.className = 'tail'; el.appendChild(n); }
      n.style.width = n.style.height = pt(11); n.style.left = pt(tail.x); n.style.top = pt(tail.y); n.style.borderRadius = pt(2);
    } else if (n) {
      n.remove();
    }
    el.style.setProperty('--from', tail ? pt(tail.x + 5) + ' 0' : '0 100%');
    if (b.fresh) { el.classList.add('in'); b.fresh = false; }
    b.box = { x: x, top: y !== null ? y : winH - bottom - tall, w: w, h: tall };
  }
  function escape(text) {
    return String(text).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  // Two lines along the bottom, one in a small window, over the band,
  // 18 in from the sides; the newest words, the speaker's name dimmer
  // at the start. Words come as Meet writes them; when they need a new
  // line the lines above roll up by one, as a video's captions do.
  var capsWords = '', capsHigh = 0, capsWho = '', capsSaid = '';
  function drawCaptions() {
    var now = captionsOn() ? captionsNow() : null;
    var max = view < 300 ? 1 : 2;
    if (!now) { caps.style.display = 'none'; capsLines = 0; capsWords = ''; capsHigh = 0; return; }
    caps.style.display = 'flex';
    caps.style.left = caps.style.right = pt(18);
    caps.style.fontSize = pt(11);
    caps.style.lineHeight = pt(17);
    caps.style.maxHeight = pt(17 * max);
    caps.style.bottom = pt(lift ? lift : 14);
    var roll = caps.firstChild;
    if (!roll) { roll = document.createElement('div'); caps.appendChild(roll); }
    var words = (now.who ? '<em>' + escape(now.who.split(' ')[0]) + ':</em> ' : '') + escape(now.said);
    if (words !== capsWords) {
      // The same speaker going on rolls; someone else starts afresh.
      var fresh = now.who !== capsWho || !now.said.startsWith(capsSaid.slice(0, 12));
      capsWords = words; capsWho = now.who; capsSaid = now.said;
      roll.innerHTML = '<span style="padding:' + pt(1) + ' ' + pt(4) + ';border-radius:' + pt(3) + '">' + words + '</span>';
      var high = roll.getBoundingClientRect().height, line = 17 * pageW() / Math.max(view, 1);
      if (!fresh && capsHigh && high > capsHigh + line / 2 && !still()) {
        roll.animate([{ transform: 'translateY(' + (high - capsHigh) + 'px)' }, { transform: 'none' }], { duration: 220, easing: 'cubic-bezier(.2,.8,.2,1)' });
      }
      capsHigh = high;
    }
    capsLines = max;
  }

  // Whose message is at a point of the window: answered by a click.
  function hitBubble(x, y) {
    for (var i = 0; i < bubbles.length; i++) {
      var el = bubbles[i].el;
      if (!el) continue;
      var r = el.getBoundingClientRect(), k = view / Math.max(pageW(), 1);
      var ox = crop ? crop.x : 0, oy = crop ? crop.y : 0;
      if (x >= (r.left - ox) * k && x <= (r.right - ox) * k && y >= (r.top - oy) * k && y <= (r.bottom - oy) * k) return bubbles[i];
    }
    return null;
  }
  // The bubble clicked comes down to be the field to answer it in: its
  // place, its size and its dark, over the row (where the window opens
  // the field as it gets there, CallReply.open).
  function becomeField(b) {
    bubbles = bubbles.filter(function (x) { return x !== b; });
    var el = b.el;
    b.el = null;
    if (!el) return;
    if (still()) return el.remove();
    var r = el.getBoundingClientRect();
    el.classList.remove('in');
    var tail = el.querySelector('.tail');
    if (tail) tail.remove();
    el.style.top = r.top + 'px'; el.style.bottom = 'auto'; el.style.height = r.height + 'px';
    void el.offsetWidth;
    el.classList.add('becomes');
    var fw = Math.min(300, view - 28);
    el.style.left = pt((view - fw) / 2); el.style.width = pt(fw);
    el.style.top = pt(winH - (14 + 38 + 8) - 28); el.style.height = pt(28);
    el.style.borderRadius = pt(14);
    el.style.backgroundColor = 'rgba(52,52,58,.92)';
    el.style.color = 'transparent';
    el.style.boxShadow = 'none';
    setTimeout(function () { el.remove(); }, 300);
  }

  // Words into the chat, as typed and sent: the panel opened if it is
  // shut, and shut again after.
  async function send(words) {
    history.push({ name: 'You', text: words, mine: true, pending: true });
    if (threading) drawThread();
    var field = chatField(), opened = false;
    if (!field || !visible(field)) {
      var b = chatButton();
      if (!b) return false;
      b.click();
      opened = true;
      for (var i = 0; i < 10 && !(field = chatField()); i++) await wait(100);
      if (!field) return false;
    }
    field.focus();
    if (field.isContentEditable) {
      // Zoom's editor (ProseMirror) takes words as typed ones.
      document.execCommand('selectAll', false);
      document.execCommand('insertText', false, words);
    } else {
      var set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
      set.call(field, words);
      field.dispatchEvent(new Event('input', { bubbles: true }));
    }
    await wait(200);
    var sendButton = document.querySelector('button[jsname="Jr6x1e"]') || icon(['send'], document, true) ||
      labelled(/send (a )?message|^send( now)?$/i);
    if (sendButton && !sendButton.disabled) sendButton.click();
    else field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    if (opened && !openedChat) { await wait(150); var again = chatButton(); if (again) again.click(); }
    return true;
  }

  async function react(emoji) {
    var b = reactButton();
    if (!b) return false;
    var pick = function () {
      var all = document.querySelectorAll('button, [role="button"]');
      for (var i = 0; i < all.length; i++) {
        var holder = all[i].closest('[data-emoji]');
        var label = (holder && holder.getAttribute('data-emoji')) || all[i].getAttribute('aria-label') || '';
        if (ZOOM && ZOOM_REACT[emoji] === label) return all[i];
        var img = all[i].querySelector('img[alt]');
        if (label === emoji || all[i].textContent.trim() === emoji || (img && img.alt === emoji)) return all[i];
      }
      return null;
    };
    var hit = pick();
    if (!hit) { b.click(); await wait(200); hit = pick(); }
    if (!hit) return false;
    hit.click();
    echo(emoji);
    return true;
  }
  // Yours, sent from the window: on your picture (or your circle over a
  // screen) at once, whether or not Meet marks it.
  function echo(emoji) {
    if (!mine) return;
    var now = performance.now(), was = reacting.get(mine);
    var n = was && was.emoji === emoji && was.until > now ? was.n + 1 : 1;
    reacting.set(mine, { emoji: emoji, until: now + REACT + (n - 1) * 400, n: n, fresh: true });
    echoed = { emoji: emoji, at: now };
    if (host) scan();
  }

  // Leave, as the page has it: Meet's red button, Teams', Zoom's and a
  // huddle's, and Meet's icon by name, whatever the language; Zoom then
  // asks once more.
  function leaveButton() {
    if (ZOOM) return zoomButton(/^(leave|end)$/i);
    var picks = [
      'button[jsname="CQylAd"]', '[aria-label*="leave call" i]', '#hangup-button',
      '[data-tid="hangup-main-btn"]', 'button.footer__leave-btn', '[data-qa="huddle_toolbar__leave_button"]',
      '[data-qa="huddle_channel_header_button__leave_button"]'
    ];
    for (var i = 0; i < picks.length; i++) {
      var hit = document.querySelector(picks[i]);
      if (hit) return hit;
    }
    var icons = document.querySelectorAll('i, span');
    for (var j = 0; j < icons.length; j++) {
      if (icons[j].textContent.trim() === 'call_end') return icons[j].closest('button') || icons[j];
    }
    return null;
  }
  // Share, as the page has it: Meet's by its jsname (its label and
  // icon have changed, "Present now" and present_to_all, then "Share
  // screen" and computer_arrow_up), then by what it is called, Teams',
  // Zoom's and a huddle's. Never a Stop: yab stops a share itself.
  function shareButton() {
    var meet = document.querySelector('button[jsname="hNGZQc"]');
    if (meet && visible(meet)) return meet;
    var icons = document.querySelectorAll('button i, [role="button"] i');
    for (var j = 0; j < icons.length; j++) {
      var word = icons[j].textContent.trim();
      if (word === 'computer_arrow_up' || word === 'present_to_all') {
        var b = icons[j].closest('button, [role="button"]');
        if (b && visible(b)) return b;
      }
    }
    var picks = [
      'button[aria-label="Share screen" i]', 'button[aria-label*="present now" i]', 'button[aria-label*="share screen" i]',
      'button[aria-label*="screen share" i]', '[data-tid="desktop-share-button"]', '#screenshare-button',
      '[data-qa="huddle_toolbar_screenshare_button"]', 'button.sharing-entry-button-container'
    ];
    for (var i = 0; i < picks.length; i++) {
      var all = document.querySelectorAll(picks[i]);
      for (var k = 0; k < all.length; k++) {
        if (!/stop/i.test(all[k].getAttribute('aria-label') || '') && visible(all[k])) return all[k];
      }
    }
    return null;
  }
  function visible(el) {
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  }

  // The devices, from the page's own menus. Meet keeps one for the
  // microphone, one for the speaker and one for the camera in the page
  // even while they are closed: radio items that carry the device's id
  // (data-device-id), the one in use checked. Which menu is which is
  // told by those ids against the page's own list of devices, whatever
  // the language; a pick is a click on the item, the menu opened first
  // by what opens it, when the click alone didn't take.
  var ITEM = '[role="menuitemradio"][data-device-id]';
  function wait(ms) { return new Promise(function (done) { setTimeout(done, ms); }); }
  // Kept from every look: WebKit hides the ids again once a capture is
  // ended from outside the page, and the menus' ids stay what they were.
  var kinds = {};
  async function known() {
    var list = [];
    try { list = await navigator.mediaDevices.enumerateDevices(); } catch (e) {}
    list.forEach(function (d) { if (d.deviceId) kinds[d.deviceId] = d.kind; });
    return kinds;
  }
  function named(item) {
    var span = item.querySelector('span[jsname="K4r5Ff"]');
    var text = (span && span.textContent) || item.getAttribute('aria-label') || item.innerText || item.textContent || '';
    return text.split('\n').map(function (l) { return l.trim(); }).filter(Boolean)[0] || '';
  }
  // Each menu of devices, as {kind, menu, items: [{label, on, item}]}.
  function menusOf(kinds) {
    var seen = new Map();
    document.querySelectorAll(ITEM).forEach(function (item) {
      var menu = item.closest('[role="menu"], [role="listbox"]') || item.parentElement;
      if (!seen.has(menu)) seen.set(menu, []);
      seen.get(menu).push(item);
    });
    var out = [];
    seen.forEach(function (items, menu) {
      var votes = {};
      items.forEach(function (item) {
        var kind = kinds[item.getAttribute('data-device-id')];
        if (kind) votes[kind] = (votes[kind] || 0) + 1;
      });
      var kind = Object.keys(votes).sort(function (x, y) { return votes[y] - votes[x]; })[0];
      if (!kind) return;
      out.push({ kind: kind, menu: menu, items: items.map(function (item) {
        return { label: named(item), id: item.getAttribute('data-device-id'),
                 on: item.getAttribute('aria-checked') === 'true', item: item };
      }).filter(function (d) { return d.label; }) });
    });
    return out;
  }
  var KIND = { mic: 'audioinput', speaker: 'audiooutput', camera: 'videoinput' };
  function bare(found, kind) {
    var menu = found.find(function (m) { return m.kind === kind; });
    return menu ? menu.items.map(function (d) { return { label: d.label, id: d.id, on: d.on }; }) : [];
  }
  async function readDevices() {
    var found = menusOf(await known());
    var speakers = bare(found, KIND.speaker);
    if (!speakers.length) speakers = await ownSpeakers();
    return {
      mics: bare(found, KIND.mic), speakers: speakers, cameras: bare(found, KIND.camera),
      sharable: !!shareButton()
    };
  }

  // Speakers for a page with no menu of its own for them (Meet, when it
  // thinks the browser can't choose; any other call): WebKit's own list
  // (enumerateDevices' "audiooutput", shown once the page may use the
  // microphone), and the call's sound sent to the one picked by setSinkId
  // on each of the page's audio and video elements, and on each that
  // starts playing later. Null: the page's own choice, left alone.
  var sink = null, sinkWatch = false;
  function players() { return Array.prototype.slice.call(document.querySelectorAll('audio, video')); }
  function sinkNow() {
    if (sink !== null) return sink;
    var el = players().find(function (e) { return typeof e.sinkId === 'string'; });
    return el ? el.sinkId : '';
  }
  async function ownSpeakers() {
    if (!('setSinkId' in HTMLMediaElement.prototype)) return [];
    var list = [];
    try { list = await navigator.mediaDevices.enumerateDevices(); } catch (e) {}
    var outs = list.filter(function (d) { return d.kind === 'audiooutput' && d.deviceId && d.label; });
    if (!outs.length) return [];
    var now = sinkNow();
    var out = [];
    // The Mac's own choice first, named by the device it is now (WebKit
    // lists the default output first), unless the list has its own.
    if (!outs.some(function (d) { return d.deviceId === 'default'; })) {
      out.push({ label: outs[0].label, id: 'default', on: now === '' || now === 'default' });
    }
    // WebKit's own "default" entry is the Mac's choice too: an element
    // never sent anywhere says '' for it, not 'default'.
    outs.forEach(function (d) {
      out.push({ label: d.label, id: d.deviceId, on: now === d.deviceId || (d.deviceId === 'default' && now === '') });
    });
    return out;
  }
  async function sinkTo(id) {
    if (!('setSinkId' in HTMLMediaElement.prototype)) return false;
    var want = !id || id === 'default' ? '' : id;
    sink = want;
    if (!sinkWatch) {
      sinkWatch = true;
      // Media events don't bubble, but the document sees them on the way down.
      document.addEventListener('play', function (event) {
        var el = event.target;
        if (sink !== null && el && typeof el.setSinkId === 'function' && el.sinkId !== sink) el.setSinkId(sink).catch(function () {});
      }, true);
    }
    var done = true;
    for (var el of players()) {
      if (typeof el.setSinkId !== 'function' || el.sinkId === want) continue;
      try { await el.setSinkId(want); } catch (e) { done = false; }
    }
    return done;
  }
  // Showing your screen no more, by the page's own Stop, so it ends its
  // share as it would by hand: Meet's "Stop presenting" (or "Stop
  // sharing"), by itself or in the menu its share button opens while
  // you present; Zoom's and Teams' by what they are called. False when
  // there is none, and yab ends the capture itself.
  function stopButton() {
    var zoom = ZOOM && document.querySelector('button.sharer-button--stop');
    if (zoom && visible(zoom)) return zoom;
    var all = document.querySelectorAll('[aria-label*="stop presenting" i], [aria-label*="stop shar" i], ' +
      '[data-tooltip*="stop presenting" i], [data-tooltip*="stop shar" i]');
    var any = null;
    for (var i = 0; i < all.length; i++) {
      var b = all[i].closest('button, [role="button"], [role="menuitem"]') || all[i];
      if (visible(b)) return b;
      any = any || b;
    }
    return any;
  }
  async function unshare() {
    var stop = stopButton();
    if (!stop) {
      var share = document.querySelector('button[jsname="hNGZQc"]');
      if (!share) return false;
      share.click();
      await wait(200);
      stop = stopButton();
      if (!stop) { share.click(); return false; }
    }
    stop.click();
    return true;
  }

  // What opens a menu of devices: the element that says it controls it,
  // or the one beside it that pops a menu up.
  function opener(menu) {
    if (menu.id) {
      var by = document.querySelector('[aria-controls="' + CSS.escape(menu.id) + '"]');
      if (by) return by;
    }
    var near = menu.parentElement;
    for (var up = 0; near && up < 4; up++, near = near.parentElement) {
      var hit = near.querySelector('[aria-haspopup="menu"], [aria-haspopup="true"], [aria-haspopup="listbox"]');
      if (hit && !menu.contains(hit)) return hit;
    }
    return null;
  }
  async function pickDevice(kind, label, id) {
    var want = KIND[kind];
    if (!want || !(label || id)) return false;
    var menu = menusOf(await known()).find(function (m) { return m.kind === want; });
    // No speaker menu in the page: the sound sent there by yab itself.
    if (!menu && want === KIND.speaker) {
      var out = id || ((await ownSpeakers()).find(function (d) { return d.label === label; }) || {}).id;
      return out ? sinkTo(out) : false;
    }
    if (!menu) return false;
    var hit = (id && menu.items.find(function (d) { return d.id === id; })) ||
              menu.items.find(function (d) { return d.label === label; });
    if (!hit) return false;
    if (hit.on) return true;
    var target = hit.id;
    hit.item.click();
    if (await taken(want, target, 8)) return true;
    // The click alone didn't take: open the menu, as a person would, and
    // pick in it; it closes on the pick.
    var button = opener(menu.menu);
    if (!button) return false;
    button.click();
    await wait(150);
    var again = menusOf(kinds).find(function (m) { return m.kind === want; });
    var item = again && again.items.find(function (d) { return d.id === target; });
    if (!item) return false;
    item.item.click();
    var done = await taken(want, target, 8);
    if (button.getAttribute('aria-expanded') === 'true') button.click();
    return done;
  }
  // The pick shown in the page's menu, looked for a tenth of a second
  // at a time: the page may switch the device first and tick it after.
  async function taken(kind, id, tries) {
    for (var i = 0; i < tries; i++) {
      await wait(100);
      var menu = menusOf(kinds).find(function (m) { return m.kind === kind; });
      if (menu && menu.items.some(function (d) { return d.id === id && d.on; })) return true;
    }
    return false;
  }

  return {
    on: function (width) {
      if (width > 0) view = width;
      var n = scan();
      // Under the stage, the chat's panel can be open unseen: its list
      // is where the messages are. Zoom says who you are only in its
      // participants list: read once, before the chat takes the side.
      if (ZOOM && !zoomMe) zoomLearnMe().then(function () { setTimeout(readChat, 300); });
      else setTimeout(readChat, 800);
      if (!timer) {
        // Twice a second: who joined, left, turned a camera on, and a
        // ring that should go out. Speaking itself lights it at once.
        timer = setInterval(scan, 500);
        addEventListener('resize', scan);
      }
      return n;
    },
    // The window's size in points and the part of the page it shows.
    size: function (s) {
      if (typeof s === 'number') { if (s > 0) view = s; }
      else if (s && s.w > 0 && s.cw > 0) { view = s.w; crop = { x: s.x, y: s.y, cw: s.cw, ch: s.ch }; placeHost(); }
      if (host) scan();
      return true;
    },
    names: function (on) {
      names = !!on;
      if (stage) { stage.classList.toggle('named', names); settle('regrid'); scan(); }
      return true;
    },
    // Where the window's island and marks stand (CallAsk.overlay).
    overlay: function (o) {
      island = { x: Number(o && o.x) || 0, y: Number(o && o.y) || 0, w: Number(o && o.w) || 0, h: Number(o && o.h) || 0 };
      marksFoot = Number(o && o.marks) || 0;
      if (stage) { settle('regrid'); scan(); }
      return true;
    },
    // The call's news for the window (CallNews.swift).
    news: function () {
      var hb = handButton();
      return {
        waiting: waiting().map(function (w) { return { name: w.name, face: w.face }; }),
        unread: unread, recording: recording(),
        hand: handUp(hb),
        captions: captionsOn(),
        canHand: !!hb, canCaptions: !!captionsButton(), canReact: !!reactButton(), canChat: !!chatButton(),
        events: edgeEvents.splice(0),
        talking: Array.from(spoke.values()).some(function (at) { return performance.now() - at < SPEAKING; }),
        handsUp: wasRaised.size > 0
      };
    },
    admit: function (name) {
      // Remembered, so their face flies from the island to their seat.
      var at = performance.now();
      waiting().forEach(function (w) { if (!name || w.name === name) admittedAt.set(w.name, at); });
      if (!name) {
        var all = admitButtons().find(function (b) { return /admit all/i.test(b.textContent || b.getAttribute('aria-label') || ''); });
        if (all) { all.click(); return true; }
      }
      var list = waiting(), hit = name ? list.find(function (w) { return w.name === name; }) : list[0];
      if (!name) { list.forEach(function (w) { w.button.click(); }); return list.length > 0; }
      if (!hit) return false;
      hit.button.click();
      return true;
    },
    deny: function (name) {
      var list = waiting();
      if (!name) {
        // Everyone: Meet's own Deny all where it has one, else each.
        var every = Array.prototype.find.call(document.querySelectorAll('button, [role="button"]'), function (b) {
          return /^(deny|decline) all/i.test(said(b)) && visible(b);
        });
        if (every) { every.click(); return true; }
        var denied = 0;
        list.forEach(function (w) { var b = denyIn(w.box); if (b) { b.click(); denied++; } });
        return denied > 0;
      }
      var hit = list.find(function (w) { return w.name === name; });
      var b = hit && denyIn(hit.box);
      if (!b) return false;
      b.click();
      return true;
    },
    hand: function () {
      if (ZOOM) return zoomHand();
      var b = handButton(); if (!b) return false; b.click(); return true;
    },
    captions: function () { var b = captionsButton(); if (!b) return false; b.click(); return true; },
    react: function (emoji) { return react(emoji); },
    send: function (words) { return send(words); },
    read: function () { unread = 0; return true; },
    thread: function (on) { threading = !!on; if (host) drawThread(); return true; },
    hit: function (at) {
      var b = at ? hitBubble(at.x, at.y) : null;
      if (!b) return '';
      becomeField(b);
      return b.name || 'message';
    },
    // The band along the bottom taken or free: your picture glides
    // over it or back down.
    band: function (on) {
      var to = Number(on) || 0;
      if (lift === to) return true;
      lift = to;
      band = to > 0;
      if (!stage) return true;
      stage.classList.add('glide');
      scan();
      clearTimeout(gliding);
      gliding = setTimeout(function () { if (stage) stage.classList.remove('glide'); }, 340);
      return true;
    },
    // The page's own Share, pressed: the meeting knows you present, and
    // macOS's picker asks what to show. False when it has none.
    share: function () {
      var b = shareButton();
      if (!b) return false;
      b.click();
      return true;
    },
    unshare: function () { return unshare(); },
    // What the page's own menus offer, read unseen under the stage:
    // {mics, speakers, cameras: [{label, on}], sharable}.
    devices: function () { return readDevices(); },
    // A device picked in the page's own menu: {kind, label}.
    pick: function (what) { return pickDevice(what && what.kind, what && what.label, what && what.id); },
    off: function () { unreadChat(); clear(); return true; },
    // Who the page shows, read and not drawn: for the bench and tests.
    who: function () {
      return people().map(function (p) {
        return { name: p.name, self: !!p.self, shared: !!p.shared, muted: !!p.muted, hand: !!p.hand, picture: hasPicture(p) };
      });
    },
    // The call's news and its messages, read: for the bench and tests.
    heard: function () {
      return { messages: messages(), reactions: reactions(), hand: handUp(handButton()), captions: captionsOn(),
               canHand: !!handButton(), canChat: !!chatButton(), canReact: !!reactButton(),
               share: !!shareButton(), leave: !!leaveButton() };
    },
    // For the bench: one look, in milliseconds, the mean of twenty.
    cost: function () {
      var up = !!timer, t = performance.now();
      for (var i = 0; i < 20; i++) scan();
      var ms = (performance.now() - t) / 20;
      if (!up) clear();
      return ms;
    },
    leave: function () {
      var button = leaveButton();
      if (!button) return false;
      var asks = '[role="dialog"], [role="alertdialog"], dialog[open]';
      var before = new Set(document.querySelectorAll(asks));
      button.click();
      // What the page does next comes in its own time (Meet's question
      // took longer than 400 ms): looked for until it shows, 3 s at most.
      return new Promise(function (done) {
        var tries = 0;
        (function look() {
          var buttons = Array.prototype.slice.call(document.querySelectorAll('button'));
          // Not the button just pressed: Zoom's own says "Leave" too.
          var again = buttons.find(function (b) { return b !== button && /^leave( meeting)?$/i.test(b.textContent.trim()); });
          if (again && ZOOM) {
            // Zoom asks the host who hosts next ("Assign a New Host"):
            // that is yours to answer, on the page.
            again.click();
            var waited = 0;
            return (function assign() {
              if (/assign a new host/i.test(document.body.innerText)) return done('asked');
              if (++waited < 15) return setTimeout(assign, 100);
              done(true);
            })();
          }
          if (again) { again.click(); return done(true); }
          // Meet asks the one who started the call: end it for
          // everyone, or just leave. Leave means leave: the call goes
          // on for the others.
          var only = buttons.find(function (b) { return /just leave/i.test(b.textContent) && b.getBoundingClientRect().width > 0; });
          if (only) { only.click(); return done(true); }
          // Any other question of the page's own is yours to answer, on the page.
          var ask = Array.prototype.find.call(document.querySelectorAll(asks), function (d) {
            if (before.has(d)) return false;
            var box = d.getBoundingClientRect();
            return box.width > 0 && box.height > 0 && d.querySelector('button');
          });
          if (ask && tries >= 4) return done('asked');
          if (++tries < 30) return setTimeout(look, 100);
          done(ask ? 'asked' : true);
        })();
      });
    }
  };
})();
