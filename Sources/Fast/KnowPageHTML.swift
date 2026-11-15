import Foundation
import YabDesign

// yab://you as drawn (docs/get-to-know.md, The notebook): on the site's
// paper, set in the system's type, the pen in the site's red marking only
// what it says something about. A hello; what Yab knows, told as your story
// with the people and apps in it as their faces and logos; your people;
// the run's questions; what forms get; what Yab can set up, under the
// drawings Settings wears; where it all is, and Forget Everything.

extension KnowPage {
    /// The Settings drawings the page wears, and each one's marker color.
    nonisolated static let drawings: [(key: String, color: UInt32?)] = [
        ("agentMemory", 0xa2845e), ("privacy", 0x3b82f0), ("folder", 0xf0943a), ("search", nil),
        ("agentRoutines", 0xe84c6c), ("doc", 0xe8b33a), ("spaces", 0x34b85a), ("mail", 0x2f8cf6),
        ("calendar", 0xe84c6c), ("autofill", 0x34b85a), ("person", 0x615fd8),
    ]

    /// The drawings as the page takes them: each one's ink, the swipe of
    /// marker under it, and the marker's color, as JSON.
    nonisolated static func pens() -> String {
        var out: [String: Any] = [:]
        for (key, color) in drawings {
            guard let ink = PenArt.ink[key] else { continue }
            let shape = PenArt.swipe[key] != nil ? key : PenArt.borrowed[key] ?? "ai"
            var pen: [String: Any] = ["ink": ink]
            if let color, let swipe = PenArt.swipe[shape] {
                pen["swipe"] = swipe
                pen["color"] = String(format: "#%06x", color)
            }
            out[key] = pen
        }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func html(title: String) -> String {
        #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light dark">
<title>\#(title)</title>
<style>
@font-face { font-family: "Caveat"; src: url("yab://font/caveat.ttf") format("truetype"); font-weight: 400 700; font-display: block; }
:root {
  --paper: #fbfaf5; --ground: #ffffff; --sheet: #ffffff; --ink: #171717; --muted: #6f6e6a; --faint: #c9c6be;
  --hairline: rgba(23,23,23,.09); --wash: rgba(23,23,23,.06); --hover: rgba(23,23,23,.04);
  --pen: #d93b30; --bad: #ff3b30; --tile: #fbfaf8; --tile-rim: rgba(0,0,0,.1); --tile-ink: #1c1c1e;
  --disp: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
  --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper: #1b1a18; --ground: #262522; --sheet: #242320; --ink: #ecebe6; --muted: #98968f; --faint: #4a4843;
    --hairline: rgba(237,237,237,.09); --wash: rgba(237,237,237,.08); --hover: rgba(237,237,237,.05);
    --pen: #ef6a5f; --bad: #ff453a; --tile: #2b2b2f; --tile-rim: rgba(255,255,255,.1); --tile-ink: #f1f1f3;
  }
}
* { box-sizing: border-box; }
html { background: var(--paper); }
body { margin: 0; color: var(--ink); background: var(--paper); font: 15px/1.5 var(--sans); -webkit-font-smoothing: antialiased; cursor: default; }
button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: default; }
\#(ButtonCSS.css)
.sheet { position: relative; max-width: 760px; margin: 0 auto; padding: 64px 40px 120px; }
.ink { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; overflow: visible; z-index: 2; }
.ink path { fill: none; stroke: var(--pen); stroke-width: 2.3; stroke-linecap: round; stroke-linejoin: round; }
.hand { font-family: "Caveat", "Bradley Hand", cursive; color: var(--pen); font-weight: 500; }
.hidden { visibility: hidden; }

/* hello */
.ttl { font: 600 48px/1.04 var(--disp); letter-spacing: -.034em; margin: 0; text-wrap: balance; }
.ttl .dot { color: var(--pen); }
.portrait { font: 500 19px/1.42 var(--disp); letter-spacing: -.01em; margin: 14px 0 0; max-width: 36ch; }
.read { font-size: 13px; color: var(--muted); margin: 10px 0 0; }

/* parts */
.ph { display: flex; align-items: baseline; gap: 12px; margin: 56px 0 6px; padding-bottom: 10px; border-bottom: 1px solid var(--hairline); scroll-margin-top: 20px; }
.ph h2 { font: 600 24px/1.15 var(--disp); letter-spacing: -.02em; margin: 0; }
.ph p { margin: 0 0 0 auto; font-size: 12.5px; color: var(--muted); }
.sub { font: 600 13px var(--sans); color: var(--muted); margin: 30px 0 10px; }
.more { font-size: 13px; color: var(--muted); margin: 10px 0 0; }

/* the story */
.story { display: grid; gap: 14px; margin-top: 18px; }
.story p { margin: 0; font: 400 18px/1.62 var(--disp); letter-spacing: -.008em; max-width: 60ch; text-wrap: pretty; }
.s { border-radius: 4px; padding: 1px 0; transition: background .15s; }
.s:hover, .s.on { background: color-mix(in srgb, var(--pen) 9%, transparent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--pen) 9%, transparent); }
.s.gone { opacity: .42; }
.s.gone:hover { background: none; box-shadow: none; opacity: .6; }
.s b { font-weight: 600; }
.ent { display: inline-block; vertical-align: baseline; padding: 1px 7px 1px 4px; border-radius: 7px; background: var(--sheet); box-shadow: inset 0 0 0 1px var(--hairline);
  font: 500 .86em/1.5 var(--sans); white-space: nowrap; }
.ent .logo { display: inline-block; width: 15px; height: 15px; border-radius: 4px; vertical-align: -3px; margin-right: 5px; object-fit: cover; }
.ent.who { padding-left: 3px; border-radius: 99px; }
.ent.who:hover { box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--ink) 25%, transparent); }
.glue { white-space: nowrap; }
.face { display: inline-block; width: 17px; height: 17px; border-radius: 50%; vertical-align: -4px; margin-right: 5px; object-fit: cover; }
s.was { color: var(--muted); text-decoration: line-through; text-decoration-color: var(--pen); text-decoration-thickness: 1.6px; }
.fixin { font: inherit; color: var(--ink); background: var(--sheet); border: 0; border-radius: 6px; padding: 1px 6px; margin: -1px 0; outline: 1.5px solid var(--pen); width: min(100%, 62ch); }

