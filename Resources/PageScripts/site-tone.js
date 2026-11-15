(function () {
  // A browser bar continues the site's controls, not its document or film.
  // Inspect a bounded number of hit-test stacks; never scan the whole page.
  const W = innerWidth, H = innerHeight, html = document.documentElement, body = document.body;
  const controls = 'button,input,select,[role="button"],[role="tab"],[role="combobox"],a[href]';
  const chrome = 'header,nav,[role="banner"],[role="navigation"],[role="toolbar"]';
  const content = 'canvas,video,img,picture,main,article,[role="main"],[role="dialog"],[aria-modal="true"]';
  if (!body || W < 1 || H < 1) return null;

  function rgb(value) {
    let m = value.match(/^rgba?\(([^)]+)\)$/);
    if (!m) return null;
    const parts = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
    return parts.length >= 3 && parts.every(Number.isFinite) && (parts.length < 4 || parts[3] >= .98)
      ? parts.slice(0, 3) : null;
  }
  function close(a, b) { return a && b && Math.max(...a.map((v, i) => Math.abs(v - b[i]))) <= 12; }
  function flat(el) {
    const s = getComputedStyle(el);
    if (Number(s.opacity) < .98 || s.visibility === 'hidden' || s.display === 'none' || s.backgroundImage !== 'none') return null;
    return rgb(s.backgroundColor);
  }
  function excluded(el) {
    return el.matches(content) || !!el.closest('main,article,[role="main"],[role="dialog"],[aria-modal="true"]');
  }
  function hasControls(el) { return el.querySelectorAll(controls).length >= 2; }
  function backing(el) {
    // Read the flat backing through a translucent/blurred bar, rather than
    // sampling the animated pixels it happens to have over it this frame.
    for (let n = el; n; n = n.parentElement) {
      if (n.matches('video,canvas,img,picture')) return null;
      const color = flat(n);
      if (color) return color;
      if (getComputedStyle(n).backgroundImage !== 'none') return null;
    }
    return null;
  }
  const seen = new Set(), tops = [], left = [], right = [];
  for (const y of [4, 12, 28]) {
    for (const x of [W * .025, W * .12, W * .5, W * .88, W * .975]) {
      for (const el of document.elementsFromPoint(x, Math.min(y, H - 1))) {
        if (seen.has(el) || el === html || el === body || excluded(el)) continue;
        seen.add(el);
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        if (r.top > 4 || r.bottom < 20 || s.position === 'fixed' && el.closest('[role="dialog"],[aria-modal="true"]')) continue;
        const semantic = el.matches(chrome), controlled = hasControls(el);
        if (r.left <= 4 && r.right >= W - 4 && r.height >= 20 && r.height <= Math.max(240, H * .5) && (semantic || controlled)) {
          const color = backing(el);
          tops.push({el, r, color, semantic});
        }
        // Both long, controlled sides must agree. A dark advertisement or
        // the edge of an image alone cannot override a light workspace.
        if (r.height >= Math.max(120, H * .45) && r.width >= 48 && r.width <= W * .4 && controlled && !el.querySelector('video,canvas')) {
          const color = flat(el);
          if (color && r.left <= 4) left.push({el, r, color});
          if (color && r.right >= W - 4) right.push({el, r, color});
        }
      }
    }
  }
  tops.sort((a, b) => Number(b.semantic) - Number(a.semantic) || a.r.height - b.r.height);
  let chosen = tops.find(v => v.color), source = chosen ? 'header' : '';
  let pair = null;
  for (const a of left) for (const b of right) {
    if (a.el !== b.el && close(a.color, b.color)) {
      const width = a.r.width + b.r.width;
      if (!pair || width > pair.width) pair = {a, b, width};
    }
  }
  if (!chosen && pair) {
    chosen = {color: pair.a.color.map((v, i) => (v + pair.b.color[i]) / 2)};
    source = 'panels';
  }
  // With no chrome, an opaque root with no image is an honest fallback.
  // If even that is unknown, the native side may inspect a few top rows.
  if (!chosen) {
    const color = backing(body);
    if (color) { chosen = {color}; source = 'root'; }
  }
  const region = tops[0]?.r;
  const regions = [{x: 0, y: region ? Math.max(0, region.top) + 2 : 2,
    width: W, height: region ? Math.min(18, region.height - 2) : Math.min(18, H - 2)}];
  // The pixels are the site's chrome only while nothing lies over it. A
  // page's own full screen, or a modal's veil over the whole page, is there
  // for a moment and covers it: read then, the browser wore the veil's gray
  // or the film's black (register 2669). Covered, say so, and the color
  // the page was last seen in stays until it shows again.
  const covered = !!(document.fullscreenElement || document.webkitFullscreenElement) ||
    !chosen && [W * .12, W * .5, W * .88].some(function (x) {
      const top = document.elementFromPoint(x, regions[0].y + 1);
      if (!top || top === html || top === body) return false;
      if (tops[0]) return !tops[0].el.contains(top);
      for (let n = top; n && n !== body; n = n.parentElement) {
        if (getComputedStyle(n).position !== 'fixed') continue;
        const r = n.getBoundingClientRect();
        return r.width >= W - 4 && r.height >= H * .9;
      }
      return false;
    });

  // Watch only the roots and the selected controls' surfaces. No subtree
  // observer on the document: video, canvas and scrolling must stay quiet.
  const bridge = window.webkit?.messageHandlers?.yabScroll;
  if (bridge) {
    let watch = window.__yabSiteToneWatch;
    if (!watch) {
      watch = window.__yabSiteToneWatch = {nodes: [], timer: 0, last: 0, themed: false};
      watch.notify = function (theme) {
        watch.themed = watch.themed || theme === true;
        clearTimeout(watch.timer);
        watch.timer = setTimeout(function () {
          watch.last = performance.now();
          bridge.postMessage({tone: true, theme: watch.themed, href: location.href, origin: performance.timeOrigin});
          watch.themed = false;
        }, Math.max(160, 800 - (performance.now() - watch.last)));
      };
      watch.observer = new MutationObserver(function (changes) {
        if (!changes.some(c => /class|style|theme|color|appearance|dark|light/i.test(c.attributeName || ''))) return;
        const themed = changes.some(c => /theme|color|appearance|dark|light/i.test(c.attributeName || '') ||
          c.attributeName === 'class' && /dark|light|theme|night/i.test((c.oldValue || '') + ' ' + c.target.className) ||
          c.attributeName === 'style' && (c.target === html || c.target === body) && /color|background/i.test(c.target.getAttribute('style') || ''));
        watch.notify(themed);
      });
      window.addEventListener('resize', watch.notify, {passive: true});
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', watch.notify);
    }
    const surfaces = [...tops.slice(0, 3).map(v => v.el), ...(pair ? [pair.a.el, pair.b.el] : [])];
    const ancestors = [];
    for (const surface of surfaces) {
      for (let n = surface, depth = 0; n && n !== body && depth < 6; n = n.parentElement, depth++) ancestors.push(n);
    }
    const nodes = [...new Set([html, body, ...ancestors])];
    if (nodes.length !== watch.nodes.length || nodes.some((n, i) => n !== watch.nodes[i])) {
      watch.observer.disconnect();
      watch.nodes = nodes;
      nodes.forEach(el => watch.observer.observe(el, {attributes: true, attributeOldValue: true}));
    }
  }
  return {color: chosen?.color || null, source, regions, width: W, height: H, covered,
    href: location.href, origin: performance.timeOrigin};
})()
