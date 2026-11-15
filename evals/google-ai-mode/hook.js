// Put in a Google AI Mode page as early as it can be: the page's errors
// (window.onerror, rejections, console.error) into window.__aiErrors, and
// how long its frames took (window.__aiFrames: the longest gap between two
// animation frames and how many went over 100 ms), for detect.js to read.
(() => {
  if (window.__aiErrors) return;
  const errors = window.__aiErrors = [];
  const keep = (what) => { if (errors.length < 60) errors.push(String(what).slice(0, 200)); };
  addEventListener('error', (e) => keep('error: ' + (e.message || (e.target && (e.target.src || e.target.href)) || 'resource')), true);
  addEventListener('unhandledrejection', (e) => keep('rejection: ' + (e.reason && (e.reason.message || e.reason))));
  const said = console.error;
  console.error = function (...args) { keep('console: ' + args.map(String).join(' ')); return said.apply(this, args); };
  const frames = window.__aiFrames = { longest: 0, over100: 0, count: 0 };
  let last = 0;
  const tick = (now) => {
    if (last && document.visibilityState === 'visible') {
      const gap = now - last;
      frames.count++;
      if (gap > frames.longest) frames.longest = Math.round(gap);
      if (gap > 100) frames.over100++;
    }
    last = now;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
})();
