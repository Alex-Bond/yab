// The people on the call: their tiles on the stage, laid out as a grid or
// beside a shared screen, and who speaks when.
//
// Each tile is marked the way Meet marks its own, so a browser that knows
// Meet reads this call the same way: div[data-participant-id] with its
// data-tile-media-id (a screen shared is a tile whose media id is not its
// person's), the name in span.notranslate, the picture in an <img> served
// from /googleusercontent/, and a sound level, [jsname="QgSmzd"], whose
// class changes only while that person talks.

import { local, micMuted, cameraOff, micLevel, sinkOf } from './media.js';

const ROOM = 'spaces/rt-design-review';

export const PEOPLE = [
  {
    id: 'anna', name: 'Anna Ek', device: 212,
    bg: 'radial-gradient(120% 120% at 70% 18%, #4d2445 0%, #2b1731 55%, #141017 100%)',
    glow: 'rgba(232, 121, 165, 0.55)', ring: [236, 132, 176],
    base: '#160e17',
    blobs: [
      { c: [205, 78, 140], a: 0.55, x: 0.28, y: 0.32, r: 0.62, ax: 0.16, ay: 0.18, sx: 0.21, sy: 0.17 },
      { c: [112, 70, 190], a: 0.5, x: 0.78, y: 0.7, r: 0.66, ax: 0.14, ay: 0.16, sx: 0.15, sy: 0.23 },
      { c: [244, 150, 116], a: 0.32, x: 0.62, y: 0.16, r: 0.5, ax: 0.2, ay: 0.12, sx: 0.27, sy: 0.19 },
    ],
  },
  {
    id: 'jonas', name: 'Jonas Berg', device: 211,
    bg: 'radial-gradient(120% 120% at 28% 18%, #1d4b46 0%, #13292b 55%, #0f1617 100%)',
    glow: 'rgba(72, 204, 182, 0.5)', ring: [88, 214, 190],
    base: '#0c1516',
    blobs: [
      { c: [40, 168, 150], a: 0.55, x: 0.3, y: 0.28, r: 0.6, ax: 0.15, ay: 0.17, sx: 0.19, sy: 0.24 },
      { c: [44, 92, 170], a: 0.5, x: 0.76, y: 0.72, r: 0.68, ax: 0.17, ay: 0.14, sx: 0.23, sy: 0.16 },
      { c: [150, 214, 140], a: 0.26, x: 0.7, y: 0.2, r: 0.46, ax: 0.18, ay: 0.15, sx: 0.29, sy: 0.21 },
    ],
  },
  {
    id: 'elliot', name: 'Elliot Park', device: 213,
    bg: 'radial-gradient(120% 120% at 30% 22%, #4f3620 0%, #2c2119 55%, #15110e 100%)',
    glow: 'rgba(242, 164, 80, 0.5)', ring: [244, 170, 92],
    base: '#17110c',
    blobs: [
      { c: [214, 132, 52], a: 0.55, x: 0.3, y: 0.3, r: 0.6, ax: 0.16, ay: 0.16, sx: 0.2, sy: 0.18 },
      { c: [176, 70, 72], a: 0.42, x: 0.75, y: 0.7, r: 0.64, ax: 0.15, ay: 0.17, sx: 0.17, sy: 0.25 },
      { c: [240, 206, 120], a: 0.26, x: 0.66, y: 0.18, r: 0.46, ax: 0.18, ay: 0.12, sx: 0.26, sy: 0.2 },
    ],
  },
];

export const ME = {
  id: 'mira', name: 'Mira Lindqvist', device: 214, self: true,
  bg: 'radial-gradient(120% 120% at 62% 18%, #302a60 0%, #1c1a38 55%, #111117 100%)',
  glow: 'rgba(146, 130, 248, 0.55)',
};

for (const p of [...PEOPLE, ME]) {
  p.pid = `${ROOM}/devices/${p.device}`;
  p.avatar = `/googleusercontent/avatars/${p.id}.svg`;
}

export const byId = (id) => (id === ME.id ? ME : PEOPLE.find((p) => p.id === id) || null);

// ---------------------------------------------------------------- what they say

