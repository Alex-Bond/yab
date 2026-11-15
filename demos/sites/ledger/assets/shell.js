/* Ledger shell: icons, helpers, the sidebar and the top bar.
   Loaded synchronously at the top of <body>, so the frame is in place
   before the page's own content is parsed: no flash of an empty sidebar. */
(function () {
  "use strict";
  var L = (window.L = window.L || {});

  var P = {
    home: '<path d="M3.5 10.2 12 3.5l8.5 6.7"/><path d="M5.5 8.8V20h13V8.8"/><path d="M9.8 20v-5.6h4.4V20"/>',
    payments: '<rect x="2.75" y="5" width="18.5" height="14" rx="2.6"/><path d="M2.75 9.6h18.5"/><path d="M6.6 15h3.8"/>',
    invoices: '<path d="M6.2 2.8h8.2L19 7.4v12.8c0 .6-.4 1-1 1H6.2c-.6 0-1-.4-1-1V3.8c0-.6.4-1 1-1Z"/><path d="M14 3v4.6h4.8"/><path d="M8.6 12.4h6.8M8.6 16.2h4.6"/>',
    customers: '<circle cx="9.2" cy="8.2" r="3.4"/><path d="M3 19.6c.8-3.4 3.2-5.2 6.2-5.2s5.4 1.8 6.2 5.2"/><path d="M15.6 5a3.4 3.4 0 0 1 0 6.4M17.8 14.6c1.6.8 2.7 2.4 3.1 5"/>',
    expenses: '<path d="M5.5 2.8h13v18.4l-2.6-1.6-2.4 1.6-2-1.6-2 1.6-2.4-1.6-2.6 1.6Z"/><path d="M8.8 7.6h6.4M8.8 11.2h6.4M8.8 14.8h3.8"/>',
    reports: '<path d="M3.5 20.5h17"/><rect x="5.2" y="11" width="3.2" height="6.6" rx="1"/><rect x="10.4" y="5.6" width="3.2" height="12" rx="1"/><rect x="15.6" y="13.4" width="3.2" height="4.2" rx="1"/>',
    developers: '<path d="m8.2 7.2-4.8 4.8 4.8 4.8M15.8 7.2l4.8 4.8-4.8 4.8M13.4 4.6l-2.8 14.8"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 14.6a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5v.2a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1.1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1h-.2a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1.1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3h.1a1.6 1.6 0 0 0 1-1.5v-.2a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8v.1a1.6 1.6 0 0 0 1.5 1h.2a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1Z"/>',
    bell: '<path d="M6.2 9.4a5.8 5.8 0 0 1 11.6 0c0 4.6 1.9 6.2 1.9 6.2H4.3s1.9-1.6 1.9-6.2Z"/><path d="M10.2 19a2 2 0 0 0 3.6 0"/>',
    help: '<circle cx="12" cy="12" r="8.8"/><path d="M9.6 9.4a2.5 2.5 0 0 1 4.8.9c0 1.7-2.4 2.3-2.4 2.3"/><path d="M12 16.4h.01"/>',
    search: '<circle cx="10.8" cy="10.8" r="6.3"/><path d="m15.6 15.6 4.4 4.4"/>',
    chevDown: '<path d="m7 10 5 5 5-5"/>',
    chevRight: '<path d="m10 7 5 5-5 5"/>',
    chevLeft: '<path d="m14 7-5 5 5 5"/>',
    updown: '<path d="m8 9.5 4-4 4 4M8 14.5l4 4 4-4"/>',
    plus: '<path d="M12 5.5v13M5.5 12h13"/>',
    download: '<path d="M12 4v11"/><path d="m7.5 10.8 4.5 4.5 4.5-4.5"/><path d="M5 19.5h14"/>',
    upload: '<path d="M12 15.5v-11"/><path d="m7.5 8.7 4.5-4.5 4.5 4.5"/><path d="M5 19.5h14"/>',
    more: '<circle cx="5.5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="18.5" cy="12" r="1.3"/>',
    check: '<path d="m5.5 12.5 4.2 4.2 8.8-9.2"/>',
    checkCircle: '<circle cx="12" cy="12" r="8.8"/><path d="m8.4 12.3 2.5 2.5 4.9-5.1"/>',
    x: '<path d="m6.5 6.5 11 11M17.5 6.5l-11 11"/>',
    alert: '<path d="M12 8v4.6"/><path d="M12 16.2h.01"/><circle cx="12" cy="12" r="8.8"/>',
    warn: '<path d="M10.3 4.3 2.9 17.2a2 2 0 0 0 1.7 3h14.8a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0Z"/><path d="M12 9.5v4"/><path d="M12 17h.01"/>',
    clock: '<circle cx="12" cy="12" r="8.8"/><path d="M12 7.4V12l3 2"/>',
    refund: '<path d="M9 14 4.5 9.5 9 5"/><path d="M4.5 9.5H15a5 5 0 0 1 0 10h-2.5"/>',
    retry: '<path d="M20 11.5a8 8 0 1 1-2.4-5.7L20 8.2"/><path d="M20 3.5v4.7h-4.7"/>',
    copy: '<rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.4"/><path d="M15.5 8.5V6.4c0-1.3-1-2.4-2.4-2.4H6.4C5.1 4 4 5.1 4 6.4v6.7c0 1.3 1.1 2.4 2.4 2.4h2.1"/>',
    eye: '<path d="M2.6 12S6 5.6 12 5.6 21.4 12 21.4 12 18 18.4 12 18.4 2.6 12 2.6 12Z"/><circle cx="12" cy="12" r="2.8"/>',
    eyeOff: '<path d="M4 4l16 16"/><path d="M9.9 6a8.9 8.9 0 0 1 2.1-.3c6 0 9.4 6.3 9.4 6.3a16 16 0 0 1-2.4 3.2M6.6 7.4A15.6 15.6 0 0 0 2.6 12s3.4 6.4 9.4 6.4a8.7 8.7 0 0 0 4.6-1.3"/><path d="M10 10a2.8 2.8 0 0 0 4 4"/>',
    clip: '<path d="m20 11.4-8 8a5 5 0 0 1-7.1-7.1l8.6-8.6a3.3 3.3 0 1 1 4.7 4.7l-8.6 8.6a1.7 1.7 0 0 1-2.4-2.4l7.9-7.9"/>',
    file: '<path d="M6.2 2.8h8.2L19 7.4v12.8c0 .6-.4 1-1 1H6.2c-.6 0-1-.4-1-1V3.8c0-.6.4-1 1-1Z"/><path d="M14 3v4.6h4.8"/>',
    image: '<rect x="3.5" y="4.5" width="17" height="15" rx="2.6"/><circle cx="9" cy="10" r="1.7"/><path d="m20.5 15.5-4.6-4.6-8.4 8.6"/>',
    bank: '<path d="M3.5 9.2 12 4.5l8.5 4.7"/><path d="M5.5 10v7M9.8 10v7M14.2 10v7M18.5 10v7"/><path d="M3.5 19.5h17"/>',
    arrowUp: '<path d="M12 18.5v-13M6.5 11 12 5.5l5.5 5.5"/>',
    arrowDown: '<path d="M12 5.5v13M6.5 13l5.5 5.5 5.5-5.5"/>',
    arrowUpRight: '<path d="M7.5 16.5 16.5 7.5M8.5 7.5h8v8"/>',
    filter: '<path d="M4 6h16M7 12h10M10 18h4"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="2.6"/><path d="M3.5 9.8h17M8 3v4M16 3v4"/>',
    card: '<rect x="2.75" y="5" width="18.5" height="14" rx="2.6"/><path d="M2.75 9.6h18.5"/>',
    key: '<circle cx="8" cy="15.5" r="4"/><path d="m10.9 12.6 8.6-8.6M16.4 7.1l2.5 2.5M14.2 9.3l1.8 1.8"/>',
    hook: '<path d="M18 16.5a3.5 3.5 0 1 1-3.4 4.3"/><path d="M8.6 9.4 6 14a3.5 3.5 0 1 0 5.8 3.2h6.2"/><path d="m15.4 9.8-3-5.4A3.5 3.5 0 1 0 7.6 8"/>',
    pulse: '<path d="M3 12h4l2.6-6.5 4.8 13 2.6-6.5H21"/>',
    globe: '<circle cx="12" cy="12" r="8.8"/><path d="M3.2 12h17.6M12 3.2c2.4 2.4 3.6 5.3 3.6 8.8s-1.2 6.4-3.6 8.8c-2.4-2.4-3.6-5.3-3.6-8.8S9.6 5.6 12 3.2Z"/>',
    sparkle: '<path d="M12 3.5v4M12 16.5v4M3.5 12h4M16.5 12h4M6 6l2.6 2.6M15.4 15.4 18 18M18 6l-2.6 2.6M8.6 15.4 6 18"/>',
    shield: '<path d="M12 3 4.5 6v5.6c0 4.5 3.1 7.9 7.5 9.4 4.4-1.5 7.5-4.9 7.5-9.4V6Z"/><path d="m8.8 12.2 2.3 2.3 4.3-4.5"/>',
    csv: '<path d="M6.2 2.8h8.2L19 7.4v12.8c0 .6-.4 1-1 1H6.2c-.6 0-1-.4-1-1V3.8c0-.6.4-1 1-1Z"/><path d="M14 3v4.6h4.8"/><path d="M8.5 12h7v6h-7zM8.5 15h7M12 12v6"/>',
    trend: '<path d="m3.5 16.5 6-6 4 4 7-7.5"/><path d="M15 7h5.5v5.5"/>',
    users: '<circle cx="9.2" cy="8.2" r="3.4"/><path d="M3 19.6c.8-3.4 3.2-5.2 6.2-5.2s5.4 1.8 6.2 5.2"/>',
    info: '<circle cx="12" cy="12" r="8.8"/><path d="M12 11v5.2"/><path d="M12 7.8h.01"/>',
    send: '<path d="m4 11.5 16-7.5-6.5 16-2.6-6.4Z"/><path d="m10.9 13.6 4-4"/>',
    lock: '<rect x="4.5" y="10.5" width="15" height="10" rx="2.4"/><path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9"/>',
    pin: '<path d="M12 21s-6.5-5.4-6.5-11a6.5 6.5 0 0 1 13 0c0 5.6-6.5 11-6.5 11Z"/><circle cx="12" cy="10" r="2.3"/>',
    out: '<path d="M14 4.5h4.5c.6 0 1 .4 1 1v13c0 .6-.4 1-1 1H14"/><path d="M10 16.5 14.5 12 10 7.5M14.5 12H4.5"/>'
  };

  // Icons come in 12 (badges only), 16, 20 and 24, and every stroke draws
  // 1.5px whatever the size: the 24-unit drawing's stroke is scaled to match.
  L.icon = function (name, size, extra) {
    size = size || 16;
    var stroke = Math.round((1.5 * 24 / size) * 100) / 100;
    return '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + stroke + '" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"' + (extra ? " " + extra : "") + ">" + (P[name] || "") + "</svg>";
  };

  L.mark = function (size) {
    size = size || 28;
    return '<svg class="mark" width="' + size + '" height="' + size + '" viewBox="0 0 32 32" aria-hidden="true"><defs><linearGradient id="lg' + size + '" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1FBFAA"/><stop offset="1" stop-color="#0B6A63"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#lg' + size + ')"/><rect x="14" y="8.4" width="10" height="2.8" rx="1.4" fill="#fff" fill-opacity=".7"/><rect x="11" y="13.8" width="13" height="2.8" rx="1.4" fill="#fff" fill-opacity=".7"/><rect x="8" y="19.6" width="16" height="2" rx="1" fill="#fff"/><rect x="8" y="23.2" width="16" height="2" rx="1" fill="#fff"/></svg>';
  };

  /* Fills every [data-icon] placeholder under root with its drawing. */
  L.icons = function (root) {
    var list = (root || document).querySelectorAll("[data-icon]");
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      if (el.firstChild) continue;
      el.innerHTML = L.icon(el.getAttribute("data-icon"), +el.getAttribute("data-size") || 16);
    }
  };

  /* ------------------------------------------------------------ formatting */

  L.now = Date.now();
  var usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
  var usd0 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
  var int = new Intl.NumberFormat("en-US");
  L.money = function (n) { return usd.format(n); };
  L.money0 = function (n) { return usd0.format(n); };
  L.int = function (n) { return int.format(n); };
  L.short = function (n) {
    if (Math.abs(n) >= 1000) return "$" + (n / 1000).toFixed(n % 1000 === 0 ? 0 : 1).replace(/\.0$/, "") + "k";
    return "$" + n;
  };
  var dt = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  var d1 = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" });
  var d2 = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });
  var tm = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", second: "2-digit" });
  L.dateTime = function (d) { return dt.format(d); };
  L.date = function (d) { return (new Date(d).getFullYear() === new Date(L.now).getFullYear() ? d1 : d2).format(d); };
  L.dateYear = function (d) { return d2.format(d); };
  L.time = function (d) { return tm.format(d); };
  L.minutesAgo = function (m) { return new Date(L.now - m * 60000); };
  L.daysFromNow = function (days) {
    var d = new Date(L.now);
    d.setHours(12, 0, 0, 0);
    d.setDate(d.getDate() + days);
    return d;
  };
  L.ago = function (d) {
    var m = Math.max(0, Math.round((L.now - d) / 60000));
    if (m < 1) return "just now";
    if (m < 60) return m + " min ago";
    var h = Math.round(m / 60);
    if (h < 24) return h + "h ago";
    var days = Math.round(h / 24);
    return days === 1 ? "yesterday" : days + " days ago";
  };
  L.esc = function (s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  };
  L.initials = function (name) {
    var parts = String(name).replace(/&/g, " ").split(/\s+/).filter(Boolean);
    return ((parts[0] || "")[0] + ((parts[1] || "")[0] || "")).toUpperCase();
  };
  L.size = function (bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB";
    return (bytes / 1048576).toFixed(1) + " MB";
  };

  /* ------------------------------------------------------------ pieces */

  L.pill = function (status) {
    var map = {
      Succeeded: ["ok", "check"], Paid: ["ok", "check"], Approved: ["ok", "check"], Active: ["ok", "check"], Reimbursed: ["ok", "check"],
      Failed: ["fail", "x"], "Past due": ["fail", "alert"], Canceled: ["refund", "x"],
      Refunded: ["refund", "refund"], Void: ["refund", "x"], Draft: ["draft", "file"],
      Pending: ["wait", "clock"], Open: ["info", "clock"], "In review": ["info", "clock"], "Needs receipt": ["wait", "clip"],
      Trialing: ["violet", "sparkle"], Scheduled: ["info", "calendar"]
    };
    var m = map[status] || ["plain", null];
    return '<span class="pill ' + m[0] + '">' + (m[1] ? L.icon(m[1], 12) : "") + L.esc(status) + "</span>";
  };

  L.method = function (m) {
    if (!m) return "";
    var label = { visa: "VISA", mc: "MC", amex: "AMEX", bank: L.icon("bank", 12) }[m.brand] || "";
    return '<span class="method"><span class="brandmark ' + m.brand + '">' + label + "</span>" + (m.kind ? L.esc(m.kind) + " " : "") + "•••• " + L.esc(m.last4) + "</span>";
  };

  L.logo = function (c, small) {
    return '<span class="logo' + (small ? " sm" : "") + '" style="background:' + c.color + '">' + L.esc(c.short || L.initials(c.name)) + "</span>";
  };

  L.toast = function (html, ms) {
    var t = document.querySelector(".toast");
    if (!t) {
      t = document.createElement("div");
      t.className = "toast";
      t.setAttribute("role", "status");
      document.body.appendChild(t);
    }
    t.innerHTML = L.icon("checkCircle", 16) + "<div>" + html + "</div>";
    requestAnimationFrame(function () { t.classList.add("show"); });
    clearTimeout(L._toast);
    L._toast = setTimeout(function () { t.classList.remove("show"); }, ms || 3600);
  };

  L.copy = function (text, btn) {
    var done = function () {
      if (!btn) return;
      var was = btn.innerHTML;
      btn.innerHTML = L.icon("check", 16);
      btn.style.color = "var(--green)";
      setTimeout(function () { btn.innerHTML = was; btn.style.color = ""; }, 1300);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, done);
    } else {
      done();
    }
  };

  /* ------------------------------------------------------------ the frame */

  var page = document.body.getAttribute("data-page") || "";
  var nav = [
    ["home", "/", "Home", "home"],
    ["payments", "/payments", "Payments", "payments"],
    ["invoices", "/invoices", "Invoices", "invoices"],
    ["customers", "/customers", "Customers", "customers"],
    ["expenses", "/expenses", "Expenses", "expenses"],
    ["reports", "/reports", "Reports", "reports"],
    ["developers", "/developers", "Developers", "developers"]
  ];

  var side =
    '<aside class="side" aria-label="Main">' +
    '<button class="account" type="button" title="Switch account">' + L.mark(28) +
    '<span class="who"><b>Tern Labs</b><span>Ledger · Live</span></span>' + L.icon("updown", 16, 'class="chev"') + "</button>" +
    '<nav class="nav">' +
    nav.map(function (n) {
      var badge = n[0] === "payments" ? '<span class="count" data-failed>1</span>' : "";
      return '<a href="' + n[1] + '"' + (n[0] === page ? ' class="on" aria-current="page"' : "") + ">" + L.icon(n[3], 16) + "<span>" + n[2] + "</span>" + badge + "</a>";
    }).join("") +
    "</nav>" +
    "<h6>Shortcuts</h6>" +
    '<div class="shortcuts">' +
    '<a href="/customers#northwind"><span class="dot" style="background:#2563eb">N</span>Northwind</a>' +
    '<a href="/invoices#INV-2026-0941"><span class="dot" style="background:var(--ink-4)">#</span>INV-2026-0941</a>' +
    '<a href="/expenses/new"><span class="dot" style="background:var(--warning-mark)">+</span>New expense</a>' +
    "</div>" +
    '<div class="foot">' +
    '<a href="/developers#webhooks">' + L.icon("pulse", 16) + "<span>Status</span></a>" +
    '<a href="/settings">' + L.icon("settings", 16) + "<span>Settings</span></a>" +
    "</div>" +
    "</aside>";

  var top =
    '<header class="top">' +
    '<div class="search" role="search">' + L.icon("search", 16) +
    '<input id="q" type="text" placeholder="Search payments, customers, invoices" autocomplete="off" spellcheck="false" aria-label="Search">' +
    "<kbd>/</kbd>" +
    '<div class="results" id="results"></div></div>' +
    '<div class="right">' +
    '<button class="mode" type="button" id="mode" title="Switch to test data"><span class="switch"></span>Test mode</button>' +
    '<div class="create-wrap hide-sm"><button class="btn primary create" type="button" id="create" aria-haspopup="menu" aria-expanded="false">' + L.icon("plus", 16) + "Create</button>" +
    '<div class="menu" id="create-menu" role="menu">' +
    '<a role="menuitem" href="/invoices">' + L.icon("invoices", 16) + "Invoice</a>" +
    '<a role="menuitem" href="/payments">' + L.icon("payments", 16) + "Payment link</a>" +
    '<a role="menuitem" href="/customers">' + L.icon("customers", 16) + "Customer</a>" +
    '<a role="menuitem" href="/expenses/new">' + L.icon("expenses", 16) + "Expense</a>" +
    "</div></div>" +
    '<button class="icon-btn" type="button" title="Help">' + L.icon("help", 20) + "</button>" +
    '<button class="icon-btn" type="button" title="Notifications">' + L.icon("bell", 20) + '<span class="ping"></span></button>' +
    '<button class="icon-btn" type="button" title="Settings" onclick="location.href=\'/settings\'">' + L.icon("settings", 20) + "</button>" +
    '<button class="avatar" type="button" title="Mira Lindqvist · mira@ternlabs.com">ML</button>' +
    "</div></header>";

  document.body.classList.add("app");
  var me = document.currentScript;
  me.insertAdjacentHTML("beforebegin", side + top);

  /* ------------------------------------------------------------ behavior */

  document.addEventListener("DOMContentLoaded", function () {
    var topbar = document.querySelector(".top");
    var onScroll = function () { topbar.classList.toggle("scrolled", window.scrollY > 4); };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();

    var create = document.getElementById("create");
    var menu = document.getElementById("create-menu");
    create.addEventListener("click", function (e) {
      e.stopPropagation();
      var open = !menu.classList.contains("open");
      menu.classList.toggle("open", open);
      create.setAttribute("aria-expanded", String(open));
    });
    document.addEventListener("click", function (e) {
      if (!e.target.closest("#create-menu")) { menu.classList.remove("open"); create.setAttribute("aria-expanded", "false"); }
    });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") menu.classList.remove("open"); });

    var mode = document.getElementById("mode");
    mode.addEventListener("click", function () {
      mode.classList.toggle("on");
      L.toast(mode.classList.contains("on") ? "Viewing test data" : "Viewing live data", 1800);
    });

    // Search: customers, invoices and payments, all from this page's data.
    var q = document.getElementById("q");
    var box = document.getElementById("results");
    var hot = -1;
    var render = function () {
      var text = q.value.trim().toLowerCase();
      if (!text) { box.classList.remove("open"); return; }
      var customers = (L.customers || []).filter(function (c) {
        return (c.name + " " + c.email).toLowerCase().indexOf(text) >= 0;
      }).slice(0, 4);
      var invoices = (L.invoices || []).filter(function (i) {
        var c = L.customer(i.customer);
        return (i.number + " " + (c ? c.name : "")).toLowerCase().indexOf(text) >= 0;
      }).slice(0, 3);
      var html = "";
      if (customers.length) {
        html += "<h6>Customers</h6>" + customers.map(function (c) {
          return '<a href="/customers#' + c.id + '">' + L.logo(c, true) + L.esc(c.name) + '<span class="r-end">' + L.esc(c.email) + "</span></a>";
        }).join("");
      }
      if (invoices.length) {
        html += "<h6>Invoices</h6>" + invoices.map(function (i) {
          var c = L.customer(i.customer);
          return '<a href="/invoices#' + i.number + '">' + L.icon("invoices", 16) + L.esc(i.number) + '<span class="r-end">' + L.esc(c ? c.name : "") + " · " + L.money(i.amount) + "</span></a>";
        }).join("");
      }
      box.innerHTML = html || '<div class="none">No results for “' + L.esc(q.value.trim()) + "”</div>";
      box.classList.add("open");
      hot = -1;
    };
    q.addEventListener("input", render);
    q.addEventListener("focus", render);
    q.addEventListener("blur", function () { setTimeout(function () { box.classList.remove("open"); }, 150); });
    q.addEventListener("keydown", function (e) {
      var links = box.querySelectorAll("a");
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (!links.length) return;
        hot = (hot + (e.key === "ArrowDown" ? 1 : -1) + links.length) % links.length;
        links.forEach(function (a, i) { a.classList.toggle("hot", i === hot); });
      } else if (e.key === "Enter") {
        var pick = links[hot] || links[0];
        if (pick) location.href = pick.getAttribute("href");
      } else if (e.key === "Escape") {
        q.value = "";
        box.classList.remove("open");
        q.blur();
      }
    });
    document.addEventListener("keydown", function (e) {
      var t = e.target;
      var typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
      if (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        q.focus();
      }
    });
  });
})();
