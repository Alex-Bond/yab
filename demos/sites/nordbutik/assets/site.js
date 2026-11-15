/* Nordbutik: the bag in localStorage, the product page, the bag page and
   the checkout. Everything else is written by the server. */
(function () {
  'use strict';
  var NB = window.NB || { products: {}, freeOver: 1000, delivery: { postnord: 59, budbee: 99 } };
  var KEY = 'nordbutik.bag';
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  // ---------------------------------------------------------------- the bag
  function valid(l) { return l && NB.products[l.slug] && NB.products[l.slug].colors[l.color] && l.qty > 0; }
  function load() {
    try {
      var v = JSON.parse(localStorage.getItem(KEY) || '[]');
      return Array.isArray(v) ? v.filter(valid) : [];
    } catch (e) { return []; }
  }
  function save(lines) {
    try { localStorage.setItem(KEY, JSON.stringify(lines)); } catch (e) {}
    paintCount();
  }
  function count(lines) { return lines.reduce(function (n, l) { return n + l.qty; }, 0); }
  function subtotal(lines) { return lines.reduce(function (n, l) { return n + NB.products[l.slug].price * l.qty; }, 0); }
  function group(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' '); }
  function kr(n) { return group(Math.round(n)) + ' kr'; }
  function kr2(x) { var s = x.toFixed(2).split('.'); return group(s[0]) + ',' + s[1] + ' kr'; }
  function media(slug, color, view) {
    if (view === 'dims') return '/media/' + slug + '-dims.svg';
    return '/media/' + slug + '-' + color + (view === 'detail' ? '-detail' : '') + '.svg';
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function add(slug, color, qty) {
    var lines = load(), hit = null;
    lines.forEach(function (l) { if (l.slug === slug && l.color === color) hit = l; });
    if (hit) hit.qty = Math.min(20, hit.qty + qty); else lines.push({ slug: slug, color: color, qty: qty });
    save(lines);
    return lines;
  }
  function paintCount(bump) {
    var n = count(load());
    $$('[data-bag-count]').forEach(function (el) {
      el.textContent = n; el.hidden = !n;
      if (bump) { el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump'); }
    });
    $$('.bag-link').forEach(function (a) {
      if (a.closest('.co-header') && !n) return;
      a.setAttribute('aria-label', n ? 'Bag, ' + n + (n === 1 ? ' item' : ' items') : 'Bag');
    });
  }
  // A link can carry a bag: ?bag=glass-carafe:amber:1,fjord-linen-throw:sand:1
  // puts exactly that in it, ?add=… adds to what is there, ?bag=empty empties it.
  (function () {
    var q = new URLSearchParams(location.search), set = q.get('bag'), more = q.get('add');
    if (set === null && more === null) return;
    var lines = set !== null ? [] : load();
    (set || more || '').split(',').forEach(function (part) {
      var bits = part.split(':'), slug = bits[0], p = NB.products[slug];
      if (!p) return;
      var color = p.colors[bits[1]] ? bits[1] : Object.keys(p.colors)[0];
      var qty = Math.max(1, Math.min(20, parseInt(bits[2], 10) || 1));
      var hit = null;
      lines.forEach(function (l) { if (l.slug === slug && l.color === color) hit = l; });
      if (hit) hit.qty = Math.min(20, hit.qty + qty); else lines.push({ slug: slug, color: color, qty: qty });
    });
    try { localStorage.setItem(KEY, JSON.stringify(lines)); } catch (e) {}
    q.delete('bag'); q.delete('add');
    var rest = q.toString();
    history.replaceState(null, '', location.pathname + (rest ? '?' + rest : '') + location.hash);
  })();
  paintCount();

  // ---------------------------------------------------------------- the product page
  var pdp = $('[data-product]');
  if (pdp) {
    var slug = pdp.getAttribute('data-product');
    var product = NB.products[slug];
    var main = $('[data-main]', pdp);
    var view = 'hero';
    var color = function () { var c = $('input[name="color"]:checked', pdp); return c ? c.value : Object.keys(product.colors)[0]; };
    var paint = function () {
      var c = color();
      main.src = media(slug, c, view);
      main.alt = view === 'dims' ? 'Measured drawing of the ' + product.name : product.name + ' in ' + product.colors[c];
      $$('.thumb', pdp).forEach(function (t) {
        var v = t.getAttribute('data-view');
        $('img', t).src = media(slug, c, v);
        t.classList.toggle('is-on', v === view);
        t.setAttribute('aria-pressed', v === view ? 'true' : 'false');
      });
      var name = $('[data-color-name]', pdp);
      if (name) name.textContent = product.colors[c];
    };
    // the other colors' pictures, ready before they are asked for
    Object.keys(product.colors).forEach(function (c) { new Image().src = media(slug, c, 'hero'); });
    $$('input[name="color"]', pdp).forEach(function (r) { r.addEventListener('change', function () { if (view === 'dims') view = 'hero'; paint(); }); });
    $$('.thumb', pdp).forEach(function (t) { t.addEventListener('click', function () { view = t.getAttribute('data-view'); paint(); }); });
    var qty = $('#qty', pdp);
    $$('[data-qty]', pdp).forEach(function (b) {
      b.addEventListener('click', function () {
        var v = Math.max(1, Math.min(10, (parseInt(qty.value, 10) || 1) + parseInt(b.getAttribute('data-qty'), 10)));
        qty.value = v;
      });
    });
    $('[data-add]', pdp).addEventListener('submit', function (e) {
      e.preventDefault();
      var q = Math.max(1, Math.min(10, parseInt(qty.value, 10) || 1));
      var c = color();
      var lines = add(slug, c, q);
      paintCount(true);
      openDrawer(slug, c, q, lines);
    });
  }

  // ---------------------------------------------------------------- the drawer
  var drawer = $('[data-drawer]'), scrim = $('[data-drawer-scrim]'), drawerTimer = null;
  function openDrawer(slug, c, q, lines) {
    if (!drawer) return;
    var p = NB.products[slug];
    $('[data-drawer-item]', drawer).innerHTML =
      '<img src="' + media(slug, c) + '" alt="">' +
      '<div><b>' + esc(p.name) + '</b><small>' + esc(p.colors[c]) + ' · Qty ' + q + '</small></div>' +
      '<span class="money">' + kr(p.price * q) + '</span>';
    var sub = subtotal(lines), left = NB.freeOver - sub;
    $('[data-drawer-free]', drawer).innerHTML = left > 0
      ? 'Add <b class="money" style="color:inherit">' + kr(left) + '</b> more for free delivery.'
      : '<b>Free delivery unlocked.</b> Your bag comes to ' + kr(sub) + '.';
    $('[data-drawer-view]', drawer).textContent = 'View bag (' + count(lines) + ')';
    drawer.hidden = false; scrim.hidden = false;
    requestAnimationFrame(function () { drawer.classList.add('is-open'); scrim.classList.add('is-open'); });
    clearTimeout(drawerTimer);
  }
  function closeDrawer() {
    if (!drawer || drawer.hidden) return;
    drawer.classList.remove('is-open'); scrim.classList.remove('is-open');
    setTimeout(function () { drawer.hidden = true; scrim.hidden = true; }, 300);
  }
  if (drawer) {
    $$('[data-drawer-close]', drawer).forEach(function (b) { b.addEventListener('click', closeDrawer); });
    scrim.addEventListener('click', closeDrawer);
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeDrawer(); });
  }

  // ---------------------------------------------------------------- the bag page
  var bagRoot = $('[data-bag-root]');
  function renderBag() {
    var lines = load();
    if (!lines.length) {
      bagRoot.innerHTML = '<div class="bag-empty"><p>Your bag is empty. Everything you add stays here until you check out.</p>' +
        '<a class="btn btn-dark" href="/collections/all">Continue shopping</a></div>';
      return;
    }
    var sub = subtotal(lines), left = NB.freeOver - sub;
    var rows = lines.map(function (l, i) {
      var p = NB.products[l.slug];
      return '<article class="bag-line">' +
        '<a class="thumb-link" href="/p/' + l.slug + '"><img src="' + media(l.slug, l.color) + '" alt="' + esc(p.name + ' in ' + p.colors[l.color]) + '"></a>' +
        '<div><h2><a href="/p/' + l.slug + '">' + esc(p.name) + '</a></h2>' +
        '<p class="meta">' + esc(p.colors[l.color]) + ' · <span class="money">' + kr(p.price) + '</span></p>' +
        '<div class="controls"><div class="qty">' +
        '<button type="button" data-step="-1" data-i="' + i + '" aria-label="Decrease quantity of ' + esc(p.name) + '"><svg class="icon" aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M6 12h12"/></svg></button>' +
        '<input type="number" value="' + l.qty + '" min="1" max="20" aria-label="Quantity of ' + esc(p.name) + '" data-set="' + i + '">' +
        '<button type="button" data-step="1" data-i="' + i + '" aria-label="Increase quantity of ' + esc(p.name) + '"><svg class="icon" aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M6 12h12M12 6v12"/></svg></button>' +
        '</div><button type="button" class="remove" data-remove="' + i + '">Remove</button></div></div>' +
        '<p class="line-total money">' + kr(p.price * l.qty) + '</p></article>';
    }).join('');
    var free = left > 0
      ? '<div class="free">You are <b class="money">' + kr(left) + '</b> away from free delivery.<div class="bar"><i style="width:' + Math.min(100, sub / NB.freeOver * 100).toFixed(1) + '%"></i></div></div>'
      : '<div class="free done"><svg class="icon" aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>You have free delivery.</div>';
    var n = count(lines);
    bagRoot.innerHTML =
      '<section class="bag-lines" aria-label="Items in your bag">' + rows + '</section>' +
      '<aside class="bag-sum" aria-label="Order summary"><h2>Order summary</h2>' + free +
      '<dl class="sum-lines"><div><dt>Subtotal (' + n + (n === 1 ? ' item' : ' items') + ')</dt><dd class="money">' + kr(sub) + '</dd></div>' +
      '<div><dt>Delivery</dt><dd>' + (left > 0 ? 'From <span class="money">' + kr(NB.delivery.postnord) + '</span>' : 'Free') + '</dd></div>' +
      '<div class="sum-total"><dt>Total</dt><dd><small>SEK</small> <span class="money">' + kr(sub + (left > 0 ? NB.delivery.postnord : 0)) + '</span></dd></div></dl>' +
      '<a class="btn btn-dark" href="/checkout">Checkout</a>' +
      '<p class="bag-note">Taxes included. Discount codes go in at checkout.</p>' +
      '<div class="pay-marks"><b>Visa</b><b>Mastercard</b><b>Amex</b><b>Invoice</b></div></aside>';
  }
  if (bagRoot) {
    renderBag();
    bagRoot.addEventListener('click', function (e) {
      var step = e.target.closest('[data-step]'), rm = e.target.closest('[data-remove]');
      var lines = load();
      if (step) {
        var l = lines[+step.getAttribute('data-i')];
        if (!l) return;
        l.qty = Math.max(1, Math.min(20, l.qty + (+step.getAttribute('data-step'))));
        save(lines); renderBag();
        var again = bagRoot.querySelector('[data-step="' + step.getAttribute('data-step') + '"][data-i="' + step.getAttribute('data-i') + '"]');
        if (again) again.focus();
      } else if (rm) {
        lines.splice(+rm.getAttribute('data-remove'), 1);
        save(lines); renderBag();
      }
    });
    bagRoot.addEventListener('change', function (e) {
      var set = e.target.closest('[data-set]');
      if (!set) return;
      var lines = load(), l = lines[+set.getAttribute('data-set')];
      if (!l) return;
      l.qty = Math.max(1, Math.min(20, parseInt(set.value, 10) || 1));
      save(lines); renderBag();
    });
  }

  // ---------------------------------------------------------------- the checkout
  var form = $('#checkout');
  if (form) {
    var lines = load();
    if (!lines.length) {
      // Opened straight from a link: the shop's bestseller, so there is something to pay for.
      lines = [{ slug: 'fjord-linen-throw', color: 'sand', qty: 1 }];
      save(lines);
    }
    var sub = subtotal(lines);
    $('[data-bag-field]', form).value = JSON.stringify(lines);
    $('[data-sum-items]').innerHTML = lines.map(function (l) {
      var p = NB.products[l.slug];
      return '<div class="sum-item"><div class="sum-thumb"><img src="' + media(l.slug, l.color) + '" alt=""><span class="sum-qty">' + l.qty + '</span></div>' +
        '<div class="sum-name"><b>' + esc(p.name) + '</b><small>' + esc(p.colors[l.color]) + '</small></div>' +
        '<span class="money">' + kr(p.price * l.qty) + '</span></div>';
    }).join('');
    var totals = function () {
      var method = (form.querySelector('input[name="delivery"]:checked') || {}).value || 'postnord';
      var ship = method === 'budbee' ? NB.delivery.budbee : (sub >= NB.freeOver ? 0 : NB.delivery.postnord);
      var total = sub + ship;
      $('[data-sum-subtotal]').textContent = kr(sub);
      $('[data-sum-ship]').textContent = ship ? kr(ship) : 'Free';
      $('[data-sum-total]').textContent = kr(total);
      $('[data-sum-tax]').textContent = 'Including ' + kr2(total * 0.2) + ' in taxes';
      var pn = $('[data-ship-price="postnord"]');
      if (pn) pn.textContent = sub >= NB.freeOver ? 'Free' : kr(NB.delivery.postnord);
      $('[data-pay-label]', form).textContent = 'Pay ' + kr(total);
      return total;
    };
    totals();
    $$('input[name="delivery"]', form).forEach(function (r) { r.addEventListener('change', totals); });

    // the card's number in fours, its brand, the date as MM / YY
    var num = $('#f-cardnumber'), exp = $('#f-exp'), cvc = $('#f-cvc');
    var brandOf = function (d) {
      if (/^4/.test(d)) return ['visa', 'VISA'];
      if (/^(5[1-5]|2[2-7])/.test(d)) return ['mc', 'Mastercard'];
      if (/^3[47]/.test(d)) return ['amex', 'AMEX'];
      return null;
    };
    var shapeNumber = function () {
      var d = num.value.replace(/\D/g, '').slice(0, 19);
      var amex = /^3[47]/.test(d);
      var parts = amex ? [d.slice(0, 4), d.slice(4, 10), d.slice(10, 15)] : d.match(/.{1,4}/g) || [];
      var shaped = parts.filter(Boolean).join(' ');
      var atEnd = num.selectionStart === num.value.length;
      if (shaped !== num.value) { num.value = shaped; if (atEnd) num.setSelectionRange(shaped.length, shaped.length); }
      var b = brandOf(d), mark = $('[data-brand]'), row = $('.brands');
      mark.textContent = b ? b[1] : '';
      mark.classList.toggle('on', !!b);
      row.classList.toggle('picked', !!b);
      $$('.brand', row).forEach(function (el) { el.classList.toggle('is-on', !!b && el.classList.contains(b[0])); });
    };
    var shapeExp = function (e) {
      var d = exp.value.replace(/\D/g, '').slice(0, 4);
      if (d.length === 1 && +d > 1) d = '0' + d;
      var deleting = e && e.inputType && e.inputType.indexOf('delete') === 0;
      var shaped = d.length > 2 ? d.slice(0, 2) + ' / ' + d.slice(2) : (d.length === 2 && !deleting ? d + ' / ' : d);
      if (shaped !== exp.value) exp.value = shaped;
    };
    num.addEventListener('input', shapeNumber);
    exp.addEventListener('input', shapeExp);
    cvc.addEventListener('input', function () { var d = cvc.value.replace(/\D/g, '').slice(0, 4); if (d !== cvc.value) cvc.value = d; });
    if (num.value) shapeNumber();

    var luhn = function (d) {
      var sum = 0;
      for (var i = 0; i < d.length; i++) {
        var n = +d[d.length - 1 - i];
        if (i % 2) { n *= 2; if (n > 9) n -= 9; }
        sum += n;
      }
      return sum % 10 === 0;
    };
    var rules = {
      email: function (v) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.trim()) ? '' : 'Enter an email address, like name@example.com.'; },
      name: function (v) { return v.trim() ? '' : 'Enter your full name.'; },
      address1: function (v) { return v.trim() ? '' : 'Enter your street address.'; },
      postal_code: function (v) { return v.replace(/\D/g, '').length >= 4 ? '' : 'Enter a postal code, like 116 40.'; },
      city: function (v) { return v.trim() ? '' : 'Enter your city.'; },
      phone: function (v) { return v.replace(/\D/g, '').length >= 7 ? '' : 'Enter a phone number for delivery updates.'; },
      cardnumber: function (v) { var d = v.replace(/\D/g, ''); return d.length >= 12 && d.length <= 19 && luhn(d) ? '' : 'Your card number is incomplete or not valid.'; },
      exp: function (v) {
        var m = v.match(/^\s*(\d{1,2})\s*\/?\s*(\d{2}|\d{4})\s*$/);
        if (!m || +m[1] < 1 || +m[1] > 12) return 'Enter the expiration date as MM / YY.';
        var y = 2000 + (+m[2] % 100), now = new Date();
        return (y < now.getFullYear() || (y === now.getFullYear() && +m[1] < now.getMonth() + 1)) ? 'Your card has expired.' : '';
      },
      cvc: function (v) { return /^\d{3,4}$/.test(v.trim()) ? '' : 'Enter the 3 or 4 digit security code.'; },
      ccname: function (v) { return v.trim() ? '' : 'Enter the name on your card.'; }
    };
    var show = function (name, msg) {
      var input = form.elements[name];
      if (!input) return;
      var field = input.closest('.field'), err = $('#err-' + name);
      field.classList.toggle('has-error', !!msg);
      if (msg) { input.setAttribute('aria-invalid', 'true'); input.setAttribute('aria-describedby', 'err-' + name); }
      else { input.removeAttribute('aria-invalid'); }
      if (err) { err.textContent = msg; err.hidden = !msg; }
    };
    Object.keys(rules).forEach(function (name) {
      var input = form.elements[name];
      if (!input) return;
      input.addEventListener('blur', function () { if (input.value) show(name, rules[name](input.value)); });
      input.addEventListener('input', function () { if (input.closest('.field').classList.contains('has-error')) show(name, rules[name](input.value)); });
    });
    var paying = false;
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (paying) return;
      var first = null;
      Object.keys(rules).forEach(function (name) {
        var input = form.elements[name];
        var msg = rules[name](input.value);
        show(name, msg);
        if (msg && !first) first = input;
      });
      if (first) { first.focus(); first.scrollIntoView({ block: 'center' }); return; }
      paying = true;
      $('[data-bag-field]', form).value = JSON.stringify(load().length ? load() : lines);
      var pay = $('[data-pay]', form);
      pay.disabled = true;
      pay.setAttribute('aria-busy', 'true');
      pay.innerHTML = '<span class="spin" aria-hidden="true"></span><span>Processing payment</span>';
      setTimeout(function () { HTMLFormElement.prototype.submit.call(form); }, 1100);
    });
    var discount = $('[data-discount]');
    if (discount) discount.addEventListener('submit', function (e) {
      e.preventDefault();
      var msg = $('[data-discount-msg]'), code = $('#discount').value.trim();
      msg.textContent = code ? 'This discount code isn’t valid right now.' : 'Enter a discount code.';
      msg.hidden = false;
    });
  }

  // ---------------------------------------------------------------- after paying
  var placed = document.body.getAttribute('data-placed');
  if (placed && document.cookie.indexOf('nb_placed=' + placed) >= 0) {
    save([]);
    document.cookie = 'nb_placed=; Max-Age=0; Path=/';
  }

  // ---------------------------------------------------------------- letters
  $$('[data-letters]').forEach(function (f) {
    f.addEventListener('submit', function (e) {
      e.preventDefault();
      if (!/@/.test($('input', f).value)) { $('input', f).focus(); return; }
      f.hidden = true;
      var done = f.parentNode.querySelector('.letters-done');
      if (done) done.hidden = false;
    });
  });
})();
