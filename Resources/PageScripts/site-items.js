(function () {
  // The things on a site's pages a skill's actions are about (SiteItems.swift):
  // a button of Yab's in the site's own row beside each, and which one the
  // pointer is on, for ⌘J. Yab's world: the page never sees this script.
  if (window.__yabItems) return;
  var specs = __YAB_SPECS__;
  var hidden = new Set(__YAB_HIDDEN__);
  var MARK = 'data-yab-item';
  var on = true;
  var told = false;
  var pointed = '';
  var mineTold = new Set();
  var frame = 0;

  function post(message) {
    try { window.webkit.messageHandlers.yabItems.postMessage(message); } catch (e) {}
  }
  function visible(el) {
    if (!(el instanceof HTMLElement)) return false;
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var s = getComputedStyle(el);
    return s.display !== 'none' && s.visibility !== 'hidden';
  }
  function one(root, selector) {
    if (!selector || !root) return null;
    try { return root.querySelector(selector); } catch (e) { return null; }
  }
  function all(root, selector) {
    if (!selector || !root) return [];
    try { return Array.prototype.slice.call(root.querySelectorAll(selector)); } catch (e) { return []; }
  }
  function words(el, most) {
    return el ? (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, most) : '';
  }
  function holder(spec, el) {
    if (spec.container === 'page') return document.body;
    try { return el.closest(spec.container); } catch (e) { return null; }
  }
  function ours(el) {
    return el instanceof Element && el.hasAttribute(MARK);
  }

  // What the agent is told about it, and the key it is hidden by.
  function info(spec, root) {
    var page = spec.container === 'page';
    var scope = page ? document : root;
    var linked = one(scope, spec.link);
    var link = linked ? (linked.href || linked.getAttribute('href') || '') : '';
    var name = words(one(scope, spec.name), 80);
    var when = words(one(scope, spec.when), 40);
    var body = (spec.body && one(scope, spec.body)) || (page ? null : root);
    var text = '';
    if (body) {
      // Without Yab's own button in it.
      var copy = body.cloneNode(true);
      all(copy, '[' + MARK + ']').forEach(function (b) { b.remove(); });
      text = words(copy, 1500);
    }
    var key = page ? location.origin + location.pathname + location.hash
      : link || [name, when, text.slice(0, 80)].join(' ');
    return {
      kind: spec.kind, spec: specs.indexOf(spec), key: spec.kind + ' ' + key,
      name: name, title: words(one(scope, spec.title), 160), when: when,
      link: link || location.href, text: text
    };
  }

  // The site's own controls Yab's button stands beside, in rows: each
  // thing's last one, or for a page, the last row of `min` together.
  function rows(spec) {
    // A page-wide gate (Gmail's open thread) applies before any anchors:
    // an inbox cannot get a button, even while its rows keep changing.
    if (spec.container === 'page' && !passes(spec, document.body)) return [];
    var text = spec.text ? new RegExp(spec.text, 'i') : null;
    var anchors = all(document, spec.anchor).filter(function (a) {
      if (ours(a) || !visible(a) || (text && !text.test(words(a, 80)))) return false;
      // A row of buttons: each the height of one.
      var h = a.getBoundingClientRect().height;
      return spec.min < 2 || (h >= 24 && h <= 56);
    });
    var found = [];
    if (spec.min > 1) {
      var parents = [];
      anchors.forEach(function (a) { if (a.parentElement && parents.indexOf(a.parentElement) < 0) parents.push(a.parentElement); });
      parents.forEach(function (p) {
        var own = anchors.filter(function (a) { return a.parentElement === p; });
        if (own.length < spec.min) return;
        var root = holder(spec, p);
        if (root) found.push({ root: root, anchor: own[own.length - 1] });
      });
    } else {
      anchors.forEach(function (a) {
        var root = holder(spec, a);
        if (!root) return;
        var at = -1;
        for (var i = 0; i < found.length; i++) if (found[i].root === root) at = i;
        if (at < 0) found.push({ root: root, anchor: a });
        else found[at].anchor = a;
      });
    }
    // One button for the page: the row nearest its end.
    if (spec.container === 'page' && found.length > 1) found = [found[found.length - 1]];
    // `if`: only where a control there says so (X's box whose button says Reply, not Post).
    return spec.container === 'page' ? found : found.filter(function (row) { return passes(spec, row.root); });
  }

  // `if`: only where a control there says so (X's box whose button says
  // Reply, not Post; Gmail's open thread, not its notifications banner).
  function passes(spec, root) {
    if (!spec.gate) return true;
    var cut = spec.gate.lastIndexOf(' ~ ');
    var sel = cut < 0 ? spec.gate : spec.gate.slice(0, cut), said = cut < 0 ? null : new RegExp(spec.gate.slice(cut + 3), 'i');
    var el = one(spec.container === 'page' ? document : root, sel);
    return !!el && visible(el) && (!said || said.test(words(el, 80)));
  }

  // Whether the anchor's row runs down rather than across.
  function stacked(anchor) {
    var kids = anchor.parentElement ? Array.prototype.filter.call(anchor.parentElement.children, visible) : [];
    if (kids.length < 2) return false;
    var a = kids[0].getBoundingClientRect(), b = kids[1].getBoundingClientRect();
    return Math.abs(a.left - b.left) < 2 && b.top >= a.bottom - 1;
  }

  // The first element holding words of its own, outside Yab's buttons.
  function textual(el) {
    if (!el) return null;
    var walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (var n = walk.nextNode(); n; n = walk.nextNode()) {
      var at = n.parentElement;
      if (n.nodeValue.trim() && at && !at.closest('[' + MARK + ']')) return at;
    }
    return null;
  }

  // The agent's face, as its tabs wear it (AgentFace.swift): a circle and
  // two eyes on a 24-point grid, the raised hand when it needs you, the
  // eyes swung into a tick when it is done. Drawn in the site's ink, at
  // the size and line of the site's own glyphs beside it.
  var NS = 'http://www.w3.org/2000/svg';
  var HAND = 'M12.0673 2C11.4414 2 10.934 2.50447 10.934 3.12676V9.88732C10.934 10.1985 10.6803 10.4507 10.3674 10.4507C10.0545 10.4507 9.80077 10.1985 9.80077 9.88732V4.25352C9.80077 3.63123 9.2934 3.12676 8.66753 3.12676C8.04165 3.12676 7.53428 3.63123 7.53428 4.25352V11.1464C7.53428 11.3763 7.39386 11.5831 7.17946 11.669C6.96506 11.7549 6.71966 11.7027 6.55938 11.5371L5.21282 10.1458C4.43664 9.34385 3.10627 9.49382 2.53035 10.4482L2.5 10.4985L5.29405 17.2834C6.46887 20.1363 9.26174 22 12.3623 22C16.5805 22 20 18.6 20 14.406V6.50704C20 5.88475 19.4926 5.38028 18.8668 5.38028C18.2409 5.38028 17.7335 5.88475 17.7335 6.50704V11.0141C17.7335 11.3252 17.4798 11.5775 17.1669 11.5775C16.8539 11.5775 16.6003 11.3252 16.6003 11.0141V4.25352C16.6003 3.63123 16.0929 3.12676 15.467 3.12676C14.8411 3.12676 14.3338 3.63123 14.3338 4.25352V10.4507C14.3338 10.7619 14.0801 11.0141 13.7671 11.0141C13.4542 11.0141 13.2005 10.7619 13.2005 10.4507V3.12676C13.2005 2.50447 12.6931 2 12.0673 2Z';
  var still = false;
  try { still = matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) {}
  var moving = new Set();
  var ticking = 0;

  function faceArt(size, stroke) {
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    if (size) { svg.setAttribute('width', size); svg.setAttribute('height', size); }
    svg.style.overflow = 'visible';
    svg.style.flex = '0 0 auto';
    var w = String(Math.round(stroke * 100) / 100);
    function part(tag, attrs) {
      var node = document.createElementNS(NS, tag);
      Object.keys(attrs).forEach(function (key) { node.setAttribute(key, attrs[key]); });
      svg.appendChild(node);
      return node;
    }
    part('circle', { cx: '12', cy: '12', r: '9', fill: 'none', stroke: 'currentColor', 'stroke-width': w });
    var hand = part('path', { fill: 'currentColor', opacity: '0', d: HAND });
    hand.style.transformOrigin = '12px 16px';
    part('path', { fill: 'none', stroke: 'currentColor', 'stroke-width': w, 'stroke-linecap': 'round' });
    svg.__face = { gx: 0, gy: 0, open: 1, tick: 0, hand: 0, mode: 'rest', t0: 0, blink: -1, look: [-0.7, 0.3], until: 0 };
    draw(svg, 1, 0);
    return svg;
  }
  // Its stroke in the grid's units for `px` on screen.
  function line(size, px) { return px ? px * 24 / size : 2; }

  function goal(f, t) {
    var g = { gx: 0, gy: 0, open: 1, tick: 0, hand: 0 }, d = t - f.t0;
    if (f.mode === 'thing') { g.gx = f.look[0]; g.gy = f.look[1]; }
    else if (f.mode === 'button') g.gy = 0.05;
    else if (f.mode === 'press') { g.gx = -1; g.gy = -0.1; if (d > 0.35) { f.mode = 'work'; f.t0 = t; } }
    else if (f.mode === 'work') {
      // The eyes run along three lines and back, as on a tab it reads.
      var p = (d % 2.7) / 0.9, row = Math.floor(p);
      g.gx = -0.7 + 1.4 * Math.min(1, (p - row) / 0.8); g.gy = -0.35 + 0.35 * row;
    } else if (f.mode === 'hand') { g.hand = 1; g.open = 0.1; }
    else if (f.mode === 'done') g.tick = 1;
    return g;
  }
  function draw(svg, open, t) {
    var f = svg.__face, kids = svg.childNodes;
    var half = 1.25 * Math.max(0.08, open), dx = f.gx * 2.3, dy = f.gy * 2, k = f.tick;
    function m(ax, ay, bx, by) { return (ax + (bx - ax) * k).toFixed(2) + ' ' + (ay + (by - ay) * k).toFixed(2); }
    kids[2].setAttribute('d', 'M' + m(9.5 + dx, 11 + dy - half, 7.5, 12.3) + 'L' + m(9.5 + dx, 11 + dy + half, 10.7, 15.5)
      + 'M' + m(14.5 + dx, 11 + dy + half, 10.7, 15.5) + 'L' + m(14.5 + dx, 11 + dy - half, 16.8, 9));
    kids[0].style.opacity = String(1 - f.hand);
    kids[2].style.opacity = String(Math.max(0, 1 - f.hand * 2.2));
    kids[1].setAttribute('opacity', f.hand.toFixed(3));
    var turn = 0;
    // The hand waves as it lands, and a little every three seconds.
    if (f.mode === 'hand' && !still) { var p = (t - f.t0) % 3; if (p < 0.6) turn = Math.sin(p / 0.6 * Math.PI * 2) * 12 * (1 - p / 0.6); }
    kids[1].style.transform = 'scale(' + (0.7 + 0.3 * f.hand).toFixed(3) + ') rotate(' + turn.toFixed(1) + 'deg)';
  }
  function step() {
    ticking = 0;
    var t = performance.now() / 1000;
    moving.forEach(function (svg) {
      if (!svg.isConnected) { moving.delete(svg); return; }
      var f = svg.__face, g = goal(f, t), k = still ? 1 : 0.2;
      f.gx += (g.gx - f.gx) * k; f.gy += (g.gy - f.gy) * k;
      f.open += (g.open - f.open) * (still ? 1 : 0.25);
      f.tick += (g.tick - f.tick) * (still ? 1 : 0.16);
      f.hand += (g.hand - f.hand) * (still ? 1 : 0.14);
      var open = f.open, b = (t - f.blink) / 0.21;
      if (!still && b >= 0 && b <= 1) open *= b < 0.29 ? 1 - b / 0.29 * 0.9 : b < 0.43 ? 0.1 : 0.1 + (b - 0.43) / 0.57 * 0.9;
      draw(svg, open, t);
      if (f.mode === 'done' && f.until && t > f.until) { f.mode = 'rest'; f.until = 0; }
      // Settled and keeping still: off the clock.
      var near = Math.abs(g.gx - f.gx) + Math.abs(g.gy - f.gy) + Math.abs(g.open - f.open) + Math.abs(g.tick - f.tick) + Math.abs(g.hand - f.hand);
      if (near < 0.002 && b > 1 && f.mode !== 'work' && f.mode !== 'hand' && f.mode !== 'press' && !f.until) moving.delete(svg);
    });
    if (moving.size) ticking = requestAnimationFrame(step);
  }
  function pose(svg, mode, look) {
    var f = svg && svg.__face;
    if (!f || !on) return;
    // A task's face is the task's until it ends: hovering doesn't move it.
    var busy = f.mode === 'press' || f.mode === 'work' || f.mode === 'hand';
    if (busy && (mode === 'rest' || mode === 'thing' || mode === 'button')) return;
    if (f.mode === 'done' && (mode === 'thing' || mode === 'button')) return;
    if (mode === f.mode) return;
    var t = performance.now() / 1000;
    if (look) f.look = look;
    if (mode === 'thing') f.blink = t + 0.32;
    else if (mode === 'button' || mode === 'press' || mode === 'done' || f.mode === 'hand') f.blink = t + 0.05;
    f.mode = mode; f.t0 = t;
    f.until = 0;
    moving.add(svg);
    if (!ticking) ticking = requestAnimationFrame(step);
  }
  function faceOf(b) { return b ? b.querySelector('svg[data-yab-face]') : null; }
  // Where the thing is from its button, for the eyes to look: the way to
  // the middle of its words.
  function towards(b, spec, root) {
    var at = (spec.body && one(spec.container === 'page' ? document : root, spec.body)) || root;
    if (!at || at === document.body) return [-0.7, -0.5];
    var r = b.getBoundingClientRect(), q = at.getBoundingClientRect();
    var x = (q.left + q.width / 2) - (r.left + r.width / 2), y = (q.top + Math.min(q.height, 60) / 2) - (r.top + r.height / 2);
    var n = Math.sqrt(x * x + y * y) || 1;
    return [x / n * 0.8, y / n * 0.8];
  }

  // The site's own glyph beside it, when there is one: its svg, or a
  // picture drawn before its words (Gmail's Reply).
  function glyph(model) {
    var svg = model.querySelector('svg');
    if (svg && visible(svg)) {
      var r = svg.getBoundingClientRect();
      return { size: Math.round(r.width * 100) / 100, color: getComputedStyle(svg).color, el: svg };
    }
    var before = getComputedStyle(model, '::before');
    var w = parseFloat(before.width);
    if (before.content !== 'none' && w > 0) return { size: w, color: '', gap: parseFloat(before.marginRight) || 8 };
    return null;
  }
  // How far its glyph stands from its words.
  function gapOf(model, g) {
    if (g.gap) return g.gap;
    var words = textual(model);
    if (!g.el || !words) return 6;
    var d = words.getBoundingClientRect().left - g.el.getBoundingClientRect().right;
    return d > 0 && d < 16 ? Math.round(d) : 6;
  }

  // `style: clone`: the anchor itself again, its glyph the face, its words
  // gone: in a row of icons, the site's own button with the site's own
  // size, ink, hover and press. What makes it the site's (ids, handlers'
  // names, inputs, labels) is left out.
  // A model with a glyph drawn before its words (Gmail's Reply), not an
  // svg: the clone's is hidden, and the face stands in its place.
  var noGlyph = null;
  function hideGlyphs() {
    if (noGlyph && noGlyph.isConnected) return;
    noGlyph = document.createElement('style');
    noGlyph.textContent = '[data-yab-noglyph]::before { display: none !important; }';
    (document.head || document.documentElement).appendChild(noGlyph);
  }

  // `style: clone`: the site's own control again, the one beside it (or the
  // one `like` names), so the site's rules give it its size, ink, font,
  // hover and press. Its glyph is the face; its words, if it has any, are
  // ours ("Review with Claude" as GitHub's All commits; Slack's More
  // actions as the face alone). What makes it the site's (ids, test and
  // handler names, inputs, labels, a tooltip) is left out.
  function cloned(spec, anchor, model) {
    // Never from a control under the pointer: its hover and its tooltip
    // would be copied too and stay. Another of the row at rest will do.
    var source = model || anchor;
    if (source.matches(':hover')) {
      var calm = Array.prototype.filter.call(source.parentElement ? source.parentElement.children : [], function (o) {
        return o !== source && !ours(o) && !o.matches(':hover') && o.querySelector('svg') && visible(o);
      });
      if (calm.length) source = calm[calm.length - 1];
    }
    var mark = glyph(source);
    var c = source.cloneNode(true);
    // Words floating over the row (a tooltip): not part of the button. A
    // wordless layer laid over it is its hover (Google's) and stays.
    var glyphAt = source.querySelector('svg');
    var originals = [source].concat(all(source, '*')), copies = [c].concat(all(c, '*'));
    var floating = [];
    originals.forEach(function (o, i) {
      if (i === 0 || !copies[i] || (glyphAt && o.contains(glyphAt)) || !o.textContent.trim()) return;
      var at = getComputedStyle(o).position;
      if (at === 'absolute' || at === 'fixed') floating.push(copies[i]);
    });
    floating.forEach(function (e) { e.remove(); });
    all(c, 'input, textarea, select, iframe, video, img, [role="tooltip"]').forEach(function (e) { e.remove(); });
    // Data the site's styles read (Primer's data-variant) stays; names its
    // scripts and tests find things by don't.
    [c].concat(all(c, '*')).forEach(function (e) {
      Array.prototype.slice.call(e.attributes).forEach(function (a) {
        var n = a.name;
        if (n === 'id' || n === 'href' || n === 'name' || n === 'disabled' || n === 'title' || n.indexOf('aria-') === 0
            || n.indexOf('js') === 0 || n.indexOf('on') === 0 || n === 'data-testid' || n === 'data-qa'
            || n.indexOf('data-tooltip') === 0 || n.indexOf('data-yab') === 0) e.removeAttribute(n);
      });
    });
    var svgs = all(c, 'svg');
    var first = svgs[0];
    svgs.slice(1).forEach(function (e) { e.remove(); });
    var size = spec.icon || (mark ? mark.size : 0);
    // The words: its first run of them ours, the rest gone; none, none.
    var walk = document.createTreeWalker(c, NodeFilter.SHOW_TEXT), texts = [];
    for (var n = walk.nextNode(); n; n = walk.nextNode()) if (n.nodeValue.trim()) texts.push(n);
    var lead = texts[0] || null;
    if (lead) lead.nodeValue = spec.label;
    texts.slice(1).forEach(function (t) { t.remove(); });
    if (!size && lead) size = Math.round(parseFloat(getComputedStyle(source).fontSize) * 1.15);
    size = size || 18;
    var art = faceArt(first ? 0 : size, line(size, spec.stroke));
    art.setAttribute('data-yab-face', '');
    if (first) {
      // Its classes and size, so the site's rules draw it as the glyph was.
      ['class', 'width', 'height', 'style'].forEach(function (n) { var v = first.getAttribute(n); if (v) art.setAttribute(n, v); });
      art.style.overflow = 'visible';
      if (!first.getAttribute('width') && !first.getAttribute('class')) { art.setAttribute('width', size); art.setAttribute('height', size); }
      first.replaceWith(art);
    } else if (lead) {
      // Before the words, as far from them as the model's own glyph was.
      if (mark && !mark.el) { c.setAttribute('data-yab-noglyph', ''); hideGlyphs(); }
      art.style.marginRight = (mark && mark.gap ? mark.gap : 6) + 'px';
      art.style.verticalAlign = '-0.2em';
      lead.parentNode.insertBefore(art, lead);
    } else {
      var press = c.matches('button, [role="button"]') ? c : (one(c, 'button, [role="button"]') || c);
      press.appendChild(art);
    }
    return c;
  }


  // A clone's hover. Where the site draws it with CSS (Slack, Linear) the
  // clone has it already. Where the site's script draws it (X, Google),
  // the row is watched: what the site puts on an icon of its own while the
  // pointer is on it (classes, a style), keyed by the element's classes at
  // rest, is put on the clone's element with the same classes, and taken
  // off again. Until the row has shown one, the icon's ink at `hover:`
  // (8% if unsaid) behind it, as both of those sites draw it.
  var learned = {};
  var watchedRows = new WeakSet();
  var restOf = new WeakMap();
  function classes(v) { return (v || '').split(/\s+/).filter(Boolean); }
  function learn(row) {
    if (!row || watchedRows.has(row)) return;
    watchedRows.add(row);
    // Every icon as it is now, at rest, for what a hover changes on it.
    all(row, '*').forEach(function (e) {
      restOf.set(e, { cls: e.getAttribute('class') || '', style: e.getAttribute('style') || '' });
    });
    new MutationObserver(function (records) {
      // What each record left, though later ones in the batch changed it
      // again: the next record's old value, or the element as it is now.
      var seen = new Map();
      records.forEach(function (m, i) {
        var t = m.target;
        if (!(t instanceof Element) || t.closest('[' + MARK + ']')) return;
        var icon = t;
        while (icon && icon.parentElement !== row) icon = icon.parentElement;
        if (!icon) return;
        var next = null;
        for (var j = i + 1; j < records.length && !next; j++) {
          if (records[j].target === t && records[j].attributeName === m.attributeName) next = records[j];
        }
        var value = next ? (next.oldValue || '') : (t.getAttribute(m.attributeName) || '');
        var rest = restOf.get(t) || { cls: m.attributeName === 'class' ? (m.oldValue || '') : (t.getAttribute('class') || ''),
                                      style: m.attributeName === 'style' ? (m.oldValue || '') : (t.getAttribute('style') || '') };
        if (!restOf.has(t)) restOf.set(t, rest);
        var now = seen.get(t) || { cls: rest.cls, style: rest.style };
        if (m.attributeName === 'class') now.cls = value; else now.style = value;
        seen.set(t, now);
        if (!icon.matches(':hover') && !(over && icon.contains(over))) { restOf.set(t, { cls: now.cls, style: now.style }); return; }
        var was = classes(rest.cls), cls = classes(now.cls);
        var got = {
          add: cls.filter(function (c) { return was.indexOf(c) < 0; }),
          drop: was.filter(function (c) { return cls.indexOf(c) < 0; }),
          style: now.style !== rest.style ? now.style : null
        };
        // Back as it was at rest: nothing to learn from that.
        if (!got.add.length && !got.drop.length && got.style === null) return;
        learned[rest.cls] = got;
      });
    }).observe(row, { attributes: true, attributeFilter: ['class', 'style'], attributeOldValue: true, subtree: true });
  }
  // What a hover paints behind an icon: a fill, or a layer before it.
  function look(el) {
    var c = getComputedStyle(el), b = getComputedStyle(el, '::before');
    return c.backgroundColor + '|' + b.backgroundColor + '|' + b.opacity;
  }
  function hovering(b, spec, anchor) {
    learn(anchor.parentElement);
    // The face draws itself: its parts are not the site's to restyle.
    var parts = [b].concat(all(b, '*')).filter(function (e) { return !e.closest('svg[data-yab-face]'); });
    var press = one(b, 'button, [role="button"]') || b;
    var rest = null;
    b.addEventListener('pointerenter', function () {
      rest = parts.map(function (e) { return { cls: e.getAttribute('class'), style: e.getAttribute('style') }; });
      var any = false;
      parts.forEach(function (e, i) {
        var got = learned[rest[i].cls || ''];
        if (!got) return;
        any = true;
        got.drop.forEach(function (c) { e.classList.remove(c); });
        got.add.forEach(function (c) { e.classList.add(c); });
        if (got.style !== null) e.setAttribute('style', got.style);
      });
      if (any) return;
      // None seen yet: a hover the site's CSS draws shows against the
      // clone at rest; where none does, the tint.
      var calm = b.__yabCalm;
      if (calm && parts.some(function (e, i) { return look(e) !== calm[i]; })) return;
      var ink = getComputedStyle(press.firstElementChild || press).color;
      press.style.backgroundColor = 'color-mix(in srgb, ' + ink + ' ' + (Math.round(parseFloat(spec.hover)) || 8) + '%, transparent)';
    });
    b.addEventListener('pointerleave', function () {
      if (!rest) return;
      parts.forEach(function (e, i) {
        if (rest[i].cls === null) e.removeAttribute('class'); else e.setAttribute('class', rest[i].cls);
        if (rest[i].style === null) e.removeAttribute('style'); else e.setAttribute('style', rest[i].style);
      });
      rest = null;
    });
    // How it looks at rest once it is in the page.
    setTimeout(function () { if (b.isConnected && !b.matches(':hover')) b.__yabCalm = parts.map(look); }, 0);
  }

  function button(spec, anchor, root, key) {
    var b, face;
    if (spec.style === 'clone') {
      var model = spec.like ? (one(root, spec.like) || one(document, spec.like)) : null;
      b = cloned(spec, anchor, model && visible(model) && !ours(model) ? model : null);
      face = faceOf(b);
    } else {
      b = document.createElement('button');
      b.type = 'button';
      var words = document.createElement('span');
      words.textContent = spec.label;
      b.appendChild(words);
    }
    b.__yabRoot = root;
    b.__yabSpec = spec;
    b.setAttribute(MARK, key);
    b.title = spec.tip;
    // A clone's own button inside it is the one to reach and to name.
    var named = (spec.style === 'clone' && one(b, 'button, [role="button"]')) || b;
    named.setAttribute('aria-label', spec.full || spec.label);
    if (named.tagName !== 'BUTTON') named.setAttribute('role', 'button');
    named.tabIndex = 0;
    if (spec.style === 'class') {
      b.className = anchor.className;
      var mark = glyph(anchor);
      face = faceArt(mark ? mark.size : 16, line(mark ? mark.size : 16, spec.stroke));
      Object.assign(b.style, { width: 'auto', minWidth: '0', padding: '0 8px', whiteSpace: 'nowrap', fontSize: '12px', fontWeight: '700',
                               display: 'inline-flex', alignItems: 'center', gap: '6px' });
      b.insertBefore(face, b.firstChild);
    } else if (spec.style !== 'clone') {
      // The look of the anchor, or of the control `like` names (in the
      // thing first, then anywhere on the page).
      var like = spec.like ? (one(root, spec.like) || one(document, spec.like)) : null;
      var model = like && visible(like) ? like : anchor;
      var cs = getComputedStyle(model);
      var r = model.getBoundingClientRect();
      // A site that sets its face only on the words inside (X's spans):
      // the font and ink of the words, not the wrapper's browser default.
      var lettered = textual(model) || textual(anchor.parentElement);
      var type = lettered ? getComputedStyle(lettered) : cs;
      var own = glyph(model);
      // Its glyph as big as the model's, or as its words are tall.
      var size = spec.icon || (own ? own.size : Math.round(parseFloat(type.fontSize) * 1.15));
      face = faceArt(size, line(size, spec.stroke));
      if (own && own.color && own.color !== type.color) face.style.color = own.color;
      // An icon's square button gives a word less room at its sides.
      var side = r.width <= r.height * 1.2 ? '10px' : '16px';
      // A round icon's 50% would make a long word an ellipse: half its height.
      var radius = cs.borderRadius.indexOf('%') >= 0 ? (r.height / 2) + 'px' : cs.borderRadius;
      Object.assign(b.style, {
        boxSizing: 'border-box', display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        gap: (own ? gapOf(model, own) : 6) + 'px',
        // As wide as its words, whatever the site's rules for its buttons say.
        width: 'auto', minWidth: '0', maxWidth: 'none', flex: '0 0 auto',
        // A model with a glyph of its own has the room beside it right.
        height: r.height + 'px', padding: own ? cs.padding : '0 ' + side, whiteSpace: 'nowrap', margin: cs.margin,
        border: cs.border, borderRadius: radius, background: cs.backgroundColor,
        color: type.color, font: type.font, letterSpacing: type.letterSpacing, cursor: 'pointer'
      });
      b.insertBefore(face, b.firstChild);
      // A column of buttons as wide as each other (Amazon's): as wide too.
      if (stacked(anchor)) b.style.width = r.width + 'px';
    }
    if (face) face.setAttribute('data-yab-face', '');
    if (spec.style === 'clone') hovering(b, spec, anchor);
    b.addEventListener('pointerenter', function () { pose(faceOf(b), 'button'); });
    b.addEventListener('pointerleave', function () { pose(faceOf(b), pointed === key ? 'thing' : 'rest', towards(b, spec, root)); });
    // The site's own handlers on the row never hear it.
    ['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach(function (type) {
      b.addEventListener(type, function (e) { e.stopPropagation(); });
    });
    b.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      // Its task under way or done: the press goes to it, never a second one.
      var svg = faceOf(b), f = svg && svg.__face;
      if (f && (f.mode === 'press' || f.mode === 'work' || f.mode === 'hand' || f.mode === 'done')) {
        if (f.mode === 'done') pose(svg, 'rest');
        post({ k: 'open', item: info(spec, root) });
        return;
      }
      pose(svg, 'press');
      post({ k: 'press', item: info(spec, root) });
    });
    b.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      e.preventDefault();
      e.stopPropagation();
      b.click();
    });
    b.addEventListener('contextmenu', function (e) {
      e.preventDefault();
      e.stopPropagation();
      post({ k: 'menu', x: e.clientX, y: e.clientY, item: info(spec, root) });
    });
    return b;
  }

  // Addressed to you (`mine:`): a selector in the thing, or `path:` and a
  // pattern over the page's path, `*` within one part of it.
  function mine(spec, root) {
    if (!spec.mine) return false;
    if (spec.mine.indexOf('path:') === 0) {
      var glob = spec.mine.slice(5).trim().replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*');
      // "/notifications/mentions/" is "/notifications/mentions".
      var path = location.pathname.length > 1 ? location.pathname.replace(/\/+$/, '') : location.pathname;
      return new RegExp('^' + glob + '$').test(path);
    }
    return !!one(spec.container === 'page' ? document : root, spec.mine);
  }

  function scan() {
    frame = 0;
    // A page out of sight too: its buttons are there when it comes back.
    if (!on) return;
    specs.forEach(function (spec) {
      rows(spec).forEach(function (row) {
        // A site that moves one row from thing to thing (Slack's hover
        // actions): the button there is the last thing's, made again.
        var there = one(row.anchor.parentElement, '[' + MARK + ']');
        if (there && there.__yabRoot === row.root) return;
        if (there) there.remove();
        var key = info(spec, row.root).key;
        if (hidden.has(key)) return;
        if (!mineTold.has(key) && mine(spec, row.root)) {
          mineTold.add(key);
          post({ k: 'mine', item: info(spec, row.root) });
        }
        if (spec.container !== 'page' && one(row.root, '[' + MARK + ']')) return;
        var b = button(spec, row.anchor, row.root, key);
        // An anchor in a wrapper of its own (Linear's tooltips) keeps the
        // row's gap outside it: the button keeps its own from the anchor.
        var wrap = row.anchor.parentElement;
        if (wrap && wrap.children.length === 1) {
          var gap = wrap.parentElement ? parseFloat(getComputedStyle(wrap.parentElement).columnGap) : 0;
          b.style[spec.place === 'before' ? 'marginRight' : 'marginLeft'] = (gap > 0 ? gap : 6) + 'px';
        }
        row.anchor.insertAdjacentElement(spec.place === 'before' ? 'beforebegin' : 'afterend', b);
        if (!told) { told = true; post({ k: 'shown' }); }
      });
    });
  }
  // A timer, not a frame: WebKit holds frames back from a window out of
  // sight, and a row the site moved would keep the last thing's button.
  function soon() {
    if (!frame && on) frame = setTimeout(scan, 30);
  }

  // Which thing the pointer is on, for ⌘J: said only when it changes.
  function point(target) {
    var found = null;
    for (var i = 0; i < specs.length && !found; i++) {
      var spec = specs[i];
      if (spec.container === 'page') continue;
      var root = target instanceof Element ? holder(spec, target) : null;
      if (root && passes(spec, root)) found = info(spec, root);
    }
    if (!found) {
      for (var j = 0; j < specs.length && !found; j++) {
        if (specs[j].container === 'page' && rows(specs[j]).length) found = info(specs[j], document.body);
      }
    }
    var key = found ? found.key : '';
    if (key === pointed) return;
    // The face looks at the thing the pointer came to, and away from the last.
    all(document, '[' + MARK + ']').forEach(function (b) {
      var k = b.getAttribute(MARK);
      if (k === pointed && k !== key) pose(faceOf(b), 'rest');
      if (k === key && b.__yabSpec) pose(faceOf(b), 'thing', towards(b, b.__yabSpec, b.__yabRoot));
    });
    pointed = key;
    post({ k: 'point', item: found });
  }
  var pointing = 0;
  // What the pointer came to last, for a hover the site's script draws.
  var over = null;
  document.addEventListener('mouseout', function (e) { if (!e.relatedTarget) over = null; }, { capture: true, passive: true });
  document.addEventListener('mouseover', function (e) {
    over = e.target;
    if (!on) return;
    clearTimeout(pointing);
    var target = e.target;
    pointing = setTimeout(function () { point(target); }, 80);
  }, { capture: true, passive: true });

  var watch = new MutationObserver(soon);
  function start() {
    if (!document.body) return;
    watch.observe(document.body, { childList: true, subtree: true });
    soon();
  }
  if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);

  Object.defineProperty(window, '__yabItems', {
    value: {
      // Never on this site, or nowhere: every button goes now.
      off: function () {
        on = false;
        watch.disconnect();
        all(document, '[' + MARK + ']').forEach(function (b) { b.remove(); });
        if (pointed) { pointed = ''; post({ k: 'point', item: null }); }
      },
      // Hidden for one thing: its button goes, and stays gone.
      hide: function (key) {
        hidden.add(key);
        all(document, '[' + MARK + ']').forEach(function (b) { if (b.getAttribute(MARK) === key) b.remove(); });
      },
      show: function (key) { hidden.delete(key); soon(); },
      // The task a press began, on the face of every button for its
      // thing: working, needs you, done; '' when it is over or gone.
      state: function (key, mode, tip) {
        all(document, '[' + MARK + ']').forEach(function (b) {
          if (b.getAttribute(MARK) !== key) return;
          var svg = faceOf(b);
          if (svg && svg.__face) {
            if (!mode) { svg.__face.mode = 'done'; svg.__face.until = 0; pose(svg, 'rest'); }
            else pose(svg, mode);
          }
          b.title = tip || (b.__yabSpec ? b.__yabSpec.tip : b.title);
        });
      },
      // On again, without a reload.
      resume: function () { if (on) return; on = true; start(); }
    }
  });
})();
