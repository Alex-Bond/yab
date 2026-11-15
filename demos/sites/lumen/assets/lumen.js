/* Lumen: dates worked out from today, the clock in the bar, and the
   registration form's checks. */
(function () {
  'use strict';
  var L = window.LUMEN || { events: {} };
  var DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function addDays(d, n) { return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n); }

  // The events are in Stockholm: their days and hours are Stockholm's,
  // whatever clock this computer keeps. Dates here are calendar days, kept
  // as local midnights only to name them.
  function stockholmToday() {
    try {
      var parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/Stockholm', year: 'numeric', month: 'numeric', day: 'numeric' })
        .formatToParts(new Date());
      var get = function (t) { for (var i = 0; i < parts.length; i++) if (parts[i].type === t) return +parts[i].value; return 0; };
      return new Date(get('year'), get('month') - 1, get('day'));
    } catch (e) {
      var n = new Date();
      return new Date(n.getFullYear(), n.getMonth(), n.getDate());
    }
  }
  function lastSunday(year, month) {
    var d = new Date(year, month + 1, 0);
    return addDays(d, -d.getDay());
  }
  function summer(d) { return d >= lastSunday(d.getFullYear(), 2) && d < lastSunday(d.getFullYear(), 9); }
  function zone(d) { return summer(new Date(d.getFullYear(), d.getMonth(), d.getDate())) ? 'GMT+2' : 'GMT+1'; }
  // weekday: Monday 0 to Sunday 6; week 0 is the next one after today,
  // week 1 next week's, week 2 the week after.
  function occurrence(rule, today) {
    var wd = (today.getDay() + 6) % 7, d;
    if (rule.week === 0) {
      var delta = ((rule.wd - wd) % 7 + 7) % 7 || 7;
      d = addDays(today, delta);
    } else {
      d = addDays(addDays(today, -wd + 7 * rule.week), rule.wd);
    }
    return new Date(d.getFullYear(), d.getMonth(), d.getDate(), rule.h, rule.m);
  }
  function time(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function fmt(d, kind, ev) {
    switch (kind) {
      case 'long': return DAYS[d.getDay()] + ', ' + MONTHS[d.getMonth()] + ' ' + d.getDate();
      case 'short': return DAYS[d.getDay()].slice(0, 3) + ', ' + MONTHS[d.getMonth()].slice(0, 3) + ' ' + d.getDate();
      case 'md': return MONTHS[d.getMonth()].slice(0, 3) + ' ' + d.getDate();
      case 'month': return MONTHS[d.getMonth()].slice(0, 3).toUpperCase();
      case 'day': return String(d.getDate());
      case 'weekday': return DAYS[d.getDay()];
      case 'time': return time(d);
      case 'range':
        var mins = d.getHours() * 60 + d.getMinutes() + Math.round(ev.hours * 60);
        return time(d) + ' to ' + pad(Math.floor(mins / 60) % 24) + ':' + pad(mins % 60) + ' ' + zone(d);
      case 'deadline': return fmt(addDays(d, -3), 'long');
    }
    return '';
  }
  var today = stockholmToday();
  Array.prototype.forEach.call(document.querySelectorAll('[data-ev][data-fmt]'), function (el) {
    var ev = L.events[el.getAttribute('data-ev')];
    if (!ev) return;
    var text = fmt(occurrence(ev.rule, today), el.getAttribute('data-fmt'), ev);
    if (text && el.textContent !== text) el.textContent = text;
  });

  // ---------------------------------------------------------------- the form
  var form = document.getElementById('register');
  if (form) {
    var rules = {
      name: function (v) { return v.trim() ? '' : 'Please enter your name.'; },
      email: function (v) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.trim()) ? '' : 'Please enter an email address the hosts can reach you at.'; },
      working_on: function (v) { return v.trim() ? '' : 'Please tell the hosts what you are working on.'; },
      hoping_for: function (v) { return v.trim() ? '' : 'Please tell the hosts what you hope to get out of the night.'; },
      consent: function (v, el) { return el.checked ? '' : 'Please agree to share your answers so the hosts can review your request.'; }
    };
    var show = function (name, msg) {
      var el = form.elements[name], err = document.getElementById('err-' + name);
      var box = el.closest('.field') || el.closest('.tick');
      if (box) box.classList.toggle('bad', !!msg);
      if (msg) { el.setAttribute('aria-invalid', 'true'); el.setAttribute('aria-describedby', 'err-' + name); }
      else el.removeAttribute('aria-invalid');
      if (err) { err.textContent = msg; err.hidden = !msg; }
    };
    Object.keys(rules).forEach(function (name) { if (!form.elements[name]) delete rules[name]; });
    Object.keys(rules).forEach(function (name) {
      var el = form.elements[name];
      if (!el) return;
      var again = function () {
        var bad = (el.closest('.field') || el.closest('.tick') || {}).classList;
        if (bad && bad.contains('bad')) show(name, rules[name](el.value, el));
      };
      el.addEventListener('input', again);
      el.addEventListener('change', again);
    });
    // a question's box grows with the answer
    Array.prototype.forEach.call(form.querySelectorAll('textarea'), function (t) {
      var fit = function () { t.style.height = 'auto'; t.style.height = Math.max(96, t.scrollHeight + 2) + 'px'; };
      t.addEventListener('input', fit);
      fit();
    });
    var sending = false;
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (sending) return;
      var first = null;
      Object.keys(rules).forEach(function (name) {
        var el = form.elements[name], msg = rules[name](el.value, el);
        show(name, msg);
        if (msg && !first) first = el;
      });
      if (first) { first.focus(); first.scrollIntoView({ block: 'center' }); return; }
      sending = true;
      var btn = form.querySelector('[data-send]');
      btn.disabled = true;
      btn.innerHTML = '<span class="spin" aria-hidden="true"></span><span>' + (/request/i.test(btn.textContent) ? 'Sending request' : 'Registering') + '</span>';
      setTimeout(function () { HTMLFormElement.prototype.submit.call(form); }, 450);
    });
  }

  var signin = document.querySelector('[data-signin]');
  if (signin) signin.addEventListener('submit', function (e) {
    e.preventDefault();
    var input = signin.querySelector('input');
    if (!/@/.test(input.value)) { input.focus(); return; }
    signin.querySelector('.signin-done').hidden = false;
  });
})();