/* the tooltip over a line */
.tip { position: absolute; z-index: 8; display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; padding: 4px 4px 4px 9px; border-radius: 9px;
  background: var(--sheet); box-shadow: 0 8px 22px -8px rgba(0,0,0,.35), inset 0 0 0 1px var(--hairline); font: 12px/1 var(--sans); color: var(--muted);
  opacity: 0; transform: translateY(3px); pointer-events: none; transition: opacity .12s, transform .12s; }
.tip.on { opacity: 1; transform: none; pointer-events: auto; }
.tip::after { content: ""; position: absolute; left: -12px; right: -12px; top: 100%; height: 12px; }
.tip .from { display: inline-flex; align-items: center; gap: 6px; }
.said { font-size: 12px; color: var(--muted); padding: 0 4px; }

/* cards: people, what forms get */
.cards { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.card { position: relative; display: grid; grid-template-columns: 40px minmax(0, 1fr); gap: 12px; align-items: center; padding: 10px 12px; border-radius: 12px;
  background: var(--sheet); box-shadow: inset 0 0 0 1px var(--hairline); min-width: 0; scroll-margin-top: 80px; }
/* your people: a row each, the whole note under the name */
.cards.people { grid-template-columns: minmax(0, 1fr); gap: 2px; }
.card.person { grid-template-columns: 34px minmax(0, 1fr) auto; align-items: start; padding: 8px; margin: 0 -8px; border-radius: 10px; background: none; box-shadow: none; }
.card.person:hover { background: var(--hover); }
.card .k { display: block; font-size: 12px; color: var(--muted); }
.card .v { display: block; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.card.person .v { font-weight: 600; font-size: 14px; white-space: normal; width: fit-content; max-width: 100%; }
.card .n { display: block; font-size: 13px; line-height: 1.45; color: var(--muted); text-wrap: pretty; max-width: 68ch; }
.card .from { display: inline-flex; align-items: center; gap: 5px; font-size: 11.5px; color: var(--muted); }
.card .from .logo { width: 12px; height: 12px; border-radius: 3px; }
.card .acts { position: absolute; right: 8px; top: 8px; display: none; gap: 4px; align-items: center; padding: 2px; border-radius: 9px; background: var(--sheet); }
.card:hover .acts { display: flex; }
/* a person's Fix and Cross Out keep their place, so pointing at a row never rewraps its note */
.card.person .acts { position: static; display: flex; visibility: hidden; padding: 0; margin-top: 4px; background: none; }
.card.person:hover .acts { visibility: visible; }
.card.gone .v, .card.gone .k, .card.gone .ava { opacity: .42; }
.card.lit { box-shadow: inset 0 0 0 2px color-mix(in srgb, var(--pen) 40%, transparent); }
.ava { width: 34px; height: 34px; border-radius: 50%; display: grid; place-items: center; color: #fff; font: 600 13px var(--sans); overflow: hidden; }
.ava img { width: 100%; height: 100%; object-fit: cover; display: block; }
.card .fixin { width: 100%; font-size: 14px; }
.others { margin-top: 12px; }
.row { display: flex; gap: 12px; align-items: baseline; padding: 6px 8px; margin: 0 -8px; border-radius: 8px; position: relative; }
.row:hover { background: var(--hover); }
.row .v { min-width: 0; flex: 1; }
.row .k { width: 110px; flex: none; font-size: 12px; color: var(--muted); }
.row small { display: block; font-size: 12px; color: var(--muted); }
.row .acts { display: none; gap: 4px; align-items: center; }
.row:hover .acts { display: flex; }
.row .mark { font-size: 20px; line-height: 1; transform: rotate(-3deg); }
.row.gone .v, .row.gone .k { opacity: .42; }

/* the Settings drawings */
.tile { position: relative; flex: none; display: block; width: 40px; height: 40px; border-radius: 10px; background: var(--tile); box-shadow: inset 0 0 0 1px var(--tile-rim); }
.tile i { position: absolute; inset: 0; -webkit-mask-size: 100% 100%; mask-size: 100% 100%; }
.tile .sw { opacity: .6; }
.tile .in { background: var(--tile-ink); }
.tile.big { width: 44px; height: 44px; border-radius: 11px; }

/* questions */
.q { position: relative; padding: 14px 16px; border-radius: 12px; background: var(--sheet); box-shadow: inset 0 0 0 1px var(--hairline); }
.q + .q { margin-top: 10px; }
.q .head { display: flex; gap: 12px; align-items: center; padding-right: 110px; }
.q .head b { display: block; font-weight: 500; }
.choices { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 0 52px; }
.choice { position: relative; padding: 7px 12px; border-radius: 9px; background: var(--wash); font-size: 13.5px; font-variant-numeric: tabular-nums; transition: opacity .2s; }
.choice:hover { background: color-mix(in srgb, var(--ink) 12%, transparent); }
.choice.on { background: none; font-weight: 600; }
.choice.off { opacity: .35; }
.choice svg { position: absolute; inset: -8px -12px; width: calc(100% + 24px); height: calc(100% + 16px); overflow: visible; pointer-events: none; }
.choice svg path { fill: none; stroke: var(--pen); stroke-width: 2.1; stroke-linecap: round; }
.none { position: absolute; top: 10px; right: 10px; padding: 5px 10px; border-radius: 8px; font-size: 12.5px; color: var(--muted); }
.none:hover { color: var(--ink); background: var(--hover); }
.none.on { color: var(--ink); background: var(--wash); font-weight: 500; }
.none.off { opacity: .35; }
.kept { margin: 10px 0 0 52px; font-size: 12.5px; color: var(--muted); }
.link { color: var(--pen); text-decoration: underline; text-underline-offset: 2px; }

/* set up for you */
.kind { display: grid; grid-template-columns: 44px minmax(0, 1fr); gap: 4px 14px; margin-top: 26px; }
.kind > .tile { grid-row: 1 / span 2; }
.kind .head { display: flex; align-items: baseline; gap: 10px; min-width: 0; }
.kind .head b { font: 600 16px var(--sans); }
.kind .head span { font-size: 13px; color: var(--muted); }
.kind .head .btn { margin-left: auto; }
.kind .items { grid-column: 2; display: grid; gap: 8px; }
.offer { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 14px; align-items: center; padding: 12px 14px; border-radius: 12px; background: var(--sheet); box-shadow: inset 0 0 0 1px var(--hairline); }
.offer .t { font-weight: 500; }
.offer .why { font-size: 12.5px; color: var(--muted); }
.offer .why button { text-decoration: underline; text-decoration-color: var(--faint); text-underline-offset: 2px; }
.offer .why button:hover { color: var(--ink); }
.offer .bt { display: flex; gap: 4px; align-items: center; }
.offer.done, .offer.away { background: transparent; }
.offer.done .t, .offer.away .t { color: var(--muted); font-weight: 400; }
.offer.away { padding: 6px 14px; }
.offer.away .why { display: none; }
.ok { font-size: 12.5px; color: var(--muted); display: inline-flex; gap: 6px; align-items: center; }
.ok svg { width: 18px; height: 18px; overflow: visible; }
.ok path { fill: none; stroke: var(--pen); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }

/* left alone */
.quote { line-height: 1.55; padding: 2px 0 2px 12px; border-left: 2px solid var(--faint); margin: 6px 0; max-width: 560px; color: var(--muted); }
.quote b { color: var(--ink); font-weight: 500; }

/* where it is */
.priv, .ask, .empty { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 8px; margin: 64px auto 0; max-width: 440px; }
.priv b, .ask b { font: 600 15px var(--disp); letter-spacing: -.01em; }
.priv p, .ask p { margin: 0; font-size: 12.5px; line-height: 1.5; color: var(--muted); text-wrap: balance; }
.priv .forget { color: #3b82f0; font-size: 12.5px; }
.priv .forget:hover { text-decoration: underline; text-underline-offset: 2px; }
.ask { padding: 18px 20px; border-radius: 14px; background: var(--sheet); box-shadow: 0 16px 40px -18px rgba(0,0,0,.35), inset 0 0 0 1px var(--hairline); }
.ask .two { display: flex; gap: 8px; margin-top: 6px; }
.empty { padding-top: 80px; }
.empty h1 { font: 600 34px/1.1 var(--disp); letter-spacing: -.03em; margin: 8px 0 0; }
.empty p { margin: 0; max-width: 40ch; color: var(--muted); }
.foot { display: flex; align-items: center; gap: 12px; margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--hairline); font-size: 13px; color: var(--muted); }
.foot .sig { font-size: 28px; margin-left: auto; transform: rotate(-4deg); display: inline-flex; align-items: center; gap: 8px; }
.foot .sig svg { width: 30px; height: 26px; overflow: visible; }
.foot .sig path { fill: none; stroke: var(--pen); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
.doo { position: absolute; width: 30px; height: 30px; overflow: visible; pointer-events: none; z-index: 1; }
.doo path { fill: none; stroke: var(--pen); stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }

@media (max-width: 760px) {
  .sheet { padding: 36px 20px 100px; }
  .ttl { font-size: 36px; }
  .story p { font-size: 16.5px; }
  .cards { grid-template-columns: minmax(0, 1fr); }
  .ph p { display: none; }
  .doo { display: none; }
  .kind { grid-template-columns: 34px minmax(0, 1fr); }
  .kind > .tile { width: 34px; height: 34px; border-radius: 9px; }
}
</style>
</head>
<body>
<div class="sheet" id="sheet"></div>
<script>
const PEN = \#(pens());
const met = location.search.slice(1).split('&').includes('met');
// The relay answers with JSON, its keys in order: the same page is the same words.
const ask = async (verb, body = {}) => {
  const said = await window.webkit.messageHandlers.yabYou.postMessage(Object.assign({ do: verb }, body));
  return typeof said === 'string' ? JSON.parse(said) : said;
};
const $ = q => document.querySelector(q);
const $$ = q => Array.from(document.querySelectorAll(q));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const still = matchMedia('(prefers-reduced-motion: reduce)');
// Motion only where it is seen: a page behind other tabs gets the marks at once.
const moving = () => !still.matches && document.visibilityState === 'visible';
const sheet = $('#sheet');
let S = null, last = '', editing = null, writing = false, later = null, wanted = '';
const R = new Map();          // id: the row as last drawn
const gone = new Map();       // id: a row crossed out, as it was
const fixed = new Map();      // id: its words before you fixed them
const undos = [];             // what ⌘Z takes back, the last one last
const key = s => { const { now, done, said, ...page } = s; return JSON.stringify(page); };
const flat = t => String(t ?? '').replace(/\s+/g, ' ').trim();
// A story's words as plain text, for the field a fix is typed in.
const plain = t => flat(String(t ?? '').replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, '$2').replace(/\[\[([^\]]+)\]\]/g, (m, to) => to.split('/').pop().replace(/-/g, ' ')).replace(/\*\*([^*]+)\*\*/g, '$1'));

// ---- the drawings Settings wears ----
const mask = svg => `url('data:image/svg+xml;utf8,${encodeURIComponent(svg)}')`;
function tile(name, big) {
  const p = PEN[name]; if (!p) return '';
  const sw = p.swipe ? `<i class="sw" style="background:${p.color};-webkit-mask-image:${mask(p.swipe)}"></i>` : '';
  return `<span class="tile${big ? ' big' : ''}" aria-hidden="true">${sw}<i class="in" style="-webkit-mask-image:${mask(p.ink)}"></i></span>`;
}
const icon = host => `yab://icon/${encodeURIComponent(host)}`;
const logo = host => host ? `<img class="logo" src="${icon(host)}" alt="" onerror="this.remove()">` : '';
function initials(name, color) {
  const l = esc((name || '?').trim()[0] || '?');
  return `<svg class="face" viewBox="0 0 17 17" aria-hidden="true"><circle cx="8.5" cy="8.5" r="8.5" fill="${color}"/><text x="8.5" y="11.8" text-anchor="middle" font-size="9" font-weight="600" fill="#fff" font-family="-apple-system, sans-serif">${l}</text></svg>`;
}
// Words as the story writes them: **bold**, people and sites as their faces
// and logos, other links as their words.
function words(text) {
  let out = '', i = 0;
  const re = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]|\*\*([^*]+)\*\*|\[([^\]]+)\]\((?:https?|mailto):[^)]+\)/g;
  for (let m; (m = re.exec(text));) {
    out += esc(text.slice(i, m.index)); i = re.lastIndex;
    if (m[3]) { out += `<b>${esc(m[3])}</b>`; continue; }
    if (m[4]) { out += esc(m[4]); continue; }
    const to = m[1].replace(/\.md$/, ''), name = m[2] || to.split('/').pop().replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    // A full stop or comma right after a pill stays on its line with it.
    const tail = /^[.,;:!?)]/.test(text.slice(i)) ? text[i] : '';
    if (tail) { i += 1; re.lastIndex = i; out += '<span class="glue">'; }
    if (to.startsWith('people/')) {
      const p = (S.people || []).find(x => x.path === to + '.md');
      const face = p && p.photo ? `<img class="face" src="${p.photo}" alt="">` : initials(name, p ? p.color : '#8a8780');
      out += `<button type="button" class="ent who" data-act="person" data-id="${esc(to + '.md')}">${face}${esc(name)}</button>`;
    } else if (to.startsWith('sites/')) {
      out += `<span class="ent">${logo(to.slice(6))}${esc(name)}</span>`;
    } else if (to.startsWith('companies/') || to.startsWith('projects/')) {
      out += `<span class="ent">${esc(name)}</span>`;
    } else out += esc(name);
    if (tail) out += esc(tail) + '</span>';
  }
  return out + esc(text.slice(i));
}

