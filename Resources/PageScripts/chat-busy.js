(function () {
  // An AI chat or a builder at work (ChatBusy.swift): the site's own Stop
  // control on the page, the page is at work; gone, it is done. Said to the
  // browser only as it changes.
  //
  // A tab out of sight is a hidden page: no animation frames, timers slowed
  // to a crawl. So nothing here waits on either. A MutationObserver is
  // called as the answer's words land, and the control going is a change
  // like those, heard at once. While at work, the control found is kept and
  // only asked whether it is still in the page; a page at rest is searched
  // at most every 300 ms.
  if (window.__yabBusy) return;
  window.__yabBusy = true;
  var site = __YAB_SITE__;
  if (!site.stop) return;

  var busy = false, word = '', control = null, last = 0, later = null;

  function say() {
    try { window.webkit.messageHandlers.yabForms.postMessage({ kind: 'busy', on: busy, word: word }); } catch (e) {}
  }

  function find() {
    try { return document.querySelector(site.stop); } catch (e) { return null; }
  }

  function named() {
    if (site.longer) {
      try { if (document.querySelector(site.longer)) return site.longerWord; } catch (e) {}
    }
    return site.word;
  }

  function look() {
    clearTimeout(later);
    later = null;
    last = Date.now();
    var found = control && control.isConnected && control.matches(site.stop) ? control : find();
    control = found;
    var now = !!found;
    var said = now ? named() : '';
    if (now === busy && said === word) return;
    busy = now;
    word = said;
    say();
  }

  function changed() {
    // At work: is the control still there? One step, every time.
    if (busy) {
      if (!(control && control.isConnected && control.matches(site.stop))) look();
      return;
    }
    var wait = 300 - (Date.now() - last);
    if (wait <= 0) look();
    else if (!later) later = setTimeout(look, wait);
  }

  new MutationObserver(changed).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ['aria-label', 'data-testid', 'data-is-streaming', 'title', 'hidden']
  });
  look();
})();
