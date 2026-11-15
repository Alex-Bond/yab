/* Tern Labs' books, as Ledger keeps them. Times are relative to page load. */
(function () {
  "use strict";
  var L = (window.L = window.L || {});

  L.customers = [
    { id: "northwind", name: "Northwind", legal: "Northwind Studio AB", email: "billing@northwind.io", plan: "Team", billing: "annual", seats: 12, mrr: 112, color: "#2563eb", since: "Mar 2025", status: "Past due", country: "SE", method: { brand: "visa", last4: "8836" } },
    { id: "vesper", name: "Vesper Hotels", email: "accounts@vesperhotels.com", plan: "Business", seats: 150, color: "#7c3aed", since: "Nov 2024", status: "Active", country: "US", method: { brand: "amex", last4: "1009" } },
    { id: "brightline", name: "Brightline", email: "accounts@brightline.health", plan: "Business", seats: 120, color: "#0891b2", since: "Aug 2024", status: "Active", country: "DE", method: { brand: "bank", kind: "SEPA", last4: "3301" } },
    { id: "fjell", name: "Fjell Studio", email: "finance@fjellstudio.no", plan: "Business", seats: 45, color: "#0f766e", since: "Jun 2025", status: "Active", country: "NO", method: { brand: "mc", last4: "5521" } },
    { id: "copperleaf", name: "Copperleaf", email: "ap@copperleaf.io", plan: "Team", seats: 32, color: "#c2410c", since: "Jan 2025", status: "Active", country: "GB", method: { brand: "visa", last4: "0417" } },
    { id: "kestrel", name: "Kestrel Health", email: "ap@kestrelhealth.se", plan: "Business", seats: 85, color: "#be185d", since: "Apr 2025", status: "Active", country: "SE", method: { brand: "bank", kind: "Bank", last4: "6610" } },
    { id: "kitewing", name: "Kitewing Robotics", email: "finance@kitewing.dev", plan: "Business", seats: 40, color: "#ea580c", since: "Sep 2026", status: "Active", country: "US", method: { brand: "visa", last4: "4418" } },
    { id: "oakridge", name: "Oakridge & Co", email: "finance@oakridgeco.com", plan: "Business", seats: 60, color: "#15803d", since: "Feb 2025", status: "Active", country: "US", method: { brand: "mc", last4: "7712" } },
    { id: "mosaic", name: "Mosaic Learning", email: "finance@mosaiclearning.org", plan: "Business", seats: 70, color: "#db2777", since: "Oct 2024", status: "Active", country: "US", method: { brand: "bank", kind: "ACH", last4: "1182" } },
    { id: "halcyon", name: "Halcyon Labs", email: "billing@halcyonlabs.ai", plan: "Team", seats: 15, color: "#4f46e5", since: "Jul 2025", status: "Active", country: "US", method: { brand: "visa", last4: "2290" } },
    { id: "meridian", name: "Meridian Freight", email: "invoices@meridianfreight.com", plan: "Team", seats: 40, color: "#0369a1", since: "Dec 2024", status: "Active", country: "US", method: { brand: "mc", last4: "4471" } },
    { id: "bluefin", name: "Bluefin Logistics", email: "ap@bluefinlogistics.com", plan: "Team", seats: 36, color: "#1d4ed8", since: "Jan 2025", status: "Active", country: "NL", method: { brand: "visa", last4: "7741" } },
    { id: "fernway", name: "Fernway", email: "billing@fernway.app", plan: "Team", seats: 28, color: "#16a34a", since: "Mar 2025", status: "Active", country: "US", method: { brand: "amex", last4: "2004" } },
    { id: "nordlys", name: "Nordlys Media", email: "finance@nordlys.media", plan: "Team", seats: 22, color: "#9333ea", since: "Aug 2025", status: "Past due", country: "NO", method: { brand: "visa", last4: "6603" } },
    { id: "pinecrest", name: "Pinecrest Schools", email: "it@pinecrest.edu", plan: "Starter", seats: 25, color: "#059669", since: "Sep 2024", status: "Active", country: "US", method: { brand: "bank", kind: "ACH", last4: "9930" } },
    { id: "arbor", name: "Arbor Legal", email: "billing@arborlegal.co.uk", plan: "Team", seats: 14, color: "#334155", since: "May 2025", status: "Past due", country: "GB", method: { brand: "visa", last4: "3158" } },
    { id: "quarry", name: "Quarry Design", email: "studio@quarry.design", plan: "Team", seats: 9, color: "#57534e", since: "Jun 2025", status: "Past due", country: "DK", method: { brand: "visa", last4: "5530" } },
    { id: "saltmarsh", name: "Saltmarsh Coffee", email: "hello@saltmarsh.coffee", plan: "Starter", seats: 6, color: "#a16207", since: "Sep 2025", status: "Active", country: "US", method: { brand: "visa", last4: "9024" } },
    { id: "solberg", name: "Solberg Architects", email: "office@solbergark.no", plan: "Business", seats: 18, color: "#0e7490", since: "Sep 2026", status: "Trialing", country: "NO", method: { brand: "mc", last4: "2087" } },
    { id: "ember", name: "Ember & Oak", email: "hello@emberandoak.com", plan: "Starter", seats: 4, color: "#b45309", since: "Aug 2025", status: "Canceled", country: "US", method: { brand: "visa", last4: "1276" } }
  ];
  L.prices = { Starter: 8, Team: 12, Business: 20 };
  L.customer = function (id) {
    for (var i = 0; i < L.customers.length; i++) if (L.customers[i].id === id) return L.customers[i];
    return null;
  };
  L.customers.forEach(function (c) {
    if (c.mrr == null) c.mrr = c.status === "Canceled" || c.status === "Trialing" ? 0 : c.seats * L.prices[c.plan];
  });

  // ago: minutes before page load.
  L.payments = [
    { id: "py_3Q8nRa2eZvKYlo2C1bH7mW0e", customer: "vesper", amount: 3000, status: "Succeeded", desc: "Tern Business · 150 seats", ago: 41 },
    { id: "py_3Q8nNc2eZvKYlo2C0cV2pL8s", customer: "fjell", amount: 900, status: "Succeeded", desc: "Tern Business · 45 seats", ago: 76 },
    { id: "py_3Q8nJk2eZvKYlo2C1kD4rE6t", customer: "copperleaf", amount: 384, status: "Succeeded", desc: "Tern Team · 32 seats", ago: 128 },
    { id: "py_3Q8nFo2eZvKYlo2C0fN8aY3u", customer: "halcyon", amount: 36, status: "Refunded", desc: "Seat refund · 3 seats", ago: 190 },
    { id: "py_3Q8nBw2eZvKYlo2C1pS5gU7v", customer: "brightline", amount: 2400, status: "Succeeded", desc: "Tern Business · 120 seats", ago: 245 },
    { id: "py_3Q8nWd2eZvKYlo2C0x1kTq4R", customer: "northwind", amount: 240, status: "Failed", desc: "Tern Team, annual · Focus insights", ago: 300, reason: "Card declined: insufficient funds" },
    { id: "py_3Q8mXy2eZvKYlo2C0aQ1hI9w", customer: "kestrel", amount: 1700, status: "Pending", desc: "Tern Business · 85 seats", ago: 312 },
    { id: "py_3Q8mTb2eZvKYlo2C1zM6jO2x", customer: "kitewing", amount: 800, status: "Succeeded", desc: "Tern Business · 40 seats", ago: 520 },
    { id: "py_3Q8lPq2eZvKYlo2C0eK3vB5y", customer: "oakridge", amount: 1200, status: "Succeeded", desc: "Tern Business · 60 seats", ago: 1290 },
    { id: "py_3Q8lLr2eZvKYlo2C1rT9nC8z", customer: "saltmarsh", amount: 48, status: "Succeeded", desc: "Tern Starter · 6 seats", ago: 1420 },
    { id: "py_3Q8lHs2eZvKYlo2C0wG4xD1a", customer: "meridian", amount: 480, status: "Succeeded", desc: "Tern Team · 40 seats", ago: 1630 },
    { id: "py_3Q8kDt2eZvKYlo2C1uF7yE4b", customer: "mosaic", amount: 1400, status: "Succeeded", desc: "Tern Business · 70 seats", ago: 2600 },
    { id: "py_3Q8k5v2eZvKYlo2C1oL5aG0d", customer: "bluefin", amount: 432, status: "Succeeded", desc: "Tern Team · 36 seats", ago: 2890 },
    { id: "py_3Q8iXx2eZvKYlo2C1tR1cJ6f", customer: "fernway", amount: 336, status: "Succeeded", desc: "Tern Team · 28 seats", ago: 3400 },
    { id: "py_3Q8hPz2eZvKYlo2C1hU7eL2h", customer: "pinecrest", amount: 200, status: "Succeeded", desc: "Tern Starter · 25 seats", ago: 4380 },
    { id: "py_3Q8hLa2eZvKYlo2C0jW0fM5i", customer: "ember", amount: 32, status: "Refunded", desc: "Canceled plan · prorated", ago: 5020 },
    { id: "py_3Q8gHb2eZvKYlo2C1kX3gN8j", customer: "vesper", amount: 400, status: "Succeeded", desc: "Seat add-on · 20 seats", ago: 5610 },
    { id: "py_3Q8gDc2eZvKYlo2C0lZ6hP1k", customer: "copperleaf", amount: 96, status: "Succeeded", desc: "Seat add-on · 8 seats", ago: 6120 },
    { id: "py_3Q8f9d2eZvKYlo2C1mA9iQ4l", customer: "fjell", amount: 120, status: "Succeeded", desc: "Seat add-on · 6 seats", ago: 7010 },
    { id: "py_3Q8f5e2eZvKYlo2C0nB2jR7m", customer: "halcyon", amount: 216, status: "Succeeded", desc: "Tern Team · 18 seats", ago: 7930 },
    { id: "py_3Q8e1f2eZvKYlo2C1pC5kS0n", customer: "kestrel", amount: 340, status: "Succeeded", desc: "Seat add-on · 17 seats", ago: 8650 },
    { id: "py_3Q8dXg2eZvKYlo2C0qD8lT3o", customer: "arbor", amount: 168, status: "Failed", desc: "Tern Team · 14 seats", ago: 12960, reason: "Card declined: do not honor" },
    { id: "py_3Q8cTh2eZvKYlo2C1rE1mU6p", customer: "nordlys", amount: 264, status: "Failed", desc: "Tern Team · 22 seats", ago: 23040, reason: "Card expired" },
    { id: "py_3Q8bPi2eZvKYlo2C0sF4nV9q", customer: "quarry", amount: 108, status: "Failed", desc: "Tern Team · 9 seats", ago: 30240, reason: "Retries exhausted" }
  ];
  L.payments.forEach(function (p) {
    p.at = L.minutesAgo(p.ago);
    p.method = L.customer(p.customer).method;
  });

  // created and due: days from today (negative is past).
  L.invoices = [
    { number: "INV-2026-0944", customer: "bluefin", amount: 432, status: "Draft", created: 0, due: 30, item: "Tern Team · 36 seats" },
    { number: "INV-2026-0943", customer: "fernway", amount: 336, status: "Draft", created: 0, due: 30, item: "Tern Team · 28 seats" },
    { number: "INV-2026-0942", customer: "vesper", amount: 3000, status: "Paid", created: 0, due: 0, item: "Tern Business · 150 seats" },
    { number: "INV-2026-0941", customer: "northwind", amount: 240, status: "Past due", created: 0, due: 0, item: "Focus insights, annual", note: "Payment failed" },
    { number: "INV-2026-0940", customer: "fjell", amount: 900, status: "Paid", created: 0, due: 0, item: "Tern Business · 45 seats" },
    { number: "INV-2026-0939", customer: "copperleaf", amount: 384, status: "Paid", created: 0, due: 0, item: "Tern Team · 32 seats" },
    { number: "INV-2026-0938", customer: "kestrel", amount: 1700, status: "Open", created: 0, due: 7, item: "Tern Business · 85 seats", note: "Bank debit processing" },
    { number: "INV-2026-0937", customer: "brightline", amount: 2400, status: "Paid", created: 0, due: 0, item: "Tern Business · 120 seats" },
    { number: "INV-2026-0936", customer: "kitewing", amount: 800, status: "Paid", created: 0, due: 0, item: "Tern Business · 40 seats" },
    { number: "INV-2026-0935", customer: "oakridge", amount: 1200, status: "Paid", created: -1, due: -1, item: "Tern Business · 60 seats" },
    { number: "INV-2026-0934", customer: "saltmarsh", amount: 48, status: "Paid", created: -1, due: -1, item: "Tern Starter · 6 seats" },
    { number: "INV-2026-0933", customer: "meridian", amount: 480, status: "Paid", created: -1, due: -1, item: "Tern Team · 40 seats" },
    { number: "INV-2026-0932", customer: "pinecrest", amount: 2400, status: "Open", created: -2, due: 28, item: "Tern Starter, annual · 25 seats", note: "Net 30 · bank transfer" },
    { number: "INV-2026-0931", customer: "mosaic", amount: 1400, status: "Paid", created: -2, due: -2, item: "Tern Business · 70 seats" },
    { number: "INV-2026-0929", customer: "arbor", amount: 168, status: "Past due", created: -9, due: -9, item: "Tern Team · 14 seats", note: "Card declined" },
    { number: "INV-2026-0926", customer: "nordlys", amount: 264, status: "Past due", created: -16, due: -16, item: "Tern Team · 22 seats", note: "Card expired" },
    { number: "INV-2026-0921", customer: "quarry", amount: 108, status: "Past due", created: -21, due: -21, item: "Tern Team · 9 seats", note: "Retries exhausted" },
    { number: "INV-2026-0918", customer: "northwind", amount: 2240, status: "Open", created: -12, due: 2, item: "Tern Team, annual · 12 seats" },
    { number: "INV-2026-0915", customer: "ember", amount: 32, status: "Void", created: -15, due: null, item: "Tern Starter · 4 seats" }
  ];

  // Movements behind this month's MRR, customer by customer.
  L.movements = [
    { kind: "New", customer: "kitewing", amount: 800, note: "Tern Business · 40 seats" },
    { kind: "Expansion", customer: "vesper", amount: 400, note: "20 seats added" },
    { kind: "Expansion", customer: "kestrel", amount: 340, note: "17 seats added" },
    { kind: "Expansion", customer: "copperleaf", amount: 96, note: "8 seats added" },
    { kind: "Contraction", customer: "halcyon", amount: -36, note: "3 seats removed" },
    { kind: "Churned", customer: "ember", amount: -32, note: "Canceled Tern Starter" }
  ];

  // Months ending with the current one: MRR, a year before, subscriptions, net volume.
  L.mrr = [30180, 31120, 31480, 33610, 35020, 36110, 38240, 39680, 41350, 43960, 46064, 48920];
  L.mrrPrev = [17240, 17980, 18310, 19720, 20560, 21480, 22950, 24010, 25230, 26840, 28120, 29660];
  L.subs = [842, 871, 889, 925, 951, 984, 1031, 1072, 1118, 1169, 1242, 1284];
  L.subsPrev = [512, 534, 547, 571, 590, 612, 640, 668, 694, 723, 760, 801];
  L.volume = [32410, 33980, 35620, 36110, 38240, 39870, 41960, 43120, 45380, 47210, 49030, 51872];
  L.volumePrev = [18920, 19640, 20410, 21380, 22050, 23260, 24510, 25790, 26880, 28120, 29750, 31260];
  L.months = (function () {
    var out = [];
    var d = new Date(L.now);
    for (var i = 11; i >= 0; i--) out.push(new Date(d.getFullYear(), d.getMonth() - i, 1));
    return out;
  })();

  L.team = [
    { name: "Mira Lindqvist", email: "mira@ternlabs.com", role: "Founding Designer", color: "linear-gradient(135deg,#f6a96b,#d9577a)" },
    { name: "Jonas Berg", email: "jonas@ternlabs.com", role: "CEO, co-founder", color: "#2563eb" },
    { name: "Anna Ek", email: "anna@ternlabs.com", role: "Product lead", color: "#0d9488" },
    { name: "Elliot Park", email: "elliot@ternlabs.com", role: "Engineer", color: "#7c3aed" },
    { name: "Sara Holm", email: "sara@ternlabs.com", role: "Engineer", color: "#db2777" }
  ];
  L.person = function (name) {
    for (var i = 0; i < L.team.length; i++) if (L.team[i].name === name) return L.team[i];
    return { name: name, color: "#64748b" };
  };

  L.paymentRow = function (p) {
    var c = L.customer(p.customer);
    return '<tr data-id="' + p.id + '" id="' + p.id + '">' +
      '<td class="r"><span class="amt">' + L.money(p.amount) + '</span><span class="cur">USD</span></td>' +
      '<td data-status>' + L.pill(p.status) + "</td>" +
      '<td><div class="who">' + L.logo(c) + "<div><b>" + L.esc(c.name) + '</b><span class="sub">' + L.esc(c.email) + "</span></div></div></td>" +
      '<td class="desc">' + L.esc(p.desc) + (p.reason ? '<span class="sub why">' + L.esc(p.reason) + "</span>" : "") + "</td>" +
      '<td class="hide-md">' + L.method(p.method) + "</td>" +
      '<td class="date">' + L.dateTime(p.at) + "</td>" +
      '<td class="r"><button class="icon-btn kebab" type="button" aria-label="More">' + L.icon("more", 16) + "</button></td>" +
      "</tr>";
  };
})();