// A design review of the onboarding deck, said in turns and looped.
const SCRIPT = [
  ['anna', "Okay, I'm on the first-run flow now. The big change is one question per screen."],
  ['jonas', 'That already feels calmer. How many screens is it, end to end?'],
  ['anna', 'Four. Your name, your workspace, invite your team, and a short tour you can skip.'],
  ['elliot', 'Is skip on every step, or only on the tour?'],
  ['anna', 'Every step. If you skip invites, we bring them back later as a card on the home screen.'],
  ['jonas', 'I like that. Last round we lost almost a third of new people on the invite step.'],
  ['elliot', 'The card is easy on our side. We already have the slot from the setup checklist.'],
  ['anna', "Next up are the empty states. These are the ones I'd love feedback on today."],
  ['jonas', 'The illustration on the projects screen is great. Can the copy lose a line?'],
  ['anna', "Sure, I'll cut the second sentence. It only repeats the button anyway."],
  ['elliot', 'How does this look with a really long workspace name, like forty characters?'],
  ['anna', "Good catch. Right now it wraps to two lines. I'll add a truncation rule."],
  ['jonas', "Let's give the permissions step the same treatment before we ship."],
  ['elliot', 'I can have a build behind a flag by Thursday, so we can try it on real accounts.'],
  ['anna', "Perfect. I'll update the deck tonight and post the final version in the channel."],
  ['jonas', "Great, thanks Anna. Let's keep going, what's on the next slide?"],
];

const voices = new Map();   // id → { until, hold, pauses, lv }
for (const p of [...PEOPLE, ME]) voices.set(p.id, { until: 0, hold: 0, pauses: [], lv: 0, lit: false });

const turnHearers = new Set();
export function onTurn(fn) { turnHearers.add(fn); }

let line = 0;
let turnTimer = 0;
let levelTimer = 0;
let running = false;

function speak(id, ms, text) {
  const v = voices.get(id);
  const now = performance.now();
  v.until = Math.max(v.until, now + ms);
  v.pauses = text ? breaths(text, now, ms) : [];
  if (text) turnHearers.forEach((fn) => fn({ person: byId(id), text, ms }));
}

// A breath after a comma or a full stop inside a line.
function breaths(text, start, ms) {
  const words = text.split(/\s+/);
  const each = ms / words.length;
  const out = [];
  words.forEach((w, i) => {
    if (i === words.length - 1 || !/[,.?!]$/.test(w)) return;
    const at = start + each * (i + 1);
    out.push([at, at + (w.endsWith(',') ? 170 : 320)]);
  });
  return out;
}

function turn() {
  if (!running) return;
  const [id, text] = SCRIPT[line % SCRIPT.length];
  line += 1;
  const words = text.split(/\s+/).length;
  const ms = Math.round((words * 330 + 520) * (0.92 + Math.random() * 0.16));
  speak(id, ms, text);
  // Now and then someone agrees under it, briefly.
  if (ms > 2600 && Math.random() < 0.35) {
    const others = PEOPLE.filter((p) => p.id !== id);
    const who = others[Math.floor(Math.random() * others.length)].id;
    setTimeout(() => { if (running) speak(who, 420 + Math.random() * 520); }, ms * (0.45 + Math.random() * 0.4));
  }
  const gap = Math.random() < 0.14 ? 1500 + Math.random() * 1100 : 260 + Math.random() * 640;
  turnTimer = setTimeout(turn, ms + gap);
}

function setLevel(id, lv, lit) {
  const v = voices.get(id);
  const t = tiles.get(id);
  if (v.lv !== lv) {
    v.lv = lv;
    if (t) t.level.className = `tile-level lv${lv}`;
    document.querySelectorAll(`[data-bars-for="${id}"]`).forEach((b) => { b.className = `person-bars lv${lv}`; });
  }
  if (v.lit !== lit) {
    v.lit = lit;
    if (t) t.el.classList.toggle('is-speaking', lit);
  }
  const feed = feeds.get(id);
  if (feed) feed.hear(lit, lv);
}

