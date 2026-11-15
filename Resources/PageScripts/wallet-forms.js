(function () {
  if (window.__yabWallet) return;
  var top = window === window.top;
  // This document's own name: frames from one address are still apart.
  var me = Math.random().toString(36).slice(2);
  function post(m) {
    m.frame = me;
    try { window.webkit.messageHandlers.yabWallet.postMessage(m); } catch (e) {}
  }

  // What the page says a box is for, in the words of the HTML standard.
  var AUTO = {
    'cc-number': 'number', 'cc-name': 'holder', 'cc-given-name': 'holderGiven',
    'cc-family-name': 'holderFamily', 'cc-exp': 'exp', 'cc-exp-month': 'month',
    'cc-exp-year': 'year', 'cc-csc': 'csc',
    'name': 'name', 'given-name': 'given', 'family-name': 'family',
    'organization': 'org', 'street-address': 'street', 'address-line1': 'line1',
    'address-line2': 'line2', 'address-line3': 'line3', 'address-level2': 'city',
    'address-level1': 'region', 'postal-code': 'postal', 'country': 'country',
    'country-name': 'country', 'tel': 'tel', 'tel-national': 'telNational', 'tel-country-code': 'telCode',
    'tel-area-code': 'telArea', 'tel-local': 'telLocal', 'email': 'email'
  };
  var CARD = { number: 1, holder: 1, holderGiven: 1, holderFamily: 1, exp: 1, month: 1, year: 1, csc: 1 };
  var PLACE = { street: 1, line1: 1, line2: 1, city: 1, postal: 1, region: 1 };

  // And failing that, what its name, label and placeholder say. Card
  // boxes first: "name on card" is not a name for an address.
  var RULES = [
    ['csc', /cvc|cvv|\bcsc\b|\bcvn\b|security.?code|card.?verification/],
    ['number', /card.?(number|no\b|num)|cc.?(number|num)|ccnum|cardnum|credit.?card|debit.?card|card ?#|kartennummer|numéro de carte|n[uú]mero de (la )?tarjeta/, /name|holder|cvc|cvv|exp/],
    ['holder', /card.?holder|name.?on.?(the.?)?card|cc.?name|holder.?name|card.?name|nameoncard/],
    ['email', /e.?mail/],
    ['tel', /phone|mobile|\btel\b|telephone/],
    ['given', /first.?name|given.?name|\bfname\b|firstname/, /user|login/],
    ['family', /last.?name|surname|family.?name|\blname\b|lastname/],
    ['org', /company|organi[sz]ation|business.?name/],
    ['line2', /address.?(line)?.?2|addr(ess)?.?2|\bapt\b|apartment|suite|\bunit\b|\bflat\b/],
    ['line1', /address.?(line)?.?1|addr(ess)?.?1|street|\baddress\b|\baddr\b/, /e.?mail|ip.?address|web|url|\bmac\b/],
    ['city', /city|town|locality|suburb/],
    ['region', /\bstate\b|province|region|county/, /statement/],
    ['postal', /\bzip|postal|post.?code|postcode|\bpin.?code/],
    ['country', /country/],
    ['name', /full.?name|^name\b|your.?name|recipient|\bname\b/, /user|login|company|card|file|nick|search|first|last|middle|business|display|domain|project|team/]
  ];

  function text(n) { return n ? (n.innerText || n.textContent || '') : ''; }

  // Everything the page says about a box, lower case, in one line.
  function hint(el) {
    var parts = [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), el.getAttribute('title')];
    if (el.labels) for (var i = 0; i < el.labels.length; i++) parts.push(text(el.labels[i]));
    var by = el.getAttribute('aria-labelledby');
    if (by) by.split(/\s+/).forEach(function (id) { parts.push(text(document.getElementById(id))); });
    // A label that isn't tied to its box: the words just around it.
    if (!(el.labels && el.labels.length) && el.tagName !== 'SELECT' && !picker(el)) {
      var p = el.parentElement, words = text(p);
      if (words && words.length < 60) parts.push(words);
    }
    return parts.filter(Boolean).join(' ').toLowerCase().replace(/\s+/g, ' ');
  }

  // A menu the page draws itself, no <select>: a button or a box that
  // opens a list of options (Fluent's Dropdown on Azure's sign-up, MUI's
  // Select). Its words are read as a menu's, and a pick opens it and
  // clicks the option (pick()).
  function picker(el) {
    var tag = el.tagName.toLowerCase();
    if (tag === 'input' || tag === 'select' || tag === 'textarea') return false;
    return el.getAttribute('role') === 'combobox' || el.getAttribute('aria-haspopup') === 'listbox';
  }
  function menu(el) { return el.tagName === 'SELECT' || picker(el); }

  // The kind of box, or null.
  function kind(el) {
    if (!el || !el.tagName) return null;
    var tag = el.tagName.toLowerCase();
    if (tag !== 'input' && tag !== 'select' && tag !== 'textarea' && !picker(el)) return null;
    if (tag === 'input') {
      var t = (el.getAttribute('type') || 'text').toLowerCase();
      if (['text', 'tel', 'email', 'number', 'search'].indexOf(t) < 0) return null;
    }
    if (el.disabled || el.readOnly || el.getAttribute('aria-disabled') === 'true' || codeBox(el)) return null;
    var auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/)
      .filter(function (w) { return w && w !== 'webauthn'; });
    var named = auto.length ? AUTO[auto[auto.length - 1]] : null;
    if (named) return tag === 'textarea' && named !== 'street' ? null : named;
    if (tag === 'textarea') return /address|street/.test(hint(el)) ? 'street' : null;
    var h = hint(el);
    if (h) {
      // A card's date: one box for both, or a box each.
      // "exp", but not "expected" or "expectation": a salary box asks
      // for a year too, and took the cards' list.
      var dated = /exp(?!ect)|valid|cc.?m|cc.?y|card.?m|card.?y/.test(h);
      if (/mm.?\/?.?yy|exp(iry|iration)?.?date|expir(y|ation)$|valid.?(thru|until)/.test(h)) return 'exp';
      if (dated && /month|\bmm\b|\bmon\b/.test(h)) return 'month';
      if (dated && /year|\byy(yy)?\b/.test(h)) return 'year';
      for (var r = 0; r < RULES.length; r++) {
        if (RULES[r][1].test(h) && !(RULES[r][2] && RULES[r][2].test(h))) return RULES[r][0];
      }
    }
    var type = (el.getAttribute('type') || '').toLowerCase();
    if (type === 'email') return 'email';
    if (type === 'tel') return 'tel';
    // A menu beside a card's number that lists the twelve months, or
    // the years ahead, is its date, whatever it is called.
    if (tag === 'select' && el.options.length >= 10 && document.querySelector('[autocomplete~="cc-number"], [name*="card" i][name*="num" i]')) {
      var nums = [].map.call(el.options, function (o) { return +(o.value || '').replace(/\D/g, '') || 0; }).filter(Boolean);
      if (nums.length >= 12 && Math.max.apply(null, nums) === 12 && Math.min.apply(null, nums) === 1) return 'month';
      var year = new Date().getFullYear();
      if (nums.length >= 5 && nums.every(function (n) { return (n >= year && n < year + 30) || (n >= year % 100 && n < year % 100 + 30); })) return 'year';
    }
    return null;
  }

  // A box someone can see: of a size a person could type in, on the
  // page, not faded out, and not cut away by a box around it (a
  // height of 0 with its overflow hidden). What only a script can
  // see never gets anything.
  // Within one look at a whole form (oneLook()), what each box around
  // the boxes is, read once: every box of a big form shares the same
  // few dozen of them, and a look on each keystroke read them all
  // again for each box.
  var around = null;
  function aroundOf(up) {
    var got = around && around.get(up);
    if (got) return got;
    var u = getComputedStyle(up);
    got = { faded: parseFloat(u.opacity || '1') < 0.2,
            clips: !(u.overflow === 'visible' && u.overflowX === 'visible' && u.overflowY === 'visible') };
    if (got.clips) got.rect = up.getBoundingClientRect();
    if (around) around.set(up, got);
    return got;
  }
  function oneLook(look) {
    var was = around;
    around = was || new Map();
    try { return look(); } finally { around = was; }
  }
  function shown(el) {
    var r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return false;
    // A box put far off the page to catch whatever fills it.
    if (r.right < -100 || r.bottom < -window.scrollY - 100 || r.left > Math.max(document.documentElement.scrollWidth, innerWidth) + 100) return false;
    var s = getComputedStyle(el);
    if (s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity || '1') < 0.2) return false;
    for (var up = el.parentElement; up && up !== document.body; up = up.parentElement) {
      var u = aroundOf(up);
      if (u.faded) return false;
      if (!u.clips) continue;
      var b = u.rect;
      // What of the box is left inside what clips it.
      var w = Math.min(r.right, b.right) - Math.max(r.left, b.left);
      var h = Math.min(r.bottom, b.bottom) - Math.max(r.top, b.top);
      if (w < 8 || h < 8) return false;
    }
    return true;
  }

  // The boxes of a form, or of the page, each with its kind.
  function boxes(scope) {
    var out = [], all = (scope || document).querySelectorAll('input, select, textarea, [role=combobox], [aria-haspopup=listbox]');
    for (var i = 0; i < all.length; i++) {
      var k = kind(all[i]);
      if (k && shown(all[i])) out.push({ el: all[i], kind: k });
    }
    return out;
  }
  function scopeOf(el) { return (el && (el.form || (el.closest && el.closest('form')))) || document; }

  // Whether the boxes around this one ask for an address: three parts
  // of one at least, and where it is among them.
  function addressy(scope) {
    var kinds = {}, place = false;
    boxes(scope).forEach(function (b) {
      if (CARD[b.kind]) return;
      kinds[b.kind] = 1;
      if (PLACE[b.kind]) place = true;
    });
    return place && Object.keys(kinds).length >= 3;
  }

  // Which list a box calls for: a card's, an address's, or none.
  function group(el) {
    var k = kind(el);
    if (!k) return null;
    if (CARD[k]) {
      if (k === 'csc') return null;
      // A name on its own is a card's only beside a card's number, or
      // beside the frames the number is in, or in a frame of its own:
      // a payment form's (Bilt's VGS) puts each box in one, and the
      // name's held no list.
      if (k === 'holder' || k === 'holderGiven' || k === 'holderFamily') {
        var scope = scopeOf(el);
        var near = boxes(scope).some(function (b) { return b.kind === 'number' || b.kind === 'exp'; });
        if (!near && top && !document.querySelector('iframe')) return null;
      }
      return 'card';
    }
    return addressy(scopeOf(el)) ? 'address' : null;
  }

  // A phone box: the numbers kept for you hang from it, in a form too,
  // where an address's list showed streets under it. Not a sign-in's
  // name box, which the accounts hang from.
  function alonePhone(el) {
    var k = kind(el);
    if (k !== 'tel' && k !== 'telNational') return false;
    if (/username/i.test(el.getAttribute('autocomplete') || '')) return false;
    return shown(el);
  }

  function active() {
    var el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el;
  }

  // Where the caret is, when it is in a box a card or an address could
  // go in, so a list can hang from it.
  __YAB_GROUND__
  var said = '', grounded = null, dark = null;
  function caret() {
    var el = active();
    // A drawn menu opens its own list where Yab's would hang: it is filled
    // from the form's other boxes.
    var g = !el || !el.tagName || picker(el) ? null : alonePhone(el) ? 'phone' : group(el) || (formy(el) ? 'form' : null);
    if (!g) {
      if (said) { said = ''; post({ kind: 'focus' }); }
      return;
    }
    var r = el.getBoundingClientRect();
    if (el !== grounded) { grounded = el; dark = yabGround(el); }
    var m = {
      kind: 'focus', group: g, field: kind(el), empty: !value(el).value,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height }, dark: dark,
      secure: !!window.isSecureContext, href: location.href,
      vw: document.documentElement.clientWidth, vh: document.documentElement.clientHeight
    };
    var line = JSON.stringify(m);
    if (line === said) return;
    said = line;
    post(m);
    watchGone();
  }
  // A box taken out of the page, or hidden, says no focusout: a step of
  // a sign-in swapped for the next one left its list hanging. Looked at
  // while a list may hang, and only whether the box is still there.
  var watching = 0;
  function watchGone() {
    if (watching) return;
    watching = setInterval(function () {
      if (!said) { clearInterval(watching); watching = 0; return; }
      var el = active();
      if (el !== grounded || !el || !el.isConnected || !shown(el)) caret();
    }, 400);
  }
  var moving = false;
  function moved() {
    if (moving) return;
    moving = true;
    requestAnimationFrame(function () { moving = false; caret(); });
  }
  document.addEventListener('focusin', caret, true);
  document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
  document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
  window.addEventListener('scroll', moved, true);
  window.addEventListener('resize', moved);
  document.addEventListener('input', moved, true);

  // What the boxes hold.
  function digits(v) { return String(v || '').replace(/\D/g, ''); }
  function value(el) {
    if (el.tagName === 'SELECT') {
      var o = el.selectedOptions && el.selectedOptions[0];
      return o ? { value: o.value, text: (o.text || '').trim() } : { value: '', text: '' };
    }
    // A drawn menu shows its choice, or its placeholder: "MM", "--Select--".
    if (picker(el)) {
      var shows = String(text(el)).replace(/\s+/g, ' ').trim();
      if (/^(--|—|select|choose|pick|please|mm|yy|yyyy|month|year)\b/i.test(shows)) shows = '';
      return { value: shows, text: shows };
    }
    return { value: el.value || '', text: el.value || '' };
  }
  function card(list) {
    var c = { number: '', name: '', month: 0, year: 0, csc: '' };
    var given = '', family = '';
    list.forEach(function (b) {
      var v = value(b.el);
      switch (b.kind) {
        case 'number': c.number = digits(v.value); break;
        case 'holder': c.name = v.value.trim(); break;
        case 'holderGiven': given = v.value.trim(); break;
        case 'holderFamily': family = v.value.trim(); break;
        case 'exp':
          var d = digits(v.value);
          if (d.length >= 3) { c.month = +d.slice(0, 2); c.year = +d.slice(2); }
          break;
        case 'month': c.month = +digits(v.value) || +digits(v.text); break;
        case 'year': c.year = +digits(v.value) || +digits(v.text); break;
        case 'csc': c.csc = digits(v.value).slice(0, 4); break;
      }
    });
    if (!c.name && (given || family)) c.name = (given + ' ' + family).trim();
    return c.number || c.name || c.month || c.year || c.csc ? c : null;
  }
  function address(list) {
    var a = {}, lines = [], given = '', family = '';
    list.forEach(function (b) {
      if (CARD[b.kind]) return;
      var v = value(b.el), t = v.value.trim();
      switch (b.kind) {
        case 'street': lines = t.split(/\n+/); break;
        case 'line1': lines[0] = t; break;
        case 'line2': lines[1] = t; break;
        case 'line3': lines[2] = t; break;
        case 'given': given = t; break;
        case 'family': family = t; break;
        case 'country': case 'region': a[b.kind] = menu(b.el) ? v.text : t; break;
        case 'org': a.organization = t; break;
        case 'tel': a.phone = t; break;
        default: a[b.kind] = t;
      }
    });
    if (!a.name && (given || family)) a.name = (given + ' ' + family).trim();
    a.street = lines.filter(Boolean).join('\n');
    return a.street ? a : null;
  }

  // Sent: a form's submit, Return in one of its boxes, or a click on a
  // button. What the boxes held goes to yab, which keeps it only if
  // the page moves on, a payment that went through.
  function send() {
    var list = boxes(document);
    var c = card(list), scope = null;
    for (var i = 0; i < list.length; i++) if (!CARD[list[i].kind]) { scope = scopeOf(list[i].el); break; }
    var a = scope && addressy(scope) ? address(list) : null;
    if (!c && !a) {
      // The card is in other sites' frames: the top page says it was
      // sent, and yab puts that together with what those frames said.
      if (top && document.querySelector('iframe')) post({ kind: 'send' });
      return;
    }
    post({ kind: 'send', card: c, address: a });
  }
  // Only a person's own press counts, or an agent's real click: a
  // click a page's script makes is not someone paying.
  document.addEventListener('submit', function (e) { if (e.isTrusted) send(); }, true);
  document.addEventListener('keydown', function (e) {
    if (e.isTrusted && e.key === 'Enter' && group(active())) send();
  }, true);
  document.addEventListener('click', function (e) {
    var el = e.target;
    if (!e.isTrusted) return;
    if (el && el.closest && el.closest('button, input[type="submit"], input[type="image"], [role="button"]')) setTimeout(send, 0);
  }, true);

  // A card's boxes in a frame of their own: what they hold as it
  // changes, so the page around them can send it.
  var seeing = null;
  function seen() {
    clearTimeout(seeing);
    seeing = setTimeout(function () {
      var list = boxes(document).filter(function (b) { return CARD[b.kind]; });
      var c = card(list);
      if (c) post({ kind: 'seen', card: c });
    }, 300);
  }
  function cardChanged(e) {
    var k = kind(e.target);
    if (!CARD[k]) return;
    // The 300 ms collection below is for autofill suggestions. Mark
    // sensitive pixels at once, before an agent can ask for a screenshot.
    if ((k === 'number' || k === 'csc') && e.target.value) post({ kind: 'sensitive' });
    seen();
  }
  document.addEventListener('input', cardChanged, true);
  document.addEventListener('change', cardChanged, true);
  if (!top) {
    // Said as soon as the boxes are there, not when the caret first
    // comes in: a pick in the page around fills every such frame, the
    // number's, the date's and the code's, each its own frame.
    var told = '', looking = null;
    var tell = function () {
      var list = boxes(document);
      // A frame with the security code alone counts: a kept card has its
      // code, and Stripe's split fields put it in a frame of its own.
      var card = list.some(function (b) { return CARD[b.kind]; });
      var place = addressy(document);
      var now = (card ? 'card' : '') + (place ? 'address' : '');
      if (!now || now === told) return;
      told = now;
      post({ kind: 'fields', card: card, address: place });
    };
    tell();
    window.addEventListener('load', tell);
    setTimeout(tell, 700);
    setTimeout(tell, 2200);
    new MutationObserver(function () {
      if (looking) return;
      looking = setTimeout(function () { looking = null; tell(); }, 250);
    }).observe(document.documentElement, { childList: true, subtree: true });
  }

  // Putting a value where a person would have typed it: through the
  // box's own setter, then the events a keystroke fires, so a page's
  // script sees it as typed.
  // While a whole form is filled, what each box held before, for undo.
  var recording = null;
  function put(el, v) {
    if (v == null || v === '') return false;
    if (menu(el)) return choose(el, v);
    if (recording) recording.push({ el: el, value: el.value });
    var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) setter.set.call(el, v); else el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    glow(el);
    return true;
  }
  // What yab put in shows for a moment, a pale yellow that fades back
  // to the box's own ground: the one trace of a fill,
  // with nothing said. An animation of the box's own, so the page's
  // styles are never touched.
  function glow(el) {
    if (!el.animate) return;
    try {
      var ground = getComputedStyle(el).backgroundColor;
      var tint = 'rgba(255, 204, 0, 0.24)';
      el.animate([{ backgroundColor: tint }, { backgroundColor: tint, offset: 0.5 }, { backgroundColor: ground }],
                 { duration: 1500, easing: 'ease-out' });
    } catch (e) {}
  }
  // A menu: the option whose value or words are what is meant, "US",
  // "United States", "08", "August", "2028" or "28".
  function choose(el, wanted) {
    if (picker(el)) { queued.push({ el: el, wanted: [].concat(wanted) }); return false; }
    var list = [].concat(wanted), opts = el.options;
    for (var w = 0; w < list.length; w++) {
      var want = String(list[w]).trim().toLowerCase();
      if (!want) continue;
      for (var i = 0; i < opts.length; i++) {
        var o = opts[i];
        if (o.disabled) continue;
        if (o.value.toLowerCase() === want || (o.text || '').trim().toLowerCase() === want) {
          if (recording) recording.push({ el: el, value: el.value });
          el.value = o.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          glow(el);
          return true;
        }
      }
    }
    return false;
  }

  // Drawn menus waiting for their pick: opening one re-renders the page,
  // so they are picked one after another once the plain boxes are in.
  var queued = [];
  // A press as a pointer makes it: some menus open on the press, some
  // on the click.
  function press(el) {
    var r = el.getBoundingClientRect(), at = { bubbles: true, cancelable: true, composed: true, button: 0,
      clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, view: window };
    var P = window.PointerEvent || MouseEvent;
    el.dispatchEvent(new P('pointerdown', at));
    el.dispatchEvent(new MouseEvent('mousedown', at));
    el.dispatchEvent(new P('pointerup', at));
    el.dispatchEvent(new MouseEvent('mouseup', at));
    el.dispatchEvent(new MouseEvent('click', at));
  }
  // The options a drawn menu has opened: its own list by aria-controls
  // or aria-owns, else the list now showing.
  function optionsOf(el) {
    var ids = ((el.getAttribute('aria-controls') || '') + ' ' + (el.getAttribute('aria-owns') || '')).split(/\s+/);
    for (var i = 0; i < ids.length; i++) {
      var own = ids[i] && document.getElementById(ids[i]);
      if (own) {
        var mine = own.getAttribute('role') === 'option' ? [own] : [].slice.call(own.querySelectorAll('[role=option]'));
        if (mine.length) return mine;
      }
    }
    return [].filter.call(document.querySelectorAll('[role=option]'), shown);
  }
  // Opens the menu and clicks the option whose words or value are
  // wanted; closes it again when none is. True when one was picked.
  function pick(el, wanted) {
    var want = wanted.map(function (w) { return String(w == null ? '' : w).trim().toLowerCase(); }).filter(Boolean);
    if (!want.length) return Promise.resolve(false);
    if (want.indexOf(value(el).text.toLowerCase()) >= 0) return Promise.resolve(false);
    try { el.focus(); } catch (e) {}
    press(el);
    return new Promise(function (done) {
      var tries = 0;
      (function look() {
        var opts = optionsOf(el), hit = null;
        for (var w = 0; w < want.length && !hit; w++) {
          for (var i = 0; i < opts.length; i++) {
            var o = opts[i];
            if (o.getAttribute('aria-disabled') === 'true') continue;
            var words = String(text(o)).replace(/\s+/g, ' ').trim().toLowerCase();
            var v = (o.getAttribute('data-value') || o.getAttribute('value') || '').toLowerCase();
            if (words === want[w] || v === want[w]) { hit = o; break; }
          }
        }
        if (hit) { press(hit); glow(el); return done(true); }
        // Open with nothing that fits, or never opened: put away.
        if ((opts.length && tries >= 3) || ++tries > 20) {
          el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
          return done(false);
        }
        setTimeout(look, 30);
      })();
    });
  }
  // `n` boxes filled, and the menus queued meanwhile picked: a promise
  // of the whole count when there are any.
  function picks(n) {
    var list = queued;
    queued = [];
    if (!list.length) return n;
    return list.reduce(function (chain, q) {
      return chain.then(function () {
        if (!q.el.isConnected) return;
        return pick(q.el, q.wanted).then(function (ok) { if (ok) n++; });
      });
    }, Promise.resolve()).then(function () { return n; });
  }

  var MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
  var COUNTRIES = {
    'us': ['united states', 'united states of america', 'usa'], 'gb': ['united kingdom', 'uk', 'great britain'],
    'de': ['germany', 'deutschland'], 'fr': ['france'], 'ca': ['canada'],
    'nl': ['netherlands'], 'es': ['spain', 'españa'], 'it': ['italy', 'italia'], 'au': ['australia'], 'jp': ['japan']
  };
  // A phone as it is kept, "+1 415 555 0100", in its parts.
  function phone(v) {
    var t = String(v || '').trim(), m = t.match(/^\+(\d{1,3})[\s.(-]+(.*)$/);
    if (m) return { code: '+' + m[1], national: m[2].replace(/\D/g, '') };
    var d = t.replace(/\D/g, '');
    if (t[0] === '+' && d.length === 11 && d[0] === '1') return { code: '+1', national: d.slice(1) };
    return { code: '', national: d };
  }
  // A whole phone box: as kept, unless it asks for a country's own
  // digits (a mask with no +, "(___) ___-____"): then those.
  function phoneIn(el, v) {
    var shape = (el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('pattern') || '');
    var p = phone(v);
    if (p.code && /[_(#9]/.test(shape) && shape.indexOf('+') < 0) return p.national;
    return v;
  }
  var STATES = {
    AL: 'Alabama', AK: 'Alaska', AZ: 'Arizona', AR: 'Arkansas', CA: 'California', CO: 'Colorado', CT: 'Connecticut',
    DE: 'Delaware', DC: 'District of Columbia', FL: 'Florida', GA: 'Georgia', HI: 'Hawaii', ID: 'Idaho', IL: 'Illinois',
    IN: 'Indiana', IA: 'Iowa', KS: 'Kansas', KY: 'Kentucky', LA: 'Louisiana', ME: 'Maine', MD: 'Maryland',
    MA: 'Massachusetts', MI: 'Michigan', MN: 'Minnesota', MS: 'Mississippi', MO: 'Missouri', MT: 'Montana',
    NE: 'Nebraska', NV: 'Nevada', NH: 'New Hampshire', NJ: 'New Jersey', NM: 'New Mexico', NY: 'New York',
    NC: 'North Carolina', ND: 'North Dakota', OH: 'Ohio', OK: 'Oklahoma', OR: 'Oregon', PA: 'Pennsylvania',
    RI: 'Rhode Island', SC: 'South Carolina', SD: 'South Dakota', TN: 'Tennessee', TX: 'Texas', UT: 'Utah',
    VT: 'Vermont', VA: 'Virginia', WA: 'Washington', WV: 'West Virginia', WI: 'Wisconsin', WY: 'Wyoming',
    PR: 'Puerto Rico', AB: 'Alberta', BC: 'British Columbia', MB: 'Manitoba', NB: 'New Brunswick',
    NL: 'Newfoundland and Labrador', NS: 'Nova Scotia', ON: 'Ontario', PE: 'Prince Edward Island', QC: 'Quebec',
    SK: 'Saskatchewan'
  };
  // A state as kept, "CA" or "California", in every way a menu may
  // name it: its code, its name, "US-CA".
  function regions(v) {
    var t = String(v || '').trim(), up = t.toUpperCase(), out = [t];
    if (STATES[up]) out.push(STATES[up], 'US-' + up);
    Object.keys(STATES).forEach(function (code) { if (STATES[code].toLowerCase() === t.toLowerCase()) out.push(code, 'US-' + code); });
    return out;
  }
  // A state box: two letters when it holds only two.
  function regionIn(el, v) {
    var all = regions(v);
    if (el.maxLength === 2) return all.filter(function (x) { return /^[A-Za-z]{2}$/.test(x); })[0] || v;
    return v;
  }
  function countries(v) {
    var t = String(v || '').trim().toLowerCase(), out = [v];
    Object.keys(COUNTRIES).forEach(function (code) {
      var names = COUNTRIES[code];
      if (t === code || names.indexOf(t) >= 0) { out.push(code, code.toUpperCase()); out = out.concat(names); }
    });
    return out;
  }

  // A card's date in the shape the box asks for: "MM / YY", "MM/YYYY",
  // "MMYY".
  // The shape the page shows first, in its placeholder ("MM / YY",
  // "MM/YYYY", "MMYY"); failing that, what fits its length.
  function dated(el, month, year) {
    var mm = ('0' + month).slice(-2), yyyy = String(year), yy = yyyy.slice(-2);
    var shape = (el.getAttribute('placeholder') || '').toLowerCase();
    var max = el.maxLength > 0 ? el.maxLength : 0;
    var long = /yyyy|aaaa/.test(shape) || (!/yy|aa/.test(shape) && (max === 7 || max === 6));
    var sep = / \/ /.test(shape) ? ' / ' : /\//.test(shape) ? '/' : /-/.test(shape) ? '-' : (max === 4 || max === 6) ? '' : shape ? '' : '/';
    if (!shape) sep = max === 4 || max === 6 ? '' : max === 7 && !long ? ' / ' : '/';
    return mm + sep + (long ? yyyy : yy);
  }
  // A year box on its own: two digits when its placeholder or length says so.
  function yearIn(el, yyyy) {
    var shape = (el.getAttribute('placeholder') || '').toLowerCase();
    var two = el.maxLength === 2 || (/yy|aa/.test(shape) && !/yyyy|aaaa/.test(shape));
    return two ? yyyy.slice(-2) : yyyy;
  }

  function fillCard(c, list) {
    var n = 0, words = String(c.name || '').trim().split(/\s+/);
    // A number in several boxes, four digits each: each takes its part.
    var parts = list.filter(function (b) { return b.kind === 'number'; });
    var rest = String(c.number || '');
    list.forEach(function (b) {
      var el = b.el, done = false;
      switch (b.kind) {
        case 'number':
          if (parts.length > 1) {
            var take = el.maxLength > 0 && el.maxLength < rest.length ? el.maxLength : rest.length;
            done = put(el, rest.slice(0, take));
            rest = rest.slice(take);
          } else {
            done = put(el, c.number);
          }
          break;
        case 'holder': done = put(el, c.name); break;
        case 'holderGiven': done = put(el, words[0]); break;
        case 'holderFamily': done = put(el, words.slice(1).join(' ')); break;
        case 'exp': done = put(el, dated(el, c.month, c.year)); break;
        case 'month':
          done = menu(el)
            ? choose(el, [('0' + c.month).slice(-2), String(c.month), MONTHS[c.month - 1], MONTHS[c.month - 1].slice(0, 3)])
            : put(el, ('0' + c.month).slice(-2));
          break;
        case 'year':
          var yyyy = String(c.year);
          done = menu(el) ? choose(el, [yyyy, yyyy.slice(-2)]) : put(el, yearIn(el, yyyy));
          break;
        case 'csc': done = put(el, c.csc); break;
      }
      if (done) n++;
    });
    // A security code not kept is the one thing left to type: the
    // caret goes there.
    for (var i = 0; i < list.length; i++) {
      if (list[i].kind === 'csc' && !list[i].el.value) { try { list[i].el.focus(); } catch (e) {} break; }
    }
    return n;
  }

  // keep(el): a box left as it is, as a follow-up pass leaves one the
  // person typed in.
  function fillAddress(a, list, keep) {
    var n = 0, lines = String(a.street || '').split('\n'), words = String(a.name || '').trim().split(/\s+/);
    var parts = {};
    list.forEach(function (b) { parts[b.kind] = 1; });
    list.forEach(function (b) {
      var el = b.el, v = null;
      switch (b.kind) {
        case 'name': v = a.name; break;
        case 'given': v = words[0]; break;
        case 'family': v = words.slice(1).join(' '); break;
        case 'org': v = a.organization; break;
        case 'street': v = el.tagName === 'TEXTAREA' ? a.street : (parts.line2 ? lines[0] : lines.join(', ')); break;
        case 'line1': v = parts.line2 ? lines[0] : lines.join(', '); break;
        case 'line2': v = lines.slice(1).join(', '); break;
        case 'city': v = a.city; break;
        case 'region': v = menu(el) ? regions(a.region) : regionIn(el, a.region); break;
        case 'postal': v = a.postal; break;
        case 'country': v = menu(el) ? countries(a.country) : a.country; break;
        case 'tel': v = phoneIn(el, a.phone); break;
        case 'telCode': v = phone(a.phone).code; break;
        case 'telNational': v = phone(a.phone).national; break;
        case 'telArea': v = phone(a.phone).national.slice(0, 3); break;
        case 'telLocal': v = phone(a.phone).national.slice(3); break;
        case 'email': v = a.email; break;
      }
      if (keep && (keep(el) || (!menu(el) && v === el.value))) return;
      if (v && (menu(el) ? choose(el, v) : put(el, v))) n++;
    });
    return n;
  }

  // A form that shows the rest of an address only once its first line
  // is in (Stripe Checkout's billing details: City, State, ZIP come in
  // under the street) is filled again as its boxes come, for a moment:
  // each new empty box, and a first line still holding the whole street
  // it took before a second line was there for the flat. A box the
  // person typed in since is theirs.
  function follow(a, scope, first) {
    var ours = new Map(), seen = new Set();
    var list = function () { return boxes(scope).filter(function (b) { return !CARD[b.kind]; }); };
    var n = first();
    list().forEach(function (b) { seen.add(b.el); ours.set(b.el, b.el.value); });
    var until = Date.now() + 3000;
    (function again() {
      if (Date.now() > until) return;
      setTimeout(function () {
        var now = list();
        if (now.some(function (b) { return !seen.has(b.el); })) {
          var mine = function (el) { return !value(el).value || ours.get(el) === el.value; };
          var take = now.filter(function (b) { return mine(b.el); }).map(function (b) { return b.el; });
          fillAddress(a, now, function (el) { return take.indexOf(el) < 0; });
          now.forEach(function (b) { seen.add(b.el); if (take.indexOf(b.el) >= 0) ours.set(b.el, b.el.value); });
        }
        again();
      }, 200);
    })();
    return n;
  }

  // MARK: a whole form
  //
  // Every box a person fills in a form, not only an address's or a
  // card's: its words, its kind, its choices, whether it is empty, so
  // yab can say what it would put in each (FormPlan) and put it there.

  var TEXTY = ['text', 'email', 'tel', 'url', 'number', 'search', 'date', ''];
  function fillable(el) {
    if (!el || !el.tagName) return false;
    var tag = el.tagName.toLowerCase();
    if (tag !== 'input' && tag !== 'select' && tag !== 'textarea') return false;
    if (el.disabled || el.readOnly) return false;
    if (tag === 'input') {
      var t = (el.getAttribute('type') || 'text').toLowerCase();
      if (TEXTY.indexOf(t) < 0 && t !== 'radio' && t !== 'checkbox') return false;
      if (t === 'search') return false;
    }
    return true;
  }
  // A radio or a checkbox is often drawn by a label beside a box the
  // page hides: it counts when its label can be seen.
  function seeable(el) {
    if (shown(el)) return true;
    var t = (el.getAttribute('type') || '').toLowerCase();
    if (t !== 'radio' && t !== 'checkbox') return false;
    var l = el.labels && el.labels[0];
    return !!(l && shown(l));
  }
  function clean(t) { return String(t || '').replace(/\s+/g, ' ').trim(); }
  // The words that name a box, as a person reads them.
  function labelOf(el) {
    if (el.labels && el.labels.length) {
      var l = el.labels[0].cloneNode(true);
      [].forEach.call(l.querySelectorAll('input, select, textarea, option'), function (x) { x.remove(); });
      var w = clean(text(l));
      if (w) return w;
    }
    var by = el.getAttribute('aria-labelledby');
    if (by) {
      var said = by.split(/\s+/).map(function (id) { return clean(text(document.getElementById(id))); }).join(' ');
      if (said) return said;
    }
    if (el.getAttribute('aria-label')) return clean(el.getAttribute('aria-label'));
    // The words just before it, a few boxes up: a heading or a div
    // a page drew as its label.
    for (var up = el, n = 0; up && n < 4; up = up.parentElement, n++) {
      for (var sib = up.previousElementSibling; sib; sib = sib.previousElementSibling) {
        if (sib.querySelector && sib.querySelector('input, select, textarea')) break;
        var w2 = clean(text(sib));
        if (w2 && w2.length <= 200) return w2;
        if (w2) break;
      }
    }
    return clean(el.getAttribute('placeholder') || el.getAttribute('title') || '');
  }
  function groupLabel(radio) {
    var set = radio.closest && radio.closest('fieldset');
    if (set) { var lg = set.querySelector('legend'); if (lg) return clean(text(lg)); }
    var g = radio.closest && radio.closest('[role=radiogroup]');
    if (g) {
      var named = g.getAttribute('aria-label') || (g.getAttribute('aria-labelledby') && text(document.getElementById(g.getAttribute('aria-labelledby'))));
      if (named) return clean(named);
    }
    // The words before the group: up from the first radio until a box
    // holds another group's radios.
    for (var up = radio.parentElement, n = 0; up && n < 5; up = up.parentElement, n++) {
      if (up.querySelectorAll('input[type=radio][name="' + CSS.escape(radio.name) + '"]').length < 2) continue;
      for (var sib = up.previousElementSibling; sib; sib = sib.previousElementSibling) {
        var w = clean(text(sib));
        if (w && w.length <= 200) return w;
        if (w) break;
      }
    }
    return '';
  }
  // The form around a box: its <form>, or the nearest box holding three
  // boxes or more, for pages drawn without one.
  function formOf(el) {
    var f = el && (el.form || (el.closest && el.closest('form')));
    if (f) return f;
    for (var up = el && el.parentElement; up && up !== document.body; up = up.parentElement) {
      if (up.querySelectorAll('input, select, textarea').length >= 3) return up;
    }
    return document;
  }
  // A box a one-time code goes in: said so by the page, or one of a row
  // of four to eight one-character boxes (forms.js codeRow). The code's
  // own list hangs from it; it is never a form's box.
  function codeBox(el) {
    if (!el || (el.tagName || '').toLowerCase() !== 'input') return false;
    if ((el.getAttribute('autocomplete') || '').toLowerCase().indexOf('one-time-code') >= 0) return true;
    if (window.__yabForms && window.__yabForms.isCodeField) return window.__yabForms.isCodeField(el);
    // Frames may load the wallet before the forms script. Reject explicit
    // code labels there too, before type=tel can become a contact phone.
    var words = hint(el);
    if (!/card|cvc|cvv|postal|zip|coupon|promo|country|area/i.test(words) &&
        /verification.?code|verify.?code|authenticat|one.?time|[4-8][ -]?digit.?code|\botp\b|\btotp\b/i.test(words)) return true;
    if (el.maxLength !== 1) return false;
    for (var up = el.parentElement, n = 0; n < 3 && up; n++, up = up.parentElement) {
      var row = [].filter.call(up.querySelectorAll('input'), function (b) { return b.maxLength === 1 && shown(b); });
      if (row.length >= 4 && row.length <= 8) return true;
    }
    return false;
  }
  // Asked on every move of the caret and every scroll: worked out once
  // a second for the same box at most.
  var formyWas = { el: null, at: 0, yes: false };
  function formy(el) {
    if (!fillable(el) || !seeable(el)) return false;
    var t = (el.getAttribute('type') || '').toLowerCase();
    if (t === 'radio' || t === 'checkbox') return false;
    if (codeBox(el)) return false;
    var now = Date.now();
    if (formyWas.el === el && now - formyWas.at < 1000) return formyWas.yes;
    var yes = describe(formOf(el)).filter(function (d) { return d.type !== 'checkbox'; }).length >= 3;
    formyWas = { el: el, at: now, yes: yes };
    return yes;
  }
  var formEls = [], formBefore = [];
  function describe(scope) {
    var out = [], radios = {}, els = [];
    var all = (scope || document).querySelectorAll('input, select, textarea');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!fillable(el) || !seeable(el) || codeBox(el)) continue;
      var tag = el.tagName.toLowerCase(), type = tag === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : tag;
      if (type === 'radio') {
        var key = el.name || ('#' + i);
        var opt = clean(el.labels && el.labels[0] ? text(el.labels[0]) : el.value);
        if (radios[key]) { radios[key].options.push(opt); radios[key].els.push(el); if (el.checked) { radios[key].d.checked = true; radios[key].d.empty = false; } continue; }
        var d0 = { i: els.length, tag: 'input', type: 'radio', kind: '', label: groupLabel(el), name: el.name || '',
                   placeholder: '', auto: '', required: !!el.required, maxLength: 0, options: [opt], empty: !el.checked, checked: !!el.checked };
        radios[key] = { d: d0, options: d0.options, els: [el] };
        els.push(radios[key].els);
        out.push(d0);
        continue;
      }
      var d = {
        i: els.length, tag: tag, type: type === tag ? '' : type, kind: kind(el) || '', label: labelOf(el), name: el.name || el.id || '',
        placeholder: el.getAttribute('placeholder') || '', auto: el.getAttribute('autocomplete') || '',
        required: !!el.required || el.getAttribute('aria-required') === 'true', maxLength: el.maxLength > 0 ? el.maxLength : 0,
        options: tag === 'select' ? [].map.call(el.options, function (o) { return clean(o.text); }).filter(Boolean) : [],
        empty: type === 'checkbox' ? !el.checked : tag === 'select' ? !el.value || el.selectedIndex <= 0 : !clean(el.value),
        checked: type === 'checkbox' ? !!el.checked : false
      };
      if (tag === 'select' && d.options.length && /^(choose|select|pick|--|—|please)/i.test(d.options[0])) d.options.shift();
      els.push(el);
      out.push(d);
    }
    formEls = els;
    return out;
  }
  // What was in a box, to put back.
  function was(el) { return el.type === 'checkbox' || el.type === 'radio' ? { el: el, checked: el.checked } : { el: el, value: el.value }; }
  function tick(el, on) {
    if (!!el.checked === !!on) return false;
    el.click();
    if (!!el.checked !== !!on) {
      el.checked = !!on;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return true;
  }
  function raw(el, v) {
    var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) setter.set.call(el, v); else el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // MARK: where each value came from
  //
  // A dot inside the right edge of each box a fill put something in,
  // green for the Wallet, the Mac's accent for the profile and drafts, gray for
  // an answer given before, and with the pointer on the box, the words
  // over it: "Profile · LinkedIn". Drawn in a layer of its own over the
  // page, in a closed shadow root, positioned, so the page's layout and
  // styles are never touched, and no pointer ever lands on it: a box's
  // own clear button, date picker or arrow under it still takes the
  // click. A box typed in loses its dot; a sent form, or ⌘Z, all.
  var DOT = { green: '#34C759', accent: '-apple-system-control-accent', gray: '#8E8E93' };
  var marks = [], markRoot = null, markHost = null, marking = false, markTick = null;
  function markLayer() {
    if (markHost && markHost.isConnected) return markRoot;
    markHost = document.createElement('yab-marks');
    markHost.setAttribute('aria-hidden', 'true');
    markHost.style.cssText = 'all: initial; position: absolute; left: 0; top: 0; width: 0; height: 0; overflow: visible; z-index: 2147483647; pointer-events: none;';
    markRoot = markHost.attachShadow({ mode: 'closed' });
    var style = document.createElement('style');
    style.textContent =
      '.dot { position: absolute; width: 7px; height: 7px; pointer-events: none; }' +
      '.dot i { position: absolute; left: 0; top: 0; width: 7px; height: 7px; border-radius: 50%; box-shadow: 0 0 0 1px rgba(0,0,0,0.08); }' +
      '.tag { position: absolute; right: -3px; bottom: 13px; white-space: nowrap; font: 500 11px/1.3 -apple-system, system-ui, sans-serif;' +
      ' color: #fff; background: rgba(28,28,30,0.92); padding: 2px 6px; border-radius: 5px; opacity: 0; transition: opacity 0.12s; pointer-events: none; }' +
      '.dot.lit .tag { opacity: 1; }';
    markRoot.appendChild(style);
    (document.documentElement || document.body).appendChild(markHost);
    return markRoot;
  }
  function markPlace() {
    marking = false;
    marks = marks.filter(function (m) { if (m.el.isConnected) return true; m.dot.remove(); return false; });
    // The ten minutes over, or the form gone from the page (a page
    // that draws itself took it away): the guide ends, and the ring.
    if (guide && (Date.now() > guide.until || !guide.scope.isConnected)) guideStop();
    // Its button gone, another may stand for it.
    else if (ringOn && (!ringEl || !ringEl.isConnected)) ringCheck();
    ringPlace();
    fileRingPlace();
    if (!marks.length && !ringOn && !fileRingEl) { clearInterval(markTick); markTick = null; return; }
    var sx = window.scrollX, sy = window.scrollY;
    marks.forEach(function (m) {
      var r = m.el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) { m.dot.style.display = 'none'; return; }
      // Clear of a menu's arrow and of what a box draws at its end, a
      // date's picker, a search's clear button, a number's steps, a
      // list's arrow; a big box's dot at its top corner.
      var t = (m.el.getAttribute('type') || '').toLowerCase();
      var inset = m.el.tagName === 'SELECT' || m.el.getAttribute('list') || m.el.getAttribute('role') === 'combobox' ||
        ['date', 'time', 'datetime-local', 'month', 'week', 'search', 'number'].indexOf(t) >= 0 ? 28 : 9;
      var top = m.el.tagName === 'TEXTAREA' ? r.top + 10 : r.top + r.height / 2 - 3.5;
      m.dot.style.display = '';
      m.dot.style.left = (r.right + sx - inset - 7) + 'px';
      m.dot.style.top = (top + sy) + 'px';
    });
  }
  function markMoved() {
    if (marking || (!marks.length && !ringOn && !fileRingEl)) return;
    marking = true;
    // A page out of sight draws no frames: an agent's fill in a tab
    // behind still gets its dots placed.
    if (document.visibilityState === 'visible') requestAnimationFrame(markPlace); else setTimeout(markPlace, 0);
  }
  function mark(el, how) {
    if (!el || !how || !DOT[how.c]) return;
    unmark(el);
    var root = markLayer(), dot = document.createElement('div'), i = document.createElement('i'), tag = document.createElement('span');
    dot.className = 'dot';
    // Out of sight until placed, never a moment at the page's corner.
    dot.style.display = 'none';
    i.style.background = DOT[how.c];
    tag.className = 'tag';
    tag.textContent = how.w || '';
    dot.appendChild(i);
    if (how.w) dot.appendChild(tag);
    root.appendChild(dot);
    marks.push({ el: el, dot: dot });
    markMoved();
    // A page moves its boxes without scrolling too, a message shown
    // above one: looked at twice a second while any dot is up.
    if (!markTick) markTick = setInterval(markMoved, 500);
  }
  function unmark(el) {
    marks = marks.filter(function (m) { if (m.el !== el) return true; m.dot.remove(); return false; });
  }
  function unmarkAll() {
    marks.forEach(function (m) { m.dot.remove(); });
    marks = [];
    if (!ringOn && !fileRingEl) { clearInterval(markTick); markTick = null; }
  }

  // MARK: what a box would take
  //
  // The box the caret is in shows what Yab would put in it, pale, in the
  // accent, with a Tab key at its end: Tab takes it and goes on to the
  // next box, typing anything else puts it away, Escape puts it away for
  // the whole page. Only the box the caret is in, never a list over the
  // page, and only what yab is sure of (FormFill: your own boxes, on a
  // form about you). Drawn in the dots' layer; the page's own hint words
  // are made clear while it shows, by an attribute and one rule, and
  // come back as it goes.
  var hinted = new WeakMap(), ghostEl = null, ghostView = null, hintsOff = false, ghostCss = null, ghostTick = null;
  var TABKEY = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h14m-5-5 5 5-5 5M21 5v14"/></svg>';
  function ghostable(el) {
    if (!el || !el.tagName) return false;
    if (el.tagName === 'TEXTAREA') return true;
    if (el.tagName !== 'INPUT') return false;
    var t = (el.getAttribute('type') || 'text').toLowerCase();
    return ['text', 'email', 'url', 'tel', 'search', ''].indexOf(t) >= 0;
  }
  function ghostHide() {
    if (ghostTick) { clearInterval(ghostTick); ghostTick = null; }
    if (ghostView) { ghostView.remove(); ghostView = null; }
    if (ghostEl) {
      ghostEl.removeAttribute('data-yab-ghost');
      ghostEl = null;
      post({ kind: 'ghost', v: '' });
    }
  }
  function ghostCheck() {
    var el = active();
    var hint = !hintsOff && el && hinted.get(el);
    if (!hint || !ghostable(el) || clean(el.value) || el.disabled || el.readOnly) { ghostHide(); return; }
    if (ghostEl === el && ghostView) { ghostPlace(); return; }
    ghostHide();
    if (!ghostCss) {
      ghostCss = document.createElement('style');
      ghostCss.textContent = '[data-yab-ghost]::placeholder { color: transparent !important; }';
      (document.head || document.documentElement).appendChild(ghostCss);
    }
    ghostEl = el;
    el.setAttribute('data-yab-ghost', '');
    var root = markLayer();
    ghostView = document.createElement('div');
    var words = document.createElement('span'), key = document.createElement('span');
    var cs = getComputedStyle(el), area = el.tagName === 'TEXTAREA';
    ghostView.style.cssText = 'position: absolute; pointer-events: none; box-sizing: border-box; display: flex; gap: 6px;' +
      ' color: -apple-system-control-accent; align-items: ' + (area ? 'flex-start' : 'center') + ';';
    words.style.cssText = 'flex: 1; min-width: 0; opacity: 0.6; overflow: hidden;' +
      (area ? ' white-space: pre-wrap; overflow-wrap: anywhere;' : ' white-space: nowrap; text-overflow: ellipsis;');
    ['fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'letterSpacing', 'lineHeight', 'textAlign'].forEach(function (k) { words.style[k] = cs[k]; });
    words.textContent = hint.value;
    key.style.cssText = 'flex: none; display: inline-flex; align-items: center; justify-content: center; width: 17px; height: 17px;' +
      ' border-radius: 5px; background: color-mix(in srgb, currentColor 14%, transparent); opacity: 0.8;';
    key.innerHTML = TABKEY;
    key.firstChild.style.cssText = 'width: 12px; height: 12px; display: block;';
    ghostView.appendChild(words);
    ghostView.appendChild(key);
    root.appendChild(ghostView);
    ghostPlace();
    // A box the page takes away (a step swapped in) says no focusout, and
    // one the page moves says nothing: looked at twice a second.
    ghostTick = setInterval(ghostPlace, 500);
    post({ kind: 'ghost', v: hint.value });
  }
  function ghostPlace() {
    if (!ghostView || !ghostEl) return;
    if (!ghostEl.isConnected) { ghostHide(); return; }
    var r = ghostEl.getBoundingClientRect(), cs = getComputedStyle(ghostEl);
    var px = function (k) { return parseFloat(cs[k]) || 0; };
    var left = r.left + px('borderLeftWidth') + px('paddingLeft'), right = r.right - px('borderRightWidth') - Math.max(6, px('paddingRight') / 2);
    var area = ghostEl.tagName === 'TEXTAREA';
    var top = area ? r.top + px('borderTopWidth') + px('paddingTop') : r.top + px('borderTopWidth');
    var bottom = area ? r.bottom - px('borderBottomWidth') - px('paddingBottom') : r.bottom - px('borderBottomWidth');
    ghostView.style.left = (left + window.scrollX) + 'px';
    ghostView.style.top = (top + window.scrollY) + 'px';
    ghostView.style.width = Math.max(0, right - left) + 'px';
    ghostView.style.height = Math.max(0, bottom - top) + 'px';
  }
  function ghostTake(el) {
    var hint = hinted.get(el);
    if (!hint) return false;
    hinted.delete(el);
    ghostHide();
    if (!put(el, hint.value)) return false;
    mark(el, hint.dot);
    return true;
  }
  document.addEventListener('focusin', function () { setTimeout(ghostCheck, 0); }, true);
  document.addEventListener('focusout', function () { setTimeout(ghostCheck, 0); }, true);
  // Typed in: the box is the person's, and its hint goes for good.
  document.addEventListener('input', function (e) {
    if (!e.isTrusted || !e.target) return;
    if (clean(e.target.value)) hinted.delete(e.target);
    if (ghostEl) ghostCheck();
  }, true);
  // Before the guide's Tab: the hint is taken, and the key goes on as
  // the page would have it, to the next box.
  document.addEventListener('keydown', function (e) {
    if (!ghostEl || !e.isTrusted || e.defaultPrevented || e.altKey || e.metaKey || e.ctrlKey) return;
    if (active() !== ghostEl) { ghostHide(); return; }
    if (e.key === 'Tab' && !e.shiftKey) { ghostTake(ghostEl); return; }
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      hintsOff = true;
      hinted = new WeakMap();
      ghostHide();
      post({ kind: 'formNo' });
    }
  }, true);
  window.addEventListener('scroll', function () { if (ghostView) requestAnimationFrame(ghostPlace); }, true);
  window.addEventListener('resize', function () { if (ghostView) requestAnimationFrame(ghostPlace); });

  // MARK: what is left to you
  //
  // After a fill, Tab goes only through the boxes still empty, in the
  // page's order, then to the button that sends the form; ⇧Tab back.
  // Once every box the form needs has something in it, that button
  // gets a ring, the accent's, 2 points out from it, the way a focused
  // button looks: the next press is yours. Nothing is ever pressed.
  var guide = null, ringOn = false, ringEl = null;
  // What a box's words say of it, read once a fill: a label is copied
  // to be read, which on every keystroke of a big form was felt.
  var starred = new WeakMap();
  function starOf(el, words) {
    if (!starred.has(el)) starred.set(el, /\*\s*$|\(required\)/i.test(words()));
    return starred.get(el);
  }
  function needed(el) {
    if (el.required || el.getAttribute('aria-required') === 'true') return true;
    return starOf(el, function () { return labelOf(el); });
  }
  // The boxes of the form, a radio group as one, each still to answer or not.
  function gapsOf(scope) {
    var out = [], seen = {};
    [].forEach.call(scope.querySelectorAll('input, select, textarea'), function (el) {
      if (!fillable(el) || !seeable(el)) return;
      var t = (el.getAttribute('type') || '').toLowerCase();
      if (t === 'radio') {
        var key = el.name || Math.random();
        if (seen[key]) return;
        var group = el.name ? [].filter.call(scope.querySelectorAll('input[type=radio]'), function (r) { return r.name === el.name; }) : [el];
        seen[key] = 1;
        var need = group.some(function (r) { return r.required; }) || starOf(el, function () { return groupLabel(el); });
        out.push({ el: el, open: !group.some(function (r) { return r.checked; }), need: need });
        return;
      }
      if (t === 'checkbox') {
        // Only a box the form can't go without: the page's own mail ticks are no gap.
        if (needed(el)) out.push({ el: el, open: !el.checked, need: true });
        return;
      }
      var open = el.tagName === 'SELECT' ? !el.value || el.selectedIndex <= 0 : !clean(el.value);
      out.push({ el: el, open: open, need: needed(el) });
    });
    return out;
  }
  // The button that sends it: a submit button, one that says so, or the last one.
  // A button's words, and the words of one that sends nothing: it
  // closes, goes back, skips or edits. "Next" and "Continue" send a
  // step of a form in steps, not the form.
  var NOT_SEND = /cancel|close|dismiss|\bback\b|go back|previous|\bprev\b|skip|remove|delete|clear|reset|\bedit\b|add (another|more)|upload|attach|browse|show|hide|not now|no thanks/i;
  var STEP = /^(next|continue|proceed|next step|save (and|&) continue)\b/i;
  function wordsOf(b) { return clean(text(b) || b.value || b.getAttribute('aria-label') || ''); }
  function sender(scope) {
    var all = [].filter.call(scope.querySelectorAll('button, input[type=submit], input[type=image], [role=button]'), function (b) {
      return shown(b) && (b.getAttribute('type') || '').toLowerCase() !== 'reset' && !NOT_SEND.test(wordsOf(b));
    });
    var typed = all.filter(function (b) {
      var t = (b.getAttribute('type') || '').toLowerCase();
      return t === 'submit' || t === 'image' || (b.tagName === 'BUTTON' && !t && !!b.form);
    });
    if (typed.length) return typed[typed.length - 1];
    var said = all.filter(function (b) { return /submit|send|apply|register|join|sign ?up|request|book|reserve|continue|next|confirm|save|done|rsvp/i.test(clean(text(b) || b.value)); });
    return said.length ? said[said.length - 1] : all[all.length - 1] || null;
  }
  function guideStart(scope, accent) {
    guideStop();
    if (!scope) return;
    guide = { scope: scope, accent: accent || '#007AFF', until: Date.now() + 600000 };
    starred = new WeakMap();
    ringCheck();
  }
  function guideStop() {
    guide = null;
    clearTimeout(ringSoon);
    ringCheck();
  }
  // A keystroke asks again, but once for a burst of them: a look is a
  // walk over every box of the form.
  var ringSoon = null;
  function ringLater() {
    clearTimeout(ringSoon);
    ringSoon = setTimeout(ringCheck, 150);
  }
  function ringCheck() {
    var on = false;
    if (guide && Date.now() > guide.until) guide = null;
    if (guide && guide.scope.isConnected) {
      on = oneLook(function () {
        var b = sender(guide.scope);
        ringEl = b;
        return !!b && !b.disabled && !gapsOf(guide.scope).some(function (g) { return g.need && g.open; });
      });
      if (!on) ringEl = null;
    } else {
      guide = null;
      ringEl = null;
    }
    if (on === ringOn) { if (on) markMoved(); return; }
    ringOn = on;
    var root = markLayer(), ring = root.querySelector('.ring');
    if (!on) {
      if (ring) ring.remove();
      if (!marks.length) { clearInterval(markTick); markTick = null; }
      return;
    }
    if (!ring) {
      ring = document.createElement('div');
      ring.className = 'ring';
      ring.style.cssText = 'position: absolute; pointer-events: none; box-sizing: border-box;';
      root.appendChild(ring);
    }
    ring.style.boxShadow = '0 0 0 2px ' + guide.accent;
    if (!markTick) markTick = setInterval(markMoved, 500);
    markMoved();
  }
  function ringPlace() {
    var ring = markRoot && markRoot.querySelector('.ring');
    if (!ring) return;
    if (!ringOn || !ringEl || !ringEl.isConnected) { ring.style.display = 'none'; return; }
    var r = ringEl.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) { ring.style.display = 'none'; return; }
    var radius = parseFloat(getComputedStyle(ringEl).borderTopLeftRadius) || 0;
    // 2 points out from the button, then the ring's 2.
    ring.style.display = '';
    ring.style.left = (r.left + window.scrollX - 2) + 'px';
    ring.style.top = (r.top + window.scrollY - 2) + 'px';
    ring.style.width = (r.width + 4) + 'px';
    ring.style.height = (r.height + 4) + 'px';
    ring.style.borderRadius = (radius + 2) + 'px';
  }
  document.addEventListener('input', function () { if (guide) ringLater(); }, true);
  document.addEventListener('change', function () { if (guide) ringLater(); }, true);
  document.addEventListener('keydown', function (e) {
    if (!guide || e.key !== 'Tab' || e.altKey || e.metaKey || e.ctrlKey || !e.isTrusted || e.defaultPrevented) return;
    if (Date.now() > guide.until || !guide.scope.isConnected) { guideStop(); return; }
    var here = active();
    if (!here || !guide.scope.contains(here)) return;
    var back = e.shiftKey;
    var gaps = [], b = null;
    oneLook(function () {
      gaps = gapsOf(guide.scope).filter(function (g) { return g.open || g.el === here || (here.type === 'radio' && g.el.name === here.name && here.name); });
      b = sender(guide.scope);
    });
    var stops = gaps.map(function (g) { return g.el; });
    if (b && !b.disabled) stops.push(b);
    // Where the caret is among them, by the page's order.
    var next = null;
    var ordered = function (a, z) { return a.compareDocumentPosition(z) & Node.DOCUMENT_POSITION_FOLLOWING; };
    for (var i = 0; i < stops.length; i++) {
      var s = back ? stops[stops.length - 1 - i] : stops[i];
      if (s === here || (here.type === 'radio' && s.type === 'radio' && s.name && s.name === here.name)) continue;
      if (back ? ordered(s, here) : ordered(here, s)) { next = s; break; }
    }
    if (!next) return;
    e.preventDefault();
    e.stopPropagation();
    try { next.focus({ preventScroll: true }); next.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); } catch (x) {}
  }, true);
  window.addEventListener('scroll', markMoved, true);
  window.addEventListener('resize', markMoved);
  // The pointer on a box, or its label, says where its value came from.
  function markFor(t) {
    if (!t || !marks.length) return null;
    var el = t.tagName === 'LABEL' && t.control ? t.control : t;
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i];
      if (m.el === el || (el.type === 'radio' && el.name && m.el.type === 'radio' && m.el.name === el.name)) return m;
    }
    return null;
  }
  document.addEventListener('mouseover', function (e) { var m = markFor(e.target); if (m) m.dot.classList.add('lit'); }, true);
  document.addEventListener('mouseout', function (e) { var m = markFor(e.target); if (m) m.dot.classList.remove('lit'); }, true);
  document.addEventListener('input', function (e) {
    if (!e.isTrusted || !marks.length) return;
    var el = e.target;
    // A radio's dot sits on the group's first box.
    if (el && el.type === 'radio' && el.name) {
      [].forEach.call(document.getElementsByName(el.name), unmark);
    } else {
      unmark(el);
    }
    markMoved();
  }, true);

  // MARK: a file box
  //
  // Which file box asked for a file, and what the person pressed to
  // ask: a page's "Upload resume" button calls the hidden box's
  // click(), and the list hangs from the button, not the box nobody
  // sees. A box's click, even a script's, passes through here first.
  var pressed = null, fileAsked = null, fileAway = null, fileRingEl = null, fileRing = null;
  function fileRingPlace() {
    if (!fileRing || !fileRingEl || !fileRingEl.isConnected) { if (fileRing) fileRing.style.display = 'none'; return; }
    var r = fileRingEl.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) { fileRing.style.display = 'none'; return; }
    fileRing.style.display = '';
    fileRing.style.left = (r.left + window.scrollX - 2) + 'px';
    fileRing.style.top = (r.top + window.scrollY - 2) + 'px';
    fileRing.style.width = (r.width + 4) + 'px';
    fileRing.style.height = (r.height + 4) + 'px';
    fileRing.style.borderRadius = ((parseFloat(getComputedStyle(fileRingEl).borderTopLeftRadius) || 0) + 2) + 'px';
  }
  function fileDone() {
    fileRingEl = null;
    if (fileRing) { fileRing.remove(); fileRing = null; }
    if (fileAway) { document.removeEventListener('mousedown', fileAway, true); fileAway = null; }
    if (!marks.length && !ringOn) { clearInterval(markTick); markTick = null; }
  }
  document.addEventListener('click', function (e) {
    if (e.isTrusted) pressed = { el: e.target, t: Date.now() };
    var t = e.target;
    if (t && t.tagName === 'INPUT' && (t.type || '').toLowerCase() === 'file') {
      var near = e.isTrusted ? t : pressed && Date.now() - pressed.t < 1500 ? pressed.el : t;
      fileAsked = { el: t, near: near, t: Date.now() };
    }
  }, true);
  function fileSpot() {
    var now = Date.now(), box = null, near = null;
    if (fileAsked && now - fileAsked.t < 3000) { box = fileAsked.el; near = fileAsked.near; }
    else if (pressed && now - pressed.t < 3000) { near = pressed.el; }
    var at = [near, box, box && box.labels && box.labels[0]].filter(function (x) { return x && x.isConnected && shown(x); })[0];
    // A press on words inside a button: the button.
    if (at && at.closest) at = at.closest('button, label, [role=button], a') || at;
    // Upload menus (X, for example) disappear as they click a hidden
    // file input. Its metadata still identifies the request; only the
    // optional highlight needs a visible element.
    if (!at && !box) return null;
    var r = at ? at.getBoundingClientRect() : null;
    fileDone();
    if (at) {
      fileRingEl = at;
      fileRing = document.createElement('div');
      fileRing.style.cssText = 'position: absolute; pointer-events: none; box-sizing: border-box;';
      fileRing.style.boxShadow = '0 0 0 2px ' + (guide ? guide.accent : '#007AFF');
      markLayer().appendChild(fileRing);
      fileRingPlace();
      if (!markTick) markTick = setInterval(markMoved, 500);
    }
    // A press on the page, not on the list, puts the list away.
    if (!fileAway) {
      fileAway = function (e) {
        if (!e.isTrusted) return;
        fileDone();
        post({ kind: 'fileAway' });
      };
      document.addEventListener('mousedown', fileAway, true);
    }
    return {
      rect: r ? { x: r.left, y: r.top, w: r.width, h: r.height } : null, accept: box ? box.getAttribute('accept') || '' : '',
      label: clean(box && labelOf(box) || text(at) || at && at.getAttribute('aria-label') || '') || 'File',
      multiple: !!(box && box.multiple),
      dark: yabGround(at), href: location.href,
      vw: document.documentElement.clientWidth, vh: document.documentElement.clientHeight
    };
  }

  window.__yabForm = {
    // Read-only UI state for native diagnostics: a focus reply can precede
    // the isolated ghost relay. Never change hints to satisfy an observer.
    ghostState: function () {
      var el = active();
      return { field: el ? el.name || el.id || '' : '',
        value: el && ghostEl === el && ghostView ? ghostView.firstChild.textContent : '' };
    },
    // A sign-in Yab just filled: its name and password boxes wear the
    // green dot, with where it came from over it.
    markSignIn: function (source) {
      var at = active();
      var scope = (at && (at.form || (at.closest && at.closest('form')))) || document;
      var boxes = scope.querySelectorAll('input');
      for (var i = 0; i < boxes.length; i++) {
        var b = boxes[i], t = (b.type || 'text').toLowerCase();
        if (['text', 'email', 'tel', 'password'].indexOf(t) < 0 || !b.value) continue;
        var r = b.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) mark(b, { c: 'green', w: source || '' });
      }
    },
    fileSpot: fileSpot,
    fileDone: fileDone,
    // The form the caret is in, or the page's largest.
    describe: function () {
      var here = active();
      var scope = fillable(here) ? formOf(here) : null;
      if (!scope) {
        var best = null, most = 0;
        [].forEach.call(document.querySelectorAll('form'), function (f) {
          var n = f.querySelectorAll('input, select, textarea').length;
          if (n > most) { most = n; best = f; }
        });
        scope = best || document;
      }
      return describe(scope);
    },
    // The form the caret is in, and what it says it is for: the page's
    // title, its heading, the heading over the form and the button that
    // sends it, so a form about a project posted or a friend invited is
    // told from one about you (FormRules.notYours).
    read: function () {
      var fields = window.__yabForm.describe();
      var here = active(), scope = fillable(here) ? formOf(here) : null, words = [document.title];
      var h1 = document.querySelector('h1');
      if (h1) words.push(text(h1));
      if (scope && scope !== document) {
        var head = scope.querySelector('h1, h2, h3, legend');
        for (var up = scope, n = 0; !head && up && n < 4; up = up.parentElement, n++) {
          for (var sib = up.previousElementSibling, k = 0; sib && k < 3; sib = sib.previousElementSibling, k++) {
            if (/^H[1-4]$/.test(sib.tagName)) { head = sib; break; }
            var inner = sib.querySelector && sib.querySelector('h1, h2, h3');
            if (inner) { head = inner; break; }
          }
        }
        if (head) words.push(text(head));
        var b = sender(scope);
        if (b) words.push(wordsOf(b));
      }
      return { fields: fields, about: clean(words.join(' · ')).slice(0, 400) };
    },
    // What each box would take, shown in the box the caret is in:
    // [{i, label, value, dot}], found as fill finds them.
    hints: function (steps) {
      if (hintsOff) return 0;
      var list = window.__yabForm.describe(), n = 0;
      hinted = new WeakMap();
      steps.forEach(function (s) {
        var d = list[s.i] && list[s.i].label === s.label ? list[s.i] : list.filter(function (x) { return x.label === s.label; })[0];
        var el = d && formEls[d.i];
        if (!el || Array.isArray(el) || !ghostable(el) || clean(el.value)) return;
        hinted.set(el, { value: s.value, dot: s.dot });
        n++;
      });
      ghostCheck();
      return n;
    },
    // One box's, when its draft is written after the rest.
    hintOne: function (i, label, v, dot) {
      if (hintsOff) return false;
      var list = window.__yabForm.describe();
      var d = list[i] && list[i].label === label ? list[i] : list.filter(function (x) { return x.label === label; })[0];
      var el = d && formEls[d.i];
      if (!el || Array.isArray(el) || !ghostable(el) || clean(el.value)) return false;
      hinted.set(el, { value: v, dot: dot });
      ghostCheck();
      return true;
    },
    // Values into boxes by their place in the last description:
    // [{i, value}] or [{i, untick: true}]. Each box's own events fire,
    // as typing would. What was there before is kept for undo.
    // Values into boxes: [{i, label, value}] or [{i, label, untick}],
    // each found again by its place and its words, since the page may
    // have moved on since it was described; and the kept address into
    // its boxes, when there is one. Each box's own events fire, as
    // typing would. What was there before is kept for undo.
    fill: function (steps, address, marked, accent) {
      ghostHide();
      hinted = new WeakMap();
      var list = window.__yabForm.describe(), n = 0;
      recording = [];
      unmarkAll();
      if (address) {
        var here = active(), scope = fillable(here) ? formOf(here) : document;
        var parts = boxes(scope).filter(function (b) { return !CARD[b.kind]; });
        if (parts.length >= 3) n += follow(address, scope, function () { return fillAddress(address, parts); });
        // Every box the address went into, by what it held before.
        recording.forEach(function (b) { if (marked && marked.c) mark(b.el, marked); });
      }
      steps.forEach(function (s) {
        var d = list[s.i] && list[s.i].label === s.label ? list[s.i]
          : list.filter(function (x) { return x.label === s.label && x.type === (s.type || x.type); })[0];
        var el = d && formEls[d.i];
        if (!el) return;
        if (Array.isArray(el)) {
          // A radio group: the choice whose words are the value.
          var want = clean(s.value).toLowerCase();
          for (var k = 0; k < el.length; k++) {
            var words = clean(el[k].labels && el[k].labels[0] ? text(el[k].labels[0]) : el[k].value).toLowerCase();
            if (words === want || el[k].value.toLowerCase() === want) {
              el.forEach(function (r) { recording.push(was(r)); });
              if (tick(el[k], true)) { glow(el[k].labels && el[k].labels[0] || el[k]); n++; }
              break;
            }
          }
          return;
        }
        if (s.untick) { recording.push(was(el)); if (tick(el, false)) n++; return; }
        if (el.tagName !== 'SELECT' && clean(el.value)) return;
        if (el.tagName === 'SELECT' ? choose(el, [s.value]) : put(el, s.value)) { n++; mark(el, s.dot); }
      });
      formBefore = recording;
      recording = null;
      taken = false;
      var at = active();
      guideStart(fillable(at) ? formOf(at) : (formEls[0] ? formOf(Array.isArray(formEls[0]) ? formEls[0][0] : formEls[0]) : null), accent);
      return picks(n);
    },
    // One box, when its draft arrives after the rest.
    fillOne: function (i, label, v, dot) {
      var list = window.__yabForm.describe();
      var d = list[i] && list[i].label === label ? list[i] : list.filter(function (x) { return x.label === label; })[0];
      var el = d && formEls[d.i];
      if (!el || Array.isArray(el) || clean(el.value)) return false;
      formBefore.push(was(el));
      if (!put(el, v)) return false;
      mark(el, dot);
      return true;
    },
    // Every box back as it was before the fill.
    undo: function () {
      var n = 0;
      unmarkAll();
      guideStop();
      formBefore.slice().reverse().forEach(function (b) {
        if ('checked' in b) { if (b.el.checked !== b.checked) { tick(b.el, b.checked); n++; } }
        else if (b.el.value !== b.value) { raw(b.el, b.value); n++; }
      });
      formBefore = [];
      return n;
    },
    // The caret into a box left for the person.
    focus: function (i, label) {
      var list = window.__yabForm.describe();
      var d = list[i] && list[i].label === label ? list[i] : list.filter(function (x) { return x.label === label; })[0];
      var el = d && formEls[d.i];
      if (Array.isArray(el)) el = el[0];
      if (!el) return false;
      try { el.focus(); el.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) {}
      return true;
    },
    // What a draft may lean on: the page's title, its heading, its
    // description, and the words around the form.
    context: function () {
      var meta = document.querySelector('meta[name=description], meta[property="og:description"]');
      var main = document.querySelector('main, article, [role=main]') || document.body;
      return {
        title: document.title, url: location.href,
        heading: clean(text(document.querySelector('h1'))).slice(0, 200),
        description: clean(meta && meta.getAttribute('content')).slice(0, 500),
        text: clean(text(main)).slice(0, 2500)
      };
    },
    // How many of these answers a box a person can see still holds: a
    // form that went through has left the page, or been emptied.
    holds: function (values) {
      var want = {}, n = 0;
      values.forEach(function (v) { want[clean(v)] = 1; });
      var all = document.querySelectorAll('input, select, textarea');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (!fillable(el) || !seeable(el)) continue;
        var t = (el.getAttribute('type') || '').toLowerCase(), v = '';
        if (t === 'checkbox') continue;
        if (t === 'radio') { if (!el.checked) continue; v = el.labels && el.labels[0] ? text(el.labels[0]) : el.value; }
        else if (el.tagName === 'SELECT') v = el.selectedIndex >= 0 && el.options[el.selectedIndex] ? el.options[el.selectedIndex].text : '';
        else v = el.value;
        if (want[clean(v)]) n++;
      }
      return n;
    }
  };

  // Typing after a fill: the fill is the person's now, and ⌘Z is the
  // page's again.
  var taken = true;
  document.addEventListener('input', function (e) {
    if (!e.isTrusted || taken) return;
    taken = true;
    formBefore = [];
    post({ kind: 'formTaken' });
  }, true);

  // Sent: what a person answered, question by question, for the next
  // form that asks the same (FormAnswers). Only a person's own press.
  // A form in steps: each step's answers, kept until the last step is
  // sent, and asked about only then; ten minutes at most.
  var stepped = null;
  function answered(el, step) {
    var scope = formOf(el && el.form ? el.form : el);
    if (!scope || scope === document) {
      var here = active();
      scope = fillable(here) ? formOf(here) : null;
    }
    if (!scope) return;
    var list = describe(scope), els = formEls, out = [];
    // A form, not a comment box or a chat's line: three boxes at least.
    if (list.filter(function (d) { return d.type !== 'checkbox'; }).length < 3) return;
    list.forEach(function (d) {
      if (d.type === 'checkbox' || !d.label || CARD[d.kind]) return;
      var el = els[d.i], v = '';
      if (Array.isArray(el)) {
        for (var k = 0; k < el.length; k++) if (el[k].checked) v = d.options[k];
      } else if (el.tagName === 'SELECT') {
        v = el.selectedIndex > 0 || (el.value && el.options[el.selectedIndex]) ? clean(el.options[el.selectedIndex].text) : '';
      } else {
        v = el.value;
      }
      if (clean(v)) out.push({ label: d.label, value: String(v).slice(0, 4000), kind: d.kind, type: d.type, tag: d.tag, auto: d.auto, name: d.name, placeholder: d.placeholder });
    });
    if (stepped && Date.now() - stepped.at > 600000) stepped = null;
    var before = stepped ? stepped.out.filter(function (o) { return !out.some(function (x) { return x.label === o.label; }); }) : [];
    out = before.concat(out);
    if (step) { stepped = { at: Date.now(), out: out }; return; }
    stepped = null;
    if (out.length) post({ kind: 'answers', fields: out });
  }
  // Whether a press sends its form, a step of it, or nothing: a submit
  // button, or the one that reads as sending (sender), never one that
  // cancels, closes or goes back.
  function sends(b, scope) {
    if (!b || NOT_SEND.test(wordsOf(b))) return false;
    var t = (b.getAttribute('type') || '').toLowerCase();
    if (t === 'reset' || t === 'button') return scope !== document && b === sender(scope);
    if (t === 'submit' || t === 'image' || (b.tagName === 'BUTTON' && !t && !!b.form)) return true;
    return scope !== document && b === sender(scope);
  }
  var lastSend = 0;
  // Sent, or pressed to send: the dots have said what they had to.
  document.addEventListener('submit', function (e) { if (e.isTrusted) { unmarkAll(); guideStop(); } }, true);
  // Return in a box, or a press a click didn't already count.
  document.addEventListener('submit', function (e) {
    if (!e.isTrusted || Date.now() - lastSend < 500) return;
    var b = e.submitter;
    if (b && !sends(b, e.target)) return;
    answered(e.target, !!b && STEP.test(wordsOf(b)));
  }, true);
  document.addEventListener('click', function (e) {
    if (!e.isTrusted) return;
    var b = e.target && e.target.closest && e.target.closest('button, input[type="submit"], input[type="image"], [role="button"]');
    if (!b) return;
    // A button that sends its form: its form, or the boxes around it.
    var scope = b.form || formOf(b);
    if (scope !== document && sends(b, scope)) {
      lastSend = Date.now();
      answered(b.form || b, STEP.test(wordsOf(b)));
    }
    // The button that sends it, pressed: the dots and the ring have
    // said what they had to.
    if (guide && b === sender(guide.scope)) { unmarkAll(); guideStop(); }
  }, true);

  window.__yabWallet = {
    // Fills this document's boxes with a card, or an address. An
    // address goes only into the form the caret is in, when it is in
    // one: a page with a billing and a shipping form gets it once.
    fill: function (data, what) {
      var list = boxes(document);
      // A number into the phone box the caret is in, or the page's one
      // phone box when the pick took the caret away.
      if (what === 'phone') {
        var at = active(), tels = list.filter(function (b) { return b.kind === 'tel' || b.kind === 'telNational'; });
        var box = tels.filter(function (b) { return b.el === at; })[0] || (tels.length === 1 ? tels[0] : null);
        if (!box) return 0;
        return put(box.el, box.kind === 'telNational' ? phone(data.phone).national : phoneIn(box.el, data.phone)) ? 1 : 0;
      }
      if (what === 'card') {
        var n = fillCard(data, list.filter(function (b) { return CARD[b.kind]; }));
        // A billing ZIP or country on its own beside the card, as
        // Stripe asks, takes the kept address's: not part of an
        // address form, which the address's own pick fills.
        list.forEach(function (b) {
          if ((b.kind !== 'postal' && b.kind !== 'country') || value(b.el).value || addressy(scopeOf(b.el))) return;
          var v = b.kind === 'postal' ? data.postal : data.country;
          if (v && (menu(b.el) ? choose(b.el, countries(v)) : put(b.el, v))) n++;
        });
        return picks(n);
      }
      var here = active();
      var scope = kind(here) && !CARD[kind(here)] ? scopeOf(here) : null;
      if (scope) list = boxes(scope);
      list = list.filter(function (b) { return !CARD[b.kind]; });
      if (list.length < 3) return 0;
      return picks(follow(data, scope || document, function () { return fillAddress(data, list); }));
    },
    // Whether something sent is still sitting in its boxes: asked a
    // moment after it was sent, to tell a payment that went through
    // from one the page refused.
    present: function () {
      return boxes(document).some(function (b) {
        return (CARD[b.kind] || PLACE[b.kind]) && b.kind !== 'csc' && value(b.el).value;
      });
    },
    // Where a frame's content sits in this page, found by its address
    // and its size: a list hangs from a box inside it.
    frameAt: function (href, w, h) {
      var bare = String(href || '').split('#')[0], best = null;
      (function look(doc, dx, dy) {
        var frames = doc.querySelectorAll('iframe, frame');
        for (var i = 0; i < frames.length; i++) {
          var f = frames[i], r = f.getBoundingClientRect(), s = getComputedStyle(f);
          var x = dx + r.left + f.clientLeft + (parseFloat(s.paddingLeft) || 0);
          var y = dy + r.top + f.clientTop + (parseFloat(s.paddingTop) || 0);
          var at = '';
          try { at = f.contentWindow.location.href; } catch (e) { at = f.src || ''; }
          var same = at.split('#')[0] === bare;
          var fits = Math.abs(f.clientWidth - w) <= 2 && Math.abs(f.clientHeight - h) <= 2;
          if (same && fits) { best = { x: x, y: y, el: f }; return true; }
          if ((same || fits) && !best) best = { x: x, y: y, el: f };
          try { if (f.contentDocument && look(f.contentDocument, x, y)) return true; } catch (e) {}
        }
        return false;
      })(document, 0, 0);
      // The frame's own ground is often none: the page's round it, then.
      return best && { x: best.x, y: best.y, dark: yabGround(best.el) };
    }
  };
  caret();
})();