// ---- the pen ----
function pos(el) { const o = sheet.getBoundingClientRect(), r = el.getBoundingClientRect(); return { x: r.left - o.left, y: r.top - o.top, w: r.width, h: r.height }; }
function lines(el) { const o = sheet.getBoundingClientRect(); return Array.from(el.getClientRects()).filter(r => r.width > 3).map(r => ({ x: r.left - o.left, y: r.top - o.top, w: r.width, h: r.height })); }
function zig(x1, y, x2) { let d = `M${x1.toFixed(1)} ${(y + 3).toFixed(1)}`, up = true; for (let x = x1 + 9; x < x2 - 4; x += 9) { d += ` L${x.toFixed(1)} ${(y + (up ? -4 : 4)).toFixed(1)}`; up = !up; } return d + ` L${x2.toFixed(1)} ${y.toFixed(1)}`; }
function curve(b) { const x = b.x - 3, y = b.y + b.h - 3, w = b.w + 8; return `M${x} ${y + 2} C${x + w * .35} ${y + 7} ${x + w * .7} ${y - 1} ${x + w} ${y + 1}`; }
function ring(w, h) { let d = ''; const cx = w / 2, cy = h / 2, rx = w / 2 - 2, ry = h / 2 - 2; for (let i = 0, n = 48; i <= n; i++) { const a = -2.4 + i / n * (Math.PI * 2 + .5), g = 1 + i / n * .08; d += (i ? ' L' : 'M') + (cx + Math.cos(a) * rx * g).toFixed(1) + ' ' + (cy + Math.sin(a) * ry * g).toFixed(1); } return d; }
function stroke(svg, d, ms, delay = 0) {
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', d); svg.appendChild(p);
  if (!ms || !moving()) return Promise.resolve();
  const L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
  const a = p.animate([{ strokeDashoffset: L }, { strokeDashoffset: 0 }], { duration: ms, delay, easing: 'cubic-bezier(.4,0,.2,1)', fill: 'forwards' });
  return Promise.race([a.finished.catch(() => {}), new Promise(r => setTimeout(r, ms + delay + 150))]);
}
// The pen's marks, as a doodle names them.
const MARKS = {
  star: 'M12 2.8l2.5 6.2 6.7.4-5.2 4.3 1.7 6.5L12 16.6l-5.7 3.6 1.7-6.5-5.2-4.3 6.7-.4z',
  coffee: 'M5 10h11v4.5a5 5 0 0 1-5 5h-1a5 5 0 0 1-5-5zM16 11.5h1.4a2.4 2.4 0 0 1 0 4.8H16M8.4 3.6c-.9 1 .9 2.1 0 3.2M11.8 3.6c-.9 1 .9 2.1 0 3.2',
  rocket: 'M13.6 5.2c2.7-1.9 5.6-2 6.4-1.2.8.8.7 3.7-1.2 6.4l-5.3 5.3-5-5zM8.5 10.7l-3.8.3-1.9 2.7 4 .9M13.3 15.5l-.3 3.8-2.7 1.9-.9-4M15.6 8.4h.1',
  heart: 'M12 20.2C7.2 16.6 3.4 13.4 3.7 9 4 5.8 7.6 4.3 10.1 6.3c.8.7 1.5 1.5 1.9 2.4.6-1.2 1.4-2.2 2.5-2.8 2.7-1.4 5.8.4 5.6 3.6-.2 4.2-4.6 7.2-8.6 10.4',
  spark: 'M12 3.5v4.5M12 16v4.5M3.5 12H8M16 12h4.5M6 6l3 3M15 15l3 3M18 6l-3 3M9 15l-3 3',
};
// Every mark as the rows now stand; `anim` the one being made as you watch.
function draw(anim) {
  const svg = $('#ink'); if (!svg || writing) return Promise.resolve();
  svg.innerHTML = '';
  const jobs = [];
  const nm = $('.ttl .nm'); if (nm) jobs.push(stroke(svg, curve(pos(nm))));
  $$('.s.gone, .card.gone .v, .row.gone .v').forEach(el => lines(el).forEach((b, i) => jobs.push(stroke(svg, zig(b.x - 2, b.y + b.h / 2, b.x + b.w + 2), anim && el.closest(`[data-id="${CSS.escape(anim)}"]`) ? 380 : 0, i * 120))));
  $$('.choice .rg').forEach(r => { const b = r.getBoundingClientRect(); r.setAttribute('viewBox', `0 0 ${b.width} ${b.height}`); r.innerHTML = ''; jobs.push(stroke(r, ring(b.width, b.height), anim && r.closest(`[data-q="${CSS.escape(anim)}"]`) ? 560 : 0)); });
  $$('.ok svg').forEach(t => { t.innerHTML = ''; jobs.push(stroke(t, 'M3 9.5l3.6 4L16 2.5', anim && t.closest(`[data-id="${CSS.escape(anim)}"]`) ? 420 : 0)); });
  doodles();
  return Promise.all(jobs);
}
let doodled = false;
function doodles() {
  $$('.doo').forEach(d => d.remove());
  const o = sheet.getBoundingClientRect(), pad = parseFloat(getComputedStyle(sheet).paddingLeft);
  (S.doodles || []).forEach((d, n) => {
    const el = d.at.startsWith('people/') ? $(`.card.person[data-id="note:${CSS.escape(d.at)}"]`) : $(`.s[data-id="${CSS.escape(d.at)}"]`);
    if (!el || !MARKS[d.mark]) return;
    const r = el.getClientRects()[0]; if (!r) return;
    const corner = el.classList.contains('card');
    const x = corner ? r.right - o.left - 18 : pad - 46, y = corner ? r.top - o.top - 14 : r.top - o.top - 2;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'doo'); svg.setAttribute('viewBox', '0 0 24 24');
    svg.style.cssText = `left:${x}px;top:${y}px;transform:rotate(${corner ? 12 : n % 2 ? 9 : -8}deg)`;
    sheet.appendChild(svg);
    stroke(svg, MARKS[d.mark], doodled ? 0 : 700, doodled ? 0 : 400 + n * 260);
  });
  doodled = true;
}
let hearted = false;
function heart() {
  const p = $('.sig path'); if (!p || hearted || !moving()) return; hearted = true;
  const L = p.getTotalLength(); p.style.strokeDasharray = L;
  p.animate([{ strokeDashoffset: L }, { strokeDashoffset: 0 }], { duration: 900, delay: 300, easing: 'cubic-bezier(.45,.1,.55,.9)', fill: 'both' });
}