function tickLevels() {
  const now = performance.now();
  for (const p of PEOPLE) {
    const v = voices.get(p.id);
    const speaking = now < v.until;
    let lv = 0;
    if (speaking) {
      if (!v.pauses.some(([a, b]) => now >= a && now < b)) {
        do { lv = 1 + Math.floor(Math.random() * 4); } while (lv === v.lv);
      }
      v.hold = now + 480;
    }
    setLevel(p.id, lv, speaking || now < v.hold);
  }
  // You, as your microphone hears you.
  const me = voices.get(ME.id);
  const loud = micLevel();
  if (loud > 0.07) me.until = now + 380;
  let lv = 0;
  if (now < me.until) {
    lv = loud > 0.55 ? 4 : loud > 0.35 ? 3 : loud > 0.18 ? 2 : 1;
    if (lv === me.lv) lv = lv > 1 ? lv - 1 : 2;
    me.hold = now + 420;
  }
  setLevel(ME.id, lv, now < me.until || now < me.hold);
}

// ---------------------------------------------------------------- the pictures they send

// A person whose camera is on, here: a softly moving field of their colors
// with their picture, drawn on a canvas and sent as a video stream. The
// field and the ripples are soft, so they are drawn at a quarter of the
// size and scaled up; the picture with its shadow is drawn once.
const FEED_W = 800;
const FEED_H = 450;
const SMALL = 4;
const FIELD_W = FEED_W / SMALL;
const FIELD_H = Math.round(FEED_H / SMALL);
let grain = null;
let vignette = null;

function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

function makeGrain() {
  const c = canvas(160, 160);
  const g = c.getContext('2d');
  const img = g.createImageData(160, 160);
  for (let i = 0; i < img.data.length; i += 4) {
    const n = Math.random() * 255;
    img.data[i] = img.data[i + 1] = img.data[i + 2] = n;
    img.data[i + 3] = 255;
  }
  g.putImageData(img, 0, 0);
  return c;
}

function makeVignette() {
  const c = canvas(FIELD_W, FIELD_H);
  const g = c.getContext('2d');
  const v = g.createRadialGradient(FIELD_W / 2, FIELD_H / 2, FIELD_H * 0.35, FIELD_W / 2, FIELD_H / 2, FIELD_W * 0.62);
  v.addColorStop(0, 'rgba(0,0,0,0)');
  v.addColorStop(1, 'rgba(0,0,0,0.5)');
  g.fillStyle = v;
  g.fillRect(0, 0, FIELD_W, FIELD_H);
  return c;
}

const RADIUS = FEED_H * 0.2;
const MARGIN = 48;

class Feed {
  constructor(person, host) {
    this.p = person;
    this.canvas = canvas(FEED_W, FEED_H);
    host.appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d');
    this.field = canvas(FIELD_W, FIELD_H);
    this.fctx = this.field.getContext('2d');
    this.img = new Image();
    this.img.src = person.avatar;
    this.sprite = null;
    this.seed = Math.random() * 40;
    this.lit = 0;        // eased toward 1 while speaking
    this.level = 0;      // eased sound level
    this.want = 0;
    this.talking = false;
    if (!grain) grain = makeGrain();
    if (!vignette) vignette = makeVignette();
    this.grain = this.ctx.createPattern(grain, 'repeat');
    this.draw(performance.now());
    this.stream = typeof this.canvas.captureStream === 'function' ? this.canvas.captureStream(24) : null;
  }

  hear(talking, lv) {
    this.talking = talking;
    this.want = talking ? lv / 4 : 0;
  }

  // The picture in its circle with its shadow, once it has loaded.
  makeSprite() {
    if (!this.img.complete || !this.img.naturalWidth) return null;
    const size = Math.ceil(RADIUS * 2 + MARGIN * 2);
    const c = canvas(size, size);
    const g = c.getContext('2d');
    const mid = size / 2;
    g.save();
    g.shadowColor = 'rgba(0,0,0,0.35)';
    g.shadowBlur = 30;
    g.shadowOffsetY = 10;
    g.beginPath();
    g.arc(mid, mid, RADIUS, 0, Math.PI * 2);
    g.fillStyle = '#000';
    g.fill();
    g.restore();
    g.save();
    g.beginPath();
    g.arc(mid, mid, RADIUS, 0, Math.PI * 2);
    g.clip();
    g.drawImage(this.img, mid - RADIUS, mid - RADIUS, RADIUS * 2, RADIUS * 2);
    g.restore();
    return c;
  }

