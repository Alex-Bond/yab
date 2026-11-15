// The node DevTools points at, drawn as Chromium draws it (its
// inspector_overlay: tool_highlight.ts and .css, ported as they are): the
// margin, border, padding and content boxes in Chrome's four colors, each
// cut out of the one around it, and the white title with its arrow over
// the node, or under it when there is no room above. Inspect mode adds
// Chrome's rows: color, font, background, margin, padding, and the
// accessibility section.
//
// Yab's own world, in a closed shadow root in the top layer, as Measure
// is: over any z-index, the page's scripts never see into it. Boxes come
// in the top page's CSS pixels; the title keeps its size on screen at any
// zoom. `d` null hides it; the host stays, so the page's tree changes once.
var H = window.__yabHighlight;
if (!H) {
  var host = document.createElement('yab-highlight');
  host.setAttribute('popover', 'manual');
  var root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = '<style>' + CSS + '</style><canvas></canvas><div class="tips"></div>';
  var cv = root.querySelector('canvas'), ctx = cv.getContext('2d'), tips = root.querySelector('.tips');
  var last = null, scroll = [0, 0], held = [], heard = new WeakSet();
  // Over everything, as Chromium's overlay is: a modal dialog or a popover
  // the page opened after this one would sit above it in the top layer,
  // so with one open it is shown again, last.
  var raise = function () {
    try {
      if (document.querySelector(':modal')) return true;
      var open = document.querySelectorAll(':popover-open');
      for (var i = 0; i < open.length; i++) if (open[i] !== host && open[i].localName !== 'yab-picker') return true;
    } catch (e) {}
    return false;
  };
  var attach = function () {
    if (!host.isConnected) document.documentElement.appendChild(host);
    try {
      if (host.matches(':popover-open') && raise()) host.hidePopover();
      if (!host.matches(':popover-open')) host.showPopover();
    } catch (e) {}
  };
  // The page scrolled under a node pointed at, or a box the node is in
  // (an inner scroller, a frame's document): the boxes go with it at once,
  // as Chromium's overlay follows the node, until it is measured again.
  var redraw = function () { if (last) draw(last); };
  var listen = function (target) {
    if (!target || heard.has(target)) return;
    heard.add(target);
    target.addEventListener('scroll', redraw, true);
  };
  listen(window);
  addEventListener('resize', redraw);
  // A box by its path from the document, in this world: children's places,
  // "s" an open shadow root's way in, "f" a frame's document.
  function find(path) {
    var at = document;
    for (var i = 0; i < path.length && at; i++) {
      var step = path[i];
      if (step === 's') { at = at.shadowRoot; listen(at); }
      else if (step === 'f') { var d = null; try { d = at.contentDocument; } catch (e) {} at = d; if (d) listen(d.defaultView); }
      else at = at.children ? at.children[step] : null;
    }
    return at && at.nodeType === 1 ? at : null;
  }
  H = window.__yabHighlight = function (d) {
    last = d;
    held = [];
    if (d) {
      scroll = [scrollX, scrollY];
      (d.sc || []).forEach(function (s) { var e = find(s[0]); if (e) held.push([e, s[1], s[2]]); });
    }
    draw(d);
  };

  function draw(d) {
    var w = document.documentElement.clientWidth || innerWidth, h = document.documentElement.clientHeight || innerHeight;
    var dpr = devicePixelRatio || 1;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
      cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
      cv.style.width = w + 'px'; cv.style.height = h + 'px';
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    tips.textContent = '';
    // What was drawn, for the bench (read in Yab's world only).
    H.state = { drawn: !!d, fixed: !!(d && d.fixed), boxes: d ? d.boxes.length : 0, title: null };
    if (!d) return;
    attach();
    // A node in a fixed box stays put as the page scrolls; any other goes
    // with it until it is measured again.
    var dx = d.fixed ? 0 : scroll[0] - scrollX, dy = d.fixed ? 0 : scroll[1] - scrollY;
    for (var k = 0; k < held.length; k++) { dx += held[k][1] - held[k][0].scrollLeft; dy += held[k][2] - held[k][0].scrollTop; }
    H.state.shift = [dx, dy];
    var bounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    // Chrome's order: margin first, each box with the next one cut out.
    var paths = d.boxes.slice();
    while (paths.length) {
      var p = paths.pop();
      ctx.save();
      quad(p.q, dx, dy);
      ctx.fillStyle = p.fill;
      ctx.fill();
      grow(bounds, p.q, dx, dy);
      if (paths.length) {
        ctx.globalCompositeOperation = 'destination-out';
        quad(paths[paths.length - 1].q, dx, dy);
        ctx.fillStyle = 'red';
        ctx.fill();
      }
      ctx.restore();
    }
    if (d.layout) layout(d.layout, dx, dy);
    // A flex item's base size and flexibility, unless it is a flex
    // container drawn as one already (tool_highlight.ts isVisibleFlexContainer).
    if (d.item && !(d.layout && d.layout.kind === 'flex')) flexItem(d.item, dx, dy);
    if (isFinite(bounds.minX)) H.state.at = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY];
    if (d.info && isFinite(bounds.minX)) title(d.info, bounds, w, h, d.zoom || 1);
  }

  // drawLayoutFlexItemHighlight (highlight_flex_common.ts) with DevTools'
  // flexItemHighlightConfig: the base size box hatched, its border dotted,
  // the flexibility arrow from its end to the item's.
  var itemPattern = null;
  function colinear(p1, p2, distance) {
    var angle = Math.atan((p2[1] - p1[1]) / (p2[0] - p1[0]));
    return [p1[0] + distance * Math.cos(angle), p1[1] + distance * Math.sin(angle)];
  }
  function rounded(points) {
    var path = new Path2D();
    points.forEach(function (p, i) { if (i) path.lineTo(Math.round(p[0]), Math.round(p[1])); else path.moveTo(Math.round(p[0]), Math.round(p[1])); });
    return path;
  }
  function stroke(path, dash) {
    ctx.save();
    ctx.translate(0.5, 0.5);
    ctx.lineWidth = 1;
    ctx.setLineDash(dash);
    ctx.strokeStyle = LINE;
    ctx.stroke(path);
    ctx.restore();
  }
  function flexItem(it, dx, dy) {
    var q = it.q.map(function (p) { return [p[0] + dx, p[1] + dy]; });
    var p1 = q[0], p2 = q[1], p3 = q[2], p4 = q[3];
    var b = it.horizontal ? [p1, colinear(p1, p2, it.base), colinear(p4, p3, it.base), p4]
                          : [p1, p2, colinear(p2, p3, it.base), colinear(p1, p4, it.base)];
    var box = rounded(b);
    box.closePath();
    // hatchFillPath: lines 10 apart, 5 long with 3 between, turned by the
    // item's angle (in radians, added to degrees, as Chromium adds them).
    if (!itemPattern) {
      var c = document.createElement('canvas');
      c.width = 10; c.height = 8;
      var x = c.getContext('2d');
      x.fillStyle = HATCH; x.fillRect(0, 0, 1, 5);
      itemPattern = ctx.createPattern(c, 'repeat');
    }
    var angle = Math.atan2(p4[1] - p1[1], p4[0] - p1[0]) + Math.PI * 45 / 180;
    itemPattern.setTransform(new DOMMatrix().scale(1, 1).rotate(0, 0, -45 + angle));
    ctx.save();
    ctx.fillStyle = itemPattern;
    ctx.fill(box);
    ctx.restore();
    stroke(box, [2, 2]);
    var mid = function (a, z) { return [(a[0] + z[0]) / 2, (a[1] + z[1]) / 2]; };
    var from = it.horizontal ? mid(b[1], b[2]) : mid(b[3], b[2]);
    var to = it.horizontal ? mid(p2, p3) : mid(p4, p3);
    H.state.item = { base: it.base, horizontal: it.horizontal, from: from, to: to };
    if (to[0] === from[0] && to[1] === from[1]) return;
    stroke(rounded([from, to]), []);
    var tip = rounded([[to[0] - 5, to[1] - 5], to, [to[0] - 5, to[1] + 5]]);
    ctx.save();
    ctx.translate(to[0] + 0.5, to[1] + 0.5);
    ctx.rotate(Math.atan2(to[1] - from[1], to[0] - from[0]));
    ctx.translate(-to[0] - 0.5, -to[1] - 0.5);
    stroke(tip, []);
    ctx.restore();
  }

  // Chrome's flex and grid lines (highlight_flex_common.ts,
  // highlight_grid_common.ts): its layout color, the container dashed, the
  // items' edges dotted, the empty space and the gaps tinted and hatched.
  var LINE = 'rgba(127, 32, 210, 1)', GAP = 'rgba(127, 32, 210, 0.3)', HATCH = 'rgba(127, 32, 210, 0.8)';
  var pattern = null;
  function hatch() {
    if (pattern) return pattern;
    var c = document.createElement('canvas');
    c.width = 10; c.height = 8;
    var x = c.getContext('2d');
    x.fillStyle = HATCH; x.fillRect(0, 0, 1, 5);
    pattern = ctx.createPattern(c, 'repeat');
    pattern.setTransform(new DOMMatrix().rotate(0, 0, -45));
    return pattern;
  }
  // Space: the outer box with the inner ones cut out, tinted, then hatched.
  function space(outer, holes, dx, dy) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(outer[0] + dx, outer[1] + dy, outer[2], outer[3]);
    holes.forEach(function (r) { ctx.rect(r[0] + dx, r[1] + dy + r[3], r[2], -r[3]); });
    ctx.fillStyle = GAP; ctx.fill('evenodd');
    ctx.fillStyle = hatch(); ctx.fill('evenodd');
    ctx.restore();
  }
  function line(points, dash, dx, dy) {
    ctx.save();
    ctx.translate(0.5, 0.5);
    ctx.lineWidth = 1; ctx.strokeStyle = LINE; ctx.setLineDash(dash);
    ctx.beginPath();
    for (var i = 0; i < points.length; i += 2) {
      ctx.moveTo(points[i][0] + dx, points[i][1] + dy);
      ctx.lineTo(points[i + 1][0] + dx, points[i + 1][1] + dy);
    }
    ctx.stroke();
    ctx.restore();
  }
  function edges(r) { return { l: r[0], t: r[1], r: r[0] + r[2], b: r[1] + r[3] }; }
  function layout(L, dx, dy) {
    var c = L.container, C = edges(c);
    if (L.kind === 'flex') {
      var h = L.horizontal, quads = [], seps = [], lineSeps = [];
      L.lines.forEach(function (items, i) {
        // The line spans the container along the flow; across, its items' extent.
        var lo = Math.min.apply(null, items.map(function (r) { return h ? r[1] : r[0]; }));
        var hi = Math.max.apply(null, items.map(function (r) { return h ? r[1] + r[3] : r[0] + r[2]; }));
        if (L.lines.length === 1) { lo = h ? C.t : C.l; hi = h ? C.b : C.r; }
        if (L.lines.length > 1) lineSeps.push(h ? [[C.l, lo], [C.r, lo], [C.l, hi], [C.r, hi]] : [[lo, C.t], [lo, C.b], [hi, C.t], [hi, C.b]]);
        items.forEach(function (r, k) {
          var q = h ? [r[0], lo, r[2], hi - lo] : [lo, r[1], hi - lo, r[3]];
          quads.push(q);
          var e = edges(q), next = items[k + 1], start = h ? e.l : e.t, end = h ? e.r : e.b;
          var nextStart = next ? (h ? next[0] : next[1]) : null;
          var at = function (v) { return h ? [[v, e.t], [v, e.b]] : [[e.l, v], [e.r, v]]; };
          seps.push(at(start));
          if (nextStart === null || nextStart !== end) seps.push(at(end));
        });
      });
      space(c, quads, dx, dy);
      seps.forEach(function (s) { line(s, [2, 2], dx, dy); });
      lineSeps.forEach(function (s) { line(s, [3, 3], dx, dy); });
      line([[C.l, C.t], [C.r, C.t], [C.r, C.t], [C.r, C.b], [C.r, C.b], [C.l, C.b], [C.l, C.b], [C.l, C.t]], [3, 3], dx, dy);
    } else if (L.kind === 'grid') {
      var xs = [], ys = [], x = C.l, y = C.t, gaps = [];
      L.cols.forEach(function (w, i) {
        xs.push(x, x + w);
        if (i < L.cols.length - 1 && L.colGap) gaps.push([x + w, C.t, L.colGap, c[3]]);
        x += w + L.colGap;
      });
      L.rows.forEach(function (hh, i) {
        ys.push(y, y + hh);
        if (i < L.rows.length - 1 && L.rowGap) gaps.push([C.l, y + hh, c[2], L.rowGap]);
        y += hh + L.rowGap;
      });
      var right = xs.length ? xs[xs.length - 1] : C.r, bottom = ys.length ? ys[ys.length - 1] : C.b;
      gaps.forEach(function (g) { space(g, [], dx, dy); });
      var pts = [];
      xs.forEach(function (v) { pts.push([v, C.t], [v, bottom]); });
      ys.forEach(function (v) { pts.push([C.l, v], [right, v]); });
      line(pts, [3, 3], dx, dy);
    }
  }
  // A box as Blink hands it over: a quad, turned with its transforms.
  function quad(q, dx, dy) {
    ctx.beginPath();
    ctx.moveTo(q[0][0] + dx, q[0][1] + dy);
    for (var i = 1; i < q.length; i++) ctx.lineTo(q[i][0] + dx, q[i][1] + dy);
    ctx.closePath();
  }
  function grow(b, q, dx, dy) {
    for (var i = 0; i < q.length; i++) {
      b.minX = Math.min(b.minX, q[i][0] + dx); b.minY = Math.min(b.minY, q[i][1] + dy);
      b.maxX = Math.max(b.maxX, q[i][0] + dx); b.maxY = Math.max(b.maxY, q[i][1] + dy);
    }
  }
  function el(parent, tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }
  function ellipsify(s, n) { return s.length <= n ? s : s.substr(0, n - 1) + '…'; }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }

  // createElementDescription, as Chromium builds it.
  function describe(info) {
    var box = el(null, 'div', 'element-info');
    var head = el(box, 'div', 'element-info-header');
    if (info.layout) el(head, 'div', 'element-layout-type ' + info.layout);
    var name = el(head, 'div', 'element-description');
    el(name, 'span', 'material-tag-name', info.tag);
    var id = info.id ? '#' + ellipsify(info.id, 80) : '';
    if (id) el(name, 'span', 'material-node-id', id);
    if (info.cls && id.length < 80) el(name, 'span', 'material-class-name', ellipsify(info.cls, 80 - id.length));
    var dims = el(head, 'div', 'dimensions');
    el(dims, 'span', 'material-node-width', String(Math.round(info.w * 100) / 100));
    dims.appendChild(document.createTextNode('×'));
    el(dims, 'span', 'material-node-height', String(Math.round(info.h * 100) / 100));
    var body = null;
    function row(label, valueClass) {
      body = body || el(box, 'div', 'element-info-body');
      var r = el(body, 'div', 'element-info-row');
      el(r, 'div', 'element-info-name', label);
      el(r, 'div', 'element-info-gap');
      return el(r, 'div', valueClass);
    }
    function color(label, c) {
      var v = row(label, 'element-info-value-color');
      el(el(v, 'div', 'color-swatch'), 'div', 'color-swatch-inner').style.backgroundColor = c.css;
      v.appendChild(document.createTextNode(c.text));
    }
    var s = info.style;
    if (s) {
      if (s.color) color('Color', s.color);
      if (s.font) row('Font', 'element-info-value-text').textContent = s.font;
      if (s.background) color('Background', s.background);
      if (s.margin && s.margin !== '0px') row('Margin', 'element-info-value-text').textContent = s.margin;
      if (s.padding && s.padding !== '0px') row('Padding', 'element-info-value-text').textContent = s.padding;
    }
    var a = info.a11y;
    if (a) {
      body = body || el(box, 'div', 'element-info-body');
      var section = el(body, 'div', 'element-info-row element-info-section');
      el(section, 'div', 'section-name', 'Accessibility');
      el(el(section, 'div', 'separator-container'), 'div', 'separator');
      if (a.contrast) {
        var c = row('Contrast', 'element-info-value-contrast');
        var sample = el(c, 'div', 'contrast-text', 'Aa');
        sample.style.color = a.contrast.fg; sample.style.backgroundColor = a.contrast.bg;
        el(c, 'span', null, String(Math.floor(a.contrast.ratio * 100) / 100));
        el(c, 'div', 'a11y-icon ' + (a.contrast.ratio < a.contrast.need ? 'a11y-icon-warning' : 'a11y-icon-ok'));
      }
      row('Name', 'element-info-value-text').textContent = a.name || '';
      row('Role', 'element-info-value-text').textContent = a.role || '';
      el(row('Keyboard-focusable', 'element-info-value-icon'), 'div', 'a11y-icon ' + (a.focusable ? 'a11y-icon-ok' : 'a11y-icon-not-ok'));
    }
    return box;
  }

  // drawElementTitle, as Chromium places it; in screen pixels, the title's
  // own box zoomed back so it is Chrome's size at any page zoom.
  function title(info, b, cw, ch, z) {
    var wrap = el(tips, 'div');
    wrap.style.zoom = String(1 / z);
    var content = el(wrap, 'div', 'tooltip-content');
    content.appendChild(describe(info));
    var bounds = { minX: b.minX * z, maxX: b.maxX * z, minY: b.minY * z, maxY: b.maxY * z };
    var canvasWidth = cw * z, canvasHeight = ch * z;
    var titleWidth = content.offsetWidth, titleHeight = content.offsetHeight;
    var arrowHalfWidth = 8, pageMargin = 2, arrowWidth = arrowHalfWidth * 2, arrowInset = arrowHalfWidth + 2;
    var containerMinX = pageMargin + arrowInset, containerMaxX = canvasWidth - pageMargin - arrowInset - arrowWidth;
    var arrowX;
    if (bounds.maxX - bounds.minX < arrowWidth + 2 * arrowInset) {
      arrowX = (bounds.minX + bounds.maxX) * 0.5 - arrowHalfWidth;
    } else {
      var fromLeft = bounds.minX + arrowInset, fromRight = bounds.maxX - arrowInset - arrowWidth;
      arrowX = fromLeft > containerMinX && fromLeft < containerMaxX ? fromLeft : clamp(containerMinX, fromLeft, fromRight);
    }
    var arrowHidden = arrowX < containerMinX || arrowX > containerMaxX;
    var boxX = clamp(arrowX - arrowInset, pageMargin, canvasWidth - titleWidth - pageMargin);
    var boxY = bounds.minY - arrowHalfWidth - titleHeight, onTop = true;
    if (boxY < 0) { boxY = Math.min(canvasHeight - titleHeight, bounds.maxY + arrowHalfWidth); onTop = false; }
    else if (bounds.minY > canvasHeight) boxY = canvasHeight - arrowHalfWidth - titleHeight;
    var includes = boxX >= bounds.minX && boxX + titleWidth <= bounds.maxX && boxY >= bounds.minY && boxY + titleHeight <= bounds.maxY;
    var overlaps = boxX < bounds.maxX && boxX + titleWidth > bounds.minX && boxY < bounds.maxY && boxY + titleHeight > bounds.minY;
    var state = { shown: !(overlaps && !includes), boxX: boxX, boxY: boxY, width: titleWidth, height: titleHeight, onTop: onTop,
                  arrowHidden: arrowHidden || includes, includes: includes, canvasWidth: canvasWidth, canvasHeight: canvasHeight, zoom: z,
                  text: content.textContent };
    H.state.title = state;
    if (overlaps && !includes) { content.style.display = 'none'; return; }
    content.style.top = boxY + 'px';
    content.style.left = boxX + 'px';
    content.style.setProperty('--arrow-visibility', arrowHidden || includes ? 'hidden' : 'visible');
    if (arrowHidden) return;
    content.style.setProperty('--arrow', onTop ? 'var(--arrow-down)' : 'var(--arrow-up)');
    content.style.setProperty('--arrow-top', (onTop ? titleHeight - 1 : -arrowHalfWidth) + 'px');
    content.style.setProperty('--arrow-left', (arrowX - boxX) + 'px');
  }
}
H(data);
