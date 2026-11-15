// A site's menu at the top of the page moves the window, as in Arc: its
// words and the room between them (register #454, #714). Dragged, the
// window goes; pressed and let go, the page gets its click. Never what the
// page answers a press on: a link, a button, a menu, a field, a player, or
// a pointer other than the arrow. A held press reaches the page only at
// the release, too late for menus that open on the press (profile and bell
// menus on Reddit, Facebook and Google, Mike 10-29).
//
// The page can't be asked at the press, which WebKit hands on before any
// script hears of it, so the answer is kept up to date as the pointer moves
// over the top band and sent to Yab only when it changes (TopDrag.swift).
(function () {
  if (window.__yabTopDrag || window !== window.top) return;
  window.__yabTopDrag = true;
  var BAND = __YAB_BAND__;
  var said = false, queued = null;

  function say(grab) {
    if (grab === said) return;
    said = grab;
    try { window.webkit.messageHandlers.yabTopDrag.postMessage({ grab: grab }); } catch (e) {}
  }

  // What the page answers a press on: links, buttons, menus, fields,
  // players, maps, sliders.
  var TAGS = /^(A|BUTTON|SUMMARY|LABEL|INPUT|SELECT|TEXTAREA|OPTION|VIDEO|AUDIO|IFRAME|FRAME|EMBED|OBJECT|CANVAS|DIALOG)$/;
  var ROLES = /^(button|link|menuitem|menuitemcheckbox|menuitemradio|tab|checkbox|radio|switch|option|textbox|searchbox|combobox|slider|spinbutton|scrollbar|treeitem)$/;
  // The arrow only: the hand is something the page clicks, any other
  // pointer something that drags or selects on its own.
  var CURSORS = /^(auto|default)$/;

  // The parent, out of a shadow root to its host.
  function up(n) {
    var p = n.parentNode;
    return p && p.nodeType === 11 ? p.host : p;
  }

  function busy(el) {
    for (var n = el; n && n.nodeType === 1; n = up(n)) {
      if (TAGS.test(n.tagName)) return true;
      if (n.isContentEditable) return true;
      var role = n.getAttribute && n.getAttribute('role');
      if (role && ROLES.test(role)) return true;
      if (n.hasAttribute && (n.hasAttribute('aria-haspopup') || n.hasAttribute('aria-expanded') ||
          n.hasAttribute('onclick') || n.hasAttribute('onmousedown'))) return true;
      if (n.tabIndex >= 0 && n.tagName !== 'BODY' && n.tagName !== 'HTML') return true;
    }
    return false;
  }

  function grabs(x, y) {
    if (y < 0 || y > BAND || x < 0 || x > innerWidth) return false;
    if (document.fullscreenElement || document.webkitFullscreenElement) return false;
    var el = document.elementFromPoint(x, y);
    if (!el) return false;
    // Into open shadow roots, to the element the pointer is really on.
    while (el.shadowRoot) {
      var inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    if (busy(el)) return false;
    var cursor = getComputedStyle(el).cursor;
    if (cursor && !CURSORS.test(cursor)) return false;
    // A selection that is already there is the page's to drag.
    var sel = getSelection();
    return !(sel && !sel.isCollapsed);
  }

  function look() {
    var e = queued; queued = null;
    if (e) say(grabs(e.clientX, e.clientY));
  }

  addEventListener('pointermove', function (e) {
    if (e.pointerType && e.pointerType !== 'mouse') return;
    if (e.clientY > BAND) { say(false); return; }
    if (!queued) requestAnimationFrame(look);
    queued = e;
  }, { capture: true, passive: true });
  // What is under a pointer at rest changes with a scroll; the pointer
  // leaving the page or the page leaving ends it too.
  addEventListener('scroll', function () { say(false); }, { capture: true, passive: true });
  addEventListener('pointerout', function (e) { if (!e.relatedTarget) say(false); }, true);
  addEventListener('pagehide', function () { say(false); });
})();
