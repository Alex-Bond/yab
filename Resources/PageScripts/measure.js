var M = window.__yabMeasure;
if (M) { M.set(init); return; }
if (!init.on) return;
var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.yabMeasure;
function post(m) { try { if (handler) handler.postMessage(m); } catch (e) {} }

var S = { on: false, zoom: 1, guides: [], columns: false, grid: false, rems: false,
          hover: null, sel: null, alt: false, ptr: null, drag: null, pad: null, want: null,
          pins: [], notes: [], changes: [], flash: null, showIssues: false, xray: false };
var RED = '#ff2f6d', MARGIN = '#d97a00', YELLOW = '#ffd60a', YELLOW_INK = '#1c1b20', NOTE = '#8a5cf5';
// The Mac's accent, as the page resolves it: the box, its padding and the guides.
var ACCENT = (function () {
  var p = document.createElement('yab-accent');
  p.style.cssText = 'all: initial; color: -apple-system-control-accent !important;';
  (document.documentElement || document.body).appendChild(p);
  var c = getComputedStyle(p).color;
  p.remove();
  return /^rgb\(/.test(c) ? c : 'rgb(0, 122, 255)';
})();
function accent(a) { return ACCENT.replace('rgb(', 'rgba(').replace(')', ', ' + a + ')'); }
var dark = matchMedia('(prefers-color-scheme: dark)');
var host, root, cv, ctx, hit, frame = 0, observer = null, last = null;

function u() { return 1 / (S.zoom || 1); }
function R() { return 18 * u(); }
function W() { return document.documentElement.clientWidth || innerWidth; }
function H() { return document.documentElement.clientHeight || innerHeight; }
function remBase() { return parseFloat(getComputedStyle(document.documentElement).fontSize) || 16; }
function rem() { return S.rems ? remBase() : 0; }
function f(px) { return MeasureMath.fmt(px, rem()); }

function build() {
  host = document.createElement('yab-measure');
  host.setAttribute('popover', 'manual');
  root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = '<style>' + CSS + '</style><canvas></canvas><div class="hit"></div>';
  cv = root.querySelector('canvas');
  ctx = cv.getContext('2d');
  hit = root.querySelector('.hit');
  attach();
  hit.addEventListener('pointermove', move);
  hit.addEventListener('pointerdown', down);
  hit.addEventListener('pointerup', up);
  hit.addEventListener('pointercancel', up);
  hit.addEventListener('pointerleave', leave);
  hit.addEventListener('wheel', wheel, { passive: false });
  hit.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  addEventListener('keydown', key, true);
  addEventListener('keyup', key, true);
  addEventListener('blur', blur);
  addEventListener('scroll', draw, true);
  addEventListener('resize', changed);
  addEventListener('dragover', dragOver, true);
  addEventListener('drop', drop, true);
  dark.addEventListener('change', draw);
  // A hot update or a script moving things: drawn again, once a frame
  // at most, and put back if the page took the root's children away.
  observer = new MutationObserver(function () { if (!host.isConnected) attach(); changed(); });
  observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
}

function attach() {
  document.documentElement.appendChild(host);
  try { host.showPopover(); } catch (e) {}
}

function teardown() {
  if (!host) return;
  removeEventListener('keydown', key, true);
  removeEventListener('keyup', key, true);
  removeEventListener('blur', blur);
  removeEventListener('scroll', draw, true);
  removeEventListener('resize', changed);
  removeEventListener('dragover', dragOver, true);
  removeEventListener('drop', drop, true);
  dark.removeEventListener('change', draw);
  if (observer) observer.disconnect();
  if (frame) cancelAnimationFrame(frame);
  if (issueTimer) clearTimeout(issueTimer);
  compareOff();
  if (S.xray) S.xray = false;
  host.remove();
  host = null;
  delete window.__yabMeasure;
}

function set(state) {
  if (!state.on) { teardown(); return; }
  S.zoom = state.zoom || 1;
  S.guides = (state.guides || []).map(function (g) { var p = g.split(':'); return { axis: p[0], at: +p[1] }; });
  S.columns = !!state.columns; S.grid = !!state.grid; S.rems = !!state.rems;
  S.on = true;
  if (state.pick) { var el = under(state.pick.x, state.pick.y); if (el) S.sel = el; }
  dockKey = '';
  changed();
}

function save() {
  post({ k: 'guides', guides: S.guides.map(function (g) { return g.axis + ':' + (Math.round(g.at * 10) / 10); }) });
}

// What the page looks like changed: drawn again, and looked over for
// trouble once it settles.
function changed() { issuesDirty = true; scheduleIssues(); draw(); }

// MARK: what is under the pointer

function under(x, y) {
  var all = document.elementsFromPoint(x, y);
  for (var i = 0; i < all.length; i++) {
    var e = all[i];
    if (e === host || e === document.documentElement || isRef(e)) continue;
    return e;
  }
  return null;
}

function box(el) {
  var r = el.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height };
}

function label(el) {
  var name = el.tagName.toLowerCase();
  if (el.id) return name + '#' + el.id.slice(0, 24);
  var cls = typeof el.className === 'string' ? el.className.trim().split(/\s+/) : [];
  var kept = cls.filter(function (c) { return c && c.length <= 24 && !/[:\[\]\/]/.test(c); }).slice(0, 2);
  return kept.length ? name + '.' + kept.join('.') : name;
}

function path(el) {
  var parts = [];
  for (var e = el; e && e !== document.documentElement && parts.length < 4; e = e.parentElement) {
    parts.unshift(label(e));
    if (e.id) break;
  }
  return parts.join(' > ');
}

// A selector that finds this one element and no other, for WebKit's
// Elements to show it.
function unique(el) {
  var parts = [];
  for (var e = el; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
    if (e.id && document.querySelectorAll('#' + window.CSS.escape(e.id)).length === 1) { parts.unshift('#' + window.CSS.escape(e.id)); break; }
    var n = 1;
    for (var s = e.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === e.tagName) n++;
    parts.unshift(e.tagName.toLowerCase() + ':nth-of-type(' + n + ')');
  }
  return parts.join(' > ');
}

// A number for an element, kept while it lives: what the dock's word
// "what changed" is keyed by.
var ids = new WeakMap(), nextId = 1;
function idOf(el) { if (!el) return 0; var n = ids.get(el); if (!n) { n = nextId++; ids.set(el, n); } return n; }

function clearColor(c) { return !c || c === 'transparent' || /rgba\(.*,\s*0\s*\)$/.test(c) || /\/\s*0\s*\)$/.test(c); }

// A box the eye sees as one: its own ground, a border or a shadow.
function isBox(el, cs) {
  cs = cs || getComputedStyle(el);
  if (el === document.body || el === document.documentElement) return false;
  var border = ['Top', 'Right', 'Bottom', 'Left'].some(function (s) { return parseFloat(cs['border' + s + 'Width']) > 0 && cs['border' + s + 'Style'] !== 'none'; });
  return !clearColor(cs.backgroundColor) || border || (cs.boxShadow && cs.boxShadow !== 'none');
}

function ownText(el) {
  for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3 && /\S/.test(n.data)) return true;
  return false;
}

// MARK: events

function move(e) {
  last = { x: e.clientX, y: e.clientY, shift: e.shiftKey };
  S.ptr = { x: e.clientX, y: e.clientY };
  S.alt = e.altKey;
  if (S.pad) { padTo(e.clientX, e.clientY, e.shiftKey, e.altKey); return; }
  if (S.drag) { dragTo(e.clientX, e.clientY, e.shiftKey); return; }
  S.want = true;
  draw();
}

function leave() {
  if (S.drag || S.pad) return;
  S.ptr = null; S.hover = null; last = null;
  draw();
}

function guideAt(x, y) {
  var reach = 3 * u();
  for (var i = S.guides.length - 1; i >= 0; i--) {
    var g = S.guides[i];
    if (g.axis === 'v' && Math.abs(x - (g.at - scrollX)) <= reach) return i;
    if (g.axis === 'h' && Math.abs(y - (g.at - scrollY)) <= reach) return i;
  }
  return -1;
}

function down(e) {
  if (e.button !== 0) return;
  var x = e.clientX, y = e.clientY, r = R();
  e.preventDefault();
  if (x < r && y < r) { post({ k: 'menu', x: r / 2, y: r }); return; }
  if (y < r || x < r) {
    S.guides.push({ axis: y < r ? 'h' : 'v', at: y < r ? y + scrollY : x + scrollX });
    startDrag(S.guides.length - 1, e);
    return;
  }
  var g = guideAt(x, y);
  if (g >= 0) { startDrag(g, e); return; }
  if (S.sel && !S.alt) { var hd = handleAt(x, y); if (hd) { startPad(hd, e); draw(); return; } }
  var el = under(x, y);
  S.sel = el === S.sel ? null : el;
  draw();
}

function startDrag(i, e) {
  S.drag = { i: i, name: null };
  try { hit.setPointerCapture(e.pointerId); } catch (x) {}
  dragTo(e.clientX, e.clientY, e.shiftKey);
}

function dragTo(x, y, shift) {
  var g = S.guides[S.drag.i];
  var v = g.axis === 'v' ? x + scrollX : y + scrollY;
  if (shift) {
    g.at = Math.round(v / 8) * 8; S.drag.name = null;
  } else {
    var marks = [], stack = document.elementsFromPoint(x, y), sx = scrollX, sy = scrollY;
    for (var i = 0; i < stack.length && marks.length < 60; i++) {
      var e = stack[i];
      if (e === host || e === document.documentElement) continue;
      var b = box(e), n = label(e);
      if (g.axis === 'v') marks.push({ at: b.x + sx, name: n + ' left' }, { at: b.x + b.w / 2 + sx, name: n + ' center' }, { at: b.x + b.w + sx, name: n + ' right' });
      else marks.push({ at: b.y + sy, name: n + ' top' }, { at: b.y + b.h / 2 + sy, name: n + ' middle' }, { at: b.y + b.h + sy, name: n + ' bottom' });
    }
    var s = MeasureMath.snap(v, marks, 5 * u());
    // Caught, or caught by another mark: the trackpad ticks, once.
    if (s.name && (!S.drag.name || s.at !== g.at)) post({ k: 'snap' });
    g.at = s.at; S.drag.name = s.name;
  }
  draw();
}

function up(e) {
  if (S.pad) { S.pad = null; dockKey = ''; draw(); return; }
  if (!S.drag) return;
  var g = S.guides[S.drag.i], r = R();
  if ((g.axis === 'v' ? e.clientX : e.clientY) < r) S.guides.splice(S.drag.i, 1);
  S.drag = null;
  save();
  draw();
}

function wheel(e) {
  // The page under the pointer scrolls as it would: an inner scroller
  // first, then the page itself (the default, from the host).
  var el = under(e.clientX, e.clientY);
  for (var n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
    var cs = getComputedStyle(n);
    var canY = /(auto|scroll|overlay)/.test(cs.overflowY) && n.scrollHeight > n.clientHeight &&
      (e.deltaY < 0 ? n.scrollTop > 0 : n.scrollTop + n.clientHeight < n.scrollHeight);
    var canX = /(auto|scroll|overlay)/.test(cs.overflowX) && n.scrollWidth > n.clientWidth &&
      (e.deltaX < 0 ? n.scrollLeft > 0 : n.scrollLeft + n.clientWidth < n.scrollWidth);
    if ((e.deltaY && canY) || (e.deltaX && canX)) {
      e.preventDefault();
      n.scrollBy(e.deltaX, e.deltaY);
      return;
    }
  }
}

// A field of the page's own that had the keys before Measure came keeps
// its letters, space and arrows; Measure's keys with ⌘ or ⌥ still work.
function typing() {
  var a = document.activeElement;
  if (!a || a === document.body || a === host) return false;
  return a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName);
}