// ---- the page ----
const KINDS = {
  live: ['folder', 'Live Folders', 'folders that fill themselves'],
  action: ['search', 'Quick Actions', 'a short word in ⌘T that makes something'],
  routine: ['agentRoutines', 'Routines', 'a task that comes back on its own'],
  snippet: ['doc', 'Snippets', 'words you type with ;name'],
  space: ['spaces', 'Spaces', 'work and home kept apart'],
};
const FORM_ART = { email: 'mail', phone: 'person', location: 'autofill', timezone: 'calendar' };
function remember(list) { list.forEach(r => R.set(r.id, r)); return list; }
// The rows of a list, each crossed-out one back where it stood.
function withGone(list, sec) {
  const out = list.slice();
  [...gone].filter(([id, g]) => g.sec === sec && !out.some(r => r.id === id)).sort((a, b) => a[1].idx - b[1].idx)
    .forEach(([id, g]) => out.splice(Math.min(g.idx, out.length), 0, Object.assign({}, g.row, { gone: true })));
  out.forEach((r, i) => { r.sec = sec; r.idx = i; });
  return remember(out);
}
function shownWords(r) {
  if (editing === r.id) return `<input class="fixin" value="${esc(r.fixed || r.value || plain(r.text))}" aria-label="Fix this">`;
  const was = fixed.get(r.id);
  return was && was !== r.value ? `<s class="was">${esc(was)}</s> ${esc(r.value)}` : null;
}
function acts(r) {
  if (r.gone) return `<span class="said">Crossed out</span><button type="button" class="btn sm" data-act="undo" data-id="${esc(r.id)}">Undo</button>`;
  const fix = `<button type="button" class="btn sm" data-act="fix" data-id="${esc(r.id)}">${r.kind === 'address' ? 'Edit' : 'Fix'}</button>`;
  const cross = `<button type="button" class="btn sm" data-act="cross" data-id="${esc(r.id)}">Cross Out</button>`;
  if (fixed.has(r.id) || r.fixed) return `<span class="said">Fixed by you</span>${fix}<button type="button" class="btn sm" data-act="undo" data-id="${esc(r.id)}">Undo</button>`;
  return fix + cross;
}
function sentence(r) {
  let body;
  if (editing === r.id) body = shownWords(r);
  else if (r.fixed) body = `<s class="was">${words(r.was)}</s> ${esc(r.fixed)}`;
  else body = shownWords(r) || words(r.text);
  return `<span class="s${r.gone ? ' gone' : ''}" data-id="${esc(r.id)}">${body}</span>`;
}
function person(r) {
  const face = r.photo ? `<img src="${r.photo}" alt="">` : esc((r.who || '?')[0]);
  const v = shownWords(r) ?? esc(r.value);
  return `<div class="card person${r.gone ? ' gone' : ''}" data-id="${esc(r.id)}"><span class="ava" style="background:${r.color || '#8a8780'}">${face}</span>` +
    `<span style="min-width:0"><span class="v">${esc(r.who)}</span><span class="n">${v}</span></span><span class="acts">${acts(r)}</span></div>`;
}
function fact(r) {
  const art = r.kind === 'address' ? 'autofill' : FORM_ART[r.key] || 'person';
  const link = r.sec === 'links' && /^[a-z]/.test(r.key) ? { linkedin: 'linkedin.com', x: 'x.com', github: 'github.com', telegram: 'telegram.org', instagram: 'instagram.com' }[r.key] : null;
  const pic = link ? `<span class="tile" style="display:grid;place-items:center"><img src="${icon(link)}" alt="" style="width:22px;height:22px;border-radius:5px" onerror="this.remove()"></span>` : tile(art);
  const v = shownWords(r) ?? esc(r.value);
  return `<div class="card${r.gone ? ' gone' : ''}" data-id="${esc(r.id)}">${pic}<span style="min-width:0"><span class="k">${esc(r.label)}</span><span class="v">${v}</span>` +
    `<span class="from">${esc(r.source || '')}</span></span><span class="acts">${acts(r)}</span></div>`;
}
function row(r) {
  const v = shownWords(r) ?? esc(r.value);
  return `<div class="row${r.gone ? ' gone' : ''}" data-id="${esc(r.id)}">${r.label ? `<span class="k">${esc(r.label)}</span>` : ''}<span class="v">${v}${r.source ? `<small>${esc(r.source)}</small>` : ''}</span>` +
    `${r.note ? `<span class="hand mark">${esc(r.note)}</span>` : ''}<span class="acts">${acts(r)}</span></div>`;
}
function question(d) {
  const done = d.picked >= -1;
  const art = d.about === 'email' ? 'mail' : d.about === 'phone' ? 'person' : 'autofill';
  const cs = d.choices.map((c, i) => `<button type="button" class="choice${d.picked === i ? ' on' : done ? ' off' : ''}" data-act="pick" data-id="${d.id}" data-pick="${i}">${esc(c)}${d.picked === i ? '<svg class="rg"></svg>' : ''}</button>`).join('');
  const kept = !done ? '' : d.picked === -1 ? 'Neither' : { phone: 'Your phone now', email: 'Your email now' }[d.about] || 'Kept in your notes';
  return `<div class="q" data-q="${d.id}"><button type="button" class="none${d.picked === -1 ? ' on' : done ? ' off' : ''}" data-act="pick" data-id="${d.id}" data-pick="-1">None of These</button>` +
    `<div class="head">${tile(art)}<b>${esc(d.question)}</b></div><div class="choices">${cs}</div>` +
    (done ? `<div class="kept">${kept} · <button type="button" class="link" data-act="repick" data-id="${d.id}">Change</button></div>` : '') + '</div>';
}
function offer(o) {
  const id = esc(o.id);
  if (o.state === 'away') return `<div class="offer away" data-id="${id}"><span class="t">${esc(o.title)}</span><span class="ok">Put away. It won’t be offered again · <button type="button" class="link" data-act="setup" data-do="undo" data-id="${id}">Undo</button></span></div>`;
  const why = o.state === 'added' ? esc(o.where) : esc(o.why) + (o.from ? ` · <button type="button" data-act="note" data-id="${esc(o.from)}">see note</button>` : '');
  const bt = o.state === 'added' ? `<span class="ok"><svg viewBox="0 0 18 18"></svg>Added · <button type="button" class="link" data-act="setup" data-do="undo" data-id="${id}">Undo</button></span>`
    : `<button type="button" class="btn sm" data-act="setup" data-do="add" data-id="${id}">Add</button><button type="button" class="btn sm quiet" data-act="setup" data-do="away" data-id="${id}">Not Now</button>`;
  return `<div class="offer${o.state === 'added' ? ' done' : ''}" data-id="${id}"><span style="min-width:0"><span class="t">${esc(o.title)}</span><span class="why" style="display:block">${why}</span></span><span class="bt">${bt}</span></div>`;
}

