(function () {
  "use strict";

  var NS = "http://www.w3.org/2000/svg";
  var css = getComputedStyle(document.documentElement);
  var token = function (name) { return css.getPropertyValue(name).trim(); };
  var BRAND = token("--brand") || "#f0532a";
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var DAY = 86400000;

  function el(name, attrs, parent) {
    var node = document.createElementNS(NS, name);
    for (var key in attrs) node.setAttribute(key, attrs[key]);
    if (parent) parent.appendChild(node);
    return node;
  }
  function fmt(n) { return Math.round(n).toLocaleString("en-US"); }
  function short(n) { return n >= 1000 ? (n / 1000).toFixed(n % 1000 ? 1 : 0).replace(/\.0$/, "") + "k" : String(n); }
  function day(d) { return MONTHS[d.getMonth()] + " " + d.getDate(); }

  // Weeks start on Monday; the last one is this week.
  var today = new Date();
  today.setHours(0, 0, 0, 0);
  var monday = new Date(today.getTime() - ((today.getDay() + 6) % 7) * DAY);
  function week(back) { return new Date(monday.getTime() - back * 7 * DAY); }
  var weeks = [];
  for (var w = 11; w >= 0; w--) weeks.push(week(w));
  var range = document.getElementById("range");
  if (range) range.textContent = day(weeks[0]) + " to " + day(new Date(monday.getTime() + 6 * DAY));

  // A smooth line that never overshoots its points.
  function smooth(pts) {
    var n = pts.length, d = [], m = [], i;
    for (i = 0; i < n - 1; i++) d.push((pts[i + 1][1] - pts[i][1]) / (pts[i + 1][0] - pts[i][0]));
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
    for (i = 0; i < n - 1; i++) {
      if (d[i] === 0) { m[i] = m[i + 1] = 0; continue; }
      var a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b;
      if (s > 9) { var t = 3 / Math.sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]; }
    }
    var out = "M" + pts[0][0].toFixed(1) + " " + pts[0][1].toFixed(1);
    for (i = 0; i < n - 1; i++) {
      var h = (pts[i + 1][0] - pts[i][0]) / 3;
      out += " C" + (pts[i][0] + h).toFixed(1) + " " + (pts[i][1] + m[i] * h).toFixed(1) + " " +
        (pts[i + 1][0] - h).toFixed(1) + " " + (pts[i + 1][1] - m[i + 1] * h).toFixed(1) + " " +
        pts[i + 1][0].toFixed(1) + " " + pts[i + 1][1].toFixed(1);
    }
    return out;
  }

  function scale(lo, hi, count) {
    var raw = (hi - lo) / count;
    var mag = Math.pow(10, Math.floor(Math.log10(raw)));
    var norm = raw / mag;
    var step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
    var a = Math.floor(lo / step) * step, b = Math.ceil(hi / step) * step, ticks = [];
    for (var v = a; v <= b + step / 2; v += step) ticks.push(v);
    return { lo: a, hi: b, ticks: ticks };
  }

  // Weekly active users, this period over the one before.
  var WAU = [3590, 3680, 3750, 3720, 3890, 3960, 4050, 4190, 4260, 4180, 4415, 4812];
  var PREV = [3020, 3090, 3160, 3110, 3240, 3300, 3280, 3390, 3450, 3500, 3540, 3590];

  function lineChart(box) {
    box.innerHTML = "";
    var W = box.clientWidth, H = box.clientHeight;
    var s = scale(Math.min.apply(null, PREV), Math.max.apply(null, WAU), 4);
    var svg = el("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Weekly active users, last 12 weeks" }, box);
    // The widest value label starts on the panel's edge; the plot 8 after it.
    var widest = 0;
    s.ticks.forEach(function (t) {
      var probe = el("text", {}, svg);
      probe.textContent = short(t);
      widest = Math.max(widest, probe.getComputedTextLength());
      probe.remove();
    });
    widest = Math.ceil(widest);
    var pad = { l: widest + 8, r: 6, t: 32, b: 24 };
    var x = function (i) { return pad.l + (W - pad.l - pad.r) * i / (WAU.length - 1); };
    var y = function (v) { return pad.t + (H - pad.t - pad.b) * (1 - (v - s.lo) / (s.hi - s.lo)); };
    var defs = el("defs", {}, svg);
    var grad = el("linearGradient", { id: "wau-fill", x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
    el("stop", { offset: 0, "stop-color": BRAND, "stop-opacity": 0.18 }, grad);
    el("stop", { offset: 1, "stop-color": BRAND, "stop-opacity": 0 }, grad);

    s.ticks.forEach(function (t, i) {
      el("line", { x1: pad.l, x2: W - pad.r, y1: y(t), y2: y(t), "class": i ? "grid-line" : "axis" }, svg);
      el("text", { x: widest, y: y(t) + 4, "text-anchor": "end" }, svg).textContent = short(t);
    });
    weeks.forEach(function (d, i) {
      if (i % 2 && i !== weeks.length - 1) return;
      if (i === weeks.length - 2) return;
      var anchor = i === 0 ? "start" : i === weeks.length - 1 ? "end" : "middle";
      el("text", { x: x(i), y: H - 4, "text-anchor": anchor }, svg).textContent = day(d);
    });

    // Tern 2.0's beta opened three weeks ago.
    var fx = x(9);
    var flag = el("g", { "class": "flag" }, svg);
    el("line", { x1: fx, x2: fx, y1: 20, y2: H - pad.b }, flag);
    el("rect", { x: fx - 46, y: 0, width: 92, height: 20, rx: 4 }, flag);
    el("text", { x: fx, y: 14, "text-anchor": "middle" }, flag).textContent = "2.0 beta opens";

    var cur = WAU.map(function (v, i) { return [x(i), y(v)]; });
    var prev = PREV.map(function (v, i) { return [x(i), y(v)]; });
    var line = smooth(cur);
    el("path", { d: line + " L" + x(WAU.length - 1) + " " + (H - pad.b) + " L" + pad.l + " " + (H - pad.b) + " Z", fill: "url(#wau-fill)" }, svg);
    el("path", { d: smooth(prev), "class": "line prev" }, svg);
    el("path", { d: line, "class": "line" }, svg);

    var cross = el("line", { "class": "cross", y1: pad.t - 6, y2: H - pad.b, visibility: "hidden" }, svg);
    var dotPrev = el("circle", { r: 3.5, "class": "pt prev", visibility: "hidden" }, svg);
    var dot = el("circle", { r: 4.5, "class": "pt" }, svg);
    var tip = document.createElement("div");
    tip.className = "tooltip";
    box.appendChild(tip);

    function show(i, hover) {
      dot.setAttribute("cx", cur[i][0]);
      dot.setAttribute("cy", cur[i][1]);
      [cross, dotPrev].forEach(function (n) { n.setAttribute("visibility", hover ? "visible" : "hidden"); });
      if (!hover) { tip.classList.remove("on"); return; }
      cross.setAttribute("x1", cur[i][0]);
      cross.setAttribute("x2", cur[i][0]);
      dotPrev.setAttribute("cx", prev[i][0]);
      dotPrev.setAttribute("cy", prev[i][1]);
      var change = (WAU[i] / PREV[i] - 1) * 100;
      tip.innerHTML = "<h4>Week of " + day(weeks[i]) + "</h4>" +
        "<div><span><i></i>This period</span><b>" + fmt(WAU[i]) + "</b></div>" +
        "<div><span><i class=prev></i>Previous</span><b>" + fmt(PREV[i]) + "</b></div>" +
        "<div><span>Change</span><b class=up>+" + change.toFixed(1) + "%</b></div>";
      var left = cur[i][0] + 16;
      if (left + 190 > W) left = cur[i][0] - 16 - tip.offsetWidth;
      tip.style.transform = "translate(" + left + "px," + Math.max(0, cur[i][1] - 60) + "px)";
      tip.classList.add("on");
    }
    show(WAU.length - 1, false);
    var hit = el("rect", { x: pad.l, y: 0, width: W - pad.l - pad.r, height: H, fill: "transparent" }, svg);
    hit.addEventListener("mousemove", function (e) {
      var r = svg.getBoundingClientRect();
      var i = Math.round((e.clientX - r.left - pad.l) / (W - pad.l - pad.r) * (WAU.length - 1));
      show(Math.max(0, Math.min(WAU.length - 1, i)), true);
    });
    hit.addEventListener("mouseleave", function () { show(WAU.length - 1, false); });
  }

  function sparkline(svg) {
    var values = svg.getAttribute("data-spark").split(",").map(Number);
    var W = svg.clientWidth || 260, H = svg.clientHeight || 48;
    var lo = Math.min.apply(null, values), hi = Math.max.apply(null, values);
    var pts = values.map(function (v, i) {
      return [W * i / (values.length - 1), 6 + (H - 10) * (1 - (v - lo) / (hi - lo || 1))];
    });
    var color = svg.getAttribute("data-tone") === "down" ? (token("--text-3") || "#9a9ea6") : BRAND;
    var id = "sp" + Math.random().toString(36).slice(2, 8);
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.innerHTML = "";
    var g = el("linearGradient", { id: id, x1: 0, y1: 0, x2: 0, y2: 1 }, el("defs", {}, svg));
    el("stop", { offset: 0, "stop-color": color, "stop-opacity": 0.16 }, g);
    el("stop", { offset: 1, "stop-color": color, "stop-opacity": 0 }, g);
    var line = smooth(pts);
    el("path", { d: line + " L" + W + " " + H + " L0 " + H + " Z", fill: "url(#" + id + ")" }, svg);
    el("path", { d: line, fill: "none", stroke: color, "stroke-width": 1.8, "stroke-linecap": "round", "vector-effect": "non-scaling-stroke" }, svg);
  }

  // Booking retention by the week of the first booking.
  var COHORTS = [
    [104, [100, 58.7, 49.0, 45.2, 42.3, 41.3, 40.4, 39.4]],
    [112, [100, 60.7, 51.8, 46.4, 43.8, 42.0, 41.1]],
    [109, [100, 59.6, 50.5, 47.7, 44.0, 43.1]],
    [121, [100, 62.8, 53.7, 48.8, 46.3]],
    [118, [100, 63.6, 55.1, 50.0]],
    [127, [100, 65.4, 56.7]],
    [131, [100, 66.4]],
    [138, [100]]
  ];
  function retention(table) {
    var cell = function (v) {
      var a = 0.07 + (v / 100) * 0.86;
      return "<td class='v" + (a > 0.6 ? " dark" : "") + "' style='--a:" + a.toFixed(2) + "'>" + (v === 100 ? "100%" : v.toFixed(1) + "%") + "</td>";
    };
    var head = "<tr><th>Cohort</th>";
    for (var k = 0; k < 8; k++) head += "<th>Week " + k + "</th>";
    var rows = head + "</tr>";
    var total = COHORTS.reduce(function (s, c) { return s + c[0]; }, 0);
    rows += "<tr><td>All cohorts<small>" + fmt(total) + " people</small></td>";
    for (k = 0; k < 8; k++) {
      var people = 0, kept = 0;
      COHORTS.forEach(function (c) { if (c[1].length > k) { people += c[0]; kept += c[0] * c[1][k]; } });
      rows += cell(Math.round(kept / people * 10) / 10);
    }
    rows += "</tr>";
    COHORTS.forEach(function (c, i) {
      rows += "<tr><td>" + day(week(8 - i)) + "<small>" + fmt(c[0]) + " people</small></td>";
      for (var j = 0; j < 8; j++) rows += j < c[1].length ? cell(c[1][j]) : "<td class='none'></td>";
      rows += "</tr>";
    });
    table.innerHTML = rows;
  }

  var EVENTS = [
    ["slot_offered", 61240, 7.2],
    ["booking_created", 11873, 9.6],
    ["focus_block_protected", 8415, 34.0, true],
    ["reschedule_clicked", 1932, -2.1],
    ["calendar_connected", 1108, 5.3],
    ["invite_sent", 466, 4.1]
  ];
  function events(list) {
    var top = EVENTS[0][1];
    list.innerHTML = EVENTS.map(function (e) {
      var up = e[2] >= 0;
      var arrow = up ? "M6 9.5v-7M3 5l3-3 3 3" : "M6 2.5v7M3 7l3 3 3-3";
      return "<li><div class='ev'><code>" + e[0] + (e[3] ? "<span class='new-tag'>2.0</span>" : "") + "</code>" +
        "<i style='--w:" + (Math.sqrt(e[1] / top) * 100).toFixed(1) + "%'></i></div><b>" + fmt(e[1]) + "</b>" +
        "<span class='delta " + (up ? "up" : "down") + "'><svg viewBox='0 0 12 12'><path d='" + arrow + "'/></svg>" +
        Math.abs(e[2]).toFixed(1) + "%</span></li>";
    }).join("");
  }

  function draw() {
    var wau = document.getElementById("wau");
    if (wau) lineChart(wau);
    document.querySelectorAll("[data-spark]").forEach(sparkline);
  }
  draw();
  var ret = document.getElementById("ret");
  if (ret) retention(ret);
  var list = document.getElementById("events");
  if (list) events(list);
  var timer;
  window.addEventListener("resize", function () { clearTimeout(timer); timer = setTimeout(draw, 60); });

  // Segmented controls pick one.
  document.querySelectorAll(".seg").forEach(function (seg) {
    seg.addEventListener("click", function (e) {
      var b = e.target.closest("button");
      if (!b) return;
      seg.querySelectorAll("button").forEach(function (o) { o.classList.toggle("on", o === b); });
    });
  });

  // The account menu.
  var me = document.getElementById("me");
  var menu = document.getElementById("me-menu");
  if (me && menu) {
    me.addEventListener("click", function (e) {
      e.stopPropagation();
      var open = menu.hidden;
      menu.hidden = !open;
      me.setAttribute("aria-expanded", String(open));
    });
    document.addEventListener("click", function (e) {
      if (!menu.hidden && !menu.contains(e.target)) { menu.hidden = true; me.setAttribute("aria-expanded", "false"); }
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !menu.hidden) { menu.hidden = true; me.setAttribute("aria-expanded", "false"); me.focus(); }
    });
  }
})();