function key(e) {
  if (e.key === 'Alt') { S.alt = e.type === 'keydown'; draw(); return; }
  if (e.type !== 'keydown') return;
  var stop = function () { e.preventDefault(); e.stopImmediatePropagation(); };
  var plain = !e.metaKey && !e.ctrlKey && !e.altKey;
  if (e.key === 'Escape') {
    stop();
    if (S.pad) return;
    if (S.sel) { S.sel = null; draw(); }
    else if (ref) { compareOff(); dockKey = ''; draw(); }
    else post({ k: 'off' });
    return;
  }
  if (e.metaKey && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'c') {
    if (!S.sel) return;
    stop(); post({ k: 'copy', text: markdown() }); return;
  }
  // ⌥S, by its key and not its letter: the Mac's ⌥S types ß.
  if (e.altKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyS') { if (pinNow()) stop(); return; }
  if (!plain && !(e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey)) return;
  if (ref && /^Arrow/.test(e.key)) {
    var n = e.shiftKey ? 10 : 1;
    var mv = { ArrowLeft: [-n, 0], ArrowRight: [n, 0], ArrowUp: [0, -n], ArrowDown: [0, n] }[e.key];
    ref.dx += mv[0]; ref.dy += mv[1]; styleRef(); dockKey = ''; draw(); stop(); return;
  }
  if (S.sel && (e.key === 'Enter' || e.key === 'Tab')) {
    var to = e.key === 'Enter' ? (e.shiftKey ? S.sel.parentElement : S.sel.firstElementChild)
                               : (e.shiftKey ? S.sel.previousElementSibling : S.sel.nextElementSibling);
    stop();
    if (to && to !== document.documentElement && to !== host) { S.sel = to; draw(); }
    return;
  }
  if (typing() || e.shiftKey) return;
  var k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  if (k === ' ') { stop(); post({ k: 'details' }); return; }
  if (k === 'n' && S.sel) { stop(); post({ k: 'note' }); return; }
  if (k === 'x') { stop(); S.xray = !S.xray; dockKey = ''; draw(); return; }
  if (k === 'd' && ref) { stop(); ref.diff = !ref.diff; styleRef(); dockKey = ''; draw(); return; }
  if ((k === ',' || k === '.') && stepFrame(k === '.' ? 1 : -1)) { stop(); return; }
  if ((k === 'Backspace' || k === 'Delete') && !S.sel && S.pins.length) { stop(); S.pins.pop(); dockKey = ''; draw(); return; }
}

function blur() { if (S.alt) { S.alt = false; draw(); } }

// MARK: drawing

function draw() {
  if (frame || !host) return;
  frame = requestAnimationFrame(paint);
}

var placed = null;

function paint() {
  frame = 0;
  if (!host) return;
  var w = innerWidth, h = innerHeight, dpr = devicePixelRatio || 1;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
    cv.style.width = w + 'px'; cv.style.height = h + 'px';
  }
  if (S.sel && !S.sel.isConnected) S.sel = null;
  if (S.want && last && !S.drag && !S.pad) {
    S.want = false;
    S.hover = guideAt(last.x, last.y) >= 0 || last.x < R() || last.y < R() || (S.sel && !S.alt && handleAt(last.x, last.y)) ? null : under(last.x, last.y);
  }
  if (S.hover && !S.hover.isConnected) S.hover = null;
  hit.style.cursor = cursor();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  placed = [];
  if (S.xray) paintXray();
  if (S.grid) paintGrid();
  if (S.columns) paintColumns();
  var list = S.showIssues ? issues() : [];
  if (list.length) paintIssues(list);
  var sel = S.sel && box(S.sel), hov = S.hover && S.hover !== S.sel ? box(S.hover) : null;
  // ⌥ over the picked box itself: what is inside it, its spaces or its lines.
  var inside = S.alt && sel && !S.drag && !S.pad && last && (S.hover === S.sel || (!S.hover && within(last, sel)));
  if (sel) {
    if (inside) { if (textOnly(S.sel)) paintText(S.sel); else paintSpacing(S.sel); }
    else {
      paintInsides(S.sel, sel);
      // Its numbers in their bands; ⌥ puts them away for the distances.
      if (!S.alt && !S.drag) { paintNumbers(S.sel); if (isBox(S.sel) && !S.showIssues) paintInsets(S.sel); }
    }
    outline(sel, false);
  }
  if (hov) outline(hov, true);
  paintPins();
  paintNotes();
  if (sel && !S.alt && !S.drag && (S.pad || (last && within(last, sel, 8 * u())))) paintHandles(S.sel);
  if (S.flash && S.flash.isConnected) outline(box(S.flash), false);
  paintGuides();
  var kept = S.pins.some(function (p) { return (p.a === S.sel && p.b === S.hover) || (p.b === S.sel && p.a === S.hover); });
  if (sel && hov && S.alt && !inside && !kept) paintDistances(MeasureMath.distances(sel, hov), MeasureMath.inside(hov, sel) ? hov : MeasureMath.inside(sel, hov) ? sel : null);
  else if (!sel && hov && S.alt && S.hover.parentElement && S.hover.parentElement !== document.documentElement) {
    // What "the parent" is, faintly, so the lines have an edge to end on.
    ctx.save(); ctx.globalAlpha = 0.55; outline(box(S.hover.parentElement), true); ctx.restore();
    paintDistances(MeasureMath.distances(hov, box(S.hover.parentElement)), hov);
  }
  // The picked box keeps its tag while the pointer is elsewhere; each tag
  // goes where it covers less text.
  if (sel && !S.drag && !S.pad) { var ts = tagText(S.sel, sel); tag(sel, ts, tagAbove(sel, ts)); }
  if (hov && !S.drag && !S.pad) { var th = label(S.hover) + '  ' + f(hov.w) + ' × ' + f(hov.h); tag(hov, th, tagAbove(hov, th)); }
  paintRulers(sel || hov);
  tellDock();
  tickMotion();
}

function within(p, b, slop) {
  slop = slop || 0;
  return p.x >= b.x - slop && p.x <= b.x + b.w + slop && p.y >= b.y - slop && p.y <= b.y + b.h + slop;
}

// Text and nothing laid out in it: its lines are what is inside.
function textOnly(el) { return ownText(el) && !kidsOf(el).some(function (k) { return getComputedStyle(k.el).display !== 'inline'; }); }

function cursor() {
  if (S.pad) return S.pad.h.axis === 'y' ? 'ns-resize' : 'ew-resize';
  if (S.drag) return S.guides[S.drag.i].axis === 'v' ? 'col-resize' : 'row-resize';
  if (!last) return 'default';
  if (S.sel && !S.alt) { var hd = handleAt(last.x, last.y); if (hd) return hd.axis === 'y' ? 'ns-resize' : 'ew-resize'; }
  var r = R();
  if (last.x < r && last.y < r) return 'pointer';
  if (last.y < r) return 'row-resize';
  if (last.x < r) return 'col-resize';
  var g = guideAt(last.x, last.y);
  if (g >= 0) return S.guides[g].axis === 'v' ? 'col-resize' : 'row-resize';
  return 'default';
}

function colors() {
  var d = dark.matches;
  return {
    ruler: d ? 'rgba(30, 30, 34, 0.92)' : 'rgba(250, 249, 252, 0.92)',
    edge: d ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.09)',
    tick: d ? 'rgba(255, 255, 255, 0.32)' : 'rgba(0, 0, 0, 0.28)',
    text: d ? '#a4a1ae' : '#8a8892',
  };
}

function outline(b, dashed) {
  ctx.save();
  ctx.strokeStyle = ACCENT;
  ctx.lineWidth = 1.5 * u();
  if (dashed) ctx.setLineDash([4 * u(), 3 * u()]);
  ctx.strokeRect(b.x + 0.75 * u(), b.y + 0.75 * u(), Math.max(0, b.w - 1.5 * u()), Math.max(0, b.h - 1.5 * u()));
  ctx.restore();
}

function hatch() {
  var s = 6 * u(), p = document.createElement('canvas'), d = devicePixelRatio || 1;
  p.width = p.height = Math.ceil(s * d);
  var c = p.getContext('2d');
  c.scale(d, d);
  c.fillStyle = accent(0.08); c.fillRect(0, 0, s, s);
  c.strokeStyle = accent(0.55); c.lineWidth = 1 * u();
  c.beginPath(); c.moveTo(0, s); c.lineTo(s, 0); c.stroke();
  var pat = ctx.createPattern(p, 'repeat');
  if (pat && pat.setTransform) pat.setTransform(new DOMMatrix().scale(1 / d));
  return pat;
}