function render(s, anim) {
  S = s; R.clear();
  const top = scrollY;
  document.title = met ? 'Nice to meet you' + (s.first ? ', ' + s.first : '') : 'Notes about you';
  let h = '<svg class="ink" id="ink"></svg><div class="tip" id="tip"></div>';
  const told = (s.story || []).flat(), people = s.people || [];
  if (!told.length && !people.length && !(s.profile || []).length && !(s.addresses || []).length) {
    sheet.innerHTML = h + `<div class="empty">${tile('agentMemory', true)}<h1>Notes about you</h1><p>Nothing kept about you yet. Your agent can read the sites you’re signed in to, out of sight, and keep what it learns here. Nothing is sent or bought.</p>${s.agent === false ? '' : '<button type="button" class="btn primary" data-act="know">Get to Know Me</button>'}</div>`;
    last = key(s);
    return Promise.resolve();
  }
  const name = s.first ? ` <span class="nm">${esc(s.first)}</span>` : '';
  h += `<h1 class="ttl" id="ttl">${met ? 'Nice to meet you' + (name ? ',' + name : '') : 'Notes about you'}<span class="dot">.</span></h1>`;
  if (s.portrait) h += `<p class="portrait">${esc(s.portrait)}</p>`;
  h += `<p class="read">${met && s.minutes ? `Read on ${s.sites} ${s.sites === 1 ? 'site' : 'sites'} in ${s.minutes} ${s.minutes === 1 ? 'minute' : 'minutes'}. ` : ''}Everything stays on this Mac.</p>`;

  // What I know: the story, then the brief's lines it doesn't say.
  h += `<section id="p-know"><div class="ph"><h2>What I know</h2><p>Every agent reads this. Point at a line to fix it.</p></div>`;
  h += `<div class="story">${(s.story || []).map(p => `<p>${remember(p.map(r => Object.assign(r, { sec: 'story' }))).map(sentence).join(' ')}</p>`).join('')}</div>`;
  const also = withGone(s.also || [], 'also');
  if (also.length) h += `<div class="sub">Also in your notes</div>${also.map(row).join('')}`;
  const ps = withGone(people, 'people');
  if (ps.length) h += `<div class="sub">Your people${s.morePeople ? ` · ${ps.length} of ${ps.length + s.morePeople}` : ''}</div><div class="cards people">${ps.map(person).join('')}</div>` +
    (s.morePeople ? `<p class="more">And ${s.morePeople} more <button type="button" class="inline" data-act="memory">in Memory</button></p>` : '');
  h += '</section>';

  const doubts = s.doubts || [];
  if (doubts.length) h += `<div class="sub">${doubts.length === 1 ? 'One question' : doubts.length + ' questions'}</div>${doubts.map(question).join('')}`;

  // What forms get: the profile, its links, your home and work; the rest of Autofill under them.
  const forms = withGone(s.profile || [], 'forms'), links = withGone(s.links || [], 'links');
  const addresses = withGone(s.addresses || [], 'addresses'), yours = addresses.filter(r => r.yours), others = addresses.filter(r => !r.yours);
  if (forms.length + links.length + addresses.length) {
    h += `<section id="p-forms"><div class="ph"><h2>What forms get</h2><p>Filled in for you, never sent anywhere else.</p></div><div class="cards">${[...yours, ...forms, ...links].map(fact).join('')}</div>`;
    if (others.length) {
      const tidy = others.some(r => r.act && !r.gone);
      h += `<div class="sub" style="display:flex;align-items:center;gap:10px">Also in Autofill${tidy ? '<button type="button" class="btn sm" data-act="tidy">Tidy Up</button>' : ''}</div><div class="others">${others.map(row).join('')}</div>`;
    }
    h += '</section>';
  }

  // Set up for you, by kind, under each kind's drawing.
  const offers = s.setups || [];
  if (offers.length) {
    const open = offers.filter(o => !o.state).length;
    h += `<section id="p-setup"><div class="ph"><h2>Set up for you</h2><p>${open ? `${open} ${open === 1 ? 'idea' : 'ideas'} · nothing changes until you add it` : 'All set. New ideas show up here.'}</p></div>`;
    for (const [kind, [art, title, line]] of Object.entries(KINDS)) {
      const list = offers.filter(o => o.kind === kind); if (!list.length) continue;
      const left = list.filter(o => !o.state).length;
      const both = left > 1 && kind !== 'routine' ? `<button type="button" class="btn sm quiet" data-act="all" data-id="${kind}">Add ${left === 2 ? 'Both' : 'All'}</button>` : '';
      h += `<div class="kind">${tile(art, true)}<div class="head"><b>${title}</b><span>${line}</span>${both}</div><div class="items">${list.map(offer).join('')}</div></div>`;
    }
    h += '</section>';
  }

  // What it left alone, quiet, last.
  const left = (s.left || []).map(l => `<div class="quote">${l.site ? `<b>${esc(l.site)}</b>: ` : ''}“${esc(l.said)}”</div>`).join('') +
    (s.skipped || []).map(k => `<div class="row"><span class="k">${esc(k.site)}</span><span class="v">${esc(k.why || 'Not read')}</span></div>`).join('');
  if (left) h += `<section id="p-left"><div class="sub">Left alone</div>${left}</section>`;

  h += `<div class="priv">${tile('privacy')}<b>What agents learned</b><p>Inspect the notes, Profile and addresses kept about you, or review what to clear. Passwords, card data and browsing history stay.</p><button type="button" class="forget" data-act="forget-ask">Forget Everything…</button></div>`;
  h += `<div class="foot" id="foot"><span>${s.notes} ${s.notes === 1 ? 'note' : 'notes'} in all</span><button type="button" class="btn sm raised" data-act="memory">Open Memory</button>` +
    (met ? `<span class="hand sig">glad we met <svg viewBox="0 0 30 26"><path d="M15 23C9 18.6 3.2 14.3 3.6 8.6 4 4.4 8.6 2.6 11.6 5c1.5 1.2 2.6 2.8 3.4 4.4.9-2 2.3-4 4.2-5 3.4-1.8 7.4.6 7.2 4.8-.3 5.6-6.2 9.5-11.4 13.8"/></svg></span>` : '') + '</div>';
  sheet.innerHTML = h;
  scrollTo(0, top);
  last = key(s);
  const input = $('.fixin'); if (input) { input.focus(); input.select(); }
  heart();
  return draw(anim);
}
// Drawn now, or once the words being fixed are in.
function paint(s, anim) {
  if (editing) { later = [s, anim]; return Promise.resolve(); }
  later = null;
  return render(s, anim);
}

