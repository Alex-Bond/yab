/* Overview: KPIs, the revenue chart, recent payments, the failed payment banner. */
(function () {
  "use strict";
  var L = window.L;
  var $ = function (s) { return document.querySelector(s); };
  L.icons();

  // Greeting by the local hour.
  var hour = new Date(L.now).getHours();
  var part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
  $("#hello").textContent = part + ", Mira. Here is how Tern Labs is doing.";
  $("#lcard-mark").outerHTML = L.mark(20);

  // Next business day for the payout.
  var payout = new Date(L.now);
  payout.setDate(payout.getDate() + 2);
  while (payout.getDay() === 0 || payout.getDay() === 6) payout.setDate(payout.getDate() + 1);
  $("#payout-day").textContent = L.date(payout);

  /* ---------------------------------------------------------------- sparklines */

  var churn = [2.62, 2.58, 2.6, 2.49, 2.44, 2.36, 2.33, 2.27, 2.18, 2.14, 2.2, 1.9];
  var sparks = { mrr: L.mrr, subs: L.subs, churn: churn, volume: L.volume };
  document.querySelectorAll("[data-spark]").forEach(function (svg) {
    var key = svg.getAttribute("data-spark");
    var data = sparks[key];
    var min = Math.min.apply(null, data), max = Math.max.apply(null, data);
    var pts = data.map(function (v, i) {
      return [(i / (data.length - 1)) * 94 + 1, 33 - ((v - min) / (max - min || 1)) * 28];
    });
    var color = "currentColor";
    var line = path(pts);
    var id = "sg-" + key;
    svg.innerHTML =
      '<defs><linearGradient id="' + id + '" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + color + '" stop-opacity=".22"/><stop offset="1" stop-color="' + color + '" stop-opacity="0"/></linearGradient></defs>' +
      '<path d="' + line + " L95,36 L1,36 Z" + '" fill="url(#' + id + ')"/>' +
      '<path d="' + line + '" fill="none" stroke="' + color + '" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>';
  });

  /* ---------------------------------------------------------------- chart */

  // Monotone cubic through the points: smooth, never overshooting a month.
  function path(pts) {
    var n = pts.length, i;
    if (n < 2) return "";
    var dx = [], m = [], t = [];
    for (i = 0; i < n - 1; i++) {
      dx[i] = pts[i + 1][0] - pts[i][0];
      m[i] = (pts[i + 1][1] - pts[i][1]) / dx[i];
    }
    t[0] = m[0];
    t[n - 1] = m[n - 2];
    for (i = 1; i < n - 1; i++) {
      if (m[i - 1] * m[i] <= 0) t[i] = 0;
      else t[i] = (3 * (dx[i - 1] + dx[i])) / ((2 * dx[i] + dx[i - 1]) / m[i - 1] + (dx[i] + 2 * dx[i - 1]) / m[i]);
    }
    var d = "M" + r(pts[0][0]) + "," + r(pts[0][1]);
    for (i = 0; i < n - 1; i++) {
      var h = dx[i] / 3;
      d += " C" + r(pts[i][0] + h) + "," + r(pts[i][1] + t[i] * h) + " " + r(pts[i + 1][0] - h) + "," + r(pts[i + 1][1] - t[i + 1] * h) + " " + r(pts[i + 1][0]) + "," + r(pts[i + 1][1]);
    }
    return d;
  }
  function r(v) { return Math.round(v * 10) / 10; }

  function niceStep(max, count) {
    var raw = max / count;
    var pow = Math.pow(10, Math.floor(Math.log10(raw)));
    var n = raw / pow;
    return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * pow;
  }

  var monthLong = new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric" });
  var monthShort = new Intl.DateTimeFormat("en-US", { month: "short" });
  var monthName = new Intl.DateTimeFormat("en-US", { month: "long" });

  // New, expansion and churned MRR behind each month's change.
  var moves = L.mrr.map(function (v, i) {
    var prev = i ? L.mrr[i - 1] : 29140;
    var churned = Math.round(prev * 0.015);
    var expansion = Math.round((v - prev + churned) * 0.38);
    return { net: v - prev, churned: churned, expansion: expansion, fresh: v - prev + churned - expansion };
  });

  var SERIES = {
    mrr: {
      label: "Monthly recurring revenue", data: L.mrr, prev: L.mrrPrev,
      big: function (v) { return L.money(v); }, axis: L.short, fmt: L.money0
    },
    subs: {
      label: "Active subscriptions", data: L.subs, prev: L.subsPrev,
      big: function (v) { return L.int(v); }, axis: L.int, fmt: L.int
    },
    volume: {
      label: "Net volume", data: L.volume, prev: L.volumePrev,
      big: function (v) { return L.money(v === 51872 ? 51872.4 : v); }, axis: L.short, fmt: L.money0
    }
  };
  var current = "mrr";
  var chart = $("#chart");
  var tip = $("#tip");
  var drawn = false;

  function header() {
    var s = SERIES[current];
    var n = s.data.length;
    var last = s.data[n - 1], before = s.data[n - 2];
    var pct = ((last - before) / before) * 100;
    $("#chart-label").textContent = s.label;
    $("#chart-value").textContent = s.big(last);
    var delta = $("#chart-delta");
    delta.className = "delta " + (pct >= 0 ? "up" : "down");
    delta.innerHTML = L.icon(pct >= 0 ? "arrowUp" : "arrowDown", 12) + Math.abs(pct).toFixed(1) + "%";
    $("#chart-vs").textContent = "vs " + monthName.format(L.months[n - 2]);

    var foot = $("#chart-foot");
    if (current === "mrr") {
      var mv = moves[n - 1];
      foot.innerHTML =
        '<div><span><i style="background:var(--accent)"></i>New</span><b>+' + L.money0(mv.fresh) + "</b></div>" +
        '<div><span><i style="background:var(--chart-2)"></i>Expansion</span><b>+' + L.money0(mv.expansion) + "</b></div>" +
        '<div><span><i style="background:var(--chart-neg)"></i>Churned</span><b>-' + L.money0(mv.churned) + "</b></div>" +
        '<div><span><i style="background:var(--brand)"></i>Net new MRR</span><b>+' + L.money0(mv.net) + "</b></div>";
    } else if (current === "subs") {
      foot.innerHTML =
        '<div><span><i style="background:var(--accent)"></i>New</span><b>+61</b></div>' +
        '<div><span><i style="background:var(--chart-2)"></i>Reactivated</span><b>+5</b></div>' +
        '<div><span><i style="background:var(--chart-neg)"></i>Canceled</span><b>-24</b></div>' +
        '<div><span><i style="background:var(--brand)"></i>Net change</span><b>+42</b></div>';
    } else {
      foot.innerHTML =
        '<div><span><i style="background:var(--accent)"></i>Gross volume</span><b>$54,120</b></div>' +
        '<div><span><i style="background:var(--chart-2)"></i>Refunds</span><b>-$1,240</b></div>' +
        '<div><span><i style="background:var(--chart-neg)"></i>Fees</span><b>-$1,008</b></div>' +
        '<div><span><i style="background:var(--brand)"></i>Net volume</span><b>$51,872</b></div>';
    }
  }

  // The widest axis label, as the chart's own CSS draws it.
  function measure(texts) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("style", "position:absolute;visibility:hidden");
    var g = document.createElementNS(ns, "g");
    g.setAttribute("class", "axis");
    svg.appendChild(g);
    chart.appendChild(svg);
    var w = 0;
    texts.forEach(function (t) {
      var el = document.createElementNS(ns, "text");
      el.textContent = t;
      g.appendChild(el);
      w = Math.max(w, el.getComputedTextLength());
    });
    svg.remove();
    return w;
  }

  function draw() {
    var s = SERIES[current];
    var W = Math.max(320, chart.clientWidth), H = Math.max(200, chart.clientHeight);
    var all = s.data.concat(s.prev);
    var maxV = Math.max.apply(null, all);
    var step = niceStep(maxV * 1.04, 5);
    var top = Math.ceil((maxV * 1.04) / step) * step;
    var ticks = [];
    for (var tv = 0; tv <= top + 0.5; tv += step) ticks.push(tv === 0 ? (current === "subs" ? "0" : "$0") : s.axis(tv));
    // The y labels end 12px left of the plot and the widest starts at the
    // card's padding; the plot ends at it on the right; x labels sit 8px under.
    var pad = { l: Math.ceil(measure(ticks)) + 12, r: 0, t: 8, b: 24 };
    var iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
    var n = s.data.length;
    var x = function (i) { return pad.l + (i / (n - 1)) * iw; };
    var y = function (v) { return pad.t + ih - (v / top) * ih; };
    var pts = s.data.map(function (v, i) { return [x(i), y(v)]; });
    var prevPts = s.prev.map(function (v, i) { return [x(i), y(v)]; });

    var grid = "";
    for (var v = 0; v <= top + 0.5; v += step) {
      var gy = r(y(v));
      grid += '<line class="' + (v === 0 ? "base-line" : "grid-line") + '" x1="' + pad.l + '" x2="' + (W - pad.r) + '" y1="' + gy + '" y2="' + gy + '"/>';
      grid += '<text x="' + (pad.l - 12) + '" y="' + (gy + 4) + '" text-anchor="end">' + (v === 0 ? (current === "subs" ? "0" : "$0") : s.axis(v)) + "</text>";
    }
    var labels = "";
    L.months.forEach(function (m, i) {
      var anchor = i === 0 ? "start" : i === n - 1 ? "end" : "middle";
      var text = monthShort.format(m);
      if (m.getMonth() === 0) text += " ’" + String(m.getFullYear()).slice(2);
      labels += '<text x="' + r(x(i)) + '" y="' + (H - 4) + '" text-anchor="' + anchor + '">' + text + "</text>";
    });

    var line = path(pts);
    var area = line + " L" + r(x(n - 1)) + "," + r(y(0)) + " L" + r(x(0)) + "," + r(y(0)) + " Z";
    var last = pts[n - 1];
    chart.querySelector("svg") && chart.querySelector("svg").remove();
    chart.insertAdjacentHTML("afterbegin",
      '<svg viewBox="0 0 ' + W + " " + H + '" role="img" aria-label="' + s.label + ' by month">' +
      '<defs><linearGradient id="area" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="currentColor" stop-opacity=".26"/><stop offset=".7" stop-color="currentColor" stop-opacity=".06"/><stop offset="1" stop-color="currentColor" stop-opacity="0"/></linearGradient></defs>' +
      '<g class="axis">' + grid + labels + "</g>" +
      '<path class="line-prev" d="' + path(prevPts) + '"/>' +
      '<g class="' + (drawn ? "" : "reveal") + '"><path d="' + area + '" fill="url(#area)"/><path class="line" d="' + line + '"/></g>' +
      '<g class="hov">' +
      '<line class="guide" x1="0" x2="0" y1="' + pad.t + '" y2="' + (pad.t + ih) + '"/>' +
      '<circle class="dot-prev" r="3.6" cx="-10" cy="-10"/>' +
      '<circle class="halo" r="10" cx="' + r(last[0]) + '" cy="' + r(last[1]) + '"/>' +
      '<circle class="dot" r="4.2" cx="' + r(last[0]) + '" cy="' + r(last[1]) + '"/>' +
      "</g>" +
      '<rect class="hit" x="' + pad.l + '" y="0" width="' + iw + '" height="' + H + '" fill="transparent"/>' +
      "</svg>");
    drawn = true;

    var svg = chart.querySelector("svg");
    var hov = svg.querySelector(".hov");
    var guide = svg.querySelector(".guide");
    var dot = svg.querySelector(".dot");
    var halo = svg.querySelector(".halo");
    var dotPrev = svg.querySelector(".dot-prev");
    var at = function (i) {
      var px = pts[i][0], py = pts[i][1];
      guide.setAttribute("x1", px); guide.setAttribute("x2", px);
      dot.setAttribute("cx", px); dot.setAttribute("cy", py);
      halo.setAttribute("cx", px); halo.setAttribute("cy", py);
      dotPrev.setAttribute("cx", prevPts[i][0]); dotPrev.setAttribute("cy", prevPts[i][1]);
      var v = s.data[i], pv = s.prev[i];
      var yoy = ((v - pv) / pv) * 100;
      var html = '<div class="t-month">' + monthLong.format(L.months[i]) + "</div>" +
        '<div class="t-row"><i></i>' + (current === "mrr" ? "MRR" : current === "subs" ? "Subscriptions" : "Net volume") + "<b>" + s.fmt(v) + "</b></div>" +
        '<div class="t-row"><i class="prev"></i>Year before<b>' + s.fmt(pv) + "</b></div>";
      if (current === "mrr") {
        var mv = moves[i];
        html += "<hr>" +
          '<div class="t-sub">New<b>+' + L.money0(mv.fresh) + "</b></div>" +
          '<div class="t-sub">Expansion<b>+' + L.money0(mv.expansion) + "</b></div>" +
          '<div class="t-sub">Churned<b class="neg">-' + L.money0(mv.churned) + "</b></div>";
      } else {
        html += "<hr>" + '<div class="t-sub">Year over year<b>+' + yoy.toFixed(1) + "%</b></div>";
      }
      tip.innerHTML = html;
      var tw = tip.offsetWidth, th = tip.offsetHeight;
      var left = px + 16;
      if (left + tw > W) left = px - tw - 16;
      var topPx = Math.min(Math.max(py - th / 2, 0), H - th - 24);
      tip.style.transform = "translate(" + Math.round(left) + "px," + Math.round(topPx) + "px)";
    };
    var hit = svg.querySelector(".hit");
    hit.addEventListener("mousemove", function (e) {
      var box = svg.getBoundingClientRect();
      var px = ((e.clientX - box.left) / box.width) * W;
      var i = Math.round(((px - pad.l) / iw) * (n - 1));
      i = Math.max(0, Math.min(n - 1, i));
      svg.classList.add("hover");
      at(i);
      tip.classList.add("show");
    });
    hit.addEventListener("mouseleave", function () {
      svg.classList.remove("hover");
      tip.classList.remove("show");
      dot.setAttribute("cx", last[0]); dot.setAttribute("cy", last[1]);
      halo.setAttribute("cx", last[0]); halo.setAttribute("cy", last[1]);
    });
  }

  document.querySelectorAll("#series button").forEach(function (b) {
    b.addEventListener("click", function () {
      document.querySelectorAll("#series button").forEach(function (o) { o.classList.toggle("on", o === b); });
      current = b.getAttribute("data-series");
      drawn = false;
      header();
      draw();
    });
  });
  header();
  draw();
  var lastW = chart.clientWidth, lastH = chart.clientHeight;
  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      if (chart.clientWidth !== lastW || chart.clientHeight !== lastH) {
        lastW = chart.clientWidth; lastH = chart.clientHeight;
        draw();
      }
    }).observe(chart);
  }

  /* ---------------------------------------------------------------- recent payments */

  var body = $("#recent tbody");
  body.innerHTML = L.payments.slice(0, 8).map(L.paymentRow).join("");

  /* ---------------------------------------------------------------- lists */

  var top = L.customers.slice().sort(function (a, b) { return b.mrr - a.mrr; }).slice(0, 5);
  $("#top-customers").innerHTML = top.map(function (c) {
    return '<div class="li">' + L.logo(c) +
      '<div class="grow"><b>' + L.esc(c.name) + "</b><span>Tern " + c.plan + " · " + c.seats + " seats</span></div>" +
      '<div class="end"><b>' + L.money0(c.mrr) + "</b><span>a month</span></div></div>";
  }).join("");

  // Who moved MRR this month: the emails make this card one to redact.
  $("#this-month").textContent = monthName.format(new Date(L.now));
  $("#moves").innerHTML = L.movements.map(function (m) {
    var c = L.customer(m.customer);
    var pos = m.amount >= 0;
    return '<div class="move">' + L.logo(c) +
      '<div class="m-txt"><b>' + L.esc(c.name) + "</b><span>" + L.esc(c.email) + "</span></div>" +
      '<div class="m-end"><b class="' + (pos ? "pos" : "neg") + '">' + (pos ? "+" : "-") + L.money0(Math.abs(m.amount)) + "</b><span>" + m.kind + "</span></div></div>";
  }).join("");

  // The last two payouts under the next one.
  var paid = [[2, 21304.18], [4, 16872.4]];
  $("#payouts").innerHTML = paid.map(function (p) {
    return '<div class="li"><span class="muted">' + L.date(L.daysFromNow(-p[0])) + "</span>" + L.pill("Paid") +
      '<div class="end"><b>' + L.money(p[1]) + "</b></div></div>";
  }).join("");

  // The last deliveries to Tern's webhook endpoint.
  $("#hooks-mini").innerHTML = [
    ["invoice.paid", "INV-2026-0942 from Vesper Hotels", 41],
    ["customer.subscription.updated", "Vesper Hotels, 150 seats", 64],
    ["invoice.payment_failed", "INV-2026-0941 from Northwind", 300]
  ].map(function (h) {
    return '<div class="li"><span class="code-pill c2">200</span><div class="grow"><b class="mono">' + h[0] + "</b><span>" + h[1] + '</span></div><div class="end"><span>' + L.ago(L.minutesAgo(h[2])) + "</span></div></div>";
  }).join("");
  document.addEventListener("click", function (e) {
    var b = e.target.closest("[data-copy]");
    if (b) L.copy(b.getAttribute("data-copy"), b);
  });

  /* ---------------------------------------------------------------- the failed payment */

  var failed = L.payments.filter(function (p) { return p.customer === "northwind" && p.status === "Failed"; })[0];
  if (failed) $("#failed-ago").textContent = L.ago(failed.at);
  var banner = $("#failed");
  var retry = $("#retry");
  function collapse() {
    banner.classList.add("gone");
    setTimeout(function () {
      banner.style.overflow = "hidden";
      banner.style.height = banner.offsetHeight + "px";
      requestAnimationFrame(function () {
        banner.style.transition = "height .3s ease, margin .3s ease, padding .3s ease, border-width .3s";
        banner.style.height = "0px";
        banner.style.margin = "0";
        banner.style.paddingTop = "0";
        banner.style.paddingBottom = "0";
        banner.style.borderWidth = "0";
      });
    }, 350);
  }
  retry.addEventListener("click", function () {
    retry.disabled = true;
    retry.innerHTML = '<span class="spin"></span>Retrying';
    var finish = function () {
      banner.classList.add("ok");
      banner.querySelector(".ico").innerHTML = L.icon("checkCircle", 16);
      banner.querySelector(".txt").innerHTML = "<b>Northwind paid $240.00</b> <span>· Retried on Visa •••• 8836 · just now</span>";
      retry.remove();
      banner.querySelector("a.btn").textContent = "View receipt";
      var row = document.querySelector('tr[data-id="py_3Q8nWd2eZvKYlo2C0x1kTq4R"]');
      if (row) {
        row.querySelector("[data-status]").innerHTML = L.pill("Succeeded");
        var why = row.querySelector(".why");
        if (why) why.remove();
        row.classList.add("fresh");
      }
      var badge = document.querySelector("[data-failed]");
      if (badge) badge.remove();
      setTimeout(collapse, 4200);
    };
    fetch("/payments/py_3Q8nWd2eZvKYlo2C0x1kTq4R/retry", { method: "POST" })
      .then(function (res) { return res.ok ? res.json() : null; })
      .catch(function () { return null; })
      .then(function () { setTimeout(finish, 250); });
  });
  $("#dismiss").addEventListener("click", collapse);
})();
