(function () {
  "use strict";

  var editor = document.getElementById("editor");
  if (!editor) return;
  var key = "paper:doc:" + editor.dataset.slug;
  var world = editor.dataset.world;
  var rail = document.getElementById("rail");
  var outline = document.getElementById("outline");
  var savedLabel = document.getElementById("saved");
  var editedLabel = document.getElementById("edited");

  function read() {
    try { return JSON.parse(localStorage.getItem(key) || "null"); } catch (e) { return null; }
  }
  function write(value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {}
  }

  // New lines are paragraphs, as the rest of the document is.
  try { document.execCommand("defaultParagraphSeparator", false, "p"); } catch (e) {}

  // When it was last changed, in words.
  var stored = read();
  var resolved = stored && stored.world === world && stored.resolved ? stored.resolved : [];
  var editedAt = editor.dataset.restored ? Number(editor.dataset.restored) : 0;
  function ago(at) {
    var s = (Date.now() - at) / 1000;
    if (s < 45) return "just now";
    if (s < 3600) return Math.max(1, Math.round(s / 60)) + "m ago";
    if (s < 86400) return Math.round(s / 3600) + "h ago";
    return new Date(at).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  }
  function showEdited() {
    if (editedAt) editedLabel.textContent = "Edited " + ago(editedAt);
  }
  showEdited();
  setInterval(showEdited, 30000);

  // Saved a moment after the typing stops.
  var timer = null;
  function save() {
    timer = null;
    write({ world: world, html: editor.innerHTML, at: editedAt, resolved: resolved });
    savedLabel.dataset.state = "saved";
    savedLabel.lastChild.textContent = "Saved";
  }
  function changed() {
    editedAt = Date.now();
    showEdited();
    savedLabel.dataset.state = "saving";
    savedLabel.lastChild.textContent = "Saving…";
    clearTimeout(timer);
    timer = setTimeout(save, 650);
    later();
  }
  editor.addEventListener("input", changed);
  window.addEventListener("beforeunload", function () { if (timer) { clearTimeout(timer); save(); } });

  // Pasted text comes in as text, in the document's own style.
  editor.addEventListener("paste", function (e) {
    var text = e.clipboardData && e.clipboardData.getData("text/plain");
    if (!text) return;
    e.preventDefault();
    document.execCommand("insertText", false, text);
  });

  // A checklist's boxes tick.
  editor.addEventListener("mousedown", function (e) {
    var li = e.target.closest && e.target.closest("ul.todo > li");
    if (!li || e.clientX - li.getBoundingClientRect().left > 22) return;
    e.preventDefault();
    li.dataset.done = li.dataset.done === "true" ? "false" : "true";
    changed();
  });

  // The outline: every heading, the one you are reading lit.
  var heads = [];
  function buildOutline() {
    heads = [].slice.call(editor.querySelectorAll("h2, h3")).filter(function (h) { return h.textContent.trim(); });
    outline.innerHTML = heads.length ? "" : '<p class="outline-empty">Headings you add show up here.</p>';
    heads.forEach(function (h) {
      var a = document.createElement("a");
      a.href = "#";
      a.className = h.tagName.toLowerCase();
      a.textContent = h.textContent.trim();
      a.addEventListener("click", function (e) {
        e.preventDefault();
        window.scrollTo({ top: h.getBoundingClientRect().top + window.scrollY - 84, behavior: "smooth" });
      });
      outline.appendChild(a);
    });
    spy();
  }
  function spy() {
    var links = outline.children, lit = -1;
    for (var i = 0; i < heads.length; i++) {
      if (heads[i].getBoundingClientRect().top < 140) lit = i;
    }
    if (lit < 0 && heads.length) lit = 0;
    for (var j = 0; j < links.length; j++) links[j].classList.toggle("on", j === lit);
  }

  // Comments sit by the words they are about, one under another: a card's
  // name row is centered on the first line of its words, 12 between cards.
  var lit = null;
  var GAP = 12;
  function anchor(id) { return editor.querySelector('[data-comment="' + id + '"]'); }
  function headCenter(card) {
    var head = card.querySelector(".cc-top");
    return head ? card.clientTop + head.offsetTop + head.offsetHeight / 2 : 0;
  }
  function place() {
    if (!rail) return;
    var top0 = rail.getBoundingClientRect().top;
    var items = [].slice.call(rail.querySelectorAll(".cc")).filter(function (c) {
      var done = resolved.indexOf(c.dataset.for) >= 0;
      c.hidden = done;
      return !done;
    }).map(function (c) {
      var a = anchor(c.dataset.for);
      var line = a && (a.getClientRects()[0] || a.getBoundingClientRect());
      return { card: c, anchor: a, top: line ? Math.round((line.top + line.bottom) / 2 - top0 - headCenter(c)) : Infinity };
    });
    items.sort(function (x, y) { return x.top - y.top; });
    var bottom = -Infinity;
    items.forEach(function (it) {
      var top = isFinite(it.top) ? it.top : bottom + GAP;
      top = Math.max(top, bottom + GAP, 0);
      it.card.style.top = top + "px";
      it.card.classList.toggle("gone", !it.anchor);
      bottom = top + it.card.offsetHeight;
    });
    rail.style.minHeight = Math.max(0, bottom) + "px";
    rail.classList.add("ready");
  }
  function light(id) {
    lit = id;
    rail.querySelectorAll(".cc").forEach(function (c) { c.classList.toggle("on", c.dataset.for === id); });
    editor.querySelectorAll(".cmt").forEach(function (s) { s.classList.toggle("on", s.dataset.comment === id); });
    place();
  }
  if (rail) {
    rail.addEventListener("click", function (e) {
      var card = e.target.closest(".cc");
      if (!card) return;
      if (e.target.closest(".cc-resolve")) {
        var id = card.dataset.for, a = anchor(id);
        if (a) {
          while (a.firstChild) a.parentNode.insertBefore(a.firstChild, a);
          a.remove();
        }
        resolved.push(id);
        card.classList.add("done");
        setTimeout(function () { light(null); changed(); }, 180);
        return;
      }
      if (lit !== card.dataset.for) light(card.dataset.for);
    });
  }
  editor.addEventListener("click", function (e) {
    var span = e.target.closest && e.target.closest(".cmt");
    if (span) light(span.dataset.comment);
    else if (lit) light(null);
  });
  document.addEventListener("click", function (e) {
    if (lit && !e.target.closest(".cc") && !e.target.closest(".cmt") && !editor.contains(e.target)) light(null);
  });

  // Layout follows the words: after typing, a resize, the fonts.
  var pending = null;
  function later() {
    clearTimeout(pending);
    pending = setTimeout(function () { buildOutline(); place(); }, 120);
  }
  buildOutline();
  place();
  window.addEventListener("resize", later);
  window.addEventListener("load", later);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(later);
  var ticking = false;
  window.addEventListener("scroll", function () {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () { ticking = false; spy(); });
  }, { passive: true });

  // Top bar: star, comments, share.
  var star = document.querySelector(".star");
  if (star) star.addEventListener("click", function () {
    star.setAttribute("aria-pressed", star.getAttribute("aria-pressed") === "true" ? "false" : "true");
  });
  var commentsBtn = document.getElementById("comments-btn");
  if (commentsBtn && rail) commentsBtn.addEventListener("click", function () {
    rail.style.visibility = rail.style.visibility === "hidden" ? "" : "hidden";
  });
  var share = document.getElementById("share-btn");
  var pop = document.getElementById("share-pop");
  function closeShare() { pop.hidden = true; share.setAttribute("aria-expanded", "false"); }
  if (share && pop) {
    share.addEventListener("click", function (e) {
      e.stopPropagation();
      pop.hidden = !pop.hidden;
      share.setAttribute("aria-expanded", String(!pop.hidden));
      if (!pop.hidden) pop.querySelector("input").focus();
    });
    document.addEventListener("click", function (e) { if (!pop.hidden && !pop.contains(e.target)) closeShare(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !pop.hidden) closeShare(); });
    document.getElementById("share-done").addEventListener("click", closeShare);
    var copy = document.getElementById("copy-link");
    copy.addEventListener("click", function () {
      if (navigator.clipboard) navigator.clipboard.writeText(location.origin + location.pathname).catch(function () {});
      copy.lastChild.textContent = "Copied";
      setTimeout(function () { copy.lastChild.textContent = "Copy link"; }, 1500);
    });
  }
})();