// ---- the tooltip over a sentence ----
let tipFor = null, tipHide = null;
function showTip(s, ev) {
  clearTimeout(tipHide);
  const tip = $('#tip'); if (!tip || tipFor === s) { if (tip) tip.classList.add('on'); return; }
  $$('.s.on').forEach(x => x.classList.remove('on'));
  s.classList.add('on'); tipFor = s;
  const r = R.get(s.dataset.id) || {};
  tip.innerHTML = (r.gone || r.fixed || fixed.has(r.id) ? '' : `<span class="from">From ${r.brief ? 'your notes' : 'what I read'}</span>`) + acts(r);
  const o = sheet.getBoundingClientRect(), rs = [...s.getClientRects()];
  const line = rs.find(b => ev.clientY >= b.top - 2 && ev.clientY <= b.bottom + 2) || rs[0];
  const w = tip.offsetWidth, x = Math.max(line.left, Math.min(ev.clientX - 30, line.right - w));
  tip.style.left = Math.max(8, Math.min(x - o.left, o.width - w - 8)) + 'px';
  tip.style.top = (line.top - o.top - tip.offsetHeight - 6) + 'px';
  tip.classList.add('on');
}
function hideTip() {
  clearTimeout(tipHide);
  tipHide = setTimeout(() => { const t = $('#tip'); if (t) t.classList.remove('on'); if (tipFor) tipFor.classList.remove('on'); tipFor = null; }, 280);
}
sheet.addEventListener('mouseover', e => {
  const s = e.target.closest('.s');
  if (s && !editing) showTip(s, e);
  else if (e.target.closest('#tip')) clearTimeout(tipHide);
  else if (tipFor) hideTip();
});
sheet.addEventListener('mouseleave', hideTip);