  draw(now) {
    const { ctx, fctx: f, p } = this;
    const t = now / 1000 + this.seed;
    this.lit += ((this.talking ? 1 : 0) - this.lit) * 0.12;
    this.level += (this.want - this.level) * 0.3;

    // The field, small.
    f.fillStyle = p.base;
    f.fillRect(0, 0, FIELD_W, FIELD_H);
    for (const b of p.blobs) {
      const x = FIELD_W * (b.x + b.ax * Math.sin(t * b.sx + b.r * 7));
      const y = FIELD_H * (b.y + b.ay * Math.cos(t * b.sy + b.x * 5));
      const r = FIELD_W * b.r;
      const g = f.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(${b.c[0]},${b.c[1]},${b.c[2]},${b.a})`);
      g.addColorStop(1, `rgba(${b.c[0]},${b.c[1]},${b.c[2]},0)`);
      f.fillStyle = g;
      f.fillRect(0, 0, FIELD_W, FIELD_H);
    }
    f.drawImage(vignette, 0, 0);
    const cx = FEED_W / 2 + Math.sin(t * 0.37) * 6;
    const cy = FEED_H / 2 + Math.sin(t * 0.83) * 5;
    if (this.lit > 0.02) {
      const [rr, rg, rb] = p.ring;
      for (let k = 0; k < 3; k++) {
        const phase = (t * 0.55 + k / 3) % 1;
        f.beginPath();
        f.arc(cx / SMALL, cy / SMALL, (RADIUS * (1.04 + phase * 0.8 + this.level * 0.06)) / SMALL, 0, Math.PI * 2);
        f.fillStyle = `rgba(${rr},${rg},${rb},${((1 - phase) * 0.2 * this.lit).toFixed(3)})`;
        f.fill();
      }
    }

    // Scaled up, the picture over it, and a little grain so it reads as a camera's.
    ctx.globalAlpha = 1;
    ctx.drawImage(this.field, 0, 0, FEED_W, FEED_H);
    if (!this.sprite) this.sprite = this.makeSprite();
    if (this.sprite) {
      const size = this.sprite.width * (1 + this.level * 0.035 * this.lit);
      ctx.drawImage(this.sprite, cx - size / 2, cy - size / 2, size, size);
    }
    const ox = Math.floor(Math.random() * 160);
    const oy = Math.floor(Math.random() * 160);
    ctx.globalAlpha = 0.05;
    ctx.save();
    ctx.translate(-ox, -oy);
    ctx.fillStyle = this.grain;
    ctx.fillRect(ox, oy, FEED_W, FEED_H);
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  stop() {
    if (this.stream) this.stream.getTracks().forEach((t) => t.stop());
    this.canvas.remove();
  }
}

const feeds = new Map();
let frame = 0;
let lastDraw = 0;

function loop(now) {
  frame = requestAnimationFrame(loop);
  if (now - lastDraw < 40) return;
  lastDraw = now;
  feeds.forEach((f) => f.draw(now));
}

// ---------------------------------------------------------------- tiles

const tiles = new Map();     // id → { el, video, level, muted, hand }
let order = [];
let screen = null;           // { el, who }
let stageEl = null;
let tilesEl = null;
let observer = null;
let inset = 0;

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function makeTile(p) {
  const el = document.createElement('div');
  el.className = 'tile is-new';
  el.setAttribute('data-participant-id', p.pid);
  el.setAttribute('data-tile-media-id', p.pid);
  el.dataset.person = p.id;
  el.style.setProperty('--tile-bg', p.bg);
  el.style.setProperty('--glow', p.glow);
  const name = p.self
    ? `<span class="notranslate sr-only">${esc(p.name)}</span><span class="tile-name" aria-hidden="true">You</span>`
    : `<span class="notranslate tile-name">${esc(p.name)}</span>`;
  el.innerHTML = `
    <div class="tile-bg"></div>
    <div class="tile-avatar"><img src="${p.avatar}" alt="" width="256" height="256" draggable="false"></div>
    <video class="tile-video${p.self ? ' mirror' : ''}" autoplay muted playsinline></video>${p.self ? '\n    <div class="tile-note">Camera is off</div>' : ''}
    <div class="tile-foot">${name}</div>
    <div class="tile-level lv0" jsname="QgSmzd" aria-hidden="true"><i></i><i></i><i></i></div>
    <div class="tile-muted" hidden><svg class="icon"><use href="#i-mic-off"/></svg></div>
    <div class="tile-ring"></div>`;
  const t = {
    el,
    video: el.querySelector('video'),
    level: el.querySelector('[jsname="QgSmzd"]'),
    muted: el.querySelector('.tile-muted'),
    hand: null,
  };
  const ready = () => refreshVideo(p.id);
  t.video.addEventListener('loadeddata', ready);
  t.video.addEventListener('playing', ready);
  t.video.addEventListener('emptied', ready);
  return t;
}

function play(video, stream) {
  if (video.srcObject === stream) return;
  video.srcObject = stream || null;
  if (stream) {
    sinkOf(video);
    const p = video.play();
    if (p && p.catch) p.catch(() => {});
  }
}

function refreshVideo(id) {
  const t = tiles.get(id);
  if (!t) return;
  const has = t.video.srcObject && t.video.readyState >= 2 && (id !== ME.id || !cameraOff());
  t.el.classList.toggle('has-video', !!has);
}

export function mount({ stage, tiles: host, feeds: feedHost, videos }) {
  unmount();
  stageEl = stage;
  tilesEl = host;
  for (const p of PEOPLE) {
    const t = makeTile(p);
    tiles.set(p.id, t);
    if (videos.has(p.id)) {
      const feed = new Feed(p, feedHost);
      feeds.set(p.id, feed);
      play(t.video, feed.stream);
    }
  }
  tiles.set(ME.id, makeTile(ME));
  order = [...PEOPLE.map((p) => p.id), ME.id];
  for (const id of order) host.appendChild(tiles.get(id).el);
  updateSelf();
  observer = new ResizeObserver(() => layout());
  observer.observe(stage);
  layout(true);
  lastDraw = 0;
  frame = requestAnimationFrame(loop);
  running = true;
  levelTimer = setInterval(tickLevels, 110);
  turnTimer = setTimeout(turn, 700);
}

export function unmount() {
  running = false;
  clearTimeout(turnTimer);
  clearInterval(levelTimer);
  cancelAnimationFrame(frame);
  if (observer) observer.disconnect();
  observer = null;
  feeds.forEach((f) => f.stop());
  feeds.clear();
  tiles.forEach((t) => { t.video.srcObject = null; t.el.remove(); });
  tiles.clear();
  if (screen) { screen.el.querySelector('video').srcObject = null; screen.el.remove(); screen = null; }
  for (const v of voices.values()) { v.until = v.hold = 0; v.lv = 0; v.lit = false; }
}

// You: your camera, mirrored, or your picture while it is off.
export function updateSelf() {
  const t = tiles.get(ME.id);
  if (!t) return;
  play(t.video, local.self);
  refreshVideo(ME.id);
  const muted = micMuted();
  t.el.classList.toggle('is-muted', muted);
  t.muted.hidden = !muted;
}

export function setHand(id, up) {
  const t = tiles.get(id);
  if (!t) return;
  if (up && !t.hand) {
    t.hand = document.createElement('div');
    t.hand.className = 'tile-hand';
    t.hand.innerHTML = '<svg class="icon"><use href="#i-hand"/></svg><span>Hand raised</span>';
    t.el.appendChild(t.hand);
  } else if (!up && t.hand) {
    t.hand.remove();
    t.hand = null;
  }
}

// ---------------------------------------------------------------- a screen shared

export function present({ who, stream }) {
  const p = byId(who);
  if (!p || !stageEl) return;
  unpresent(true);
  const el = document.createElement('div');
  el.className = 'tile tile-screen is-new';
  el.setAttribute('data-participant-id', p.pid);
  el.setAttribute('data-tile-media-id', `${p.pid}/presentation`);
  el.dataset.person = p.id;
  el.innerHTML = `
    <video class="tile-video" autoplay muted playsinline></video>
    <div class="tile-foot"><svg class="icon"><use href="#i-present"/></svg><span class="tile-name"><span class="notranslate">${esc(p.name)}</span> is presenting</span></div>`;
  tilesEl.prepend(el);
  play(el.querySelector('video'), stream);
  screen = { el, who: p.id };
  layout();
}

export function unpresent(quiet) {
  if (!screen) return;
  const { el } = screen;
  screen = null;
  el.classList.add('is-gone');
  setTimeout(() => { el.querySelector('video').srcObject = null; el.remove(); }, 380);
  if (!quiet) layout();
}

export function presenting() { return screen ? screen.who : null; }

// Room kept along the bottom of the stage (for captions).
export function setInset(px) {
  if (inset === px) return;
  inset = px;
  layout();
}

// ---------------------------------------------------------------- layout

const GAP = 12;

function place(el, x, y, w, h) {
  const fresh = el.classList.contains('is-new');
  if (fresh) el.style.transition = 'none';
  el.style.transform = `translate3d(${Math.round(x)}px, ${Math.round(y)}px, 0)`;
  el.style.width = `${Math.round(w)}px`;
  el.style.height = `${Math.round(h)}px`;
  el.style.setProperty('--av', `${Math.round(Math.max(44, Math.min(168, Math.min(w, h) * 0.36)))}px`);
  el.classList.toggle('is-small', w < 330);
  el.classList.remove('is-gone');
  el.style.pointerEvents = '';
  if (fresh) {
    void el.offsetWidth;
    el.style.transition = '';
    setTimeout(() => el.classList.remove('is-new'), 30);
  }
}

function tuck(el) {
  el.classList.add('is-gone');
  el.style.pointerEvents = 'none';
}

function grid(list, W, H) {
  const n = list.length;
  let best = null;
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols);
    let w = (W - GAP * (cols - 1)) / cols;
    let h = (H - GAP * (rows - 1)) / rows;
    if (w / h > 16 / 9) w = h * 16 / 9;
    else if (w / h < 1.25) h = w / 1.25;
    if (!best || w * h > best.w * best.h + 1) best = { cols, rows, w, h };
  }
  const { cols, rows, w, h } = best;
  const y0 = (H - (rows * h + (rows - 1) * GAP)) / 2;
  list.forEach((el, i) => {
    const r = Math.floor(i / cols);
    const c = i % cols;
    const inRow = r === rows - 1 ? n - r * cols : cols;
    const x0 = (W - (inRow * w + (inRow - 1) * GAP)) / 2;
    place(el, x0 + c * (w + GAP), y0 + r * (h + GAP), w, h);
  });
}

export function layout(still) {
  if (!stageEl || !tilesEl) return;
  const W = stageEl.clientWidth;
  const H = Math.max(120, stageEl.clientHeight - inset);
  if (!W || !H) return;
  if (still) tilesEl.classList.add('is-still');
  const people = order.map((id) => tiles.get(id).el);
  if (screen) {
    const side = W >= 900 ? Math.round(Math.min(300, Math.max(210, W * 0.2))) : 0;
    const mainW = side ? W - side - GAP : W;
    place(screen.el, 0, 0, mainW, H);
    if (side) {
      const n = people.length;
      let h = Math.round(side * 9 / 16);
      if (n * h + (n - 1) * GAP > H) h = Math.floor((H - (n - 1) * GAP) / n);
      const w = Math.min(side, Math.round(h * 16 / 9));
      const y0 = Math.max(0, (H - (n * h + (n - 1) * GAP)) / 2);
      people.forEach((el, i) => place(el, mainW + GAP + (side - w), y0 + i * (h + GAP), w, h));
    } else {
      people.forEach(tuck);
    }
  } else {
    grid(people, W, H);
  }
  if (still) {
    void tilesEl.offsetWidth;
    tilesEl.classList.remove('is-still');
  }
}
