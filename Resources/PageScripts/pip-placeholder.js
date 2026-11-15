// The native player leaves; its document and layout stay put. A top-layer
// placard follows only that video's visible rectangle, on either engine.
// Appearance is Stage.AwayPlacard: 115 x 90 mark, 13 pt text, #a4a4a4 on black.
(() => {
  if (window.__yabPiPPlacard || typeof ResizeObserver !== 'function') return;
  const watched = new WeakSet(), roots = new WeakSet();
  let active = null;
  const style = (node, text) => { node.style.cssText = text; return node; };
  const ancestor = node => node.parentElement || node.getRootNode()?.host;

  function clear() {
    if (!active) return;
    const old = active;
    active = null;
    old.resize.disconnect(); old.mutation.disconnect();
    document.removeEventListener('scroll', old.place, true);
    window.removeEventListener('resize', old.place);
    document.removeEventListener('fullscreenchange', old.place);
    old.host.remove();
  }

  function show(video) {
    if (!video || video.tagName !== 'VIDEO' || active?.video === video) return;
    clear();
    const host = style(document.createElement('div'), 'all:initial;position:fixed;inset:auto;margin:0;padding:0;border:0;overflow:hidden;background:#000;box-sizing:border-box;z-index:2147483647;');
    host.setAttribute('data-yab-pip-placeholder', '');
    // Top layer uses viewport coordinates even inside a transformed player.
    if (typeof host.showPopover === 'function') host.setAttribute('popover', 'manual');
    const shadow = host.attachShadow({mode:'closed'});
    const button = style(document.createElement('button'), 'all:initial;box-sizing:border-box;width:100%;height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;background:#000;color:#a4a4a4;cursor:pointer;font:13px system-ui,-apple-system,sans-serif;text-align:center;');
    const text = 'This video is playing in picture in picture.';
    button.setAttribute('aria-label', text + ' Return video to tab');
    const mark = style(document.createElement('span'), 'display:block;position:relative;flex:none;width:115px;height:90px;');
    mark.setAttribute('aria-hidden', 'true');
    mark.append(style(document.createElement('span'), 'position:absolute;box-sizing:border-box;left:0;top:0;width:106px;height:80px;border:4px solid #a4a4a4;border-radius:6px;'));
    mark.append(style(document.createElement('span'), 'position:absolute;box-sizing:border-box;left:65px;top:52px;width:50px;height:38px;border:4px solid #a4a4a4;border-radius:3.5px;background:#000;box-shadow:0 0 0 3px #000;'));
    const label = style(document.createElement('span'), 'box-sizing:border-box;max-width:402px;padding:0 10px;');
    label.textContent = text;
    button.append(mark, label); shadow.append(button);
    button.addEventListener('click', event => {
      event.stopPropagation();
      const exit = document.exitPictureInPicture
        ? document.exitPictureInPicture()
        : video.webkitSetPresentationMode('inline');
      if (exit?.catch) exit.catch(error => console.warn('Yab: PiP return failed', error));
    });

    function place() {
      if (!video.isConnected) { clear(); return; }
      const r = video.getBoundingClientRect();
      // Keep the original box for centering; clipping belongs to the host,
      // as it did to the video's scrolling/overflow ancestors.
      let left = Math.max(0, r.left), top = Math.max(0, r.top);
      let right = Math.min(innerWidth, r.right), bottom = Math.min(innerHeight, r.bottom);
      const root = document.documentElement, rootCSS = getComputedStyle(root);
      for (let node = ancestor(video); node; node = ancestor(node)) {
        // Root overflow applies to the viewport, already intersected above.
        // An HTML body's overflow propagates there too when the root is
        // visible and neither element has containment (CSS Overflow 3 §3.3).
        // Their own boxes can have zero height around positioned content.
        if (node === root) continue;
        const css = getComputedStyle(node);
        if (node === document.body && root.localName === 'html' &&
            rootCSS.overflowX === 'visible' && rootCSS.overflowY === 'visible' &&
            rootCSS.contain === 'none' && css.contain === 'none') continue;
        const box = node.getBoundingClientRect();
        if (/hidden|clip|auto|scroll/.test(css.overflowX)) { left = Math.max(left, box.left); right = Math.min(right, box.right); }
        if (/hidden|clip|auto|scroll/.test(css.overflowY)) { top = Math.max(top, box.top); bottom = Math.min(bottom, box.bottom); }
      }
      host.style.left = r.left + 'px'; host.style.top = r.top + 'px';
      host.style.width = r.width + 'px'; host.style.height = r.height + 'px';
      host.style.clipPath = right <= left || bottom <= top ? 'inset(100%)' :
        `inset(${top-r.top}px ${r.right-right}px ${r.bottom-bottom}px ${left-r.left}px)`;
    }
    const resize = new ResizeObserver(place);
    for (let node = video; node; node = ancestor(node)) resize.observe(node);
    const mutation = new MutationObserver(records => {
      if (records.some(r => r.target !== host && !host.contains(r.target))) place();
    });
    active = {video, host, resize, mutation, place};
    document.documentElement.append(host);
    if (host.showPopover) host.showPopover();
    place();
    mutation.observe(document.documentElement, {subtree:true, childList:true, attributes:true});
    if (video.getRootNode() !== document) mutation.observe(video.getRootNode(), {subtree:true, childList:true, attributes:true});
    document.addEventListener('scroll', place, true);
    window.addEventListener('resize', place);
    document.addEventListener('fullscreenchange', place);
  }

  function watch(video) {
    if (!video || watched.has(video)) return;
    watched.add(video);
    video.addEventListener('enterpictureinpicture', () => show(video));
    video.addEventListener('leavepictureinpicture', () => { if (active?.video === video) clear(); });
  }
  function listen(root) {
    if (roots.has(root)) return;
    roots.add(root);
    root.addEventListener('enterpictureinpicture', event => { watch(event.target); show(event.target); }, true);
    root.addEventListener('leavepictureinpicture', event => { if (active?.video === event.target) clear(); }, true);
  }
  window.__yabPiPPlacard = {watch, listen};
  listen(document);
  window.addEventListener('pagehide', clear);
})();
