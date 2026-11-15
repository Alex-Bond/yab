// Dark pages (DarkPages.swift, docs/dark-pages.md), in the yab-dark world of
// every frame at document start. Only in the list while pages can be dark
// here: Yab has already decided the site is not kept light.
//
// Unless the site is left to its own theme, a fallback style makes the ground
// dark and the words light before the parser draws, as darkreader--fallback does. Then
// Yab is asked what this page gets, with this frame's fixes:
//   engine  Dark Reader's engine darkens it at once (a site seen to be light)
//   check   styles first, then a look at the ground: light, the engine;
//           dark, the site's own, and the fallback goes
//   own     the site is dark itself: the fallback goes, nothing else
//   off     the same, for a frame whose page is not darkened
// What was found goes back to Yab ("done"), which learns it for the site.
//
// The engine (darkreader.js, wrapped by DarkPages.engineScript) sits in this
// world as a function and runs only when a page needs it. Its stylesheet
// proxy goes to the copy Yab put in the page's own world (darkreader-proxy.js)
// instead of an inline script, which a strict Content-Security-Policy refuses.
(() => {
  if (window.__yabDark) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yabDark;
  if (!handler) return;
  const top = window === window.top;
  const scheme = location.protocol;
  if (!(scheme === 'http:' || scheme === 'https:' || (!top && scheme === 'about:'))) return;
  if (!['text/html', 'application/xhtml+xml'].includes(document.contentType)) return;
  const ownSites = __YAB_OWN_SITES__;
  const ownHost = name => {
    const host = name.toLowerCase().replace(/\.$/, '');
    return ownSites.some(site => host === site || host.endsWith('.' + site));
  };
  const ownSite = ownHost(location.hostname) || Array.from(location.ancestorOrigins || []).some(origin => {
    try { return ownHost(new URL(origin).hostname); } catch (e) { return false; }
  });
  const ownDecision = given => ownSite && ['engine', 'on', 'check'].includes(given) ? 'own' : given;

  let theme = __YAB_THEME__;
  let fallbackCSS = __YAB_FALLBACK__;
  let dimCSS = __YAB_DIM__;
  const DEFER = __YAB_DEFER__;
  let fixes = null;
  let decision = null;
  let running = false;
  let rootWatch = null;
  let reported = false;
  let printing = false;
  // What the first look saw the site's ground made of (`shape`), for the
  // second look after load to know whether anything it could hang on changed.
  let looked = null;
  // What a look at the page found: 'own' when it is dark itself or asks
  // to be left alone.
  let found = null;

  // The fallback and the pictures' dimming are the engine's kind of style
  // ("darkreader" in their class), so it never reads them as the site's.
  const style = (name, text) => {
    const element = document.createElement('style');
    element.className = 'darkreader ' + name;
    element.textContent = text;
    return element;
  };
  const place = element => {
    const root = document.documentElement;
    if (root) { (document.head || root).appendChild(element); return; }
    const watch = new MutationObserver(() => {
      if (!document.documentElement) return;
      watch.disconnect();
      if (!element.yabDropped) (document.head || document.documentElement).appendChild(element);
    });
    watch.observe(document, { childList: true });
  };
  // These sites set their own theme late. Leave even the first paint alone,
  // before the bridge answers, including when this is another site's frame.
  let fallback = ownSite ? null : style('yab-dark-fallback', fallbackCSS);
  if (fallback) place(fallback);
  const dropFallback = () => {
    if (fallback) { fallback.yabDropped = true; fallback.remove(); }
    fallback = null;
  };
  let dim = null;
  const dimPictures = () => {
    if (!running || !dimCSS) { if (dim) { dim.yabDropped = true; dim.remove(); } dim = null; return; }
    if (!dim) { dim = style('yab-dark-dim', dimCSS); place(dim); }
    dim.textContent = dimCSS;
  };

  const report = (result, more) => {
    if (reported) return;
    reported = true;
    handler.postMessage(Object.assign({ kind: 'done', result, top }, more || {})).catch(() => {});
  };

  // Stylesheets and images the engine can't read itself, by Yab (DarkFetch):
  // never with cookies, http and https only.
  const fetchVia = request => handler.postMessage({
    kind: 'fetch', url: String(request.url), type: request.responseType || 'text',
    mime: request.mimeType || '', origin: String(request.origin || location.origin),
  });

  const engine = () => {
    if (window.DarkReader) return true;
    const start = window.__yabDarkEngine;
    if (typeof start !== 'function') return false;
    // The engine adds its proxy as an inline <script class="darkreader--proxy">
    // and takes it out at once; here it is never added, and the proxy already
    // in the page's world starts instead, with the same two choices.
    const insert = Node.prototype.insertBefore;
    Node.prototype.insertBefore = function (node, before) {
      if (node && node.nodeName === 'SCRIPT' && node.classList && node.classList.contains('darkreader--proxy')) {
        const asked = /\((true|false), (true|false)\)\s*$/.exec(node.textContent || '');
        const sheets = asked && asked[1] === 'true' ? 1 : 0;
        const elements = asked && asked[2] === 'true' ? 1 : 0;
        document.dispatchEvent(new CustomEvent('__yabdark__proxy' + sheets + elements));
        return node;
      }
      return insert.call(this, node, before);
    };
    start.call(window);
    if (!window.DarkReader) return false;
    window.DarkReader.Plugins = { fetch: fetchVia };
    return true;
  };

  // A sign the site has grown a dark theme of its own since Yab learned it
  // was light: rules for prefers-color-scheme: dark in its own CSS.
  const darkRules = () => {
    let seen = 0;
    const look = rules => {
      for (const rule of rules) {
        if (++seen > 4000) return false;
        const media = rule.media && rule.media.mediaText;
        if (media && /prefers-color-scheme\s*:\s*dark/i.test(media)) return true;
        if (rule.cssRules && look(rule.cssRules)) return true;
      }
      return false;
    };
    for (const sheet of document.styleSheets) {
      const owner = sheet.ownerNode;
      if (owner && owner.classList && owner.classList.contains('darkreader')) continue;
      if (sheet.media && /prefers-color-scheme\s*:\s*dark/i.test(sheet.media.mediaText)) return true;
      try { if (look(sheet.cssRules)) return true; } catch (e) { /* another origin's */ }
    }
    return false;
  };

  const whenLoaded = done => {
    // Two frames on, or a moment on where no frame is drawn (a tab behind).
    const settle = () => {
      let settled = false;
      const once = () => { if (!settled) { settled = true; done(); } };
      requestAnimationFrame(() => requestAnimationFrame(once));
      setTimeout(once, 150);
    };
    if (document.readyState === 'complete') settle();
    else addEventListener('load', settle, { once: true });
  };

  const on = () => {
    if (running || printing) return;
    // A learned light site can answer before Chromium creates <html>.
    // Dark Reader's early fallback needs that root. Our fallback already
    // waits for it, so keep it while waiting rather than failing the page.
    if (!document.documentElement) {
      if (!rootWatch) {
        rootWatch = new MutationObserver(() => {
          if (!document.documentElement) return;
          rootWatch.disconnect();
          rootWatch = null;
          if (['engine', 'on', 'check'].includes(decision)) on();
        });
        rootWatch.observe(document, { childList: true });
      }
      return;
    }
    if (document.querySelector('meta[name="darkreader-lock"]')) { off(); found = 'own'; report('own', { locked: true }); return; }
    try {
      if (!engine()) { dropFallback(); return; }
      window.DarkReader.enable(theme, fixes);
      running = true;
    } catch (error) {
      try { window.DarkReader && window.DarkReader.disable(); } catch (e) { /* already off */ }
      running = false;
      dropFallback();
      report('error', { error: String((error && error.message) || error).slice(0, 300) });
      return;
    }
    // The engine has put its own fallback in, in the same task: no frame
    // goes by without one.
    dropFallback();
    dimPictures();
    // A second look once the page has loaded, as Dark Reader's detector
    // waits for: a site that puts its dark theme on by script after the
    // document is parsed, or whose CSS speaks of a dark scheme, is read
    // under the engine's styles turned off, and left to its own (#336).
    whenLoaded(() => {
      if (!running) return;
      const sign = darkRules();
      // The look turns every sheet of ours off and on, which restyles the
      // whole document twice, in the middle of whatever the page does next
      // (#1889: a third of Dark pages' cost on Speedometer). After a first
      // look it is taken again only when something the ground hangs on has
      // changed since: the site's sheets or their rules, the root's or the
      // body's attributes, the color-scheme it asks for.
      const again = decision === 'check' && (looked === null || shape() !== looked);
      if ((again || sign) && siteIsDark()) { off(); found = 'own'; report('own', { late: true }); return; }
      report('engine', { sign });
    });
  };

  // What a site's own ground is made of, as a string to compare: its sheets
  // and how many rules each has, the attributes of <html> and <body> but
  // ours, and the color-scheme <meta>. Reading these restyles nothing.
  const shape = () => {
    const ours = sheet => {
      const owner = sheet.ownerNode;
      return !!(owner && owner.classList && owner.classList.contains('darkreader')) ||
        !!(sheet.cssRules && sheet.cssRules[0] && sheet.cssRules[0].selectorText === '#__darkreader__adoptedOverride');
    };
    const rules = sheet => { try { return sheet.cssRules.length; } catch (e) { return -1; } };
    const parts = [];
    for (const sheet of document.styleSheets) {
      try { if (ours(sheet)) continue; } catch (e) { /* another origin's: still the site's */ }
      parts.push((sheet.href || '') + '#' + rules(sheet) + (sheet.disabled ? 'off' : ''));
    }
    for (const sheet of document.adoptedStyleSheets || []) {
      try { if (ours(sheet)) continue; } catch (e) { /* unreadable */ }
      parts.push('adopted#' + rules(sheet));
    }
    const own = element => {
      if (!element) return '-';
      const seen = [];
      for (const attribute of element.attributes) {
        if (attribute.name.startsWith('data-darkreader')) continue;
        // The engine's own custom properties in an inline style are ours too.
        const value = attribute.name === 'style' ? attribute.value.replace(/--darkreader-[^;]*;?/g, '') : attribute.value;
        seen.push(attribute.name + '=' + value);
      }
      return seen.join('&');
    };
    const meta = document.querySelector('meta[name="color-scheme" i]');
    parts.push(own(document.documentElement), own(document.body), (meta && meta.content) || '');
    return parts.join('|');
  };

  const off = () => {
    if (rootWatch) { rootWatch.disconnect(); rootWatch = null; }
    if (running) {
      try { window.DarkReader.disable(); } catch (e) { /* nothing to undo */ }
      running = false;
    }
    dimPictures();
    dropFallback();
  };

  // [r, g, b, a] of a computed color, a 0 to 1, or null.
  const rgba = text => {
    const m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+)(%?))?\s*\)$/.exec(text || '');
    if (!m) return null;
    const a = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[5] ? 100 : 1);
    return [+m[1], +m[2], +m[3], a];
  };
  const light = c => (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255;
  const ground = element => {
    const c = element && rgba(getComputedStyle(element).backgroundColor);
    return c && c[3] >= 0.5 ? light(c) : null;
  };

  // Whether the site is dark of its own, read with the fallback off, all in
  // this one task, so no frame is drawn without it.
  const siteIsDark = () => {
    const root = document.documentElement;
    if (!root) return false;
    if (root.hasAttribute('data-darkreader-mode') && !running) return true;
    // Every style of ours and the engine's off for the read, the site's own
    // look under them, and on again in this same task.
    const ours = Array.from(document.querySelectorAll('style.darkreader, link.darkreader')).filter(sheet => !sheet.disabled);
    // Constructed stylesheets have no <style> or <link>. Dark Reader puts
    // its override beside each source in adoptedStyleSheets, marked by its
    // first rule. Leaving these on mistakes our dark ground for the site's
    // own and turns the engine off at load (#616).
    const adopted = Array.from(document.adoptedStyleSheets || []).filter(sheet =>
      !sheet.disabled && sheet.cssRules[0] && sheet.cssRules[0].selectorText === '#__darkreader__adoptedOverride');
    for (const sheet of ours) sheet.disabled = true;
    for (const sheet of adopted) sheet.disabled = true;
    try {
      let seen = ground(document.body);
      if (seen == null) seen = ground(root);
      if (seen == null && innerWidth > 0 && innerHeight > 0) {
        // A page painted by a wrapper round everything: what is under three
        // points of the window, each the first ground over it.
        const votes = [];
        for (const [x, y] of [[0.5, 0.5], [0.25, 0.3], [0.75, 0.7]]) {
          for (const element of document.elementsFromPoint(innerWidth * x, innerHeight * y)) {
            const value = ground(element);
            if (value != null) { votes.push(value); break; }
          }
        }
        if (votes.length) seen = votes.sort((a, b) => a - b)[Math.floor(votes.length / 2)];
      }
      if (seen != null) return seen < 0.5;
      // The canvas: the root's color-scheme, or the page's <meta>, which
      // WebKit honors without showing it in the computed style.
      const meta = document.querySelector('meta[name="color-scheme" i]');
      const asked = (getComputedStyle(root).colorScheme || '') + ' ' + ((meta && meta.content) || '');
      return /\bdark\b/.test(asked) && matchMedia('(prefers-color-scheme: dark)').matches;
    } finally {
      for (const sheet of ours) sheet.disabled = false;
      for (const sheet of adopted) sheet.disabled = false;
    }
  };

  // DOMContentLoaded, then the stylesheets the document links, each loaded
  // or failed, a second and a half at most.
  const stylesReady = done => {
    let finished = false;
    const finish = () => { if (!finished) { finished = true; done(); } };
    const go = () => {
      const waiting = Array.from(document.querySelectorAll('link[rel~="stylesheet" i]')).filter(link =>
        !link.sheet && !link.disabled && (!link.media || matchMedia(link.media).matches));
      if (!waiting.length) return finish();
      let left = waiting.length;
      const one = () => { if (--left <= 0) finish(); };
      for (const link of waiting) {
        link.addEventListener('load', one, { once: true });
        link.addEventListener('error', one, { once: true });
      }
      setTimeout(finish, 1500);
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go, { once: true });
    else go();
  };

  const check = () => {
    stylesReady(() => {
      if (decision !== 'check') return;
      if (siteIsDark()) { off(); found = 'own'; report('own'); return; }
      looked = shape();
      on();
    });
  };

  // A frame of another page starts the engine once it can be seen, or is
  // about to be: a frame out of sight, too small to show anything (a tracker's
  // 1 by 1, a hidden one) keeps only the fallback, which already makes its
  // ground dark, and costs nothing more. The top document starts at once.
  const shown = start => {
    if (top || typeof IntersectionObserver !== 'function') { start(); return; }
    let watch = null;
    const big = () => innerWidth >= 2 && innerHeight >= 2;
    const go = () => {
      if (!watch) return;
      watch.disconnect();
      watch = null;
      removeEventListener('resize', resized);
      start();
    };
    let seen = false;
    const resized = () => { if (seen && big()) go(); };
    watch = new IntersectionObserver(entries => {
      seen = entries.some(entry => entry.isIntersecting);
      if (seen && big()) go();
    }, { rootMargin: '100% 100%' });
    addEventListener('resize', resized);
    const observe = () => { if (watch) watch.observe(document.documentElement); };
    if (document.documentElement) observe();
    else {
      const root = new MutationObserver(() => {
        if (!document.documentElement) return;
        root.disconnect();
        observe();
      });
      root.observe(document, { childList: true });
    }
  };

  const apply = given => {
    given = ownDecision(given);
    decision = given;
    found = null;
    if (given === 'engine' || given === 'on') {
      // A test run may start the engine once the document is parsed rather
      // than at its start, the fallback holding until then, to weigh what
      // the engine costs the first paint (evals/dark-pages, DEFER).
      if (DEFER && document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { if (decision === given) shown(on); }, { once: true });
      else shown(() => { if (decision === given) on(); });
    }
    else if (given === 'check') shown(() => { if (decision === 'check') check(); });
    else off();
  };

  window.__yabDark = {
    // From Yab, for a page already up: ⌥⇧D, Site Controls, the mode.
    // A look asked for now waits a moment: the appearance Yab has just
    // changed reaches the page's styles first.
    apply(given) {
      given = ownDecision(given);
      // A look asked for now says what it found, so the row follows.
      reported = given !== 'check';
      if (given === 'check') {
        decision = given;
        found = null;
        off();
        setTimeout(() => { if (decision === 'check') check(); }, 80);
        return 'check';
      }
      apply(given);
      return window.__yabDark.state();
    },
    // The sheet's controls: the engine restyles in place.
    look(next, nextFallback, nextDim) {
      theme = next; fallbackCSS = nextFallback; dimCSS = nextDim;
      if (fallback) fallback.textContent = fallbackCSS;
      if (running) window.DarkReader.enable(theme, fixes);
      dimPictures();
      return running;
    },
    // Paper stays white: off for the print sheet, back after.
    print(going) {
      if (going) { const was = running; off(); printing = true; return was; }
      printing = false;
      if (decision === 'engine' || decision === 'on' || decision === 'check') on();
      return running;
    },
    state() {
      if (running) return 'engine';
      if (found) return found;
      return decision === 'engine' || decision === 'on' ? 'pending' : decision;
    },
  };

  handler.postMessage({ kind: 'ask', url: location.href, top }).then(answer => {
    if (!answer || !answer.decision) { dropFallback(); return; }
    fixes = answer.fixes || null;
    apply(answer.decision);
  }, () => dropFallback());
})();