// ---- what you do ----
function carry(r) { return { id: r.id, kind: r.kind, key: r.key || '', path: r.path || '', raw: r.raw || '', nth: r.nth || 0, act: r.act || '' }; }
const story = r => r.sec === 'story' && !r.brief;
async function cross(id) {
  const r = R.get(id); if (!r || r.gone) return;
  if (story(r)) { undos.push(id); return paint(await ask('say', { id, act: 'cross' }), id); }
  gone.set(id, { sec: r.sec, idx: r.idx, row: r });
  undos.push(id);
  paint(await ask('forget', carry(r)), id);
}
async function undo(id) {
  if (!id) return;
  const s = await ask('undo', { id });
  gone.delete(id); fixed.delete(id);
  const at = undos.lastIndexOf(id); if (at >= 0) undos.splice(at, 1);
  paint(s);
}
function fix(id) {
  const r = R.get(id); if (!r || r.gone || editing) return;
  if (r.kind === 'address') { ask('edit-address', { key: r.key }); return; }
  editing = id;
  hideTip();
  render(S);
  const input = $('.fixin'); if (!input) { editing = null; return; }
  let done = false;
  const commit = async save => {
    if (done) return; done = true; editing = null;
    const value = input.value.trim(), was = r.fixed || r.value || plain(r.text);
    if (!save || !value || flat(value) === flat(was)) { paint(later ? later[0] : S); return; }
    if (story(r)) { undos.push(id); paint(await ask('say', { id, value }), id); return; }
    const s = await ask('fix', Object.assign(carry(r), { value }));
    if (s.now) { fixed.set(s.now, fixed.get(id) || r.value); if (s.now !== id) fixed.delete(id); undos.push(s.now); }
    paint(s);
  };
  input.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') { e.preventDefault(); commit(true); } if (e.key === 'Escape') { e.preventDefault(); commit(false); } });
  input.addEventListener('blur', () => commit(true));
}
async function tidy() {
  const doing = [...R.values()].filter(r => r.sec === 'addresses' && r.act && !r.gone);
  for (const r of doing) { gone.set(r.id, { sec: r.sec, idx: r.idx, row: r }); undos.push(r.id); }
  paint(await ask('tidy', { ids: doing.map(r => r.id) }));
}
async function setup(id, act) {
  if (act === 'undo') return paint(await ask('setup', { id, act }));
  const s = await ask('setup', { id, act });
  paint(s, act === 'add' ? id : null);
}
function note(id) {
  const el = $(`[data-id="${CSS.escape(id)}"]`); if (!el) return;
  el.scrollIntoView({ block: 'center', behavior: moving() ? 'smooth' : 'auto' });
  el.classList.add(el.classList.contains('card') ? 'lit' : 'on');
  setTimeout(() => el.classList.remove('lit', 'on'), 1500);
}
// A part of the page, from a link in the run's chat: #brief, #forms, #addresses, #left.
function go(name) {
  const id = { brief: 'know', people: 'know', making: 'know', forms: 'forms', addresses: 'forms', left: 'left', setup: 'setup' }[name] || name;
  const el = name && document.getElementById('p-' + id);
  if (el) el.scrollIntoView({ block: 'start', behavior: moving() ? 'smooth' : 'auto' });
}
window.yabGo = name => { wanted = name; if (!writing && S) { go(name); wanted = ''; } };
addEventListener('hashchange', () => yabGo(location.hash.slice(1)));

