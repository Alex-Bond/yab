/* Daybook. Events come from the world's /__demo/state.json; without one,
   a believable week for Mira is made up around the moment the page opens,
   with the design review twelve minutes out. */
(function () {
  "use strict";

  var HOUR = 64;
  var TOP = 8; // the grid's air above midnight (.grid padding-top)
  var MIN = 60000;
  var CALL = "http://localhost:8800/r/design-review";
  var $ = function (s) { return document.querySelector(s); };

  /* ---------------------------------------------------------------- icons */

  var P = {
    search: '<circle cx="10.8" cy="10.8" r="6.3"/><path d="m15.6 15.6 4.4 4.4"/>',
    sidebar: '<rect x="3.5" y="4.5" width="17" height="15" rx="3"/><path d="M9.5 4.5v15"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2.2M12 18.3v2.2M20.5 12h-2.2M5.7 12H3.5M18 6l-1.6 1.6M7.6 16.4 6 18M18 18l-1.6-1.6M7.6 7.6 6 6"/>',
    left: '<path d="m14.5 6.5-5.5 5.5 5.5 5.5"/>',
    right: '<path d="m9.5 6.5 5.5 5.5-5.5 5.5"/>',
    video: '<rect x="3" y="6.5" width="12.5" height="11" rx="2.6"/><path d="m15.5 10.6 5-2.9v8.6l-5-2.9"/>',
    clock: '<circle cx="12" cy="12" r="8.6"/><path d="M12 7.6V12l2.8 1.8"/>',
    people: '<circle cx="9.2" cy="8.4" r="3.3"/><path d="M3.2 19.4c.8-3.3 3.1-5 6-5s5.2 1.7 6 5"/><path d="M15.6 5.3a3.3 3.3 0 0 1 0 6.2M17.7 14.7c1.5.8 2.6 2.3 3 4.7"/>',
    pin: '<path d="M12 21s-6.5-5.4-6.5-11a6.5 6.5 0 0 1 13 0c0 5.6-6.5 11-6.5 11Z"/><circle cx="12" cy="10" r="2.3"/>',
    note: '<path d="M5 5.5h14M5 10h14M5 14.5h9M5 19h6"/>',
    cal: '<rect x="3.5" y="5" width="17" height="15.5" rx="2.6"/><path d="M3.5 9.8h17M8 3v4M16 3v4"/>',
    x: '<path d="m6.5 6.5 11 11M17.5 6.5l-11 11"/>',
    edit: '<path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/>',
    trash: '<path d="M4.5 7h15M10 11v6M14 11v6M6.5 7l1 12.5c.1.8.7 1.5 1.6 1.5h5.8c.9 0 1.5-.7 1.6-1.5l1-12.5M9.5 7V4.5h5V7"/>',
    copy: '<rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.4"/><path d="M15.5 8.5V6.4c0-1.3-1-2.4-2.4-2.4H6.4C5.1 4 4 5.1 4 6.4v6.7c0 1.3 1.1 2.4 2.4 2.4h2.1"/>',
    check: '<path d="m5.5 12.5 4.2 4.2 8.8-9.2"/>',
    plane: '<path d="M10.5 13.5 4 11l1.4-1.4 7.6.9 3.6-3.6c.8-.8 2.1-.8 2.9 0s.8 2.1 0 2.9L15.9 13.4l.9 7.6-1.4 1.4-2.5-6.5-2.6 2.6v2.5l-1.2 1.2-1.4-3.5-3.5-1.4 1.2-1.2h2.5Z"/>'
  };
  // Strokes draw 1.5px at every size: the 24-unit drawing's stroke is scaled to match.
  function icon(name, size, extra) {
    size = size || 16;
    var stroke = Math.round((1.5 * 24 / size) * 100) / 100;
    return '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + stroke + '" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"' + (extra ? " " + extra : "") + ">" + (P[name] || "") + "</svg>";
  }
  function icons(root) {
    (root || document).querySelectorAll("[data-icon]").forEach(function (el) {
      if (!el.querySelector("svg")) el.insertAdjacentHTML("afterbegin", icon(el.getAttribute("data-icon"), +el.getAttribute("data-size") || 16));
    });
  }

  /* ---------------------------------------------------------------- time */

  var fmtTime = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" });
  var fmtHour = new Intl.DateTimeFormat("en-US", { hour: "numeric" });
  var fmtDay = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric" });
  var fmtDow = new Intl.DateTimeFormat("en-US", { weekday: "short" });
  var fmtMonth = new Intl.DateTimeFormat("en-US", { month: "long" });
  var fmtMon = new Intl.DateTimeFormat("en-US", { month: "short" });
  var fmtShort = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" });

  function dayStart(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function monday(d) { var x = dayStart(d); var k = (x.getDay() + 6) % 7; return addDays(x, -k); }
  function sameDay(a, b) { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate(); }
  function at(d, h, m) { var x = dayStart(d); x.setHours(h, m || 0, 0, 0); return x; }
  function isoWeek(d) {
    var x = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
    var n = x.getUTCDay() || 7;
    x.setUTCDate(x.getUTCDate() + 4 - n);
    var y0 = new Date(Date.UTC(x.getUTCFullYear(), 0, 1));
    return Math.ceil(((x - y0) / 86400000 + 1) / 7);
  }
  // "2:45 PM", or "2:45" when the other end shares the meridiem.
  function clock(d, bare) {
    var s = fmtTime.format(d);
    return bare ? s.replace(/\s?[AP]M$/, "") : s;
  }
  function span(a, b) {
    var same = (a.getHours() < 12) === (b.getHours() < 12);
    return clock(a, same) + " → " + clock(b);
  }
  function until(ms) {
    var m = Math.ceil(ms / MIN);
    if (m < 60) return m + " min";
    var h = Math.floor(m / 60), r = m % 60;
    return h + " hr" + (r ? " " + r + " min" : "");
  }
  function untilShort(ms) {
    var m = Math.ceil(ms / MIN);
    if (m < 60) return m + "m";
    var h = Math.floor(m / 60), r = m % 60;
    return h + "h" + (r ? " " + r + "m" : "");
  }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  /* ---------------------------------------------------------------- people */

  var PEOPLE = {
    "Mira Lindqvist": ["linear-gradient(135deg,#f6a96b,#d9577a)", "mira@ternlabs.com"],
    "Jonas Berg": ["#2563eb", "jonas@ternlabs.com"],
    "Anna Ek": ["#0d9488", "anna@ternlabs.com"],
    "Elliot Park": ["#7c3aed", "elliot@ternlabs.com"],
    "Sara Holm": ["#db2777", "sara@ternlabs.com"],
    "Kai Nakamura": ["#ea580c", "kai@nakamura.studio"],
    "Priya Nair": ["#0891b2", "priya@fieldwork.agency"],
    "Sofia Moreau": ["#9333ea", "sofia.moreau@gmail.com"],
    "Lena Lindqvist": ["#be185d", "lena.lindqvist@icloud.com"]
  };
  var SPARE = ["#0f766e", "#b45309", "#4f46e5", "#be123c", "#047857", "#7c2d12"];
  function personColor(name) {
    if (PEOPLE[name]) return PEOPLE[name][0];
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
    return SPARE[h % SPARE.length];
  }
  function initials(name) {
    if (/^everyone/i.test(name)) return "T";
    var p = name.split(/\s+/).filter(Boolean);
    return ((p[0] || "")[0] + ((p[1] || "")[0] || "")).toUpperCase();
  }
  function face(name, size) {
    return '<span class="face" style="background:' + personColor(name) + (size ? ";width:" + size + "px;height:" + size + "px" : "") + '" title="' + esc(name) + '">' + esc(initials(name)) + "</span>";
  }

  var NOTES = [
    [/design review/i, "Walk through Onboarding v3: the one-screen welcome and the calendar step. Deck v3 is in Figma, Anna moved this to today so Jonas can join before his board call."],
    [/standup/i, "What shipped yesterday, what ships today, what is in the way. Fifteen minutes."],
    [/launch plan/i, "Tern 2.0 goes out on Oct 21. Rollout steps, the launch post, who is on call that week."],
    [/fika/i, "Coffee and kanelbullar in the kitchen. Laptops stay at the desks."],
    [/lunch with kai/i, "Round 2 illustrations: the welcome screens and the empty states."],
    [/1:1 jonas/i, "Weekly 1:1. Hiring for the design team, the 2.0 launch, anything else."],
    [/pricing page/i, "Last pass on the pricing page copy and screenshots before the 50% rollout."],
    [/design systems night/i, "Talks and drinks in Södermalm. Jonas is going too."],
    [/interview/i, "Portfolio review for the product designer role. Scorecard is in Paper."],
    [/focus/i, "Protected time. Daybook suggests other slots to anyone who tries to book over it."],
    [/design crit/i, "Bring one thing in progress. Ten minutes each, then feedback."],
    [/^lisbon|lisbon trip/i, "Four days in Lisbon. Casa Alfama, check-in from 15:00."],
    [/dinner/i, "Babette at 19:30. Sofia booked the table, Lena is in."],
    [/coffee with priya/i, "Johan & Nyström on Swedenborgsgatan."],
    [/flight/i, "Nordic Air, booking LQ4K2P. Window seat."]
  ];
  // "Design review · Onboarding v3": the part after the dot on a line of its
  // own, so a wrap never leaves the dot hanging; the dot stays for readers.
  function titled(title) {
    var cut = title.indexOf(" \u00b7 ");
    if (cut <= 0) return esc(title);
    return esc(title.slice(0, cut)) + '<span class="sep"> \u00b7 </span><span class="sub-title">' + esc(title.slice(cut + 3)) + "</span>";
  }

  function note(title) {
    for (var i = 0; i < NOTES.length; i++) if (NOTES[i][0].test(title)) return NOTES[i][1];
    return "";
  }

  /* ---------------------------------------------------------------- data */

  var CALS = [
    { key: "Work", name: "Work", account: "work" },
    { key: "Personal", name: "Personal", account: "home" },
    { key: "Lisbon", name: "Lisbon trip", account: "home" },
    { key: "Launch", name: "Tern 2.0 rollout", account: "shared" }
  ];
  // Anna's shared calendar: the rollout dates from the launch deck.
  var ROLLOUT = [
    ["2026-10-09", "Onboarding v3 to 10%"],
    ["2026-10-14", "Pricing live, 50%"],
    ["2026-10-21", "Tern 2.0 launch"]
  ];
  var me = { name: "Mira Lindqvist", work: "mira@ternlabs.com", home: "mira@lindqvist.studio" };
  var events = [];
  var meeting = null;
  var hidden = {};
  var view = { mode: "week", start: monday(new Date()), month: dayStart(new Date()) };
  var firstScroll = true;

  function normalize(e, i) {
    var start = new Date(+e.start * 1000), end = new Date(+e.end * 1000);
    if (!(end > start)) end = new Date(start.getTime() + 30 * MIN);
    var cal = /lisbon/i.test(e.calendar || "") ? "Lisbon" : /personal|home/i.test(e.calendar || "") ? "Personal" : /launch|rollout/i.test(e.calendar || "") ? "Launch" : "Work";
    var all = !!(e.allDay || e.all_day) || end - start >= 20 * 60 * MIN;
    return {
      id: "e" + i,
      title: String(e.title || "Untitled"),
      start: start, end: end, cal: cal, all: all,
      people: Array.isArray(e.people) ? e.people.filter(Boolean).map(String) : [],
      link: e.link || null,
      where: e.where || (e.link ? "Roundtable" : ""),
      desc: e.description || e.notes || note(String(e.title || ""))
    };
  }
  function valid(e) { return e && e.title && isFinite(+e.start) && isFinite(+e.end); }

  // The week the page makes up when the world didn't say: Mira's, around now.
  function made(nowMs) {
    var now = new Date(nowMs);
    var today = dayStart(now);
    var start = Math.floor((nowMs + 12 * MIN) / MIN) * MIN;
    var review = { title: "Design review · Onboarding v3", start: start / 1000, end: start / 1000 + 1800, calendar: "Work",
      people: ["Jonas Berg", "Anna Ek", "Elliot Park"], link: CALL, where: "Roundtable" };
    var out = [];
    var add = function (d, h, m, minutes, title, cal, people, link, where) {
      var s = at(d, h, m);
      out.push({ title: title, start: s.getTime() / 1000, end: s.getTime() / 1000 + minutes * 60, calendar: cal, people: people || [], link: link || null, where: where || "" });
    };
    var standup = "http://localhost:8800/r/standup";
    var mon = monday(today);
    for (var w = -1; w <= 2; w++) {
      for (var k = 0; k < 7; k++) {
        var d = addDays(mon, w * 7 + k);
        var dow = d.getDay();
        if (dow >= 1 && dow <= 5) add(d, 9, 30, 15, "Standup", "Work", ["Jonas Berg", "Anna Ek", "Elliot Park", "Sara Holm"], standup);
        if (dow === 1) { add(d, 7, 0, 60, "Gym", "Personal"); add(d, 14, 0, 60, "Design crit", "Work", ["Anna Ek", "Elliot Park", "Sara Holm"], "http://localhost:8800/r/design-crit"); }
        if (dow === 2) add(d, 10, 0, 120, "Focus: Onboarding v3 flows", "Work");
        if (dow === 3) add(d, 7, 0, 60, "Gym", "Personal");
        if (dow === 4) add(d, 10, 0, 120, "Focus: launch notes", "Work");
        if (dow === 5) { add(d, 15, 0, 30, "Fika", "Work", ["Everyone at Tern"], null, "Kitchen, 3rd floor"); add(d, 19, 30, 150, "Dinner at Babette", "Personal", ["Sofia Moreau", "Lena Lindqvist"], null, "Babette, Roslagsgatan"); }
        if (dow === 6) add(d, 10, 0, 90, "Long run, Djurgården", "Personal");
      }
    }
    add(today, 12, 0, 60, "Lunch with Kai", "Personal", ["Kai Nakamura"], null, "Café Pascal");
    add(today, 16, 0, 30, "1:1 Jonas", "Work", ["Jonas Berg"], "http://localhost:8800/r/jonas-mira");
    add(addDays(today, 1), 14, 0, 60, "Tern 2.0 launch plan", "Work", ["Jonas Berg", "Anna Ek", "Sara Holm"], "http://localhost:8800/r/launch-plan");
    add(addDays(today, 2), 13, 0, 45, "Pricing page review", "Work", ["Anna Ek"], "http://localhost:8800/r/pricing");
    add(addDays(today, 1), 18, 0, 150, "Design Systems Night", "Personal", ["Jonas Berg"], null, "Södermalm");
    add(addDays(today, -1), 15, 0, 60, "Interview: product designer", "Work", ["Priya Nair", "Anna Ek"], "http://localhost:8800/r/interview");
    add(addDays(monday(today), 9), 9, 0, 30, "Coffee with Priya", "Personal", ["Priya Nair"], null, "Johan & Nyström");
    // Lisbon, twelve days out: the trip and its flights.
    var go = addDays(today, 12), back = addDays(today, 16);
    out.push({ title: "Lisbon", allDay: true, calendar: "Lisbon", start: go.getTime() / 1000, end: at(back, 23, 59).getTime() / 1000 });
    add(go, 7, 10, 235, "Flight to Lisbon · ARN → LIS", "Lisbon", [], null, "Arlanda Terminal 5");
    add(back, 16, 40, 225, "Flight home · LIS → ARN", "Lisbon", [], null, "Lisbon Airport");
    // Nothing else today may sit on the review.
    out = out.filter(function (e) {
      return !(e.start < review.end && e.end > review.start && sameDay(new Date(e.start * 1000), new Date(start)));
    });
    out.unshift(review);
    return { meeting: review, events: out };
  }

  function load() {
    var done = function (s) {
      s = s && typeof s === "object" ? s : {};
      if (s.persona) {
        me.name = s.persona.name || me.name;
        me.work = s.persona.work_email || me.work;
        me.home = s.persona.email || me.home;
      }
      var list = Array.isArray(s.events) ? s.events.filter(valid) : [];
      var m = valid(s.meeting) ? s.meeting : null;
      if (!list.length) {
        var g = made(Date.now());
        list = g.events;
        if (!m) m = g.meeting;
      }
      if (m && !list.some(function (e) { return e.title === m.title && +e.start === +m.start; })) list.unshift(m);
      ROLLOUT.forEach(function (r) {
        var d = new Date(r[0] + "T00:00:00");
        list.push({ title: r[1], allDay: true, calendar: "Launch", start: d.getTime() / 1000, end: addDays(d, 1).getTime() / 1000 });
      });
      events = list.map(normalize);
      meeting = m ? events.filter(function (e) { return e.title === m.title && e.start.getTime() === +m.start * 1000; })[0] || null : null;
      $("#me-name").textContent = me.name;
      $("#me-mail").textContent = me.work;
      render();
      tick();
    };
    fetch("/__demo/state.json", { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : {}; })
      .catch(function () { return {}; })
      .then(done);
  }

  /* ---------------------------------------------------------------- the next meeting */

  function upNext(now) {
    var t = now.getTime();
    var list = events.filter(function (e) {
      return !e.all && e.end.getTime() > t && e.start.getTime() > t - 10 * MIN && (e.link || e.people.length);
    }).sort(function (a, b) { return a.start - b.start; });
    var first = list[0] || null;
    if (meeting && meeting.end.getTime() > t && meeting.start.getTime() > t - 10 * MIN && (!first || meeting.start <= first.start)) return meeting;
    return first;
  }

  function tick() {
    var now = new Date();
    var next = upNext(now);
    var card = $("#next");
    var title = "Daybook";
    if (next && next.start.getTime() - now.getTime() < 12 * 60 * MIN) {
      var wait = next.start.getTime() - now.getTime();
      var live = wait <= MIN;
      var short = next.title.split(" · ")[0];
      card.hidden = false;
      card.classList.toggle("live", live);
      card.style.setProperty("--c", "var(--" + next.cal.toLowerCase() + ")");
      $("#next-when").textContent = live ? (wait > 0 ? "Now" : "Started " + Math.max(1, Math.floor(-wait / MIN)) + " min ago").replace("Started 1 min ago", "Just started") : "in " + until(wait);
      if (card.getAttribute("data-id") !== next.id) {
        card.setAttribute("data-id", next.id);
        $("#next-title").innerHTML = titled(next.title);
        $("#next-meta").textContent = span(next.start, next.end) + (next.where ? " · " + next.where : "");
        $("#next-faces").innerHTML = next.people.slice(0, 4).map(function (p) { return face(p); }).join("");
      }
      var join = $("#next-join");
      join.hidden = !next.link;
      if (next.link) join.href = next.link;
      join.lastChild.textContent = live ? "Join now" : "Join";
      title = "Daybook · " + short + (live ? " now" : " in " + untilShort(wait));
      soon(next, wait, live);
    } else {
      card.hidden = true;
      soon(null);
    }
    if (document.title !== title) document.title = title;
  }

  // The chip on the meeting's own block: "in 12m", then Join. Updated in
  // place each second; only rebuilt when the meeting or its state changes.
  function soon(next, wait, live) {
    var want = next && wait <= 60 * MIN ? next.id + (live && next.link ? ":go" : ":wait") : "";
    var have = document.querySelector(".ev .soon");
    if (have && have.getAttribute("data-key") === want && have.isConnected) {
      if (!live) have.textContent = "in " + untilShort(wait);
      return;
    }
    document.querySelectorAll(".ev .soon").forEach(function (c) { c.remove(); });
    document.querySelectorAll(".ev.next-up").forEach(function (c) { c.classList.remove("next-up"); });
    if (!want) return;
    var el = document.querySelector('.ev[data-id="' + next.id + '"]');
    if (!el) return;
    el.classList.add("next-up");
    el.insertAdjacentHTML("beforeend", live && next.link
      ? '<a class="soon go" data-key="' + want + '" href="' + esc(next.link) + '" target="_blank" rel="noopener">Join</a>'
      : '<span class="soon" data-key="' + want + '">in ' + untilShort(wait) + "</span>");
  }

  /* ---------------------------------------------------------------- rendering */

  function days() {
    var n = view.mode === "day" ? 1 : 7;
    var out = [];
    for (var i = 0; i < n; i++) out.push(addDays(view.start, i));
    return out;
  }

  function render() {
    var list = days();
    var now = new Date();
    var first = list[0], last = list[list.length - 1];
    var cal = $("#cal");
    cal.style.setProperty("--days", list.length);
    document.documentElement.style.setProperty("--days", list.length);

    // Title: the month, or both months of a week that straddles them.
    var titleEl = $("#title");
    if (first.getMonth() === last.getMonth()) {
      titleEl.innerHTML = fmtMonth.format(first) + " <span>" + first.getFullYear() + "</span>";
    } else {
      titleEl.innerHTML = fmtMon.format(first) + " / " + fmtMon.format(last) + " <span>" + last.getFullYear() + "</span>";
    }
    $("#weekno").textContent = "W" + isoWeek(view.mode === "day" ? first : addDays(first, 3));
    var off = -now.getTimezoneOffset() / 60;
    var zone = "";
    try { zone = (Intl.DateTimeFormat().resolvedOptions().timeZone || "").split("/").pop().replace(/_/g, " "); } catch (e) {}
    var gmt = "GMT" + (off >= 0 ? "+" : "-") + Math.abs(off).toString().replace(".5", ":30");
    $("#tz").textContent = (zone ? zone + " · " : "") + gmt;

    // Day heads.
    $("#dayrow").innerHTML = '<div class="gmt">' + gmt + "</div>" + list.map(function (d) {
      var cls = sameDay(d, now) ? "today" : d.getDay() % 6 === 0 ? "weekend" : "";
      return '<div class="' + cls + '">' + fmtDow.format(d) + ' <span class="num">' + d.getDate() + "</span></div>";
    }).join("");

    // All-day bars.
    var shown = events.filter(function (e) { return !hidden[e.cal]; });
    var spanStart = dayStart(first), spanEnd = addDays(dayStart(last), 1);
    var bars = shown.filter(function (e) { return e.all && e.start < spanEnd && e.end > spanStart; });
    var allday = '<div class="lbl">all-day</div>';
    bars.forEach(function (e, row) {
      var a = Math.max(0, Math.round((dayStart(e.start) - spanStart) / 86400000));
      var endDay = e.end.getHours() === 0 && e.end.getMinutes() === 0 ? addDays(e.end, -1) : e.end;
      var b = Math.min(list.length - 1, Math.round((dayStart(endDay) - spanStart) / 86400000));
      var cutL = e.start < spanStart, cutR = dayStart(endDay) >= spanEnd;
      var range = sameDay(e.start, endDay) ? "" : fmtShort.format(e.start) + " \u2192 " + fmtShort.format(endDay);
      allday += '<div class="bar-ev' + (cutL ? " cut-l" : "") + (cutR ? " cut-r" : "") + '" data-cal="' + e.cal + '" data-id="' + e.id + '" role="button" tabindex="0" style="grid-column:' + (a + 2) + " / " + (b + 3) + ";grid-row:" + (row + 1) + '" aria-label="' + esc(e.title + ", all day" + (range ? ", " + range : "")) + '">' +
        (e.cal === "Lisbon" ? icon("plane", 12) : "") + '<b class="bt">' + esc(e.title) + "</b>" + (range ? " <span>" + range + "</span>" : "") + "</div>";
    });
    $("#allday").innerHTML = allday;

    // The grid: hours, columns, events, now.
    var html = '<div class="hours">';
    for (var h = 1; h < 24; h++) html += '<span style="top:' + h * HOUR + 'px">' + fmtHour.format(at(now, h)).replace(" ", " ") + "</span>";
    html += '</div><div class="lines">';
    for (h = 0; h < 24; h++) html += "<div></div>";
    html += "</div>";
    list.forEach(function (d, i) {
      var cls = "col" + (sameDay(d, now) ? " today" : d.getDay() % 6 === 0 ? " weekend" : "");
      html += '<div class="' + cls + '" style="grid-column:' + (i + 2) + '" data-day="' + i + '">' + column(d, shown, now) + "</div>";
    });
    $("#grid").innerHTML = html;
    placeNow();

    mini();
    calendars();
    dimSearch();
    if (firstScroll) {
      firstScroll = false;
      // The working day in view, from eight, unless now (or the next
      // meeting) would fall off its foot.
      var scroller = $("#scroll");
      var visible = (scroller.clientHeight - $(".head").offsetHeight) / HOUR * 60;
      var mark = now.getHours() * 60 + now.getMinutes();
      if (meeting && meeting.start > now && meeting.start - now < 3 * 60 * MIN && sameDay(meeting.start, now)) {
        mark = Math.max(mark, meeting.start.getHours() * 60 + meeting.start.getMinutes() + 30);
      }
      var top = 8 * 60;
      if (mark > top + visible - 90) top = mark - visible + 120;
      if (now.getHours() < 8) top = Math.max(0, now.getHours() * 60 - 60);
      scroller.scrollTop = Math.max(0, (top / 60) * HOUR);
    }
    tick();
  }

  // One day's timed events, side by side where they overlap.
  function column(d, shown, now) {
    var from = dayStart(d), to = addDays(from, 1);
    var items = shown.filter(function (e) { return !e.all && e.start < to && e.end > from; }).map(function (e) {
      var s = Math.max(e.start, from), t = Math.min(e.end, to);
      return { e: e, s: (s - from) / MIN, t: (t - from) / MIN };
    }).sort(function (a, b) { return a.s - b.s || b.t - a.t; });
    var groups = [], cur = null, end = -1;
    items.forEach(function (it) {
      var shown15 = Math.max(it.t, it.s + 20);
      if (!cur || it.s >= end) { cur = []; groups.push(cur); end = shown15; }
      cur.push(it);
      end = Math.max(end, shown15);
    });
    var out = "";
    groups.forEach(function (g) {
      var cols = [];
      g.forEach(function (it) {
        var c = 0;
        while (cols[c] && cols[c] > it.s) c++;
        cols[c] = Math.max(it.t, it.s + 20);
        it.c = c;
      });
      var n = cols.length;
      g.forEach(function (it) {
        var e = it.e;
        // 1px clear of the hour lines above and below, 4px clear of the column's sides.
        var top = (it.s / 60) * HOUR + 1;
        var height = Math.max(20, ((it.t - it.s) / 60) * HOUR - 2);
        var left = (it.c / n) * 100, width = (1 / n) * 100;
        var block = height >= 44;
        var cls = "ev" + (height < 24 ? " tiny" : !block ? " short" : "") + (e.end <= now ? " past" : "");
        var time = !block ? clock(e.start) : span(e.start, e.end);
        var label = e.title + ", " + span(e.start, e.end) + (e.people.length ? ", with " + e.people.join(", ") : "") + (e.where ? ", " + e.where : "");
        var lines = Math.max(1, Math.floor((height - 8 - 16) / 16));
        out += '<div class="' + cls + '" data-cal="' + e.cal + '" data-id="' + e.id + '" role="button" tabindex="0" aria-label="' + esc(label) + '" ' +
          'style="top:' + top.toFixed(1) + "px;height:" + height.toFixed(1) + "px;left:calc(" + left + "% + 4px);width:calc(" + width + "% - 8px);--lines:" + lines + '">' +
          '<div class="t">' + esc(!block ? e.title.split(" \u00b7 ")[0] : e.title) + '</div><div class="tm">' + time + (e.link && block ? icon("video", 12) : "") + "</div></div>";
      });
    });
    return out;
  }

  function placeNow() {
    var grid = $("#grid");
    grid.querySelectorAll(".now, .now-faint, .now-label").forEach(function (n) { n.remove(); });
    var now = new Date();
    var list = days();
    var idx = -1;
    list.forEach(function (d, i) { if (sameDay(d, now)) idx = i; });
    var y = TOP + ((now.getHours() * 60 + now.getMinutes() + now.getSeconds() / 60) / 60) * HOUR;
    var n = list.length;
    if (idx < 0) return;
    grid.insertAdjacentHTML("beforeend",
      '<div class="now-faint" style="top:' + y.toFixed(1) + 'px;left:var(--gutter);right:0"></div>' +
      '<div class="now" style="top:' + y.toFixed(1) + "px;left:calc(var(--gutter) + (100% - var(--gutter)) * " + idx + " / " + n + ");width:calc((100% - var(--gutter)) / " + n + ')"></div>' +
      '<div class="now-label" style="top:' + y.toFixed(1) + 'px">' + clock(now, false).replace(/\s?[AP]M$/, "") + "</div>");
    // The hour label under the now label steps aside.
    grid.querySelectorAll(".hours span").forEach(function (s) {
      var top = parseFloat(s.style.top) + TOP;
      s.style.visibility = Math.abs(top - y) < 16 ? "hidden" : "";
    });
  }

  /* ---------------------------------------------------------------- sidebar */

  function mini() {
    var m = view.month;
    var first = new Date(m.getFullYear(), m.getMonth(), 1);
    var start = monday(first);
    var now = new Date();
    var weekA = dayStart(view.start), weekB = addDays(weekA, view.mode === "day" ? 1 : 7);
    var busy = {};
    events.forEach(function (e) { if (!hidden[e.cal]) busy[dayStart(e.start).getTime()] = true; });
    var html = '<div class="mini-head"><b>' + fmtMonth.format(first) + " " + first.getFullYear() + "</b>" +
      '<button class="icon-btn" type="button" data-m="-1" aria-label="Previous month">' + icon("left", 16) + "</button>" +
      '<button class="icon-btn" type="button" data-m="1" aria-label="Next month">' + icon("right", 16) + "</button></div>" +
      '<div class="mini-grid">' + ["M", "T", "W", "T", "F", "S", "S"].map(function (x) { return '<div class="dow">' + x + "</div>"; }).join("");
    for (var i = 0; i < 42; i++) {
      var d = addDays(start, i);
      if (i >= 35 && d.getMonth() !== m.getMonth()) break;
      var inWeek = d >= weekA && d < weekB;
      var cls = [d.getMonth() !== m.getMonth() ? "out" : "", sameDay(d, now) ? "today" : "", inWeek ? "wk" : "",
        inWeek && (d.getTime() === weekA.getTime()) ? "first" : "", inWeek && addDays(d, 1).getTime() === weekB.getTime() ? "last" : "",
        busy[d.getTime()] ? "has" : ""].filter(Boolean).join(" ");
      html += '<button type="button" class="' + cls + '" data-d="' + d.getTime() + '"><span>' + d.getDate() + "</span></button>";
    }
    $("#mini").innerHTML = html + "</div>";
  }

  function calendars() {
    var groups = [[["work", "home"], "My calendars"], [["shared"], "Other calendars"]];
    $("#cals").innerHTML = groups.map(function (g) {
      return '<div class="group"><h6>' + esc(g[1]) + "</h6>" + CALS.filter(function (c) { return g[0].indexOf(c.account) >= 0; }).map(function (c) {
        return '<button type="button" class="cal-row' + (hidden[c.key] ? " off" : "") + '" data-cal="' + c.key + '" data-toggle="' + c.key + '" aria-pressed="' + !hidden[c.key] + '">' +
          '<span class="box" style="--c:var(--' + c.key.toLowerCase() + ')">' + icon("check", 12) + "</span>" + esc(c.name) +
          "<em>" + esc(c.account === "work" ? me.work.split("@")[1] : c.account === "home" ? me.home.split("@")[1] : "Anna Ek") + "</em></button>";
      }).join("") + "</div>";
    }).join("");
  }

  /* ---------------------------------------------------------------- popover */

  var pop = $("#pop");
  var openId = null;
  function openPop(id, anchor) {
    var e = events.filter(function (x) { return x.id === id; })[0];
    if (!e) return;
    document.querySelectorAll(".ev.sel").forEach(function (x) { x.classList.remove("sel"); });
    if (anchor.classList.contains("ev")) anchor.classList.add("sel");
    openId = id;
    var now = new Date();
    var wait = e.start - now;
    var chip = "";
    if (!e.all && e.end > now) {
      if (wait > MIN && wait < 24 * 60 * MIN) chip = '<span class="chip">in ' + until(wait) + "</span>";
      else if (wait <= MIN) chip = '<span class="chip go">Now</span>';
    }
    var lastDay = e.end.getHours() === 0 && e.end.getMinutes() === 0 ? addDays(e.end, -1) : e.end;
    var when = e.all && !sameDay(e.start, lastDay) ? fmtDay.format(e.start) + " \u2192 " + fmtShort.format(lastDay) : fmtDay.format(e.start);
    var people = e.people.slice();
    var heading = titled(e.title);
    var html = '<div class="p-top" data-cal="' + e.cal + '"><span class="sq"></span><h2>' + heading + "</h2>" +
      '<div class="tools"><button class="icon-btn" type="button" aria-label="Edit">' + icon("edit", 16) + '</button><button class="icon-btn" type="button" aria-label="Delete">' + icon("trash", 16) + '</button><button class="icon-btn" type="button" data-close aria-label="Close">' + icon("x", 16) + "</button></div></div>";
    html += '<div class="rowp">' + icon("clock", 16) + "<div><b>" + esc(when) + '</b><div class="line">' + (e.all ? '<span class="sub">All day</span>' : '<span class="sub">' + span(e.start, e.end) + "</span>" + chip) + "</div></div></div>";
    if (e.link) {
      var live = wait <= MIN && e.end > now;
      html += '<div class="joinrow"><a class="join-big' + (live ? " go" : "") + '" href="' + esc(e.link) + '" target="_blank" rel="noopener">' + icon("video", 16) + "Join with Roundtable</a>" +
        '<span class="link" title="' + esc(e.link) + '">' + esc(e.link.replace(/^https?:\/\//, "")) + "</span>" +
        '<button class="icon-btn" type="button" data-copy="' + esc(e.link) + '" aria-label="Copy link">' + icon("copy", 16) + "</button></div>";
    }
    if (e.where && e.where !== "Roundtable") html += '<div class="rowp">' + icon("pin", 16) + "<div>" + esc(e.where) + "</div></div>";
    if (people.length) {
      var guests = people.length + 1;
      html += '<div class="rowp">' + icon("people", 16) + '<div style="flex:1;min-width:0"><b>' + (/^everyone/i.test(people[0]) ? "Everyone at Tern" : guests + " guests") + "</b>" +
        '<div class="people">' + people.map(function (p) {
          return '<div class="person">' + face(p, 24) + '<span class="nm">' + esc(p) + '</span><span class="st">' + (/^everyone/i.test(p) ? "11 people" : "Going") + "</span></div>";
        }).join("") + '<div class="person">' + face(me.name, 24) + '<span class="nm">' + esc(me.name) + '</span><span class="st">You</span></div></div></div></div>';
    }
    var calName = (CALS.filter(function (c) { return c.key === e.cal; })[0] || {}).name || e.cal;
    var owner = e.cal === "Work" ? me.work : e.cal === "Launch" ? "shared by Anna Ek" : me.home;
    html += '<div class="rowp">' + icon("cal", 16) + "<div>" + esc(calName) + ' <span class="sub">· ' + esc(owner) + "</span></div></div>";
    if (e.desc) html += '<div class="desc">' + esc(e.desc) + "</div>";
    if (people.length && !e.all) {
      html += '<div class="rsvp">Going?<div class="seg"><button type="button" class="on">Yes</button><button type="button">No</button><button type="button">Maybe</button></div></div>';
    }
    pop.innerHTML = html;
    pop.querySelector(".p-top").style.setProperty("--c", "var(--" + e.cal.toLowerCase() + ")");

    // Beside the event, inside the calendar.
    var box = $("#cal").getBoundingClientRect();
    var r = anchor.getBoundingClientRect();
    pop.style.left = "0px";
    pop.style.top = "0px";
    pop.classList.add("open");
    var pw = pop.offsetWidth, ph = pop.offsetHeight;
    // 8px from the event, 16px clear of the calendar's edges, never over the bar.
    var x = r.right - box.left + 8;
    if (x + pw > box.width - 16) x = r.left - box.left - pw - 8;
    if (x < 16) x = Math.min(box.width - pw - 16, Math.max(16, r.left - box.left));
    var y = Math.min(Math.max(r.top - box.top, 64), box.height - ph - 16);
    if (anchor.classList.contains("bar-ev")) {
      // Under an all-day bar, from where it starts in view.
      x = Math.max(16, Math.min(r.left - box.left, box.width - pw - 16));
      y = r.bottom - box.top + 8;
    }
    pop.style.left = Math.round(x) + "px";
    pop.style.top = Math.round(y) + "px";
    pop.style.transformOrigin = (x > r.left - box.left ? "left" : "right") + " top";
  }
  function closePop() {
    pop.classList.remove("open");
    openId = null;
    document.querySelectorAll(".ev.sel").forEach(function (x) { x.classList.remove("sel"); });
  }

  /* ---------------------------------------------------------------- input */

  function go(days) {
    view.start = addDays(view.start, days);
    view.month = new Date(view.start.getFullYear(), view.start.getMonth(), 1);
    closePop();
    render();
  }
  function today() {
    var now = new Date();
    view.start = view.mode === "day" ? dayStart(now) : monday(now);
    view.month = dayStart(now);
    closePop();
    firstScroll = true;
    render();
  }
  function setMode(mode) {
    var now = new Date();
    var anchor = view.mode === "week" && now >= view.start && now < addDays(view.start, 7) ? dayStart(now) : view.start;
    view.mode = mode;
    view.start = mode === "day" ? dayStart(anchor) : monday(anchor);
    document.querySelectorAll("#views button").forEach(function (b) { b.classList.toggle("on", b.getAttribute("data-v") === mode); });
    closePop();
    render();
  }

  document.addEventListener("click", function (ev) {
    var t = ev.target;
    if (t.closest(".soon.go")) return;
    var item = t.closest(".ev, .bar-ev");
    if (item) {
      ev.preventDefault();
      if (openId === item.getAttribute("data-id")) closePop();
      else openPop(item.getAttribute("data-id"), item);
      return;
    }
    if (t.closest("[data-close]")) { closePop(); return; }
    var copy = t.closest("[data-copy]");
    if (copy) {
      if (navigator.clipboard) navigator.clipboard.writeText(copy.getAttribute("data-copy")).catch(function () {});
      copy.innerHTML = icon("check", 16);
      setTimeout(function () { copy.innerHTML = icon("copy", 16); }, 1200);
      return;
    }
    var rsvp = t.closest(".rsvp .seg button");
    if (rsvp) {
      rsvp.parentNode.querySelectorAll("button").forEach(function (b) { b.classList.toggle("on", b === rsvp); });
      return;
    }
    if (!t.closest(".pop")) closePop();
    var toggle = t.closest("[data-toggle]");
    if (toggle) {
      var k = toggle.getAttribute("data-toggle");
      hidden[k] = !hidden[k];
      render();
      return;
    }
    var m = t.closest("[data-m]");
    if (m) {
      view.month = new Date(view.month.getFullYear(), view.month.getMonth() + +m.getAttribute("data-m"), 1);
      mini();
      return;
    }
    var d = t.closest("[data-d]");
    if (d) {
      var day = new Date(+d.getAttribute("data-d"));
      view.start = view.mode === "day" ? day : monday(day);
      render();
      return;
    }
    var v = t.closest("#views button");
    if (v) { setMode(v.getAttribute("data-v")); return; }
    if (t.closest("#find")) { openFind(); return; }
    if (t.closest("#go-today")) { today(); return; }
    if (t.closest("#go-prev")) { go(view.mode === "day" ? -1 : -7); return; }
    if (t.closest("#go-next")) { go(view.mode === "day" ? 1 : 7); return; }
  });
  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
    if (e.key === "Escape") closePop();
    else if (e.key === "t" || e.key === "T") today();
    else if (e.key === "ArrowLeft" || e.key === "k" || e.key === "p") go(view.mode === "day" ? -1 : -7);
    else if (e.key === "ArrowRight" || e.key === "j" || e.key === "n") go(view.mode === "day" ? 1 : 7);
    else if (e.key === "d") setMode("day");
    else if (e.key === "w") setMode("week");
    else if ((e.key === "Enter" || e.key === " ") && t && t.matches && t.matches(".ev, .bar-ev")) { e.preventDefault(); openPop(t.getAttribute("data-id"), t); }
  });
  $("#scroll").addEventListener("scroll", function () { if (openId) closePop(); }, { passive: true });
  window.addEventListener("resize", function () { if (openId) closePop(); });

  /* ---------------------------------------------------------------- search */

  var query = "";
  function openFind() {
    var brand = $(".brand");
    if (brand.querySelector("input")) return;
    brand.insertAdjacentHTML("beforeend", '<label class="find-box">' + icon("search", 16) + '<input id="q" type="text" placeholder="Search events" autocomplete="off" spellcheck="false"><kbd>esc</kbd></label>');
    var q = $("#q");
    q.focus();
    q.addEventListener("input", function () { query = q.value.trim().toLowerCase(); dimSearch(); });
    q.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { e.stopPropagation(); closeFind(); }
      if (e.key === "Enter") {
        var hit = events.filter(function (x) { return query && !x.all && x.title.toLowerCase().indexOf(query) >= 0 && x.end > new Date(); })[0];
        if (hit) { view.start = view.mode === "day" ? dayStart(hit.start) : monday(hit.start); render(); }
      }
    });
  }
  function closeFind() {
    var box = document.querySelector(".find-box");
    if (box) box.remove();
    query = "";
    dimSearch();
  }
  function dimSearch() {
    document.querySelectorAll(".ev, .bar-ev").forEach(function (el) {
      var e = events.filter(function (x) { return x.id === el.getAttribute("data-id"); })[0];
      el.classList.toggle("miss", !!query && !!e && (e.title + " " + e.people.join(" ") + " " + e.where).toLowerCase().indexOf(query) < 0);
    });
  }

  /* ---------------------------------------------------------------- clock */

  icons();
  load();
  setInterval(tick, 1000);
  var lastMinute = new Date().getMinutes();
  var lastDay = new Date().getDate();
  setInterval(function () {
    var now = new Date();
    if (now.getDate() !== lastDay) { lastDay = now.getDate(); render(); return; }
    if (now.getMinutes() !== lastMinute) {
      lastMinute = now.getMinutes();
      // Gone events fade, the now line moves; the open popover stays.
      document.querySelectorAll(".ev").forEach(function (el) {
        var e = events.filter(function (x) { return x.id === el.getAttribute("data-id"); })[0];
        if (e) el.classList.toggle("past", e.end <= now);
      });
      placeNow();
    }
  }, 5000);
})();
