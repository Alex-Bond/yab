// What a Google AI Mode page shows now, as one JSON string: whether its
// follow-up box ("Ask anything") is there and seen, how much answer there is,
// the page's errors since hook.js went in, and the boxes it has. A consent
// page or overlay is answered "Reject all" (non-essential cookies declined).
(() => {
  const seen = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.top > innerHeight) return false;
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      const s = getComputedStyle(e);
      if (s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity) === 0) return false;
    }
    return true;
  };
  const words = (el) => [el.getAttribute('placeholder'), el.getAttribute('aria-label'), el.getAttribute('data-placeholder')]
    .filter(Boolean).join(' ');
  let consent = false;
  for (const b of document.querySelectorAll('button, input[type=submit], div[role=button]')) {
    const t = (b.innerText || b.value || '').trim();
    if (/^reject all$/i.test(t) && seen(b)) { b.click(); consent = true; break; }
  }
  const boxes = [...document.querySelectorAll('textarea, [contenteditable="true"], [contenteditable=""], input[type=text], input[type=search], input:not([type])')];
  const ask = boxes.filter((b) => /ask anything/i.test(words(b)));
  const main = document.querySelector('[data-container-id="main-col"], [data-subtree="aimc"], main, #rcnt') || document.body;
  return JSON.stringify({
    href: location.href.slice(0, 160),
    ready: document.readyState,
    consent,
    ask: ask.length,
    askSeen: ask.some(seen),
    text: main ? (main.innerText || '').length : 0,
    boxes: boxes.slice(0, 8).map((b) => ({ tag: b.tagName, words: words(b).slice(0, 60), seen: seen(b) })),
    errors: (window.__aiErrors || []).slice(0, 30),
    hooked: !!window.__aiErrors,
    frames: window.__aiFrames || null,
    overview: /AI Overview/.test(document.body ? document.body.innerText.slice(0, 20000) : ''),
    modeLink: !!document.querySelector('a[href*="udm=50"]'),
    follow: window.__aiFollow ? (document.body.innerText.split(window.__aiFollow).length - 1) : null,
    focused: document.activeElement ? words(document.activeElement).slice(0, 40) : '',
    agent: navigator.userAgent,
    visibility: document.visibilityState,
  });
})()
