(function () {
  const seen = new Set();
  // A query typed and run isn't a draft: Slack's search box keeps its
  // words after the search, and a tab an agent searched in stayed for good.
  const searchWords = /search|find|query|filter/i;
  function searching(el) {
    if (el.type === 'search') return true;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const role = node.getAttribute('role');
      if (role === 'search' || role === 'searchbox') return true;
      if (role === 'combobox' && searchWords.test((node.getAttribute('aria-label') || '') + ' ' + (node.getAttribute('placeholder') || ''))) return true;
    }
    const words = ['aria-label', 'placeholder', 'name', 'id', 'data-qa'].map(a => el.getAttribute(a) || '').join(' ');
    return searchWords.test(words);
  }
  // Out of sight is nothing anyone is writing.
  function shown(el) {
    return el.getClientRects().length > 0 && el.ownerDocument.defaultView.getComputedStyle(el).visibility !== 'hidden';
  }
  function inspect(root) {
    if (seen.has(root)) return false;
    seen.add(root);
    if (root === document && window.__yabForms && window.__yabForms.unsaved && window.__yabForms.unsaved()) return true;
    if (Array.from(root.querySelectorAll('video,audio')).some(m => !m.paused && !m.ended)) return true;

    // Agents can fill through a site's setters, without trusted input events.
    for (const el of root.querySelectorAll('input,textarea,select,[contenteditable]')) {
      if (el.disabled || el.readOnly || !shown(el) || searching(el)) continue;
      if (el.isContentEditable) {
        if ((el.textContent || '').trim()) return true;
      } else if (el.tagName === 'SELECT') {
        const options = Array.from(el.options);
        if (el.multiple) {
          if (options.some(o => o.selected !== o.defaultSelected)) return true;
        } else {
          let start = -1;
          options.forEach((o, i) => { if (o.defaultSelected) start = i; });
          if (start < 0 && el.size <= 1) start = options.findIndex(o => !o.disabled);
          if (el.selectedIndex !== start) return true;
        }
      } else if (el.type === 'checkbox' || el.type === 'radio') {
        if (el.checked !== el.defaultChecked) return true;
      } else if (el.type === 'file') {
        if (el.files && el.files.length) return true;
      } else if (el.tagName === 'TEXTAREA' || ['text', 'search', 'email', 'url', 'tel', 'number', 'password', 'date', 'time', 'datetime-local'].includes(el.type)) {
        if (el.value.trim() && el.value !== el.defaultValue) return true;
      }
    }
    let uncertain = false;
    for (const el of root.querySelectorAll('*')) {
      let nested = el.shadowRoot;
      if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
        // Cross-origin and sandboxed documents cannot be inspected here.
        // Ads, players and captchas are everywhere, so only one holding
        // the focus, where typing goes, leaves the answer open.
        try { nested = el.contentDocument; } catch (_) { nested = null; }
        if (!nested) { if (root.activeElement === el) uncertain = true; continue; }
      }
      if (nested) {
        const busy = inspect(nested);
        if (busy === true) return true;
        if (busy === null) uncertain = true;
      }
    }
    return uncertain ? null : false;
  }
  return inspect(document);
})()
