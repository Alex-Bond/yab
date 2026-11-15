// Only empty header background moves the window. Plain div/span controls
// with delegated handlers have no discoverable listener in our isolated
// world, so words, icons and small targets always belong to the page.
// macOS 15 never holds/replays a page press at all (TopPress).
(function () {
  if (window.__yabTopDrag || window !== window.top) return;
  window.__yabTopDrag = true;
  var BAND = __YAB_BAND__;
  var said = false, queued = null;

  function say(grab, x, y) {
    // Update positive coordinates even between two empty background points.
    // Native code must never reuse one point's permission at a nearby link.
    if (!grab && grab === said) return;
    said = grab;
    var message = { grab: grab };
    if (grab) { message.x = x; message.y = y; }
    try { window.webkit.messageHandlers.yabTopDrag.postMessage(message); } catch (e) {}
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
    var style = getComputedStyle(el);
    var cursor = style.cursor;
    if (cursor && !CURSORS.test(cursor)) return false;
    // Only a broad header container's empty background is a handle. Plain
    // text, avatars, icons and small div/span controls are page content even
    // without a role, tabindex, inline listener or cursor:pointer. Isolated
    // worlds cannot inspect the site's addEventListener/delegated listeners.
    var container = /^(HEADER|NAV|DIV|SECTION|BODY|UL|OL|MENU)$/.test(el.tagName);
    // A web component can be the header's layout container too. Its empty
    // background has the same rules as a div; small/custom icon controls do not.
    var custom = /-/.test(el.localName || el.tagName) && /^(block|flex|grid|flow-root)$/.test(style.display);
    if (!container && !custom) return false;
    var rect = el.getBoundingClientRect();
    if (rect.width < innerWidth / 2 || !el.children.length) return false;
    for (var node = el.firstChild; node; node = node.nextSibling) {
      if (node.nodeType === 3 && node.textContent.trim()) return false;
    }
    var before = getComputedStyle(el, '::before').content;
    var after = getComputedStyle(el, '::after').content;
    if ((before && before !== 'none' && before !== 'normal' && before !== '""') ||
        (after && after !== 'none' && after !== 'normal' && after !== '""')) return false;
    // A selection that is already there is the page's to drag.
    var sel = getSelection();
    return !(sel && !sel.isCollapsed);
  }

  // Native hover is only a hint. Recheck the current DOM for each actual
  // down before making it a window gesture: a control can mount at rest.
  window.__yabTopDragHit = grabs;

  function look() {
    var e = queued; queued = null;
    if (e) say(grabs(e.clientX, e.clientY), e.clientX, e.clientY);
  }

  addEventListener('pointermove', function (e) {
    if (e.pointerType && e.pointerType !== 'mouse') return;
    if (e.clientY > BAND) { queued = null; say(false); return; }
    if (!queued) requestAnimationFrame(look);
    queued = e;
  }, { capture: true, passive: true });
  // What is under a pointer at rest changes with a scroll; the pointer
  // leaving the page or the page leaving ends it too.
  addEventListener('scroll', function () { queued = null; say(false); }, { capture: true, passive: true });
  addEventListener('pointerout', function (e) { if (!e.relatedTarget) { queued = null; say(false); } }, true);
  addEventListener('pagehide', function () { queued = null; say(false); });
})();
