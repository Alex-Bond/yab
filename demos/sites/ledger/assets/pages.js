/* Every Ledger page but the overview: payments, invoices, customers,
   expenses and the new expense form, reports, developers, settings. */
(function () {
  "use strict";
  var L = window.L;
  var $ = function (s) { return document.querySelector(s); };
  var page = document.body.getAttribute("data-page");

  function tabs(el, items, current, pick) {
    el.innerHTML = items.map(function (t) {
      return '<button type="button" data-k="' + t[0] + '"' + (t[0] === current ? ' class="on"' : "") + ">" + t[1] + '<span class="n">' + t[2] + "</span></button>";
    }).join("");
    el.onclick = function (e) {
      var b = e.target.closest("button");
      if (!b) return;
      el.querySelectorAll("button").forEach(function (o) { o.classList.toggle("on", o === b); });
      pick(b.getAttribute("data-k"));
    };
  }
  function count(list, key, value) { return list.filter(function (x) { return x[key] === value; }).length; }
  function has(text, q) { return !q || String(text).toLowerCase().indexOf(q) >= 0; }
  function kebab() { return '<td class="r"><button class="icon-btn kebab" type="button" aria-label="More">' + L.icon("more", 16) + "</button></td>"; }
  function who(c) {
    return '<div class="who">' + L.logo(c) + "<div><b>" + L.esc(c.name) + '</b><span class="sub">' + L.esc(c.email) + "</span></div></div>";
  }
  function none(cols, text) {
    return '<tr><td colspan="' + cols + '" class="t-empty">' + text + "</td></tr>";
  }
  // A row named in the address (#INV-2026-0941, #py_..., #northwind): brought into view and lit.
  function spotlight() {
    var id = decodeURIComponent(location.hash.slice(1));
    if (!id) return;
    var row = document.getElementById(id);
    if (!row || row.tagName !== "TR") return;
    row.classList.remove("fresh");
    void row.offsetWidth;
    row.classList.add("fresh");
    row.scrollIntoView({ block: "start" });
  }

  /* ---------------------------------------------------------------- payments */

  function payments() {
    var state = { tab: "all", q: "" };
    var list = L.payments;
    tabs($("#tabs"), [
      ["all", "All", list.length],
      ["Succeeded", "Succeeded", count(list, "status", "Succeeded")],
      ["Refunded", "Refunded", count(list, "status", "Refunded")],
      ["Failed", "Failed", count(list, "status", "Failed")],
      ["Pending", "Pending", count(list, "status", "Pending")]
    ], "all", function (k) { state.tab = k; render(); });
    function render() {
      var rows = list.filter(function (p) {
        var c = L.customer(p.customer);
        return (state.tab === "all" || p.status === state.tab) && has(c.name + " " + c.email + " " + p.desc + " " + p.id, state.q);
      });
      $("#table tbody").innerHTML = rows.map(L.paymentRow).join("") || none(7, "No payments match this filter.");
      $("#count").textContent = rows.length + (rows.length === 1 ? " result" : " results");
    }
    $("#find").addEventListener("input", function (e) { state.q = e.target.value.trim().toLowerCase(); render(); });
    render();
  }

  /* ---------------------------------------------------------------- invoices */

  function invoices() {
    var state = { status: null, q: "" };
    var list = L.invoices;
    var groups = [
      ["Draft", "Draft", "var(--ink-4)"],
      ["Open", "Outstanding", "var(--info)"],
      ["Past due", "Past due", "var(--danger-mark)"],
      ["Paid", "Paid", "var(--success-mark)"]
    ];
    var stats = $("#stats");
    stats.innerHTML = groups.map(function (g) {
      var items = list.filter(function (i) { return i.status === g[0]; });
      var total = items.reduce(function (s, i) { return s + i.amount; }, 0);
      return '<button type="button" class="card stat" data-status="' + g[0] + '">' +
        '<div class="s-label"><i style="background:' + g[2] + '"></i>' + g[1] + "</div>" +
        '<div class="s-value">' + L.money(total) + "</div>" +
        '<div class="s-sub">' + items.length + (items.length === 1 ? " invoice" : " invoices") + "</div></button>";
    }).join("");
    stats.addEventListener("click", function (e) {
      var b = e.target.closest(".stat");
      if (!b) return;
      var s = b.getAttribute("data-status");
      state.status = state.status === s ? null : s;
      stats.querySelectorAll(".stat").forEach(function (o) { o.classList.toggle("on", o.getAttribute("data-status") === state.status); });
      render();
    });
    function due(inv) {
      if (inv.due == null) return '<span class="muted">No due date</span>';
      var d = L.daysFromNow(inv.due);
      if (inv.status === "Past due") {
        var late = -inv.due;
        return '<span class="late">' + L.date(d) + (late > 0 ? " · " + late + (late === 1 ? " day late" : " days late") : " · today") + "</span>";
      }
      return L.date(d);
    }
    function row(inv) {
      var c = L.customer(inv.customer);
      return '<tr id="' + inv.number + '">' +
        '<td class="r"><span class="amt">' + L.money(inv.amount) + '</span><span class="cur">USD</span></td>' +
        "<td>" + L.pill(inv.status) + "</td>" +
        '<td><span class="mono">' + inv.number + '</span><span class="sub">' + L.esc(inv.item) + "</span></td>" +
        "<td>" + who(c) + "</td>" +
        '<td class="date">' + due(inv) + (inv.note ? '<span class="sub">' + L.esc(inv.note) + "</span>" : "") + "</td>" +
        '<td class="date hide-lg">' + L.date(L.daysFromNow(inv.created)) + "</td>" +
        '<td class="r"><a class="btn" href="/invoices/' + inv.number + '.pdf" title="Download ' + inv.number + '.pdf">' + L.icon("download", 16) + '<span><span class="wide">Download </span>PDF</span></a></td></tr>';
    }
    function render() {
      var rows = list.filter(function (inv) {
        var c = L.customer(inv.customer);
        return (!state.status || inv.status === state.status) && has(inv.number + " " + c.name + " " + c.email + " " + inv.item, state.q);
      });
      $("#table tbody").innerHTML = rows.map(row).join("") || none(7, "No invoices match this filter.");
      $("#count").textContent = rows.length + " of " + list.length + " invoices";
    }
    $("#find").addEventListener("input", function (e) { state.q = e.target.value.trim().toLowerCase(); render(); });
    render();
  }

  /* ---------------------------------------------------------------- customers */

  function customers() {
    var state = { tab: "all", q: "" };
    var list = L.customers;
    tabs($("#tabs"), [
      ["all", "All", list.length],
      ["Active", "Active", count(list, "status", "Active")],
      ["Trialing", "Trialing", count(list, "status", "Trialing")],
      ["Past due", "Past due", count(list, "status", "Past due")],
      ["Canceled", "Canceled", count(list, "status", "Canceled")]
    ], "all", function (k) { state.tab = k; render(); });
    function row(c) {
      return '<tr id="' + c.id + '">' +
        "<td>" + who(c) + "</td>" +
        '<td><span class="pill plain">Tern ' + c.plan + "</span>" + (c.billing === "annual" ? ' <span class="muted small">annual</span>' : "") + "</td>" +
        '<td class="r num">' + c.seats + "</td>" +
        '<td class="r"><span class="amt">' + L.money(c.mrr) + "</span></td>" +
        '<td class="hide-md">' + L.method(c.method) + "</td>" +
        "<td>" + L.pill(c.status) + "</td>" +
        '<td class="date">' + c.since + "</td>" + kebab() + "</tr>";
    }
    function render() {
      var rows = list.filter(function (c) {
        return (state.tab === "all" || c.status === state.tab) && has(c.name + " " + c.email + " " + c.plan, state.q);
      });
      $("#table tbody").innerHTML = rows.map(row).join("") || none(8, "No customers match this filter.");
      $("#count").textContent = "Showing " + rows.length + " of 412 customers";
    }
    $("#find").addEventListener("input", function (e) { state.q = e.target.value.trim().toLowerCase(); render(); });
    render();
  }

  /* ---------------------------------------------------------------- expenses */

  var RATES = { USD: 1, EUR: 1.08, SEK: 0.0945, GBP: 1.27, NOK: 0.092 };
  function cash(amount, currency) {
    try {
      return new Intl.NumberFormat("en-US", { style: "currency", currency: currency || "USD" }).format(amount);
    } catch (e) {
      return L.money(amount);
    }
  }
  function isoDay(days) {
    var d = L.daysFromNow(days);
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  }
  var SEED = [
    { merchant: "Form Design Week", note: "Conference ticket, Copenhagen", category: "Events", day: -2, by: "Mira Lindqvist", files: [], status: "Needs receipt", amount: 95, currency: "EUR" },
    { merchant: "Kai Nakamura", note: "Illustrations for Tern 2.0, round 2", category: "Contractors", day: -3, by: "Mira Lindqvist", files: ["Invoice KN-2026-14.pdf"], status: "Approved", amount: 2400, currency: "USD" },
    { merchant: "Bageri Petrus", note: "Fika for the design crit", category: "Meals", day: -4, by: "Anna Ek", files: ["IMG_4471.jpg"], status: "Reimbursed", amount: 812, currency: "SEK" },
    { merchant: "Penline", note: "Design tool, team plan, annual", category: "Software", day: -6, by: "Mira Lindqvist", files: ["penline-receipt-0924.pdf"], status: "Approved", amount: 540, currency: "USD" },
    { merchant: "Typefoundry Co", note: "Display font license for Tern 2.0", category: "Software", day: -8, by: "Mira Lindqvist", files: ["TF-license-88213.pdf"], status: "In review", amount: 360, currency: "EUR" },
    { merchant: "Fieldwork", note: "Six usability sessions, Onboarding v3", category: "Research", day: -9, by: "Mira Lindqvist", files: ["fieldwork-invoice-0412.pdf"], status: "Approved", amount: 300, currency: "USD" },
    { merchant: "Officeland", note: "Monitor arm", category: "Hardware", day: -11, by: "Sara Holm", files: [], status: "Needs receipt", amount: 1390, currency: "SEK" },
    { merchant: "Tracklane", note: "Issue tracker, 11 seats", category: "Software", day: -15, by: "Elliot Park", files: ["tracklane-sep.pdf"], status: "Approved", amount: 96, currency: "USD" },
    { merchant: "Northstack Cloud", note: "Staging servers, September", category: "Software", day: -29, by: "Elliot Park", files: ["northstack-2026-09.pdf"], status: "Approved", amount: 1248.17, currency: "USD" }
  ];

  function face(name) {
    var p = L.person(name);
    return '<span class="face" style="background:' + p.color + '">' + L.initials(name) + "</span>";
  }

  function expenses() {
    var state = { tab: "all" };
    var seed = SEED.map(function (e, i) {
      return Object.assign({ id: "exp_seed" + i, date: isoDay(e.day), receipts: e.files.map(function (n) { return { name: n }; }) }, e);
    });
    var added = [];
    var list = function () { return added.concat(seed); };
    var params = new URLSearchParams(location.search);
    var fresh = params.get("added");

    function stats() {
      var all = list();
      var month = new Date(L.now).getMonth();
      var spent = all.filter(function (e) { return new Date(e.date + "T12:00:00").getMonth() === month; })
        .reduce(function (s, e) { return s + e.amount * (RATES[e.currency] || 1); }, 0);
      var missing = all.filter(function (e) { return e.status === "Needs receipt"; });
      var review = all.filter(function (e) { return e.status === "In review"; });
      var reimbursed = all.filter(function (e) { return e.status === "Reimbursed"; })
        .reduce(function (s, e) { return s + e.amount * (RATES[e.currency] || 1); }, 0);
      $("#stats").innerHTML = [
        ["var(--accent)", "Spent this month", L.money(spent + 4210.55), "Team card and reimbursements"],
        ["var(--warning-mark)", "Needs a receipt", String(missing.length), missing.length === 1 ? "1 expense waiting" : missing.length + " expenses waiting"],
        ["var(--info)", "In review", String(review.length), "Anna reviews within 2 days"],
        ["var(--success-mark)", "Reimbursed", L.money(reimbursed + 1164.2), "Paid out with salaries"]
      ].map(function (s) {
        return '<div class="card stat"><div class="s-label"><i style="background:' + s[0] + '"></i>' + s[1] + '</div><div class="s-value">' + s[2] + '</div><div class="s-sub">' + s[3] + "</div></div>";
      }).join("");
      var all2 = list();
      tabs($("#tabs"), [
        ["all", "All", all2.length],
        ["Needs receipt", "Needs receipt", count(all2, "status", "Needs receipt")],
        ["In review", "In review", count(all2, "status", "In review")],
        ["Approved", "Approved", count(all2, "status", "Approved")],
        ["Reimbursed", "Reimbursed", count(all2, "status", "Reimbursed")]
      ], state.tab, function (k) { state.tab = k; render(); });
    }

    function receipt(e) {
      if (!e.receipts || !e.receipts.length) return '<a class="add-receipt" href="/expenses/new">' + L.icon("plus", 16) + "Add receipt</a>";
      var first = e.receipts[0];
      var more = e.receipts.length > 1 ? ' <span class="muted">+' + (e.receipts.length - 1) + "</span>" : "";
      var label = L.icon(/\.pdf$/i.test(first.name) ? "file" : "image", 16) + "<span>" + L.esc(first.name) + "</span>";
      return first.url ? '<a class="receipt" href="' + first.url + '" target="_blank" rel="noopener">' + label + "</a>" + more : '<span class="receipt">' + label + "</span>" + more;
    }

    function row(e) {
      var usd = e.currency !== "USD" ? '<span class="sub">≈ ' + L.money(e.amount * (RATES[e.currency] || 1)) + "</span>" : "";
      var short = e.merchant.split(/\s+/).map(function (w) { return w[0]; }).join("").slice(0, 2).toUpperCase();
      return '<tr id="' + e.id + '"' + (e.id === fresh ? ' class="fresh"' : "") + ">" +
        '<td><div class="who"><span class="logo" style="background:' + tint(e.merchant) + '">' + L.esc(short) + "</span><div><b>" + L.esc(e.merchant) + '</b><span class="sub">' + L.esc(e.note || "No notes") + "</span></div></div></td>" +
        '<td><span class="pill plain">' + L.esc(e.category || "Other") + "</span></td>" +
        '<td class="date">' + L.date(new Date(e.date + "T12:00:00")) + "</td>" +
        '<td><span class="person">' + face(e.by) + L.esc(e.by.split(" ")[0]) + "</span></td>" +
        "<td>" + receipt(e) + "</td>" +
        "<td>" + L.pill(e.status) + "</td>" +
        '<td class="r"><span class="amt">' + cash(e.amount, e.currency) + "</span>" + usd + "</td></tr>";
    }

    function render() {
      var rows = list().filter(function (e) { return state.tab === "all" || e.status === state.tab; });
      $("#table tbody").innerHTML = rows.map(row).join("") || none(7, "Nothing here.");
      $("#count").textContent = rows.length + (rows.length === 1 ? " expense" : " expenses");
    }

    stats();
    render();
    fetch("/api/expenses", { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : { expenses: [] }; })
      .catch(function () { return { expenses: [] }; })
      .then(function (data) {
        added = (data.expenses || []).map(function (e) {
          return Object.assign({}, e, { note: e.notes || (e.receipts && e.receipts.length ? "Receipt attached" : "") });
        });
        stats();
        render();
        if (fresh) {
          var e = added.filter(function (x) { return x.id === fresh; })[0];
          if (e) {
            var n = e.receipts ? e.receipts.length : 0;
            L.toast("<b>Expense submitted</b> <span>· " + L.esc(e.merchant) + " · " + cash(e.amount, e.currency) + (n ? " · " + n + (n === 1 ? " receipt" : " receipts") : "") + "</span>", 4200);
          }
          history.replaceState(null, "", "/expenses");
        }
      });
  }

  function tint(name) {
    var colors = ["#0f766e", "#2563eb", "#7c3aed", "#c2410c", "#be185d", "#0369a1", "#15803d", "#a16207", "#4f46e5", "#57534e"];
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
    return colors[h % colors.length];
  }

  /* ---------------------------------------------------------------- new expense */

  // What a receipt's name, or a receipt Ledger has read before, says about it.
  var KNOWN = [
    { test: /taxi.*arlanda|arlanda.*taxi|taxi kurir/i, fill: { merchant: "Taxi Kurir Stockholm", amount: "675.00", currency: "SEK", date: "2026-09-24", category: "Travel", notes: "Arlanda Terminal 5 to Södermannagatan" } },
    { test: /lunch.*kai|caf[eé] pascal/i, fill: { merchant: "Café Pascal", amount: "382.00", currency: "SEK", date: "2026-09-26", category: "Meals", notes: "Lunch with Kai Nakamura about the round 2 illustrations" } },
    { test: /nordic.?air|LQ4K2P/i, fill: { merchant: "Nordic Air", category: "Travel" } },
    { test: /casa.?alfama/i, fill: { merchant: "Casa Alfama", category: "Travel" } },
    { test: /invoice/i, fill: { category: "Contractors" } }
  ];
  var WORDS = [
    [/taxi|uber|train|flight|air|hotel|airbnb|rail|bus|parking/i, "Travel"],
    [/lunch|dinner|fika|coffee|cafe|café|bakery|bageri|restaurant/i, "Meals"],
    [/license|subscription|saas|plan/i, "Software"],
    [/monitor|keyboard|laptop|cable|mouse/i, "Hardware"]
  ];

  function expenseNew() {
    var form = $("#expense"), input = $("#receipt"), drop = $("#drop"), filesEl = $("#files"), attach = $("#attach");
    var fields = { merchant: $("#merchant"), amount: $("#amount"), currency: $("#currency"), date: $("#date"), category: $("#category"), notes: $("#notes") };
    var picked = [];
    var urls = [];
    var canAssign = (function () {
      try { return !!new DataTransfer().items; } catch (e) { return false; }
    })();
    fields.date.value = isoDay(0);
    var symbols = { USD: "$", EUR: "€", SEK: "kr", GBP: "£", NOK: "kr" };
    var syncSymbol = function () {
      var s = symbols[fields.currency.value] || "$";
      $("#sym").textContent = s;
      fields.amount.style.paddingLeft = s.length > 1 ? "32px" : "24px";
    };
    fields.currency.addEventListener("change", syncSymbol);
    syncSymbol();

    attach.addEventListener("click", function (e) {
      e.stopPropagation();
      input.click();
    });
    drop.addEventListener("click", function (e) {
      if (e.target.closest("button")) return;
      input.click();
    });
    input.addEventListener("change", function () {
      var chosen = Array.prototype.slice.call(input.files || []);
      if (!chosen.length) return;
      add(chosen, true);
    });
    ["dragenter", "dragover"].forEach(function (t) {
      drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.add("over"); });
    });
    ["dragleave", "dragend"].forEach(function (t) {
      drop.addEventListener(t, function () { drop.classList.remove("over"); });
    });
    drop.addEventListener("drop", function (e) {
      e.preventDefault();
      drop.classList.remove("over");
      var dropped = Array.prototype.slice.call((e.dataTransfer && e.dataTransfer.files) || []);
      var ok = dropped.filter(function (f) { return /pdf$/i.test(f.type) || /^image\//.test(f.type) || /\.pdf$/i.test(f.name); });
      if (ok.length) add(ok, false);
    });

    function add(list, fromInput) {
      if (canAssign) {
        var seen = {};
        picked.concat(list).forEach(function (f) { seen[f.name + "|" + f.size] = f; });
        picked = Object.keys(seen).map(function (k) { return seen[k]; });
        sync();
      } else {
        picked = fromInput ? list : picked;
      }
      render();
      guess(list[0]);
    }
    function sync() {
      if (!canAssign) return;
      var dt = new DataTransfer();
      picked.forEach(function (f) { dt.items.add(f); });
      input.files = dt.files;
    }
    function kind(f) {
      if (/pdf$/i.test(f.type) || /\.pdf$/i.test(f.name)) return "PDF document";
      if (/^image\//.test(f.type)) return (f.type.split("/")[1] || "image").toUpperCase().replace("JPEG", "JPG") + " image";
      return "File";
    }
    function render() {
      urls.forEach(function (u) { URL.revokeObjectURL(u); });
      urls = [];
      filesEl.innerHTML = picked.map(function (f, i) {
        var thumb;
        if (/^image\//.test(f.type)) {
          var u = URL.createObjectURL(f);
          urls.push(u);
          thumb = '<span class="thumb"><img alt="" src="' + u + '"></span>';
        } else {
          thumb = '<span class="thumb pdf">' + L.icon("file", 16) + "<em>PDF</em></span>";
        }
        return '<div class="file">' + thumb +
          '<div class="f-txt"><b title="' + L.esc(f.name) + '">' + L.esc(f.name) + "</b><span>" + L.size(f.size) + " · " + kind(f) + "</span></div>" +
          '<span class="pill ok f-ok">' + L.icon("check", 12) + "Attached</span>" +
          '<button class="icon-btn rm" type="button" data-i="' + i + '" aria-label="Remove ' + L.esc(f.name) + '">' + L.icon("x", 16) + "</button></div>";
      }).join("");
      var n = picked.length;
      drop.classList.toggle("has", n > 0);
      $("#drop-title").textContent = n ? (n === 1 ? "1 receipt attached" : n + " receipts attached") : "Drop receipts here";
      if (!n) $("#drop-sub").textContent = "PDF, JPG or PNG, up to 10 MB each";
      attach.innerHTML = L.icon(n ? "plus" : "clip", 16) + (n ? "Attach another" : "Attach receipt");
    }
    filesEl.addEventListener("click", function (e) {
      var b = e.target.closest(".rm");
      if (!b) return;
      var i = +b.getAttribute("data-i");
      picked.splice(i, 1);
      if (canAssign) sync(); else { input.value = ""; picked = []; }
      render();
    });

    function guess(f) {
      if (!f) return;
      var base = f.name.replace(/\.[a-z0-9]+$/i, "");
      var fill = {};
      KNOWN.forEach(function (k) {
        if (k.test.test(f.name)) Object.keys(k.fill).forEach(function (key) { if (fill[key] == null) fill[key] = k.fill[key]; });
      });
      var m = base.match(/(20\d\d)[-_.]?(\d\d)[-_.]?(\d\d)/);
      if (m) fill.date = m[1] + "-" + m[2] + "-" + m[3];
      if (!fill.category) WORDS.forEach(function (w) { if (!fill.category && w[0].test(base)) fill.category = w[1]; });
      if (!fill.merchant) {
        var words = base.replace(/(20\d\d)[-_.]?(\d\d)[-_.]?(\d\d)/, "").replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
        if (words && !/^(img|image|scan|receipt|document|file|screenshot)\b/i.test(words) && words.length <= 40) fill.merchant = words;
      }
      var filled = [];
      var typedAmount = !!fields.amount.value;
      Object.keys(fill).forEach(function (key) {
        var el = fields[key];
        if (!el || (el.value && !(key === "date" && el.value === isoDay(0)) && !(key === "currency"))) return;
        if (key === "currency" && typedAmount) return;
        el.value = fill[key];
        if (key !== "currency") filled.push(el);
        el.classList.remove("auto");
        void el.offsetWidth;
        el.classList.add("auto");
      });
      syncSymbol();
      if (filled.length) {
        $("#drop-sub").textContent = "Read from the receipt: " + filled.map(function (el) {
          return { merchant: "merchant", amount: "amount", date: "date", category: "category", notes: "notes" }[el.id] || el.id;
        }).join(", ");
        ["f-merchant", "f-amount"].forEach(function (id) { document.getElementById(id).classList.remove("bad"); });
      } else {
        $("#drop-sub").textContent = "Ready to submit with the expense";
      }
    }

    form.addEventListener("submit", function (e) {
      var bad = [];
      if (!fields.merchant.value.trim()) bad.push("f-merchant");
      var amount = parseFloat(String(fields.amount.value).replace(/[^0-9.]/g, ""));
      if (!(amount > 0)) bad.push("f-amount");
      ["f-merchant", "f-amount"].forEach(function (id) { document.getElementById(id).classList.toggle("bad", bad.indexOf(id) >= 0); });
      if (bad.length) {
        e.preventDefault();
        document.querySelector("#" + bad[0] + " input").focus();
        return;
      }
      var submit = $("#submit");
      if (!canAssign && picked.length && !(input.files && input.files.length)) {
        // Dropped files that the input can't hold: send them ourselves.
        e.preventDefault();
        var data = new FormData(form);
        picked.forEach(function (f) { data.append("receipt", f, f.name); });
        fetch("/expenses", { method: "POST", body: data, headers: { Accept: "application/json" } })
          .then(function (r) { return r.json(); })
          .then(function (x) { location.href = "/expenses?added=" + encodeURIComponent(x.id); });
      }
      submit.innerHTML = '<span class="spin"></span>Submitting';
      setTimeout(function () { submit.disabled = true; }, 0);
    });
    ["merchant", "amount"].forEach(function (k) {
      fields[k].addEventListener("input", function () { document.getElementById("f-" + k).classList.remove("bad"); });
    });
  }

  /* ---------------------------------------------------------------- reports */

  function reports() {
    var month = new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric" }).format(new Date(L.now));
    $("#period").textContent = month;
    $("#period-2").textContent = month;
    var short = new Intl.DateTimeFormat("en-US", { month: "short" });
    var max = Math.max.apply(null, L.volume);
    $("#bars").innerHTML = L.volume.map(function (v, i) {
      return '<div title="' + short.format(L.months[i]) + ": " + L.money0(v) + '"><span style="height:' + Math.round((v / max) * 76) + 'px"></span><em>' + short.format(L.months[i]) + "</em></div>";
    }).join("");
    var stamp = new Date(L.now);
    var ym = stamp.getFullYear() + "-" + String(stamp.getMonth() + 1).padStart(2, "0");
    var items = [
      ["payments", "payments", "var(--brand-tint)", "var(--brand)", "Payments", "Every charge with its fee, net amount, customer and card. One row per payment.", "480 rows"],
      ["balance", "bank", "var(--info-bg)", "var(--info)", "Balance change", "What moved the balance this month: charges, refunds, payouts and adjustments.", "460 rows"],
      ["payouts", "send", "var(--violet-bg)", "var(--violet)", "Payout reconciliation", "Each payout to Tern Labs AB, with the payments and fees it settled.", "420 rows"],
      ["mrr", "trend", "var(--warning-bg)", "var(--warning)", "MRR movements", "New, expansion, contraction and churn by month, customer by customer.", "405 rows"]
    ];
    $("#reports").innerHTML = items.map(function (r) {
      return '<section class="card report"><span class="r-ico" style="background:' + r[2] + ";color:" + r[3] + '">' + L.icon(r[1], 20) + "</span>" +
        '<div class="r-txt"><b>' + r[4] + "</b><p>" + r[5] + '</p><div class="r-meta"><span>' + L.icon("csv", 16) + "</span>CSV · " + r[6] + " · " + month + "</div></div>" +
        '<div class="r-act"><a class="btn" href="/reports/' + r[0] + "-" + ym + '.csv">' + L.icon("download", 16) + "Export CSV</a></div></section>";
    }).join("");
    $("#scheduled").innerHTML = [
      ["Monthly close pack", "Payments, balance and payouts as CSV, emailed to finance@ternlabs.com on the 1st"],
      ["Weekly MRR digest", "Mondays at 9:00, to jonas@ternlabs.com and mira@ternlabs.com"]
    ].map(function (s) {
      return '<div class="li"><span class="logo" style="background:var(--brand)">' + L.icon("clock", 16) + '</span><div class="grow"><b>' + s[0] + "</b><span>" + s[1] + "</span></div>" + L.pill("Scheduled") + "</div>";
    }).join("");
  }

  /* ---------------------------------------------------------------- developers */

  function developers() {
    var PK = "pk_demo_51NqT8mLx2VcTRnB7yW3kQe5HfJ0aZpD";
    var SK = "sk_demo_51NqT8mLx2VcTRnB7Qp4ZsW8eYk2NuY3n";
    var RK1 = "rk_demo_51NqT8mLx2VcTRnB7Hj3KwP9sDf6GKx2p";
    var RK2 = "rk_demo_51NqT8mLx2VcTRnB7Ze4XcV1bN7mQMa8r";
    var WH1 = "whsec_demo_9fQk2LmT7vXc3RbN8sWd1YhJ5gPz0aEu";
    var WH2 = "whsec_demo_4TgH8nKq1ZcV6xLm3RbW9pYs2DfJ7uEa";
    var mask = function (k) {
      var head = /^whsec_demo_/.test(k) ? "whsec_demo_" : k.slice(0, k.indexOf("_", 3) + 1);
      return head + "•".repeat(/^whsec_demo_/.test(k) ? 12 : 24) + k.slice(-4);
    };
    function key(token, hidden, label) {
      return '<span class="key' + (hidden ? " masked" : "") + '" data-key="' + token + '" data-hidden="' + (hidden ? 1 : 0) + '">' +
        "<code>" + (hidden ? mask(token) : token) + "</code>" +
        (hidden ? '<button class="btn reveal" type="button">' + L.icon("eye", 16) + (label || "Reveal") + "</button>" : "") +
        '<button class="icon-btn copy" type="button" aria-label="Copy">' + L.icon("copy", 16) + "</button></span>";
    }
    $("#std-keys tbody").innerHTML =
      '<tr><td><b>Publishable key</b><span class="sub">For Tern’s web checkout</span></td><td>' + key(PK, false) + '</td><td class="date">Just now</td><td class="date hide-md">Mar 4, 2025</td>' + kebab() + "</tr>" +
      '<tr><td><b>Secret key</b><span class="sub">Tern’s backend only</span></td><td>' + key(SK, true, "Reveal live key") + '</td><td class="date">2 min ago</td><td class="date hide-md">Mar 4, 2025</td>' + kebab() + "</tr>";
    $("#rk-keys tbody").innerHTML =
      '<tr><td><b>Accounting export</b><span class="sub">Created by Jonas Berg</span></td><td>' + key(RK1, true) + '</td><td><span class="pill plain">Payments: read</span> <span class="pill plain">Customers: read</span></td><td class="date">3h ago</td>' + kebab() + "</tr>" +
      '<tr><td><b>Orbit analytics</b><span class="sub">Created by Elliot Park</span></td><td>' + key(RK2, true) + '</td><td><span class="pill plain">Subscriptions: read</span></td><td class="date">12 min ago</td>' + kebab() + "</tr>";
    $("#hooks tbody").innerHTML =
      '<tr><td><div class="endpoint"><span class="e-ico">' + L.icon("hook", 16) + '</span><div><b>https://api.ternlabs.com/hooks/ledger</b><span class="sub">Production · Tern API</span></div></div></td>' +
      '<td><span class="pill plain">invoice.payment_failed</span> <span class="muted">+6 more</span></td><td>' + key(WH1, true) + '</td><td class="r num">0.2%</td><td><span class="state"><i></i>Enabled</span></td></tr>' +
      '<tr><td><div class="endpoint"><span class="e-ico off">' + L.icon("hook", 16) + '</span><div><b>https://staging.ternlabs.com/hooks/ledger</b><span class="sub">Staging · paused by Sara Holm</span></div></div></td>' +
      '<td><span class="pill plain">invoice.paid</span> <span class="muted">+2 more</span></td><td>' + key(WH2, true) + '</td><td class="r num">0%</td><td><span class="state off"><i></i>Disabled</span></td></tr>';

    var log = [
      [200, "POST", "/v1/invoices/INV-2026-0944/finalize", "req_8Yb2kQf1LxW9", "ternlabs-api · node 20", 0.4],
      [200, "GET", "/v1/subscriptions?status=active&limit=100", "req_3Hn7ZpT4cVq2", "Orbit analytics", 2],
      [200, "POST", "/v1/customers/cus_Kitewing/update", "req_6Rd1MwE8sJk5", "ternlabs-api · node 20", 9],
      [400, "POST", "/v1/customers", "req_1Tg5XbN2yLp7", "ternlabs-api · email is invalid", 26],
      [200, "GET", "/v1/balance", "req_9Kc4VsA7mQe3", "Ledger dashboard", 41],
      [200, "POST", "/v1/refunds", "req_2Lp8QyH5tWz6", "ternlabs-api · node 20", 190],
      [402, "POST", "/v1/payment_intents/pi_3Q8nWd2e/confirm", "req_7Mx3CnF6rBu1", "Billing · card_declined", 300],
      [200, "GET", "/v1/invoices?customer=northwind", "req_5Wq9JkD2pEs8", "Accounting export", 310],
      [404, "GET", "/v1/invoices/INV-2026-0899", "req_4Zr6BvT1nXa9", "ternlabs-api · node 20", 420]
    ];
    $("#log tbody").innerHTML = log.map(function (r) {
      var cls = r[0] < 300 ? "c2" : r[0] === 402 ? "c402" : "c4";
      return '<tr><td><span class="code-pill ' + cls + '">' + r[0] + "</span></td>" +
        '<td><span class="verb">' + r[1] + '</span><span class="mono">' + L.esc(r[2]) + "</span></td>" +
        '<td class="hide-md"><span class="mono muted">' + r[3] + "</span></td>" +
        '<td class="src">' + L.esc(r[4]) + "</td>" +
        '<td class="date">' + L.time(L.minutesAgo(r[5])) + "</td></tr>";
    }).join("");

    $("#events-list").innerHTML = [
      ["invoice.finalized", "INV-2026-0944 for Bluefin Logistics", 1],
      ["invoice.paid", "INV-2026-0942 from Vesper Hotels, $3,000.00", 41],
      ["customer.subscription.updated", "Vesper Hotels went from 130 to 150 seats", 64],
      ["charge.refunded", "$36.00 back to Halcyon Labs", 190],
      ["invoice.payment_failed", "INV-2026-0941 from Northwind, card declined", 300]
    ].map(function (e) {
      return '<div class="li"><span class="logo" style="background:' + (/failed/.test(e[0]) ? "var(--danger-mark)" : "var(--brand)") + '">' + L.icon(/failed/.test(e[0]) ? "x" : "check", 16) + '</span><div class="grow"><b class="mono">' + e[0] + "</b><span>" + e[1] + '</span></div><div class="end"><span>' + L.ago(L.minutesAgo(e[2])) + "</span></div></div>";
    }).join("");

    document.addEventListener("click", function (e) {
      var reveal = e.target.closest(".reveal");
      var copy = e.target.closest(".copy");
      if (reveal) {
        var k = reveal.closest(".key");
        var hidden = k.getAttribute("data-hidden") === "1";
        var token = k.getAttribute("data-key");
        k.setAttribute("data-hidden", hidden ? "0" : "1");
        k.classList.toggle("masked", !hidden);
        k.querySelector("code").textContent = hidden ? token : mask(token);
        reveal.innerHTML = L.icon(hidden ? "eyeOff" : "eye", 16) + (hidden ? "Hide" : (/^sk_/.test(token) ? "Reveal live key" : "Reveal"));
      } else if (copy) {
        var key2 = copy.closest(".key");
        L.copy(key2.getAttribute("data-key"), copy);
      }
    });
  }

  /* ---------------------------------------------------------------- settings */

  function settings() {
    var rows = function (pairs) {
      return pairs.map(function (p) {
        return '<div class="li"><div class="grow"><span>' + p[0] + "</span><b>" + p[1] + "</b></div></div>";
      }).join("");
    };
    $("#business").innerHTML = rows([
      ["Legal name", "Tern Labs AB"],
      ["Address", "Hornsgatan 45, 118 49 Stockholm, Sweden"],
      ["VAT number", "SE559312874401"],
      ["Support email", "billing@ternlabs.com"],
      ["Statement descriptor", "TERN LABS"]
    ]);
    $("#payout-settings").innerHTML = rows([
      ["Bank account", "Tern Labs AB · ···· 4417"],
      ["Schedule", "Daily, two business days after payment"],
      ["Currency", "USD, converted to SEK on arrival"],
      ["Next payout", "$18,400.00 on " + L.date(L.daysFromNow(2))]
    ]);
    var last = ["Active now", "12 min ago", "1h ago", "Yesterday", "3 days ago"];
    $("#team tbody").innerHTML = L.team.map(function (p, i) {
      return '<tr><td><div class="who"><span class="face lg" style="background:' + p.color + '">' + L.initials(p.name) + "</span><b>" + L.esc(p.name) + "</b></div></td>" +
        '<td class="src">' + L.esc(p.email) + "</td><td>" + L.esc(p.role) + "</td>" +
        "<td>" + (i < 2 ? '<span class="pill violet">Administrator</span>' : i === 2 ? '<span class="pill info">Analyst</span>' : '<span class="pill plain">Developer</span>') + "</td>" +
        '<td class="date">' + last[i] + "</td></tr>";
    }).join("");
  }

  var run = {
    payments: payments, invoices: invoices, customers: customers, expenses: expenses,
    "expense-new": expenseNew, reports: reports, developers: developers, settings: settings
  };
  if (run[page]) run[page]();
  L.icons();
  spotlight();
  window.addEventListener("hashchange", spotlight);
})();