document.addEventListener('click', async e => {
  const b = e.target.closest('[data-act]'); if (!b) return;
  const id = b.dataset.id;
  switch (b.dataset.act) {
    case 'cross': cross(id); break;
    case 'fix': fix(id); break;
    case 'undo': undo(id); break;
    case 'tidy': tidy(); break;
    case 'pick': paint(await ask('pick', { id, pick: Number(b.dataset.pick) }), id); break;
    case 'repick': S.doubts.forEach(d => { if (d.id === id) d.picked = -2; }); render(S); break;
    case 'setup': setup(id, b.dataset.do); break;
    case 'all': for (const o of (S.setups || []).filter(o => o.kind === id && !o.state)) await setup(o.id, 'add'); break;
    case 'note': note(id); break;
    case 'person': note('note:' + id); break;
    case 'memory': ask('memory'); break;
    case 'know': ask('know'); break;
    case 'forget-ask': paint(await ask('forget-all')); break;
  }
});
document.addEventListener('keydown', e => {
  if (e.target.closest && e.target.closest('input')) return;
  if (e.metaKey && e.key === 'z') { e.preventDefault(); undo(undos[undos.length - 1]); }
});

// ---- the first time: written out as you watch ----
const pause = ms => moving() ? new Promise(r => setTimeout(r, ms)) : Promise.resolve();
const seen = () => document.visibilityState === 'visible' ? Promise.resolve() : new Promise(r => {
  const look = () => { if (document.visibilityState !== 'visible') return; document.removeEventListener('visibilitychange', look); r(); };
  document.addEventListener('visibilitychange', look);
});
async function writeOut() {
  writing = true;
  const parts = [$('#ttl'), $('.portrait'), $('.read'), ...$$('section, .sub, .q, .priv, .foot')].filter(Boolean);
  parts.forEach(el => el.classList.add('hidden'));
  $('#ink').innerHTML = '';
  await seen();
  for (let i = 0; i < parts.length; i++) {
    parts[i].classList.remove('hidden');
    if (moving()) parts[i].animate([{ opacity: 0, transform: 'translateY(8px)' }, { opacity: 1, transform: 'none' }], { duration: 380, easing: 'cubic-bezier(.2,.8,.2,1)' });
    await pause(i < 3 ? 260 : 90);
  }
  writing = false;
  await draw();
  ask('seen');
  if (wanted) { go(wanted); wanted = ''; }
}

async function tick() {
  if (!editing && !writing && document.visibilityState === 'visible') {
    try { const s = await ask('state'); if (!editing && !writing && key(s) !== last) render(s); } catch (e) {}
  }
  setTimeout(tick, 4000);
}
(async () => {
  const s = await ask('state');
  await render(s);
  if (!wanted) wanted = location.hash.slice(1);
  if (s.fresh && !still.matches) await writeOut();
  else { if (s.fresh) ask('seen'); if (wanted) { go(wanted); wanted = ''; } }
  setTimeout(tick, 3000);
})();
new ResizeObserver(() => { if (!writing && S) draw(); }).observe(sheet);
</script>
</body>
</html>
"""#
    }
}
