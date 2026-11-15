// Snippets in a page's boxes (PageSnippets.swift, docs/snippets.md): ";"
// at a word's start and a name typed after it, up to the caret, said to
// Yab with where the caret is, so the snippets by that name can hang under
// it; and what is pasted, so text pasted again and again can be offered as
// a snippet. Never in a password box, a box for a code, or a code editor.
// Posted on the forms' channel (FormRelay), in Yab's own world.
(function () {
  if (window.__yabSnippets) return;
  window.__yabSnippets = true;
  var post = function (body) {
    try { window.webkit.messageHandlers.yabForms.postMessage(body); } catch (e) {}
  };

  // Whether the page is dark behind a box, for the list's look (DropFrame).
  __YAB_GROUND__

  // The element the caret is really in, inside a component's shadow root.
  function inside(el) {
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el;
  }

  var editors = '.cm-editor,.CodeMirror,.monaco-editor,.ace_editor,.CodeMirror-code,pre,code,[data-language]';
  // A box that takes words: not a password, not a code, not a code editor.
  function wordsBox(el) {
    if (!el || !el.tagName) return null;
    var tag = el.tagName.toLowerCase();
    if (el.closest && el.closest(editors)) return null;
    if (tag === 'textarea') return el;
    if (tag === 'input') {
      var kind = (el.type || 'text').toLowerCase();
      if (['text', 'search', 'email', 'url'].indexOf(kind) < 0) return null;
      var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
      if (auto.indexOf('one-time-code') >= 0 || auto.indexOf('password') >= 0) return null;
      return el;
    }
    if (el.isContentEditable === true) return el;
    return null;
  }

  function secretBox(el) {
    if (!el || !el.tagName) return false;
    if (el.tagName.toLowerCase() !== 'input') return false;
    var kind = (el.type || '').toLowerCase();
    var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
    return kind === 'password' || auto.indexOf('one-time-code') >= 0 || auto.indexOf('password') >= 0;
  }

  // ";" at a word's start, a few word characters after it, up to the caret.
  var trigger = /(^|[\s ]);([\p{L}\p{N}_-]{0,40})$/u;
  var wordAfter = /^[\p{L}\p{N}_-]/u;

  // What is before the caret in the box, and how to put words over it.
  function reading(box) {
    var tag = box.tagName.toLowerCase();
    if (tag === 'input' || tag === 'textarea') {
      var at = box.selectionStart, end = box.selectionEnd;
      if (at == null || at !== end) return null;
      return { before: box.value.slice(0, at), after: box.value.slice(at, at + 1), field: true, at: at };
    }
    var sel = box.ownerDocument.getSelection();
    if (!sel || sel.rangeCount === 0 || !sel.isCollapsed) return null;
    var range = sel.getRangeAt(0);
    var node = range.startContainer;
    if (node.nodeType !== 3) return null;
    var text = node.data;
    return { before: text.slice(0, range.startOffset), after: text.slice(range.startOffset, range.startOffset + 1),
             field: false, node: node, at: range.startOffset };
  }

  // Where the caret is, in the page's own CSS pixels: the line it is on in
  // a box of lines, the box itself for one line.
  function caretRect(box, read) {
    var r;
    if (!read.field) {
      var range = document.createRange();
      range.setStart(read.node, Math.max(0, read.at - 1));
      range.setEnd(read.node, read.at);
      var rects = range.getClientRects();
      r = rects.length ? rects[rects.length - 1] : range.getBoundingClientRect();
      var whole = box.getBoundingClientRect();
      return { x: Math.max(whole.left, r.left - 8), y: r.top - 4, w: Math.min(whole.width, 320), h: r.height + 8 };
    }
    var outer = box.getBoundingClientRect();
    if (box.tagName.toLowerCase() === 'input') return { x: outer.left, y: outer.top, w: outer.width, h: outer.height };
    // A textarea: its words copied into a twin laid out as it is, up to
    // the caret, the twin's last letter where the caret's line is.
    var style = getComputedStyle(box);
    var twin = document.createElement('div');
    ['boxSizing', 'width', 'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'letterSpacing', 'lineHeight',
     'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderRightWidth',
     'borderBottomWidth', 'borderLeftWidth', 'textTransform', 'wordSpacing', 'textIndent', 'tabSize'].forEach(function (k) {
      twin.style[k] = style[k];
    });
    twin.style.position = 'absolute';
    twin.style.visibility = 'hidden';
    twin.style.whiteSpace = 'pre-wrap';
    twin.style.wordWrap = 'break-word';
    twin.style.top = '0';
    twin.style.left = '-9999px';
    twin.textContent = read.before;
    var mark = document.createElement('span');
    mark.textContent = '​';
    twin.appendChild(mark);
    document.body.appendChild(twin);
    var top = mark.offsetTop - box.scrollTop, height = mark.offsetHeight || parseFloat(style.lineHeight) || 18;
    twin.remove();
    var y = Math.min(Math.max(outer.top, outer.top + top - 4), outer.bottom - height - 8);
    return { x: outer.left, y: y, w: Math.min(outer.width, 320), h: height + 8 };
  }

  var shown = false;
  var lastBox = null, dark = null;
  function look() {
    var box = wordsBox(inside(document.activeElement));
    var read = box && reading(box);
    var found = read && trigger.exec(read.before);
    if (!found || (read.after && wordAfter.test(read.after))) {
      if (shown) { shown = false; post({ kind: 'snippet', on: false }); }
      return;
    }
    if (box !== lastBox) { lastBox = box; dark = yabGround(box); }
    shown = true;
    // Where ";" stands, so esc puts away the list for that ";" alone.
    var at = read.before.length - found[0].length + found[1].length;
    post({ kind: 'snippet', on: true, words: found[2], at: at, rect: caretRect(box, read), dark: dark });
  }

  var waiting = false;
  function soon() {
    if (waiting) return;
    waiting = true;
    requestAnimationFrame(function () { waiting = false; look(); });
  }
  document.addEventListener('input', look, true);
  document.addEventListener('selectionchange', function () { if (shown) soon(); }, true);
  document.addEventListener('focusout', function () { setTimeout(look, 0); }, true);
  window.addEventListener('scroll', function () { if (shown) soon(); }, true);

  // A snippet's words over ";" and its name: typed in as the keyboard would,
  // so the page's own undo takes them back, and the first {{place}} in them
  // chosen, ready to be typed over.
  window.__yabSnippetPut = function (text) {
    var box = wordsBox(inside(document.activeElement)) || lastBox;
    if (!box) return false;
    if (document.activeElement !== box && box.focus) box.focus();
    var read = reading(box);
    var found = read && trigger.exec(read.before);
    var length = found ? found[0].length - found[1].length : 0;
    if (read && read.field) {
      var start = read.at - length;
      box.setSelectionRange(start, read.at);
      var typed = false;
      try { typed = document.execCommand('insertText', false, text); } catch (e) {}
      if (!typed) {
        box.setRangeText(text, start, read.at, 'end');
        box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      }
      var hole = /\{\{[^{}\n]{1,80}\}\}/.exec(box.value.slice(start, start + text.length));
      if (hole) box.setSelectionRange(start + hole.index, start + hole.index + hole[0].length);
    } else if (read) {
      var range = document.createRange();
      range.setStart(read.node, read.at - length);
      range.setEnd(read.node, read.at);
      var sel = box.ownerDocument.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      if (!document.execCommand('insertText', false, text)) {
        range.deleteContents();
        range.insertNode(document.createTextNode(text));
      }
    } else {
      document.execCommand('insertText', false, text);
    }
    shown = false;
    post({ kind: 'snippet', on: false });
    return true;
  };

  // What was pasted where words are typed: for Yab to count, never from a
  // password box or a box for a code.
  document.addEventListener('paste', function (e) {
    var el = inside(e.target && e.target.nodeType === 1 ? e.target : document.activeElement);
    if (secretBox(el)) return;
    if (!wordsBox(el)) return;
    var text = e.clipboardData ? e.clipboardData.getData('text/plain') : '';
    if (!text || text.length < 12 || text.length > 4000) return;
    post({ kind: 'paste', text: text });
  }, true);
})();
