(function () {
  // Promises in what you send (docs/promises.md): a message you send in a
  // site's composer (Slack, Linear, GitHub, a chat), read as you send it, on
  // this Mac. Only a sentence that promises something leaves this page, with
  // the place and its link; the rest of the message never does. A send is
  // counted only once the composer has emptied: Enter that was a new line,
  // a send that failed, a draft left in the box are nothing. What you type
  // and don't send is never read.
  if (window.__yabSent) return;
  window.__yabSent = true;

  var starts = ["i'll ", "i will ", "i'm going to ", "i am going to ", "i shall ", "we'll ", "we will ",
    "will send", "will share", "will get ", "will follow up", "will intro", "will introduce", "will forward", "will loop",
    "will circle back", "will reply", "will review", "will update", "will have ", "will fix", "will finish", "will write",
    "let me send", "let me share", "let me check", "let me get back", "let me follow up", "let me look", "let me find",
    "let me dig", "let me loop", "you'll have ", "you will have ", "you'll get ", "you will get "];
  // Not promises: plans, asks, maybes, refusals. Swift reads each again
  // with the whole of MailPromise's rules; this only keeps the rest home.
  var not = ["i'll be ", "i will be ", "i'll have to ", "i'll need ", "let me know", "if you ", "would you", "could you",
    "can you", "will you", "once you ", "when you ", "unless ", "if i ", "try to", "i'll try", "hopefully", "maybe",
    "probably", "might ", "won't", "will not", "can't", "cannot"];

  function plain(s) {
    return s.toLowerCase().replace(/[’‘]/g, "'").replace(/[“”]/g, '"').trim();
  }
  function promising(sentence) {
    var lower = ' ' + plain(sentence);
    if (lower.length > 260 || /\?\s*$/.test(lower)) return false;
    for (var i = 0; i < not.length; i++) if (lower.indexOf(not[i]) >= 0) return false;
    for (var j = 0; j < starts.length; j++) if (lower.indexOf(' ' + starts[j]) >= 0) return true;
    return false;
  }
  function sentences(text) {
    var out = [];
    text.replace(/\r/g, '').split('\n').forEach(function (line) {
      var parts = line.match(/[^.!?]+[.!?]*/g) || [];
      parts.forEach(function (part) { part = part.trim(); if (part) out.push(part); });
    });
    return out;
  }

  // The box a message is written in: a contenteditable or a textarea, never
  // a password, a code, a search or a one-line field.
  function composer(el) {
    if (!el) return null;
    if (el.tagName === 'TEXTAREA') return el;
    var editable = el.closest && el.closest('[contenteditable="true"], [contenteditable=""], [role="textbox"]');
    if (!editable || editable.closest('[role="search"], [role="combobox"]')) return null;
    return editable;
  }
  function words(box) {
    if (!box) return '';
    return (box.tagName === 'TEXTAREA' ? box.value : box.innerText || '').trim();
  }
  function attached(box) {
    var root = (box && box.closest && box.closest('form, [role="dialog"], footer, [data-qa], [class]')) || document;
    return !!root.querySelector('[data-qa*="file"], [class*="attachment"], [class*="upload"], [class*="file-preview"]');
  }

  var pending = null;
  function arm(box) {
    var text = words(box);
    if (!text) return;
    var file = attached(box);
    clearTimeout(pending && pending.timer);
    pending = {
      box: box, text: text, file: file, at: location.href,
      timer: setTimeout(function () {
        var was = pending;
        pending = null;
        // Gone to another site meanwhile: whatever happened, it isn't a send here.
        if (!was || location.origin !== new URL(was.at).origin) return;
        // Sent: the box emptied or went (a reply box closes as it posts).
        var left = was.box.isConnected ? words(was.box) : '';
        if (left.length > was.text.length * 0.3) return;
        var said = sentences(was.text).filter(promising).slice(0, 4);
        window.webkit.messageHandlers.yabForms.postMessage({
          kind: 'sent', said: said, place: document.title.replace(/^\(\d+\)\s*/, '').slice(0, 120),
          url: location.href, link: /https?:\/\//.test(was.text), file: was.file
        });
      }, 1600)
    };
  }

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter' || e.shiftKey || e.altKey || e.isComposing || !e.isTrusted) return;
    var box = composer(e.target);
    if (!box) return;
    // A mention or an emoji list takes this Enter.
    if (document.querySelector('[role="listbox"]:not([hidden]) [aria-selected="true"]')) return;
    // A textarea sends with ⌘↩ (GitHub, Linear); a bare Enter is a new line there.
    if (box.tagName === 'TEXTAREA' && !(e.metaKey || e.ctrlKey)) return;
    arm(box);
  }, true);

  // A click on Send, the person's or the page's own on their behalf: the
  // words are still what the person wrote in the box.
  document.addEventListener('click', function (e) {
    var button = e.target && e.target.closest && e.target.closest('button, [role="button"]');
    if (!button) return;
    var label = ((button.getAttribute('aria-label') || '') + ' ' + (button.textContent || '')).trim().toLowerCase();
    if (!/^(send|comment|reply|post|submit|save comment|add comment)\b/.test(label) && !/\bsend( now| message)?$/.test(label)) return;
    var box = composer(document.activeElement);
    if (!box) {
      var form = button.closest('form');
      box = form && form.querySelector('textarea, [contenteditable="true"], [role="textbox"]');
    }
    if (box) arm(box);
  }, true);
})();