function paintInsides(el, b) {
  var cs = getComputedStyle(el);
  var p = [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(parseFloat);
  var m = [cs.marginTop, cs.marginRight, cs.marginBottom, cs.marginLeft].map(function (v) { return parseFloat(v) || 0; });
  var bw = [cs.borderTopWidth, cs.borderRightWidth, cs.borderBottomWidth, cs.borderLeftWidth].map(function (v) { return parseFloat(v) || 0; });
  ctx.fillStyle = 'rgba(255, 159, 10, 0.14)';
  if (m[0] > 0) ctx.fillRect(b.x, b.y - m[0], b.w, m[0]);
  if (m[2] > 0) ctx.fillRect(b.x, b.y + b.h, b.w, m[2]);
  if (m[3] > 0) ctx.fillRect(b.x - m[3], b.y, m[3], b.h);
  if (m[1] > 0) ctx.fillRect(b.x + b.w, b.y, m[1], b.h);
  ctx.fillStyle = accent(0.14);
  var ix = b.x + bw[3], iy = b.y + bw[0], iw = b.w - bw[1] - bw[3], ih = b.h - bw[0] - bw[2];
  if (p[0]) ctx.fillRect(ix, iy, iw, p[0]);
  if (p[2]) ctx.fillRect(ix, iy + ih - p[2], iw, p[2]);
  if (p[3]) ctx.fillRect(ix, iy + p[0], p[3], ih - p[0] - p[2]);
  if (p[1]) ctx.fillRect(ix + iw - p[1], iy + p[0], p[1], ih - p[0] - p[2]);
  // A flex or grid box's gaps, between the children laid out in it.
  var flow = cs.display.indexOf('flex') >= 0 || cs.display.indexOf('grid') >= 0;
  var rowGap = parseFloat(cs.rowGap) || 0, colGap = parseFloat(cs.columnGap) || 0;
  if (!flow || (!rowGap && !colGap)) return;
  var kids = [];
  for (var k = el.firstElementChild; k && kids.length < 200; k = k.nextElementSibling) {
    var kb = box(k);
    if (kb.w || kb.h) kids.push(kb);
  }
  var pat = hatch();
  for (var i = 0; i < kids.length - 1; i++) {
    var a = kids[i], c = kids[i + 1];
    if (rowGap && c.y >= a.y + a.h - 0.5) {
      var gy = a.y + a.h, gh = c.y - gy;
      if (gh > 0.5) { ctx.fillStyle = pat; ctx.fillRect(ix + p[3], gy, iw - p[1] - p[3], gh); }
    } else if (colGap && c.x >= a.x + a.w - 0.5) {
      var gx = a.x + a.w, gw = c.x - gx;
      if (gw > 0.5) { ctx.fillStyle = pat; ctx.fillRect(gx, Math.min(a.y, c.y), gw, Math.max(a.y + a.h, c.y + c.h) - Math.min(a.y, c.y)); }
    }
  }
}

// A distance of nothing: a short bar along the touching edge, and its
// number past the edge, out of the box whose edge it is, never on the
// letters.
function zeroMark(x1, y1, horizontal, v, side) {
  ctx.save();
  ctx.fillStyle = RED;
  if (horizontal) ctx.fillRect(x1 - 1 * u(), y1 - 6 * u(), 2 * u(), 12 * u());
  else ctx.fillRect(x1 - 6 * u(), y1 - 1 * u(), 12 * u(), 2 * u());
  ctx.restore();
  var t = f(Math.max(0, v || 0)), w = width(t) / 2 + 4 * u();
  var out = side ? (side === 'top' || side === 'left' ? -1 : 1) : horizontal ? (x1 < innerWidth / 2 ? -1 : 1) : (y1 < innerHeight / 2 ? -1 : 1);
  pill(horizontal ? x1 + out * w : x1, horizontal ? y1 : y1 + out * 13 * u(), t, RED, horizontal ? out : 1);
}

function paintDistances(lines, ref0) {
  ctx.save();
  ctx.strokeStyle = RED;
  ctx.lineWidth = 1 * u();
  lines.forEach(function (l) {
    if (!l.dash && l.v < 0.5) return;
    ctx.setLineDash(l.dash ? [3 * u(), 3 * u()] : []);
    ctx.beginPath(); ctx.moveTo(l.x1, l.y1); ctx.lineTo(l.x2, l.y2); ctx.stroke();
  });
  ctx.restore();
  lines.forEach(function (l) {
    if (l.dash) return;
    if (l.v < 0.5) {
      // Out from the inner box the line ends at, when there is one.
      var hz = l.y1 === l.y2, sd = ref0 ? (hz ? (l.x1 <= ref0.x + ref0.w / 2 ? 'left' : 'right') : (l.y1 <= ref0.y + ref0.h / 2 ? 'top' : 'bottom')) : null;
      zeroMark(l.x1, l.y1, hz, l.v, sd);
    } else pill((l.x1 + l.x2) / 2, (l.y1 + l.y2) / 2, f(l.v), RED);
  });
}

function paintGuides() {
  ctx.save();
  ctx.lineWidth = 1 * u();
  S.guides.forEach(function (g, i) {
    var hot = S.drag && S.drag.i === i;
    ctx.strokeStyle = hot ? ACCENT : accent(0.8);
    ctx.beginPath();
    if (g.axis === 'v') { var x = g.at - scrollX; ctx.moveTo(x, 0); ctx.lineTo(x, innerHeight); }
    else { var y = g.at - scrollY; ctx.moveTo(0, y); ctx.lineTo(innerWidth, y); }
    ctx.stroke();
  });
  ctx.restore();
  if (S.drag) {
    var g = S.guides[S.drag.i], t = f(g.at) + (S.drag.name ? '  ' + S.drag.name : '');
    if (g.axis === 'v') pill(g.at - scrollX, R() + 16 * u(), t, ACCENT);
    else pill(R() + 12 * u() + width(t) / 2, g.at - scrollY, t, ACCENT);
  }
}

function paintGrid() {
  ctx.save();
  ctx.strokeStyle = 'rgba(255, 47, 109, 0.09)';
  ctx.lineWidth = 1 * u();
  ctx.beginPath();
  for (var x = -(scrollX % 8); x < innerWidth; x += 8) { ctx.moveTo(x, 0); ctx.lineTo(x, innerHeight); }
  for (var y = -(scrollY % 8); y < innerHeight; y += 8) { ctx.moveTo(0, y); ctx.lineTo(innerWidth, y); }
  ctx.stroke();
  ctx.restore();
}

// Twelve columns over the page's content: the widest box in the middle
// of the page narrower than the page, or the page less 24 on each side.
var content = null, contentAt = 0;
function contentBox() {
  var now = performance.now();
  if (content && now - contentAt < 500) return content;
  contentAt = now;
  var w = W(), best = null;
  var stack = document.elementsFromPoint(w / 2, Math.min(H() - 1, R() + 80 * u()));
  for (var i = 0; i < stack.length; i++) {
    var e = stack[i];
    if (e === host || e === document.documentElement || e === document.body) continue;
    var b = box(e);
    if (b.w < w - 1 && b.w >= w * 0.4 && (!best || b.w > best.w)) best = b;
  }
  content = best ? { x: best.x, w: best.w } : { x: 24, w: w - 48 };
  return content;
}

function paintColumns() {
  var c = contentBox(), n = 12, gut = 24, cw = (c.w - gut * (n - 1)) / n;
  if (cw <= 0) return;
  ctx.fillStyle = 'rgba(255, 47, 109, 0.07)';
  for (var i = 0; i < n; i++) ctx.fillRect(c.x + i * (cw + gut), 0, cw, innerHeight);
}

function font(size, weight) { return (weight || 600) + ' ' + size * u() + 'px -apple-system, BlinkMacSystemFont, sans-serif'; }
function width(t) { ctx.font = font(11); return ctx.measureText(t).width + 10 * u(); }

function round(x, y, w, h, r) {
  ctx.beginPath();
  if (ctx.roundRect) ctx.roundRect(x, y, w, h, r); else ctx.rect(x, y, w, h);
}

// No number lands on another: it steps past what it hits, along its own
// line (to the right, then the left; the other way first when `dir` is
// -1, a 0 stepping out, off the letters), and only then off it.
function room(px, py, w, h, dir) {
  if (!placed) return { x: px, y: py };
  var g = 4 * u();
  var hits = function (qx, qy) { return placed.filter(function (r) { return qx < r.x + r.w + 2 * u() && qx + w + 2 * u() > r.x && qy < r.y + r.h + 2 * u() && qy + h + 2 * u() > r.y; })[0]; };
  var free = function (qx) { return qx >= R() + 2 * u() && qx + w <= innerWidth - 2 * u(); };
  if (hits(px, py)) {
    var rx = px, lx = px, done = false, k;
    var right = function () { for (k = 0; k < 6 && !done; k++) { var hr = hits(rx, py); if (!hr) { if (free(rx)) { px = rx; done = true; } break; } rx = hr.x + hr.w + g; } };
    var left = function () { for (k = 0; k < 6 && !done; k++) { var hl = hits(lx, py); if (!hl) { if (free(lx)) { px = lx; done = true; } break; } lx = hl.x - w - g; } };
    if (dir < 0) { left(); right(); } else { right(); left(); }
    if (!done) { var dy = [h + g, -(h + g)]; for (k = 0; k < 2; k++) if (!hits(px, py + dy[k])) { py += dy[k]; break; } }
  }
  placed.push({ x: px, y: py, w: w, h: h });
  return { x: px, y: py };
}

function pill(x, y, t, color, dir) {
  var w = width(t), h = 18 * u();
  var px = Math.min(Math.max(x - w / 2, R() + 2 * u()), innerWidth - w - 2 * u());
  var py = Math.min(Math.max(y - h / 2, R() + 2 * u()), innerHeight - h - 2 * u());
  var at = room(px, py, w, h, dir);
  ctx.fillStyle = color;
  round(at.x, at.y, w, h, 5 * u()); ctx.fill();
  ctx.fillStyle = '#fff';
  ctx.font = font(11);
  ctx.textBaseline = 'middle';
  ctx.fillText(t, at.x + 5 * u(), at.y + h / 2 + 0.5 * u());
}

// A tag on its side of the box; where something is drawn there already
// (another tag, a trouble's words), it stands off that, the same way
// first, then on the other side.
function tag(b, t, above) {
  var w = width(t), h = 18 * u(), gap = 6 * u(), top = R() + 2 * u(), foot = innerHeight - h - 2 * u();
  var x = Math.min(Math.max(b.x, R() + 2 * u()), innerWidth - w - 2 * u());
  function side(up) {
    var y = up ? b.y - h - gap : b.y + b.h + gap;
    if (!up && y > foot) y = b.y - h - gap;
    if (y < top) y = Math.min(foot, Math.max(top, b.y + gap));
    return y;
  }
  function hits(y) { return placed.some(function (r) { return x < r.x + r.w + 2 * u() && x + w + 2 * u() > r.x && y < r.y + r.h + 2 * u() && y + h + 2 * u() > r.y; }); }
  var y = side(above), k;
  if (hits(y)) {
    var tries = [];
    for (k = 1; k <= 3; k++) tries.push(side(above) + (above ? -1 : 1) * k * (h + 2 * u()));
    tries.push(side(!above));
    for (k = 1; k <= 3; k++) tries.push(side(!above) + (above ? 1 : -1) * k * (h + 2 * u()));
    for (k = 0; k < tries.length; k++) if (tries[k] >= top && tries[k] <= foot && !hits(tries[k])) { y = tries[k]; break; }
  }
  placed.push({ x: x, y: y, w: w, h: h });
  ctx.fillStyle = ACCENT;
  round(x, y, w, h, 5 * u()); ctx.fill();
  ctx.fillStyle = '#fff';
  ctx.font = font(11);
  ctx.textBaseline = 'middle';
  ctx.fillText(t, x + 5 * u(), y + h / 2 + 0.5 * u());
}

// A tag goes above when the room below has more text under it than the
// room above, over the tag's whole height and a little past it.
function tagAbove(b, t) {
  var w = width(t), h = 18 * u(), gap = 6 * u();
  function busy(top) {
    var n = 0;
    [top - 3 * u(), top + h / 2, top + h + 3 * u()].forEach(function (y) {
      for (var k = 0; k < 5; k++) { var e = under(b.x + 4 * u() + (w - 8 * u()) * k / 4, y); if (e && e !== S.sel && ownText(e)) n++; }
    });
    return n;
  }
  if (b.y - gap - h < R() + 2 * u()) return false;
  return busy(b.y - gap - h) < busy(b.y + b.h + gap);
}

// The picked box's tag says what matters for its kind: text its type,
// color and contrast; a box its corner and ground.
function tagText(el, b) {
  var t = label(el) + '  ' + f(b.w) + ' × ' + f(b.h);
  var i = info(el), cs = getComputedStyle(el), bits = [];
  if (ownText(el)) {
    bits.push(f(parseFloat(cs.fontSize)) + '/' + (cs.lineHeight === 'normal' ? 'normal' : f(parseFloat(cs.lineHeight))) + ' ' + cs.fontWeight);
    bits.push(i.color);
    var c = contrast(el, cs), need = contrastNeed(cs);
    if (c) bits.push(c >= need ? (c >= (need === 3 ? 4.5 : 7) ? 'AAA ' : 'AA ') + c.toFixed(1) : 'contrast ' + c.toFixed(1));
  } else {
    if (i.radius) bits.push('r ' + i.radius);
    if (i.bg) bits.push(i.bg);
  }
  return bits.length ? t + '  ·  ' + bits.join('  ·  ') : t;
}

function paintRulers(span) {
  var c = colors(), r = R(), w = innerWidth, h = innerHeight, sx = scrollX, sy = scrollY, base = rem();
  ctx.fillStyle = c.ruler;
  ctx.fillRect(0, 0, w, r);
  ctx.fillRect(0, r, r, h - r);
  ctx.fillStyle = c.edge;
  ctx.fillRect(r, r - u(), w - r, u());
  ctx.fillRect(r - u(), r, u(), h - r);
  ctx.fillRect(0, r - u(), r, u());
  if (span) {
    ctx.fillStyle = accent(0.16);
    ctx.fillRect(Math.max(r, span.x), 0, Math.max(0, span.x + span.w - Math.max(r, span.x)), r - u());
    ctx.fillRect(0, Math.max(r, span.y), r - u(), Math.max(0, span.y + span.h - Math.max(r, span.y)));
  }
  // Ticks every 10 pixels, longer every 50, a number every 100; in rems
  // every half rem, a number every 5.
  var minor = base ? base / 2 : 10, every = 10, mid = base ? 2 : 5;
  ctx.strokeStyle = c.tick;
  ctx.fillStyle = c.text;
  ctx.lineWidth = u();
  ctx.font = font(9, 500);
  ctx.textBaseline = 'alphabetic';
  ctx.beginPath();
  var start = Math.floor(sx / minor) * minor;
  for (var v = start; v - sx < w; v += minor) {
    var x = v - sx, n = Math.round(v / minor);
    if (x < r) continue;
    var big = n % every === 0, t = big ? 7 : n % mid === 0 ? 5 : 3;
    ctx.moveTo(x + 0.5 * u(), r); ctx.lineTo(x + 0.5 * u(), r - t * u());
  }
  start = Math.floor(sy / minor) * minor;
  for (v = start; v - sy < h; v += minor) {
    var y = v - sy; n = Math.round(v / minor);
    if (y < r) continue;
    big = n % every === 0; t = big ? 7 : n % mid === 0 ? 5 : 3;
    ctx.moveTo(r, y + 0.5 * u()); ctx.lineTo(r - t * u(), y + 0.5 * u());
  }
  ctx.stroke();
  // The numbers, but none under a span's end, whose own number is there.
  var ends = span ? { x: [span.x, span.x + span.w], y: [span.y, span.y + span.h] } : { x: [], y: [] };
  var clear = function (p, axis) { return ends[axis].every(function (e) { return Math.abs(p + 12 * u() - e) > 22 * u(); }); };
  var step = minor * every;
  for (v = Math.floor(sx / step) * step; v - sx < w; v += step) {
    x = v - sx;
    if (x < r || !clear(x, 'x')) continue;
    ctx.fillText(base ? String(Math.round(v / base * 100) / 100) : String(Math.round(v)), x + 3 * u(), 9 * u());
  }
  for (v = Math.floor(sy / step) * step; v - sy < h; v += step) {
    y = v - sy;
    if (y < r || !clear(y - 24 * u(), 'y')) continue;
    ctx.save(); ctx.translate(9 * u(), y - 3 * u()); ctx.rotate(-Math.PI / 2);
    ctx.fillText(base ? String(Math.round(v / base * 100) / 100) : String(Math.round(v)), 0, 0);
    ctx.restore();
  }
  // The span's ends, numbered; else where the pointer is.
  if (span) {
    mark('x', span.x, f(span.x + sx)); mark('x', span.x + span.w, f(span.x + span.w + sx));
    mark('y', span.y, f(span.y + sy)); mark('y', span.y + span.h, f(span.y + span.h + sy));
  } else if (S.ptr && !S.drag && S.ptr.x >= r && S.ptr.y >= r) {
    ctx.fillStyle = ACCENT;
    ctx.fillRect(S.ptr.x, 0, u(), r - u());
    ctx.fillRect(0, S.ptr.y, r - u(), u());
  }
  // Where the guides stand.
  ctx.fillStyle = ACCENT;
  S.guides.forEach(function (g) {
    var p = g.at - (g.axis === 'v' ? sx : sy), k = 4 * u(), d = 6 * u();
    if (p < r) return;
    ctx.beginPath();
    if (g.axis === 'v') { ctx.moveTo(p - k, r - d); ctx.lineTo(p + k, r - d); ctx.lineTo(p, r); }
    else { ctx.moveTo(r - d, p - k); ctx.lineTo(r - d, p + k); ctx.lineTo(r, p); }
    ctx.fill();
  });
  // The corner: the menu.
  ctx.strokeStyle = c.text;
  ctx.lineWidth = 1.4 * u();
  ctx.beginPath();
  ctx.moveTo(r / 2 - 3 * u(), r / 2 - 1.5 * u()); ctx.lineTo(r / 2, r / 2 + 1.5 * u()); ctx.lineTo(r / 2 + 3 * u(), r / 2 - 1.5 * u());
  ctx.stroke();
}

function mark(axis, p, t) {
  var r = R();
  if (p < r || p > (axis === 'x' ? innerWidth : innerHeight)) return;
  ctx.font = font(9);
  var w = ctx.measureText(t).width + 6 * u(), h = 11 * u();
  ctx.fillStyle = ACCENT;
  if (axis === 'x') {
    ctx.fillRect(p - w / 2, u(), w, h);
    ctx.fillStyle = '#fff'; ctx.textBaseline = 'middle';
    ctx.fillText(t, p - w / 2 + 3 * u(), u() + h / 2 + 0.5 * u());
  } else {
    ctx.save(); ctx.translate(u(), p + w / 2); ctx.rotate(-Math.PI / 2);
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = '#fff'; ctx.textBaseline = 'middle';
    ctx.fillText(t, 3 * u(), h / 2 + 0.5 * u());
    ctx.restore();
  }
}

// MARK: what is inside a box

// Where the content is drawn: its text's letters (and pictures,
// controls), not the boxes holding them. A line's box is the font's
// whole height; the letters are less, from the baseline as high and as
// low as they reach.
var inkCtx = null, glyphCache = {};
function glyphs(node, cs) {
  var text = node.data.trim().slice(0, 300), fnt = cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily, k = fnt + '|' + text;
  if (glyphCache[k]) return glyphCache[k];
  inkCtx = inkCtx || document.createElement('canvas').getContext('2d');
  inkCtx.font = fnt;
  var m = inkCtx.measureText(text);
  return (glyphCache[k] = { asc: m.fontBoundingBoxAscent, desc: m.fontBoundingBoxDescent, up: m.actualBoundingBoxAscent, down: m.actualBoundingBoxDescent, left: Math.min(0, m.actualBoundingBoxLeft) });
}

function ink(el, textOnly0) {
  var a = null, n = 0, range = document.createRange();
  function add(r) {
    if (!r.width || !r.height) return;
    if (!a) a = { x1: r.left, y1: r.top, x2: r.right, y2: r.bottom };
    else { a.x1 = Math.min(a.x1, r.left); a.y1 = Math.min(a.y1, r.top); a.x2 = Math.max(a.x2, r.right); a.y2 = Math.max(a.y2, r.bottom); }
  }
  var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (var node = walker.nextNode(); node && n < 800; node = walker.nextNode()) {
    n++;
    if (node.nodeType === 3) {
      if (!/\S/.test(node.data) || !node.parentElement) continue;
      var pcs = getComputedStyle(node.parentElement);
      if (pcs.visibility === 'hidden' || pcs.display === 'none') continue;
      var g = glyphs(node, pcs);
      range.selectNodeContents(node);
      var rs = range.getClientRects();
      for (var i = 0; i < rs.length; i++) {
        var r = rs[i], base = r.top + r.height * g.asc / (g.asc + g.desc || 1);
        add({ left: r.left - g.left, right: r.right, top: base - g.up, bottom: base + g.down, width: r.width, height: g.up + g.down });
      }
    } else if (!textOnly0 && /^(img|svg|canvas|video|input|button|textarea|select|iframe|picture)$/i.test(node.tagName)) {
      add(node.getBoundingClientRect());
    }
  }
  return a && { x: a.x1, y: a.y1, w: a.x2 - a.x1, h: a.y2 - a.y1 };
}

function inner(el, cs) {
  cs = cs || getComputedStyle(el);
  var b = box(el), bw = function (s) { return parseFloat(cs['border' + s + 'Width']) || 0; };
  return { x: b.x + bw('Left'), y: b.y + bw('Top'), w: b.w - bw('Left') - bw('Right'), h: b.h - bw('Top') - bw('Bottom') };
}

function union(list) {
  if (!list.length) return null;
  var x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
  list.forEach(function (b) { x1 = Math.min(x1, b.x); y1 = Math.min(y1, b.y); x2 = Math.max(x2, b.x + b.w); y2 = Math.max(y2, b.y + b.h); });
  return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
}

function kidsOf(el) {
  var out = [];
  for (var k = el.firstElementChild; k && out.length < 80; k = k.nextElementSibling) {
    if (k === host || isRef(k)) continue;
    var b = box(k);
    if (b.w < 0.5 && b.h < 0.5) continue;
    out.push({ el: k, b: b });
  }
  return out;
}

// How far a box's content sits in from its own edges, each side, to the
// boxes it holds and to the letters drawn in it; less than nothing is
// past the edge.
function insets(el) {
  var cs = getComputedStyle(el), i0 = inner(el, cs);
  var held = union(kidsOf(el).map(function (k) { return k.b; }));
  var text = ink(el, true);
  var to = function (k) { return k && { top: k.y - i0.y, right: i0.x + i0.w - (k.x + k.w), bottom: i0.y + i0.h - (k.y + k.h), left: k.x - i0.x, at: k }; };
  return { box: i0, held: to(held || text), text: to(text) };
}

// The edges a box's letters stand closer than 4 to: a red bar on the
// edge and the number past it. On the boxes the eye sees, and not on
// small ones, whose numbers would crowd them.
function paintInsets(el) {
  var t = insets(el), i0 = t.box, k = t.text;
  if (!k || i0.w < 90 || i0.h < 44) return;
  var a = k.at, cx = a.x + a.w / 2, cy = a.y + a.h / 2;
  [['top', cx, i0.y, false], ['bottom', cx, i0.y + i0.h, false], ['left', i0.x, cy, true], ['right', i0.x + i0.w, cy, true]].forEach(function (l) {
    var v = k[l[0]];
    if (v < 4 && v > -1) zeroMark(l[1], l[2], l[3], v, l[0]);
  });
}

// Every number of the picked box in the band it measures: padding in the
// middle of its band, margin outside in orange a quarter along, one
// number for the gaps between rows and one for those between columns.
function paintNumbers(el) {
  var cs = getComputedStyle(el), b = box(el), i0 = inner(el, cs);
  var p = ['Top', 'Right', 'Bottom', 'Left'].map(function (s) { return parseFloat(cs['padding' + s]) || 0; });
  var m = ['Top', 'Right', 'Bottom', 'Left'].map(function (s) { return parseFloat(cs['margin' + s]) || 0; });
  if (p[0] >= 1) pill(i0.x + i0.w / 2, i0.y + p[0] / 2, f(p[0]), ACCENT);
  if (p[2] >= 1) pill(i0.x + i0.w / 2, i0.y + i0.h - p[2] / 2, f(p[2]), ACCENT);
  if (p[3] >= 1) pill(i0.x + p[3] / 2, i0.y + i0.h / 2, f(p[3]), ACCENT);
  if (p[1] >= 1) pill(i0.x + i0.w - p[1] / 2, i0.y + i0.h / 2, f(p[1]), ACCENT);
  if (m[0] >= 1) pill(b.x + b.w / 4, b.y - m[0] / 2, f(m[0]), MARGIN);
  if (m[2] >= 1) pill(b.x + b.w * 3 / 4, b.y + b.h + m[2] / 2, f(m[2]), MARGIN);
  if (m[3] >= 1) pill(b.x - m[3] / 2, b.y + b.h / 4, f(m[3]), MARGIN);
  if (m[1] >= 1) pill(b.x + b.w + m[1] / 2, b.y + b.h / 4, f(m[1]), MARGIN);
  if (!/flex|grid/.test(cs.display)) return;
  var kids = kidsOf(el), done = { x: false, y: false };
  kids.forEach(function (a) {
    kids.forEach(function (c) {
      if (a === c) return;
      var oy = Math.min(a.b.y + a.b.h, c.b.y + c.b.h) - Math.max(a.b.y, c.b.y);
      var ox = Math.min(a.b.x + a.b.w, c.b.x + c.b.w) - Math.max(a.b.x, c.b.x);
      if (!done.x && oy > 1 && c.b.x >= a.b.x + a.b.w - 0.5) {
        done.x = true;
        var gx = c.b.x - (a.b.x + a.b.w);
        if (gx >= 1) pill((a.b.x + a.b.w + c.b.x) / 2, Math.max(a.b.y, c.b.y) + Math.min(oy, 40 * u()) / 2, f(gx), ACCENT);
      }
      if (!done.y && ox > 1 && c.b.y >= a.b.y + a.b.h - 0.5) {
        done.y = true;
        var gy = c.b.y - (a.b.y + a.b.h);
        if (gy >= 1) pill(Math.max(a.b.x, c.b.x) + Math.min(ox, 80 * u()) / 2, (a.b.y + a.b.h + c.b.y) / 2, f(gy), ACCENT);
      }
    });
  });
}

// ⌥ over a picked box: every space inside it at once, from its edges to
// the boxes it holds and between each pair of neighbours, zeros too.
function paintSpacing(el) {
  var cs = getComputedStyle(el), i0 = inner(el, cs), kids = kidsOf(el);
  if (!kids.length) return;
  var lines = [];
  kids.forEach(function (a, n) {
    var below = null, right = null;
    kids.forEach(function (c, m) {
      if (m === n) return;
      var ox = Math.min(a.b.x + a.b.w, c.b.x + c.b.w) - Math.max(a.b.x, c.b.x);
      var oy = Math.min(a.b.y + a.b.h, c.b.y + c.b.h) - Math.max(a.b.y, c.b.y);
      if (ox > 1 && c.b.y >= a.b.y + a.b.h - 0.5 && (!below || c.b.y < below.b.y)) below = c;
      if (oy > 1 && c.b.x >= a.b.x + a.b.w - 0.5 && (!right || c.b.x < right.b.x)) right = c;
    });
    if (below) {
      var x1 = Math.max(a.b.x, below.b.x), x2 = Math.min(a.b.x + a.b.w, below.b.x + below.b.w), x = (x1 + x2) / 2;
      lines.push({ x1: x, y1: a.b.y + a.b.h, x2: x, y2: below.b.y, v: below.b.y - (a.b.y + a.b.h), dash: false });
    }
    if (right) {
      var y1 = Math.max(a.b.y, right.b.y), y2 = Math.min(a.b.y + a.b.h, right.b.y + right.b.h), y = (y1 + y2) / 2;
      lines.push({ x1: a.b.x + a.b.w, y1: y, x2: right.b.x, y2: y, v: right.b.x - (a.b.x + a.b.w), dash: false });
    }
  });
  var pat = hatch();
  ctx.save(); ctx.fillStyle = pat;
  lines.forEach(function (l) {
    if (l.v < 0.5) return;
    if (l.x1 === l.x2) ctx.fillRect(Math.max(i0.x, l.x1 - 40 * u()), l.y1, 80 * u(), l.v);
    else ctx.fillRect(l.x1, Math.max(i0.y, l.y1 - 20 * u()), l.v, 40 * u());
  });
  ctx.restore();
  // From its edges to what it holds, the boxes this time, not the letters.
  var t = insets(el), k = t.held;
  if (k) {
    var a = k.at, cx = a.x + a.w / 2, cy = a.y + a.h / 2;
    lines.push({ x1: cx, y1: i0.y, x2: cx, y2: a.y, v: k.top, dash: false });
    lines.push({ x1: cx, y1: a.y + a.h, x2: cx, y2: i0.y + i0.h, v: k.bottom, dash: false });
    lines.push({ x1: i0.x, y1: cy, x2: a.x, y2: cy, v: k.left, dash: false });
    lines.push({ x1: a.x + a.w, y1: cy, x2: i0.x + i0.w, y2: cy, v: k.right, dash: false });
  }
  paintDistances(lines.filter(function (l) { return l.v > -1; }), k ? k.at : null);
  // Each child's own outline, faint, so the spaces read as between them.
  ctx.save(); ctx.strokeStyle = accent(0.45); ctx.lineWidth = 1 * u(); ctx.setLineDash([3 * u(), 2 * u()]);
  kids.forEach(function (c) { ctx.strokeRect(c.b.x + 0.5 * u(), c.b.y + 0.5 * u(), c.b.w - u(), c.b.h - u()); });
  ctx.restore();
}

// ⌥ over picked text: its lines, the leading hatched, the baseline, the
// cap and x heights, and the step from line to line.
var metricsCache = {};
function metrics(cs) {
  var k = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  if (metricsCache[k]) return metricsCache[k];
  var c = document.createElement('canvas').getContext('2d');
  c.font = cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  var Hm = c.measureText('H'), x = c.measureText('x');
  return (metricsCache[k] = { asc: Hm.fontBoundingBoxAscent, desc: Hm.fontBoundingBoxDescent, cap: Hm.actualBoundingBoxAscent, xh: x.actualBoundingBoxAscent });
}

function lineRects(el) {
  var out = [], range = document.createRange();
  for (var n = el.firstChild; n; n = n.nextSibling) {
    if (n.nodeType !== 3 || !/\S/.test(n.data)) continue;
    range.selectNodeContents(n);
    var rs = range.getClientRects();
    for (var i = 0; i < rs.length; i++) {
      var r = rs[i], lst = out[out.length - 1];
      if (lst && Math.abs(lst.y - r.top) < 1) { lst.x2 = Math.max(lst.x2, r.right); continue; }
      out.push({ x: r.left, x2: r.right, y: r.top, h: r.height });
    }
  }
  return out;
}

function paintText(el) {
  var cs = getComputedStyle(el), m = metrics(cs), lines = lineRects(el);
  if (!lines.length) return;
  var lh = cs.lineHeight === 'normal' ? null : parseFloat(cs.lineHeight);
  var pat = hatch(), area = m.asc + m.desc;
  lines.forEach(function (l, n) {
    var base = l.y + l.h * (m.asc / area), w = l.x2 - l.x;
    var top = lh ? l.y - (lh - l.h) / 2 : l.y, boxH = lh || l.h;
    ctx.save();
    ctx.fillStyle = pat; ctx.globalAlpha = 0.7;
    if (lh && lh > l.h) { ctx.fillRect(l.x, top, w, l.y - top); ctx.fillRect(l.x, l.y + l.h, w, top + boxH - l.y - l.h); }
    ctx.globalAlpha = 1;
    ctx.strokeStyle = accent(0.55); ctx.lineWidth = u();
    ctx.strokeRect(l.x + 0.5 * u(), top + 0.5 * u(), w - u(), boxH - u());
    ctx.strokeStyle = RED; ctx.lineWidth = 1 * u();
    ctx.beginPath(); ctx.moveTo(l.x - 6 * u(), base + 0.5 * u()); ctx.lineTo(l.x2 + 6 * u(), base + 0.5 * u()); ctx.stroke();
    ctx.setLineDash([2 * u(), 2 * u()]);
    ctx.strokeStyle = 'rgba(255, 47, 109, 0.75)';
    ctx.beginPath(); ctx.moveTo(l.x, base - m.cap + 0.5 * u()); ctx.lineTo(l.x2, base - m.cap + 0.5 * u()); ctx.stroke();
    ctx.strokeStyle = 'rgba(255, 47, 109, 0.45)';
    ctx.beginPath(); ctx.moveTo(l.x, base - m.xh + 0.5 * u()); ctx.lineTo(l.x2, base - m.xh + 0.5 * u()); ctx.stroke();
    ctx.restore();
    if (n === 0) {
      ctx.save();
      ctx.font = font(9, 600); ctx.textBaseline = 'middle'; ctx.fillStyle = RED;
      var ex = Math.min(l.x2 + 9 * u(), innerWidth - 60 * u());
      ctx.fillText('baseline', ex, base);
      ctx.globalAlpha = 0.8; ctx.fillText('cap ' + f(m.cap), ex, base - m.cap);
      if (m.cap - m.xh > 8 * u()) { ctx.globalAlpha = 0.6; ctx.fillText('x ' + f(m.xh), ex, base - m.xh); }
      ctx.restore();
    }
  });
  if (lines.length > 1) {
    var a = lines[0], b = lines[1];
    var b1 = a.y + a.h * (m.asc / area), b2 = b.y + b.h * (m.asc / area), x = a.x - 14 * u();
    ctx.save(); ctx.strokeStyle = RED; ctx.lineWidth = u();
    ctx.beginPath(); ctx.moveTo(x, b1); ctx.lineTo(x, b2); ctx.moveTo(x - 3 * u(), b1); ctx.lineTo(x + 3 * u(), b1); ctx.moveTo(x - 3 * u(), b2); ctx.lineTo(x + 3 * u(), b2); ctx.stroke();
    ctx.restore();
    pill(x - 2 * u(), (b1 + b2) / 2, f(b2 - b1), RED);
  }
}

// X: every box of the page at once, its color by depth, its padding tinted.
function depth(el) { var d = 0; for (var e = el; e && e !== document.body; e = e.parentElement) d++; return d; }
function paintXray() {
  if (!document.body) return;
  var all = document.body.getElementsByTagName('*'), hues = [212, 330, 40, 160, 270, 12];
  ctx.save();
  ctx.lineWidth = u();
  for (var k = 0; k < all.length && k < 2500; k++) {
    var el = all[k];
    if (el === host || isRef(el)) continue;
    var b = box(el);
    if (b.w < 1 || b.h < 1 || b.y > innerHeight || b.y + b.h < 0) continue;
    var cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'contents') continue;
    var hue = hues[depth(el) % hues.length];
    ctx.strokeStyle = 'hsla(' + hue + ', 90%, 62%, 0.85)';
    ctx.fillStyle = 'hsla(' + hue + ', 90%, 62%, 0.06)';
    ctx.fillRect(b.x, b.y, b.w, b.h);
    ctx.strokeRect(b.x + 0.5 * u(), b.y + 0.5 * u(), b.w - u(), b.h - u());
    var p = [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(parseFloat);
    if (p[0] || p[1] || p[2] || p[3]) {
      ctx.fillStyle = 'hsla(' + hue + ', 90%, 62%, 0.12)';
      if (p[0]) ctx.fillRect(b.x, b.y, b.w, p[0]);
      if (p[2]) ctx.fillRect(b.x, b.y + b.h - p[2], b.w, p[2]);
      if (p[3]) ctx.fillRect(b.x, b.y + p[0], p[3], b.h - p[0] - p[2]);
      if (p[1]) ctx.fillRect(b.x + b.w - p[1], b.y + p[0], p[1], b.h - p[0] - p[2]);
    }
  }
  ctx.restore();
}

// MARK: kept measurements and notes

// ⌥S keeps what is measured now: the picked box to the one under the
// pointer, or, with nothing picked, the box to its parent. Kept, it is
// measured again every frame, so it lives through scrolling and edits.
function pinNow() {
  if (S.sel && S.hover && S.hover !== S.sel) S.pins.push({ a: S.sel, b: S.hover });
  else if (!S.sel && S.hover && S.hover.parentElement && S.hover.parentElement !== document.documentElement) S.pins.push({ a: S.hover, b: S.hover.parentElement });
  else return false;
  dockKey = ''; draw();
  return true;
}

// A line's side of the box it starts from; a line of no length by the
// edge it sits on.
function sideOf(a) {
  return function (l) {
    var across = l.y1 === l.y2 && (l.x1 !== l.x2 || Math.abs(l.x1 - a.x) < 0.6 || Math.abs(l.x1 - a.x - a.w) < 0.6);
    return across ? (Math.min(l.x1, l.x2) < a.x + a.w / 2 ? 'left' : 'right') : (Math.min(l.y1, l.y2) < a.y + a.h / 2 ? 'above' : 'below');
  };
}
// Said from the inner box when one holds the other, else from the first.
function pinWords(p) {
  var a = box(p.a), b = box(p.b), side = sideOf(MeasureMath.inside(b, a) ? b : a);
  return MeasureMath.distances(a, b).filter(function (l) { return !l.dash; }).map(function (l) { return f(l.v) + ' ' + side(l); }).join(', ');
}

function paintPins() {
  S.pins = S.pins.filter(function (p) { return p.a.isConnected && p.b.isConnected; });
  S.pins.forEach(function (p) {
    var a = box(p.a), b = box(p.b), lines = MeasureMath.distances(a, b);
    ctx.save();
    ctx.strokeStyle = 'rgba(255, 47, 109, 0.5)'; ctx.lineWidth = u(); ctx.setLineDash([2 * u(), 2 * u()]);
    ctx.strokeRect(a.x + 0.5 * u(), a.y + 0.5 * u(), a.w - u(), a.h - u());
    ctx.strokeRect(b.x + 0.5 * u(), b.y + 0.5 * u(), b.w - u(), b.h - u());
    ctx.restore();
    paintDistances(lines, MeasureMath.inside(a, b) ? a : MeasureMath.inside(b, a) ? b : null);
    // The pin: a white dot at each number's start.
    lines.forEach(function (l) {
      if (l.dash || l.v < 0.5) return;
      var mx = (l.x1 + l.x2) / 2, my = (l.y1 + l.y2) / 2, w = width(f(l.v));
      var px = Math.min(Math.max(mx - w / 2, R() + 2 * u()), innerWidth - w - 2 * u());
      var py = Math.min(Math.max(my - 9 * u(), R() + 2 * u()), innerHeight - 20 * u());
      ctx.fillStyle = '#fff'; ctx.strokeStyle = RED; ctx.lineWidth = 1.5 * u();
      ctx.beginPath(); ctx.arc(px, py, 3.5 * u(), 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    });
  });
}

function paintNotes() {
  S.notes = S.notes.filter(function (n) { return n.el.isConnected; });
  S.notes.forEach(function (n, i) {
    var b = box(n.el), r0 = 10 * u(), x = Math.min(b.x + b.w - r0 - 2 * u(), innerWidth - r0 - 2 * u()), y = Math.max(b.y + r0 + 2 * u(), R() + r0 + 2 * u());
    ctx.save();
    ctx.fillStyle = NOTE; ctx.strokeStyle = '#fff'; ctx.lineWidth = 2 * u();
    ctx.beginPath(); ctx.arc(x, y, r0, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.fillStyle = '#fff'; ctx.font = font(11, 700); ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(String(i + 1), x, y + 0.5 * u());
    ctx.restore();
  });
}

// MARK: padding and gaps pulled by hand

function handles(el) {
  var cs = getComputedStyle(el), i0 = inner(el, cs), out = [];
  var p = { top: parseFloat(cs.paddingTop) || 0, right: parseFloat(cs.paddingRight) || 0, bottom: parseFloat(cs.paddingBottom) || 0, left: parseFloat(cs.paddingLeft) || 0 };
  var cx = i0.x + i0.w / 2, cy = i0.y + i0.h / 2;
  if (i0.w < 60 || i0.h < 40) return out;
  out.push({ prop: 'padding-top', axis: 'y', sign: 1, v: p.top, x: cx, y: i0.y + p.top });
  out.push({ prop: 'padding-bottom', axis: 'y', sign: -1, v: p.bottom, x: cx, y: i0.y + i0.h - p.bottom });
  out.push({ prop: 'padding-left', axis: 'x', sign: 1, v: p.left, x: i0.x + p.left, y: cy });
  out.push({ prop: 'padding-right', axis: 'x', sign: -1, v: p.right, x: i0.x + i0.w - p.right, y: cy });
  if (/flex|grid/.test(cs.display)) {
    var kids = kidsOf(el), done = { x: false, y: false };
    kids.forEach(function (a) {
      kids.forEach(function (c) {
        if (a === c) return;
        if (!done.x && c.b.x >= a.b.x + a.b.w - 0.5 && Math.min(a.b.y + a.b.h, c.b.y + c.b.h) - Math.max(a.b.y, c.b.y) > 1) {
          done.x = true;
          out.push({ prop: 'column-gap', axis: 'x', sign: 1, v: parseFloat(cs.columnGap) || 0, x: (a.b.x + a.b.w + c.b.x) / 2, y: Math.max(a.b.y, c.b.y) + Math.min(a.b.h, c.b.h) / 2, gap: true });
        }
        if (!done.y && c.b.y >= a.b.y + a.b.h - 0.5 && Math.min(a.b.x + a.b.w, c.b.x + c.b.w) - Math.max(a.b.x, c.b.x) > 1) {
          done.y = true;
          out.push({ prop: 'row-gap', axis: 'y', sign: 1, v: parseFloat(cs.rowGap) || 0, x: Math.max(a.b.x, c.b.x) + Math.min(a.b.w, c.b.w) / 2, y: (a.b.y + a.b.h + c.b.y) / 2, gap: true });
        }
      });
    });
  }
  return out;
}

function handleAt(x, y) {
  if (!S.sel) return null;
  var hs = handles(S.sel), r = 7 * u();
  for (var i = 0; i < hs.length; i++) if (Math.abs(hs[i].x - x) <= (hs[i].axis === 'y' ? 14 * u() : r) && Math.abs(hs[i].y - y) <= (hs[i].axis === 'y' ? r : 14 * u())) return hs[i];
  return null;
}

// Only the handle the pointer is near, as Figma shows a frame's: all of
// them at once stood on the box's own numbers.
function paintHandles(el) {
  var hot = S.pad ? S.pad.h.prop : (last ? (handleAt(last.x, last.y) || {}).prop : null);
  var near = function (h) { return S.pad ? h.prop === S.pad.h.prop : last && Math.abs(h.x - last.x) <= 40 * u() && Math.abs(h.y - last.y) <= 24 * u(); };
  handles(el).filter(near).forEach(function (h) {
    var w = (h.axis === 'y' ? 22 : 6) * u(), hh = (h.axis === 'y' ? 6 : 22) * u();
    ctx.save();
    ctx.fillStyle = h.prop === hot ? (h.gap ? RED : ACCENT) : '#fff';
    ctx.strokeStyle = h.gap ? RED : ACCENT; ctx.lineWidth = 1.5 * u();
    round(h.x - w / 2, h.y - hh / 2, w, hh, 3 * u()); ctx.fill(); ctx.stroke();
    ctx.restore();
    if (h.prop === hot) pill(h.x + (h.axis === 'x' ? 22 * u() : 0), h.y + (h.axis === 'y' ? 16 * u() : 0), h.prop.replace('padding-', 'padding ') + '  ' + f(h.v), h.gap ? RED : ACCENT);
  });
}

function ruleFor(el, prop) {
  var rules = rulesFor(el);
  var short = prop.indexOf('padding') === 0 ? 'padding' : prop.indexOf('gap') >= 0 ? 'gap' : prop;
  for (var i = 0; i < rules.length; i++) {
    var list = props(rules[i].rule.style);
    if (list.indexOf(prop) >= 0 || list.indexOf(short) >= 0) return rules[i];
  }
  return rules[0] || null;
}

function startPad(h, e) {
  S.pad = { h: h, from: { x: e.clientX, y: e.clientY }, v0: h.v, rule: ruleFor(S.sel, h.prop) };
  try { hit.setPointerCapture(e.pointerId); } catch (x) {}
}

// Dragged by 4s, by 1s with ⇧; with ⌥ both sides at once.
function padTo(x, y, shift, alt) {
  var p = S.pad, h = p.h, d = h.axis === 'y' ? y - p.from.y : x - p.from.x;
  var v = Math.max(0, p.v0 + d * h.sign * (h.gap ? 2 : 1));
  v = shift ? Math.round(v) : Math.round(v / 4) * 4;
  if (!p.rule) return;
  if (v !== h.v) {
    if (v !== p.last) post({ k: 'snap' });
    p.last = v;
    edit(p.rule, h.prop, v + 'px');
    if (alt && !h.gap) edit(p.rule, { 'padding-top': 'padding-bottom', 'padding-bottom': 'padding-top', 'padding-left': 'padding-right', 'padding-right': 'padding-left' }[h.prop], v + 'px');
    h.v = v;
  }
  draw();
}

// MARK: trouble, found by looking and said in words

var found = [], issuesDirty = true, issueTimer = 0, issuesVersion = 0;
// At most once in 0.8 s, so a page that never stops changing (a clock,
// a ticker) is still looked over, and not on every change.
function scheduleIssues() {
  if (issueTimer) return;
  issueTimer = setTimeout(function () { issueTimer = 0; if (host && issuesDirty) { lookForIssues(); dockKey = ''; draw(); } }, 800);
}
function issues() { if (issuesDirty && !issueTimer) lookForIssues(); return found; }

function lookForIssues() {
  issuesDirty = false;
  var out = [], all = document.body ? document.body.getElementsByTagName('*') : [];
  for (var k = 0; k < all.length && k < 3000; k++) {
    var el = all[k];
    if (el === host || isRef(el)) continue;
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.display === 'contents') continue;
    var b = box(el);
    if (b.w < 1 || b.h < 1) continue;
    if (cs.position === 'fixed' && b.w >= innerWidth - 1 && b.h >= innerHeight - 1) continue;
    var clips = /hidden|clip/.test(cs.overflowX + ' ' + cs.overflowY);
    var scrolls = /auto|scroll/.test(cs.overflowX + ' ' + cs.overflowY);
    if (isBox(el, cs)) {
      var t = insets(el), spill = [], edge = [];
      if (t.text) ['top', 'right', 'bottom', 'left'].forEach(function (s) {
        var v = t.text[s];
        if (v < -1) spill.push([s, -v]);
        else if (v < 4) edge.push([s, Math.max(0, v)]);
      });
      if (spill.length && !clips && !scrolls) out.push({ kind: 'spill', el: el, sides: spill, title: 'Spills out', words: spill.map(function (p) { return f(p[1]) + ' past the ' + p[0]; }).join(', ') });
      if (edge.length) out.push({ kind: 'edge', el: el, sides: edge, title: 'Text at the edge', words: edge.map(function (p) { return f(p[1]) + ' ' + p[0]; }).join(', ') });
    }
    if (clips && !scrolls && cs.textOverflow !== 'ellipsis' && (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1) && /\S/.test(el.textContent)) {
      var dy = el.scrollHeight - el.clientHeight, dx = el.scrollWidth - el.clientWidth;
      out.push({ kind: 'clip', el: el, title: 'Cut off', words: dy > 1 ? f(dy) + ' hidden below' : f(dx) + ' hidden on the right' });
    }
    if (ownText(el)) {
      var ratio = contrast(el, cs), need = contrastNeed(cs);
      if (ratio && ratio < need) out.push({ kind: 'contrast', el: el, ratio: ratio, title: 'Low contrast', words: ratio.toFixed(1) + ' : 1, needs ' + need });
    }
  }
  // What makes the page scroll sideways: the outermost box past its right.
  var docW = document.documentElement.clientWidth;
  if (document.documentElement.scrollWidth > docW + 1 && document.body) {
    var wide = null;
    for (k = 0; k < all.length && k < 3000; k++) {
      var e2 = all[k];
      if (e2 === host || isRef(e2)) continue;
      var r2 = e2.getBoundingClientRect();
      if (r2.right + scrollX > docW + 1 && getComputedStyle(e2).position !== 'fixed') { if (!wide || !wide.contains(e2)) { wide = e2; break; } }
    }
    if (wide) out.push({ kind: 'wide', el: wide, title: 'Scrolls sideways', words: f(wide.getBoundingClientRect().right + scrollX - docW) + ' past the page' });
  }
  found = out;
  issuesVersion++;
}

function rgba(css) {
  var m = /rgba?\(\s*([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)/.exec(css || '');
  if (!m) return null;
  var a = m[4] === undefined ? 1 : (m[4].slice(-1) === '%' ? parseFloat(m[4]) / 100 : +m[4]);
  return [+m[1], +m[2], +m[3], a];
}
function lum(c) {
  var t = c.slice(0, 3).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  return 0.2126 * t[0] + 0.7152 * t[1] + 0.0722 * t[2];
}
function groundOf(el) {
  for (var e = el; e; e = e.parentElement) {
    var c = rgba(getComputedStyle(e).backgroundColor);
    if (c && c[3] > 0) return c;
  }
  return dark.matches && /dark/.test(getComputedStyle(document.documentElement).colorScheme || '') ? [18, 18, 18, 1] : [255, 255, 255, 1];
}
function contrast(el, cs) {
  cs = cs || getComputedStyle(el);
  var fg = rgba(cs.color), bg = groundOf(el);
  if (!fg) return null;
  var a = fg[3] * (parseFloat(cs.opacity) || 1);
  var mix = [0, 1, 2].map(function (i) { return fg[i] * a + bg[i] * (1 - a); });
  var l1 = lum(mix), l2 = lum(bg);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}
function contrastNeed(cs) {
  var px = parseFloat(cs.fontSize), w = parseFloat(cs.fontWeight) || 400;
  return px >= 24 || (px >= 18.66 && w >= 700) ? 3 : 4.5;
}

var tape = null, tapeZoom = 0;
function hazard() {
  if (tape && tapeZoom === S.zoom) return tape;
  tapeZoom = S.zoom;
  var s = 8 * u(), p = document.createElement('canvas'), d = devicePixelRatio || 1;
  p.width = p.height = Math.ceil(s * d);
  var c = p.getContext('2d');
  c.scale(d, d);
  c.fillStyle = 'rgba(255, 214, 10, 0.18)'; c.fillRect(0, 0, s, s);
  c.strokeStyle = 'rgba(255, 214, 10, 0.75)'; c.lineWidth = 2 * u();
  c.beginPath(); c.moveTo(-1, s / 2 + 1); c.lineTo(s / 2 + 1, -1); c.moveTo(s / 2 - 1, s + 1); c.lineTo(s + 1, s / 2 - 1); c.stroke();
  tape = ctx.createPattern(p, 'repeat');
  if (tape && tape.setTransform) tape.setTransform(new DOMMatrix().scale(1 / d));
  return tape;
}

function flag(b, t, where) {
  ctx.font = font(11);
  var w = ctx.measureText(t).width + 12 * u(), h = 18 * u(), g = 4 * u(), x, y;
  if (where === 'after') { x = b.x + b.w + 8 * u(); y = b.y + b.h / 2 - h / 2; }
  else { x = b.x; y = where === 'below' ? b.y + b.h + g : b.y - h - g; if (y < R() + 2 * u()) y = b.y + g; }
  x = Math.min(Math.max(x, R() + 2 * u()), innerWidth - w - 2 * u());
  placed.push({ x: x, y: y, w: w, h: h });
  ctx.fillStyle = YELLOW;
  round(x, y, w, h, 5 * u()); ctx.fill();
  ctx.fillStyle = YELLOW_INK;
  ctx.textBaseline = 'middle';
  ctx.fillText(t, x + 6 * u(), y + h / 2 + 0.5 * u());
}

function paintIssues(list) {
  list.forEach(function (it) {
    if (!it.el.isConnected) return;
    var b = box(it.el);
    if (b.y + b.h < 0 || b.y > innerHeight) return;
    ctx.save();
    if (it.kind === 'edge') {
      // The tape runs just outside the edge the letters are too close to.
      var wd = 5 * u();
      ctx.fillStyle = hazard();
      it.sides.forEach(function (p) {
        var s = p[0];
        if (s === 'top') ctx.fillRect(b.x, b.y - wd, b.w, wd);
        if (s === 'bottom') ctx.fillRect(b.x, b.y + b.h, b.w, wd);
        if (s === 'left') ctx.fillRect(b.x - wd, b.y, wd, b.h);
        if (s === 'right') ctx.fillRect(b.x + b.w, b.y, wd, b.h);
      });
    } else if (it.kind === 'spill') {
      var t = insets(it.el).text, i1 = inner(it.el);
      ctx.fillStyle = hazard();
      it.sides.forEach(function (p) {
        var s = p[0], v = p[1], at = t ? t.at : b;
        if (s === 'bottom') ctx.fillRect(i1.x, i1.y + i1.h, i1.w, v);
        if (s === 'top') ctx.fillRect(i1.x, i1.y - v, i1.w, v);
        if (s === 'right') ctx.fillRect(i1.x + i1.w, at.y, v, at.h);
        if (s === 'left') ctx.fillRect(i1.x - v, at.y, v, at.h);
      });
    } else {
      var kb = it.kind === 'contrast' ? (ink(it.el, true) || b) : b;
      ctx.strokeStyle = YELLOW; ctx.lineWidth = 1.5 * u(); ctx.setLineDash([4 * u(), 3 * u()]);
      ctx.strokeRect(kb.x - 3 * u(), kb.y - 3 * u(), kb.w + 6 * u(), kb.h + 6 * u());
    }
    ctx.restore();
    var at2 = it.kind === 'contrast' ? (ink(it.el, true) || b) : b;
    if (it.kind === 'spill') { var dn = it.sides.filter(function (p) { return p[0] === 'bottom'; })[0]; if (dn) at2 = { x: b.x, y: b.y, w: b.w, h: b.h + dn[1] }; }
    if (it.kind === 'edge') at2 = { x: b.x, y: b.y - 5 * u(), w: b.w, h: b.h };
    flag(at2, it.title + '  ' + it.words, it.kind === 'contrast' ? 'after' : it.kind === 'spill' || it.kind === 'wide' ? 'below' : 'above');
  });
}

// MARK: the rules

// A selector's weight: ids, then classes, attributes and pseudo-classes,
// then elements and pseudo-elements. Close enough to the cascade's to
// say which of a few rules wins.
function weight(sel) {
  var t = sel.replace(/:(not|is|where|has)\(([^()]*)\)/g, ' $2 ');
  var a = (t.match(/#[\w-]+/g) || []).length;
  var b = (t.match(/\.[\w-]+|\[[^\]]*\]|:(?!:)[\w-]+/g) || []).length;
  var c = (t.replace(/::?[\w-]+|#[\w-]+|\.[\w-]+|\[[^\]]*\]/g, ' ').match(/(^|[\s>+~(])[a-z][\w-]*/gi) || []).length + (t.match(/::[\w-]+/g) || []).length;
  return a * 10000 + b * 100 + c;
}

// A rule's properties as written, shorthands kept: the declaration
// lists them one longhand at a time, its text as they were put.
function props(style) {
  return style.cssText.split(/;(?![^(]*\))/).map(function (d) { return d.slice(0, d.indexOf(':')).trim(); }).filter(Boolean);
}

function matchedWeight(el, text) {
  var best = -1;
  text.split(',').forEach(function (one) { try { if (el.matches(one)) best = Math.max(best, weight(one.trim())); } catch (e) {} });
  return best;
}

// The page's own rules that apply to an element, the one that wins
// first: from its stylesheets on the same server (another site's
// can't be read), under the media that hold now. Three at most, each
// declaration another one beats marked so.
function rulesFor(el) {
  var found0 = [];
  function walk(list, sheet) {
    for (var i = 0; i < list.length; i++) {
      var r = list[i];
      if (r.media && r.media.mediaText && !matchMedia(r.media.mediaText).matches) continue;
      if (!r.selectorText) { if (r.cssRules) walk(r.cssRules, sheet); continue; }
      var yes = false;
      try { yes = el.matches(r.selectorText); } catch (e) {}
      if (yes && r.style && r.style.length) found0.push({ rule: r, where: where(sheet, r), w: matchedWeight(el, r.selectorText), n: found0.length });
    }
  }
  for (var k = 0; k < document.styleSheets.length; k++) {
    var sheet = document.styleSheets[k];
    try { walk(sheet.cssRules, sheet); } catch (e) {}
  }
  found0.sort(function (p, q) { return p.w - q.w || p.n - q.n; });
  var won = {};
  for (var j = found0.length - 1; j >= 0; j--) {
    var list = props(found0[j].rule.style);
    found0[j].beaten = {};
    for (var d = 0; d < list.length; d++) {
      var prop = list[d];
      if (won[prop]) found0[j].beaten[prop] = true; else won[prop] = true;
    }
  }
  return found0.reverse().slice(0, 3);
}

// Where a rule was written: its file, and its line when the text can be
// read (a <style>, a dev server's injected one named by data-vite-dev-id,
// or a stylesheet from the same server, fetched once).
var sheetText = {};
function where(sheet, rule) {
  var node = sheet.ownerNode, name = 'style', text = null;
  if (sheet.href) {
    try { var u0 = new URL(sheet.href); name = u0.pathname.split('/').pop() || u0.host; } catch (e) {}
    if (sheetText[sheet.href] === undefined) {
      sheetText[sheet.href] = null;
      try {
        if (new URL(sheet.href).origin === location.origin) {
          fetch(sheet.href).then(function (r) { return r.text(); }).then(function (t) { sheetText[sheet.href] = t; dockKey = ''; draw(); }).catch(function () {});
        }
      } catch (e) {}
    }
    text = sheetText[sheet.href];
  } else if (node) {
    var dev = node.getAttribute && (node.getAttribute('data-vite-dev-id') || node.getAttribute('data-file'));
    if (dev) name = dev.split('/').slice(-2).join('/');
    text = node.textContent;
  }
  if (text && rule && rule.selectorText) {
    var at = text.indexOf(rule.selectorText + ' {');
    if (at < 0) at = text.indexOf(rule.selectorText + '{');
    if (at >= 0) return name + ':' + text.slice(0, at).split('\n').length;
  }
  return name;
}

// What was changed here, by hand, in the page's own rules: said again
// in Copy for Agent, so the change can be made in the source.
function edit(rule, prop, value) {
  var from = rule.rule.style.getPropertyValue(prop);
  value = String(value).trim();
  if (!value || value === from) return false;
  rule.rule.style.setProperty(prop, value, rule.rule.style.getPropertyPriority(prop));
  if (rule.rule.style.getPropertyValue(prop) === from) return false;
  var same = S.changes.filter(function (c) { return c.rule === rule.rule && c.prop === prop; })[0];
  if (same) same.to = value;
  else S.changes.push({ rule: rule.rule, sel: rule.rule.selectorText, where: rule.where, prop: prop, from: from || '0', to: value });
  dockKey = '';
  changed();
  return true;
}

// MARK: what is told

function info(el) {
  var cs = getComputedStyle(el), b = box(el), base = rem();
  var px = function (v) { return parseFloat(v) || 0; };
  var pad = MeasureMath.sides(px(cs.paddingTop), px(cs.paddingRight), px(cs.paddingBottom), px(cs.paddingLeft), base);
  var mar = MeasureMath.sides(px(cs.marginTop), px(cs.marginRight), px(cs.marginBottom), px(cs.marginLeft), base);
  var flow = cs.display.indexOf('flex') >= 0 || cs.display.indexOf('grid') >= 0;
  var gap = flow ? [px(cs.rowGap), px(cs.columnGap)] : [0, 0];
  var family = (cs.fontFamily.split(',')[0] || '').replace(/["']/g, '').trim();
  if (/^(-apple-system|BlinkMacSystemFont|system-ui)$/i.test(family)) family = 'system-ui';
  var lh = cs.lineHeight === 'normal' ? 'normal' : f(px(cs.lineHeight));
  var bg = cs.backgroundColor, clear = clearColor(bg);
  var text = (el.innerText || '').trim().replace(/\s+/g, ' ');
  return {
    name: label(el), path: path(el), b: b,
    x: f(b.x + scrollX), y: f(b.y + scrollY), w: f(b.w), h: f(b.h),
    pad: pad === '0' || pad === '0rem' ? null : pad,
    mar: mar === '0' || mar === '0rem' ? null : mar,
    gap: gap[0] || gap[1] ? (gap[0] === gap[1] || !gap[1] ? f(gap[0] || gap[1]) : f(gap[0]) + ' ' + f(gap[1])) : null,
    radius: px(cs.borderTopLeftRadius) ? f(px(cs.borderTopLeftRadius)) : null,
    type: f(px(cs.fontSize)) + '/' + lh + ' ' + family + ' ' + cs.fontWeight,
    color: MeasureMath.hex(cs.color), bg: clear ? null : MeasureMath.hex(bg),
    text: text.length > 60 ? text.slice(0, 60) + '…' : text,
  };
}

function markdown() {
  if (!S.sel) return '';
  var i = info(S.sel);
  var out = ['`' + i.name + '` on ' + location.host + location.pathname, '', '- Selector: `' + i.path + '`'];
  if (i.text) out.push('- Text: "' + i.text + '"');
  out.push('- Size: ' + i.w + ' × ' + i.h + ' at ' + i.x + ', ' + i.y);
  var box_ = [];
  if (i.pad) box_.push('padding ' + i.pad);
  if (i.gap) box_.push('gap ' + i.gap);
  if (i.mar) box_.push('margin ' + i.mar);
  if (i.radius) box_.push('radius ' + i.radius);
  if (box_.length) out.push('- Box: ' + box_.join(', '));
  out.push('- Type: ' + i.type + ', ' + i.color + (i.bg ? ' on ' + i.bg : ''));
  var tx = insets(S.sel).text;
  if (tx && isBox(S.sel)) out.push('- Text inset: ' + [tx.top, tx.right, tx.bottom, tx.left].map(function (v) { return f(Math.max(0, v)); }).join(' ') + ' (top right bottom left, to the letters)');
  var other = S.hover && S.hover !== S.sel ? S.hover : null;
  if (other) {
    var lines = MeasureMath.distances(i.b, box(other)).filter(function (l) { return !l.dash; });
    if (lines.length) out.push('- From `' + label(other) + '`: ' + lines.map(function (l) { return f(l.v); }).join(', '));
  }
  anims(S.sel).forEach(function (a) {
    var m = motionOf(a);
    out.push('- Motion: `' + m.name + '` ' + m.ms + ' ms' + (m.delay ? ' after ' + m.delay + ' ms' : '') + ', ' + m.ease + (m.props.length ? ', ' + m.props.map(function (p) { return p[0] + ' ' + p[1] + ' → ' + p[2]; }).join('; ') : ''));
  });
  var mine = issues().filter(function (it) { return it.el === S.sel || S.sel.contains(it.el); });
  if (mine.length) { out.push('', 'Found on the page:'); mine.forEach(function (it) { out.push('- ' + it.title + ' on `' + label(it.el) + '`: ' + it.words); }); }
  if (S.changes.length) {
    out.push('', 'Changed by hand in the page, to make in the source:');
    S.changes.forEach(function (c) { out.push('- `' + c.sel + '` in ' + c.where + ': `' + c.prop + ': ' + c.from + '` → `' + c.to + '`'); });
  }
  if (S.pins.length) {
    out.push('', 'Kept measurements:');
    S.pins.forEach(function (p) { out.push('- `' + label(p.a) + '` to `' + label(p.b) + '`: ' + pinWords(p)); });
  }
  if (S.notes.length) {
    out.push('', 'Notes:');
    S.notes.forEach(function (n, k) { out.push((k + 1) + '. `' + path(n.el) + '`: ' + n.text); });
  }
  return out.join('\n');
}

// MARK: motion: what moves, slowed, scrubbed, frame by frame

var BEZ = { linear: [0, 0, 1, 1], ease: [0.25, 0.1, 0.25, 1], 'ease-in': [0.42, 0, 1, 1], 'ease-out': [0, 0, 0.58, 1], 'ease-in-out': [0.42, 0, 0.58, 1] };
function bezierOf(s) {
  if (BEZ[s]) return BEZ[s];
  var m = /cubic-bezier\(([^)]+)\)/.exec(s || '');
  return m ? m[1].split(',').map(parseFloat) : BEZ.linear;
}
function anims(el) {
  if (!el) return [];
  try { return el.getAnimations({ subtree: true }).slice(0, 3); } catch (e) { return []; }
}
function animName(a) { return a.animationName || (a.transitionProperty ? a.transitionProperty + ' transition' : a.id || 'animation'); }
function motionOf(a) {
  var t = a.effect.getTiming(), kf = a.effect.getKeyframes();
  var e = typeof t.easing === 'string' ? t.easing : 'linear';
  var ease = e === 'linear' && kf[0] && kf[0].easing ? kf[0].easing : e;
  var ps = kf.length ? Object.keys(kf[0]).filter(function (k) { return ['offset', 'easing', 'composite', 'computedOffset'].indexOf(k) < 0; }) : [];
  return {
    name: animName(a), ms: Math.round(+t.duration || 0), delay: Math.round(+t.delay || 0), ease: ease, bez: bezierOf(ease),
    props: ps.slice(0, 4).map(function (p) { return [p, String(kf[0][p]), String(kf[kf.length - 1][p])]; }),
    total: Math.round((+t.delay || 0) + (+t.duration || 0)), t: Math.round(+a.currentTime || 0), running: a.playState === 'running',
  };
}
var speed = 1, motionPost = 0;
function motionAct(m) {
  var list = anims(S.sel), a = list[m.n || 0];
  if (m.speed) { speed = m.speed; list.forEach(function (x) { x.playbackRate = speed; }); }
  if (a && m.t !== undefined) { a.pause(); a.currentTime = m.t; }
  if (a && m.play) { a.cancel(); a.playbackRate = speed; a.play(); }
  dockKey = ''; draw();
}
// , and .: a frame, a sixtieth of a second, back or on.
function stepFrame(dir) {
  var list = anims(S.sel);
  list.forEach(function (a) { var now = +a.currentTime || 0, t = a.effect.getTiming(); a.pause(); a.currentTime = Math.max(0, Math.min((+t.delay || 0) + (+t.duration || 0), now + dir * 1000 / 60)); });
  if (list.length) { dockKey = ''; draw(); }
  return list.length > 0;
}
// While something picked moves, its times go to the dock a few times a
// second, and the page is drawn again with it.
function tickMotion() {
  var list = anims(S.sel);
  if (!list.some(function (a) { return a.playState === 'running'; })) return;
  var now = performance.now();
  if (now - motionPost > 50) { motionPost = now; post({ k: 'time', t: list.map(function (a) { return Math.round(+a.currentTime || 0); }) }); }
  draw();
}

// MARK: a picture of the design, laid over the page

var ref = null;
function isRef(el) { return el && el.hasAttribute && el.hasAttribute('data-yab-ref'); }
function dragOver(e) {
  var t = e.dataTransfer && e.dataTransfer.types;
  if (t && Array.prototype.indexOf.call(t, 'Files') >= 0) { e.preventDefault(); e.stopImmediatePropagation(); }
}
function drop(e) {
  var file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
  if (!file || !/^image\//.test(file.type)) return;
  e.preventDefault(); e.stopImmediatePropagation();
  var reader = new FileReader();
  reader.onload = function () { compareOn(reader.result, file.name); };
  reader.readAsDataURL(file);
}
function compareOn(src, name) {
  compareOff();
  var wrap = document.createElement('div');
  wrap.setAttribute('data-yab-ref', '');
  wrap.style.cssText = 'all: initial; position: absolute; left: ' + scrollX + 'px; top: ' + scrollY + 'px; pointer-events: none; z-index: 2147483646;';
  var img = new Image();
  img.src = src;
  // The picture at its own size in points: a 2x export is drawn at half.
  img.onload = function () { var two = /@2x/.test(name || '') || img.naturalWidth > W() * 1.5; img.style.width = (two ? img.naturalWidth / 2 : img.naturalWidth) + 'px'; draw(); };
  img.style.cssText = 'display: block; max-width: none;';
  wrap.appendChild(img);
  document.documentElement.appendChild(wrap);
  ref = { node: wrap, name: name || 'Picture', dx: 0, dy: 0, diff: true };
  styleRef();
  dockKey = ''; draw();
}
function compareOff() { if (ref && ref.node) ref.node.remove(); ref = null; }
function styleRef() {
  if (!ref) return;
  ref.node.style.opacity = ref.diff ? '1' : '0.5';
  ref.node.style.mixBlendMode = ref.diff ? 'difference' : 'normal';
  ref.node.style.transform = 'translate(' + ref.dx + 'px, ' + ref.dy + 'px)';
}

// MARK: the dock (MeasureDock.swift): what is shown there, told when it
// changes

var dockKey = '', dockSent = '';
function tellDock() {
  var b = S.sel && box(S.sel);
  var k = [idOf(S.sel), b ? f(b.w) + 'x' + f(b.h) : '', S.pins.length, S.notes.length, S.changes.length, issuesVersion, S.showIssues, ref ? ref.dx + ',' + ref.dy + ',' + ref.diff : '', S.rems, S.xray, anims(S.sel).length].join('|');
  if (k === dockKey) return;
  dockKey = k;
  var d = { sel: null, issues: found.length, showIssues: S.showIssues, rows: [], rules: [], motion: [], list: [], pins: [], notes: [], compare: null, xray: S.xray };
  if (S.sel) {
    var i = info(S.sel), tx = isBox(S.sel) ? insets(S.sel).text : null;
    var v = function (t, bad) { return { t: String(t), bad: !!bad }; };
    d.sel = { name: i.name, size: i.w + ' × ' + i.h };
    d.rows.push({ l: 'Position', v: [v(i.x + ', ' + i.y)] });
    d.rows.push({ l: 'Padding', v: [v(i.pad || '0', !i.pad && isBox(S.sel))] });
    if (tx) d.rows.push({ l: 'To text', v: [tx.top, tx.right, tx.bottom, tx.left].map(function (n) { return v(f(Math.max(0, n)), n < 4); }) });
    if (i.gap) d.rows.push({ l: 'Gap', v: [v(i.gap)] });
    if (i.mar) d.rows.push({ l: 'Margin', v: [v(i.mar)] });
    if (i.radius) d.rows.push({ l: 'Radius', v: [v(i.radius)] });
    d.rows.push({ l: 'Type', v: [v(i.type)] });
    d.rows.push({ l: 'Color', v: [], c: [i.color].concat(i.bg ? [i.bg] : []) });
    found.filter(function (it) { return it.el === S.sel; }).forEach(function (it) { d.rows.push({ l: 'Issue', v: [v(it.title, true), v(it.words)] }); });
    d.rules = rulesFor(S.sel).map(function (r) {
      var list = props(r.rule.style).slice(0, 10);
      return { sel: r.rule.selectorText, where: r.where, decls: list.map(function (p) {
        return { p: p, v: r.rule.style.getPropertyValue(p), x: !!r.beaten[p], ch: S.changes.some(function (c) { return c.rule === r.rule && c.prop === p; }) };
      }) };
    });
    d.motion = anims(S.sel).map(motionOf);
  }
  if (S.showIssues) d.list = found.slice(0, 40).map(function (it) { return { title: it.title, name: label(it.el), words: it.words }; });
  d.pins = S.pins.map(function (p) { return { a: label(p.a), b: label(p.b), v: pinWords(p) }; });
  d.notes = S.notes.map(function (n, k) { return { n: k + 1, text: n.text, mine: n.el === S.sel }; });
  if (ref) d.compare = { name: ref.name, dx: ref.dx, dy: ref.dy, diff: ref.diff };
  var json = JSON.stringify(d);
  if (json === dockSent) return;
  dockSent = json;
  post({ k: 'dock', dock: json });
}

// What the dock asks the page to do.
function act(a) {
  if (a.copy && S.sel) post({ k: 'copy', text: markdown() });
  if (a.issues !== undefined) { S.showIssues = !!a.issues; if (S.showIssues) issues(); }
  if (a.pickIssue !== undefined) { var it = found[a.pickIssue]; if (it && it.el.isConnected) { S.sel = it.el; it.el.scrollIntoView({ block: 'nearest' }); } }
  if (a.flash !== undefined) { var fl = a.flash === null ? null : found[a.flash]; S.flash = fl ? fl.el : null; }
  if (a.note && S.sel) S.notes.push({ el: S.sel, text: String(a.note) });
  if (a.unnote !== undefined) S.notes.splice(a.unnote, 1);
  if (a.unpin !== undefined) { if (a.unpin === 'all') S.pins = []; else S.pins.splice(a.unpin, 1); }
  if (a.edit && S.sel) { var r = rulesFor(S.sel)[a.edit.r]; if (r) edit(r, a.edit.p, a.edit.v); }
  if (a.motion) motionAct(a.motion);
  if (a.elements && S.sel) post({ k: 'elements', path: unique(S.sel) });
  if (a.compare === 'remove') compareOff();
  if (a.compare === 'diff' && ref) { ref.diff = !ref.diff; styleRef(); }
  if (a.xray !== undefined) S.xray = !!a.xray;
  dockKey = '';
  draw();
  return true;
}

// For the bench: act as the pointer would, and say what is shown.
function bench(a) {
  if (a.act === 'hover') { move({ clientX: a.x, clientY: a.y, shiftKey: !!a.shift, altKey: !!a.alt }); }
  else if (a.act === 'click') { down({ clientX: a.x, clientY: a.y, button: 0, shiftKey: false, preventDefault: function () {}, pointerId: 0 }); up({ clientX: a.x, clientY: a.y }); }
  else if (a.act === 'guide') {
    var e = { clientX: a.axis === 'v' ? 5 : a.from || 200, clientY: a.axis === 'v' ? a.from || 200 : 5, button: 0, shiftKey: !!a.shift, preventDefault: function () {}, pointerId: 0 };
    down(e);
    var to = { clientX: a.axis === 'v' ? a.at : 200, clientY: a.axis === 'v' ? 200 : a.at, shiftKey: !!a.shift };
    move(to); up(to);
  }
  else if (a.act === 'clear') { S.guides = []; save(); }
  else if (a.act === 'edit') { var rl = S.sel && rulesFor(S.sel)[a.rule || 0]; if (rl) edit(rl, a.prop, a.value); }
  else if (a.act === 'key') { key({ type: 'keydown', key: a.key, code: a.code || '', shiftKey: !!a.shift, metaKey: !!a.meta, altKey: !!a.alt, ctrlKey: false, preventDefault: function () {}, stopImmediatePropagation: function () {} }); }
  else if (a.act === 'alt') { S.alt = !!a.on; }
  else if (a.act === 'dock') { act(a.do || {}); }
  else if (a.act === 'compare') { compareOn(a.src, a.name); }
  else if (a.act === 'time') {
    // Pointer moves over a grid of the page, each hit test and paint
    // done at once, the time each took.
    var n = a.n || 200, times = [];
    for (var k = 0; k < n; k++) {
      var x = R() + ((k * 97) % Math.max(1, innerWidth - R())), y = R() + ((k * 61) % Math.max(1, innerHeight - R()));
      var t0 = performance.now();
      move({ clientX: x, clientY: y, shiftKey: false, altKey: false });
      if (frame) { cancelAnimationFrame(frame); frame = 0; }
      paint();
      times.push(performance.now() - t0);
    }
    times.sort(function (p, q) { return p - q; });
    return { n: n, median: times[n >> 1], p95: times[Math.floor(n * 0.95)], max: times[n - 1] };
  }
  if (issueTimer && a.act !== 'hover') { clearTimeout(issueTimer); issueTimer = 0; lookForIssues(); }
  if (frame) { cancelAnimationFrame(frame); frame = 0; }
  dockKey = '';
  paint();
  return {
    on: S.on, sel: S.sel ? label(S.sel) : null, hover: S.hover ? label(S.hover) : null,
    guides: S.guides.map(function (g) { return g.axis + ':' + g.at; }),
    markdown: markdown(), rules: (S.sel ? rulesFor(S.sel) : []).map(function (r) { return r.rule.selectorText + ' @ ' + r.where; }), changes: S.changes.length,
    inTop: (function () { try { return host.matches(':popover-open'); } catch (e) { return false; } })(),
    dock: JSON.parse(dockSent || '{}'), pins: S.pins.length, notes: S.notes.length, xray: S.xray, showIssues: S.showIssues,
    issues: found.map(function (it) { return it.kind + ' ' + label(it.el); }), compare: ref ? { dx: ref.dx, dy: ref.dy, diff: ref.diff } : null,
  };
}

var CSS = [
  // The host's own look, from inside: important there, it beats the
  // page's rules as a style attribute would, and WebKit's Elements shows
  // the element as one short line.
  ':host { all: initial !important; display: block !important; position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important; margin: 0 !important; padding: 0 !important; border: 0 !important; background: transparent !important; overflow: visible !important; pointer-events: none !important; z-index: 2147483647 !important; }',
  'canvas { position: fixed; inset: 0; pointer-events: none; }',
  '.hit { position: fixed; inset: 0; pointer-events: auto; background: transparent; }',
].join('\n');

window.__yabMeasure = { set: set, bench: bench, act: act };
build();
set(init);
