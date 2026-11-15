/* Drift: one page that draws Home, Stations, Library and every station, mix
   and single itself, so the player at the bottom keeps playing from page to
   page. The music is one <audio> element; the page's MediaSession says what
   it plays, and its own Previous track and Next track buttons are the ones a
   browser can press. Nothing plays until someone presses Play. */
(() => {
  "use strict";

  const C = window.DRIFT;
  for (const [id, t] of Object.entries(C.tracks)) t.id = id;
  const DEFAULT = "station:morning-fog";

  const $ = (sel, el = document) => el.querySelector(sel);
  const $$ = (sel, el = document) => Array.from(el.querySelectorAll(sel));
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const fmt = (s) => { s = Math.max(0, Math.floor(s || 0)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
  const length = (ids) => {
    const m = Math.round(ids.reduce((sum, id) => sum + C.tracks[id].duration, 0) / 60);
    return m >= 60 ? `${Math.floor(m / 60)} hr ${m % 60} min` : `${m} min`;
  };
  const store = {
    get(key, fallback) {
      try { const v = localStorage.getItem("drift." + key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
    },
    set(key, value) {
      try { localStorage.setItem("drift." + key, JSON.stringify(value)); } catch { /* private window: forget it */ }
    },
  };

  // ------------------------------------------------------------- icons

  const S = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
  const svg = (body, attrs = "") => `<svg viewBox="0 0 24 24" aria-hidden="true" ${attrs}>${body}</svg>`;
  const SPEAKER = '<path fill="currentColor" stroke="none" d="M3.5 9.6v4.8a1 1 0 0 0 1 1h2.7l4.2 3.5c.5.4 1.1 0 1.1-.6V5.7c0-.6-.6-1-1.1-.6L7.2 8.6H4.5a1 1 0 0 0-1 1Z"/>';
  const REPEAT = '<path d="M17 3.5 19.5 6 17 8.5"/><path d="M4.5 11.5V10a4 4 0 0 1 4-4h11"/><path d="M7 20.5 4.5 18 7 15.5"/><path d="M19.5 12.5V14a4 4 0 0 1-4 4h-11"/>';
  const HEART = "M12 20.2s-7.6-4.6-7.6-10.2A4.4 4.4 0 0 1 12 7.3 4.4 4.4 0 0 1 19.6 10c0 5.6-7.6 10.2-7.6 10.2Z";
  const ICONS = {
    play: svg('<path fill="currentColor" d="M7.2 5.2v13.6a1 1 0 0 0 1.53.85l10.4-6.8a1 1 0 0 0 0-1.7L8.73 4.35A1 1 0 0 0 7.2 5.2Z"/>'),
    pause: svg('<rect x="6" y="4.6" width="4.3" height="14.8" rx="1.4" fill="currentColor"/><rect x="13.7" y="4.6" width="4.3" height="14.8" rx="1.4" fill="currentColor"/>'),
    next: svg('<path fill="currentColor" d="M5 6.1v11.8a1 1 0 0 0 1.56.83l8.5-5.9a1 1 0 0 0 0-1.66l-8.5-5.9A1 1 0 0 0 5 6.1Z"/><rect x="16.4" y="5" width="2.6" height="14" rx="1.3" fill="currentColor"/>'),
    prev: svg('<path fill="currentColor" d="M19 6.1v11.8a1 1 0 0 1-1.56.83l-8.5-5.9a1 1 0 0 1 0-1.66l8.5-5.9A1 1 0 0 1 19 6.1Z"/><rect x="5" y="5" width="2.6" height="14" rx="1.3" fill="currentColor"/>'),
    shuffle: svg('<path d="M3.5 7h2.8c1.5 0 2.9.8 3.7 2l4 6c.8 1.2 2.2 2 3.7 2h2.8"/><path d="M3.5 17h2.8c1.5 0 2.9-.8 3.7-2l.4-.6"/><path d="M13.6 9.6l.4-.6c.8-1.2 2.2-2 3.7-2h2.8"/><path d="M18 4.5 20.5 7 18 9.5"/><path d="M18 14.5l2.5 2.5-2.5 2.5"/>', S),
    repeat: svg(REPEAT, S),
    repeatOne: svg(REPEAT + '<path d="M11 10.6l1.3-.8v4.6"/>', S),
    heart: svg(`<path d="${HEART}"/>`, S),
    heartFill: svg(`<path d="${HEART}" fill="currentColor"/>`, S),
    queue: svg('<path d="M4 6.5h16M4 12h9M4 17.5h9"/><path fill="currentColor" stroke="none" d="M15.8 12.9v6.2c0 .5.6.8 1 .5l4.6-3.1a.6.6 0 0 0 0-1l-4.6-3.1c-.4-.3-1 0-1 .5Z"/>', S),
    volume: svg(SPEAKER + '<path d="M15.8 9a4.3 4.3 0 0 1 0 6"/><path d="M18.6 6.3a8.2 8.2 0 0 1 0 11.4"/>', S),
    volumeLow: svg(SPEAKER + '<path d="M15.8 9a4.3 4.3 0 0 1 0 6"/>', S),
    mute: svg(SPEAKER + '<path d="m16 9.5 5 5m0-5-5 5"/>', S),
    home: svg('<path d="M4 10.4 12 4l8 6.4V19a1 1 0 0 1-1 1h-4.6v-5.6H9.6V20H5a1 1 0 0 1-1-1Z"/>', S),
    radio: svg('<circle cx="12" cy="12" r="2"/><path d="M8.3 15.7a5.3 5.3 0 0 1 0-7.4m7.4 0a5.3 5.3 0 0 1 0 7.4M5.4 18.6a9.4 9.4 0 0 1 0-13.2m13.2 0a9.4 9.4 0 0 1 0 13.2"/>', S),
    library: svg('<path d="M5 4v16M9.5 4v16"/><path d="m14 4.8 4.8 15"/>', S),
    search: svg('<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.1-4.1"/>', S),
    close: svg('<path d="M6.5 6.5l11 11m0-11-11 11"/>', S),
    clock: svg('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.6V12l2.9 1.9"/>', S),
    add: svg('<circle cx="12" cy="12" r="9"/><path d="M12 8v8m-4-4h8"/>', S),
    added: svg('<circle cx="12" cy="12" r="9.6" fill="currentColor" stroke="none"/><path d="m7.8 12.3 2.8 2.8 5.6-5.8" stroke="#0b0c10" stroke-width="2.2"/>', S),
  };
  const icon = (name) => ICONS[name] || "";
  const MARK = '<svg class="mini-mark" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="15" fill="#ff7458"/><path d="M18 37 A14 14 0 0 1 46 37 Z" fill="#fff"/><path d="M10 44 q5.5 -4.5 11 0 t11 0 t11 0 t11 0" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round"/><path d="M17 53 q5 -4 10 0 t10 0 t10 0" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round" opacity=".85"/></svg>';

  for (const node of $$("[data-icon]")) node.outerHTML = icon(node.dataset.icon);

  // ------------------------------------------------------------- the catalog

  const KINDS = {
    station: C.stations,
    mix: C.mixes,
    album: Object.fromEntries(Object.values(C.tracks).map((t) => [t.id, { title: t.album, about: "", tracks: [t.id], tint: t.tint }])),
  };
  const liked = () => store.get("liked", C.liked).filter((id) => C.tracks[id]);
  const saved = () => store.get("saved", ["station:morning-fog", "station:night-swim", ...Object.keys(C.mixes).map((id) => "mix:" + id), "album:low-tide", "album:paper-lanterns", "album:night-ferry"]);

  /** A station, mix, single or Liked Tracks, by its key ("station:night-swim"). */
  function col(key) {
    if (!key) return null;
    const [kind, id] = key.split(":");
    if (kind === "liked") return { kind, id: "all", key: "liked:all", title: "Liked Tracks", about: "", tracks: liked(), tint: "#6b4fd8", href: "/liked" };
    const c = KINDS[kind] && KINDS[kind][id];
    return c ? { ...c, kind, id, key, href: `/${kind}/${id}`, art: `/covers/${id}.svg` } : null;
  }
  const home = (id) => {
    const station = Object.keys(C.stations).find((s) => C.stations[s].tracks.includes(id));
    return station ? `station:${station}` : `album:${id}`;
  };

  // ------------------------------------------------------------- the player

  const audio = $("#audio");
  const ms = "mediaSession" in navigator ? navigator.mediaSession : null;
  const el = {
    np: $("#np"), img: $("#np-img"), art: $("#np-art"), title: $("#np-title"), artist: $("#np-artist"), like: $("#np-like"),
    play: $("#play"), prev: $("#prev"), next: $("#next"), shuffle: $("#shuffle"), repeat: $("#repeat"),
    elapsed: $("#elapsed"), total: $("#total"), scrub: $("#scrub"), fill: $("#fill"), knob: $("#knob-rail"), mini: $("#mini-fill"),
    vol: $("#vol"), volFill: $("#vol-fill"), volKnob: $("#vol-rail"), mute: $("#mute"),
    queueBtn: $("#queue-btn"), queue: $("#queue"), queueBody: $("#queue-body"),
  };
  const P = {
    ctx: null,          // what plays: a collection's key
    order: [],          // its tracks, in the order they play
    i: 0,
    want: false,        // someone wants it playing (the page shows it playing)
    switching: false,   // a play is under way; a pause on the way doesn't count
    loaded: null,       // the track the <audio> element has
    resume: 0,          // where to start the next load, for a restored session
    dragging: false,
    dragAt: 0,
    turn: 0,            // counts plays, so an old one's answer is known as old
    repeat: store.get("repeat", "all"),
    shuffle: store.get("shuffle", false),
    volume: clamp(Number(store.get("volume", 0.8)) || 0.8, 0, 1),
    muted: false,
  };
  const current = () => C.tracks[P.order[P.i]];
  const duration = () => (P.loaded === P.order[P.i] && isFinite(audio.duration) && audio.duration > 0 ? audio.duration : (current() || {}).duration || 0);
  const position = () => (P.dragging ? P.dragAt : P.loaded === P.order[P.i] && audio.getAttribute("src") ? audio.currentTime : P.resume);

  function setContext(key, i = 0) {
    const c = col(key);
    let ids = c.tracks.slice();
    if (P.shuffle && ids.length > 1) {
      const first = ids.splice(i, 1)[0];
      for (let k = ids.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [ids[k], ids[j]] = [ids[j], ids[k]]; }
      ids = [first, ...ids];
      i = 0;
    }
    P.ctx = key;
    P.order = ids;
    P.i = i;
    P.resume = 0;
    remember(key);
  }

  function ensureLoaded() {
    const t = current();
    if (P.loaded === t.id && audio.getAttribute("src")) return;
    const fresh = P.loaded !== null && P.loaded !== t.id;
    P.loaded = t.id;
    setMeta(t);
    audio.src = `/audio/${t.id}.m4a?v=${C.audio}`;
    if (P.resume > 0) { try { audio.currentTime = P.resume; } catch { /* starts at 0 */ } }
    P.resume = 0;
    showTrack(t, fresh);
  }

  function play() {
    if (!P.order.length) setContext(DEFAULT, 0);
    ensureLoaded();
    P.want = true;
    P.switching = true;
    const turn = ++P.turn;
    loadingSoon();
    syncUI();
    const started = audio.play();
    if (started && started.then) {
      started.then(() => { if (turn === P.turn) P.switching = false; }, () => {
        // A newer play took over: its answer counts, not this one. Otherwise
        // it was refused, or paused before it began (by the browser, say).
        if (turn !== P.turn) return;
        P.switching = false;
        if (audio.paused) { P.want = false; loading(false); syncUI(); syncProgress(); }
      });
    }
  }

  function pause() {
    P.want = false;
    P.switching = false;
    loading(false);
    audio.pause();
    syncUI();
    syncProgress();
    save();
  }

  const toggle = () => (P.want ? pause() : play());

  /** To the track at `i` of the queue (round the ends), playing if it was. */
  function go(i, keep = P.want) {
    const n = P.order.length;
    P.i = ((i % n) + n) % n;
    P.resume = 0;
    // The same track again (a single, say) starts over.
    if (P.order[P.i] === P.loaded && audio.getAttribute("src")) audio.currentTime = 0;
    if (keep) {
      play();
    } else {
      ensureLoaded();
      syncUI();
      syncProgress();
    }
    save();
  }
  const next = () => go(P.i + 1);
  function prev() {
    if (position() > 3) seek(0);
    else go(P.i - 1);
  }

  function playCollection(key) {
    if (P.ctx === key) return toggle();
    setContext(key, 0);
    play();
    save();
  }
  function playTrack(key, i) {
    const c = col(key);
    if (P.ctx === key && current() && current().id === c.tracks[i]) return toggle();
    setContext(key, i);
    play();
    save();
  }

  function seek(t) {
    t = clamp(t, 0, Math.max(0, duration() - 0.25));
    if (P.loaded === P.order[P.i] && audio.getAttribute("src")) {
      audio.currentTime = t;
    } else {
      P.resume = t;
    }
    syncProgress();
    positionState();
    save();
  }

  audio.addEventListener("play", () => {
    if (!P.want) { P.want = true; syncUI(); }
    positionState();
  });
  audio.addEventListener("playing", () => {
    P.switching = false;
    loading(false);
    syncUI();
    syncProgress();
    positionState();
  });
  audio.addEventListener("waiting", () => { loadingSoon(); syncProgress(); });
  audio.addEventListener("pause", () => {
    // A track that ended, or one loading in place of another, isn't a pause.
    if (P.switching || audio.ended) return syncProgress();
    loading(false);
    if (P.want) { P.want = false; syncUI(); }
    syncProgress();
    positionState();
    save();
  });
  audio.addEventListener("ended", () => {
    if (P.repeat === "one") { audio.currentTime = 0; play(); return; }
    if (P.repeat === "off" && P.i === P.order.length - 1) { P.want = false; go(0, false); return; }
    go(P.i + 1, true);
  });
  audio.addEventListener("timeupdate", tick);
  audio.addEventListener("durationchange", () => { syncProgress(); positionState(); });
  audio.addEventListener("seeked", () => { syncProgress(); positionState(); });
  audio.addEventListener("error", () => {
    if (!audio.getAttribute("src") || !audio.error) return;
    P.switching = false;
    P.want = false;
    loading(false);
    syncUI();
    syncProgress();
    toast(`Couldn't play ${current().title}. Try again in a moment.`);
  });

  // MediaSession: what plays, for the browser and the Mac. Artwork is the
  // track's 512 PNG at an absolute URL.
  function setMeta(t) {
    if (!ms || typeof MediaMetadata === "undefined") return;
    ms.metadata = new MediaMetadata({
      title: t.title,
      artist: t.artist,
      album: t.album,
      artwork: [{ src: new URL(`/covers/${t.id}.png`, location.origin).href, sizes: "512x512", type: "image/png" }],
    });
  }
  function positionState() {
    if (!ms || !ms.setPositionState) return;
    const d = audio.duration;
    if (!isFinite(d) || d <= 0) return;
    try { ms.setPositionState({ duration: d, playbackRate: audio.playbackRate || 1, position: clamp(audio.currentTime, 0, d) }); } catch { /* not this browser */ }
  }
  if (ms) {
    const on = (action, fn) => { try { ms.setActionHandler(action, fn); } catch { /* unsupported action */ } };
    on("play", () => play());
    on("pause", () => pause());
    on("previoustrack", () => prev());
    on("nexttrack", () => next());
    on("seekto", (d) => { if (d && isFinite(d.seekTime)) seek(d.seekTime); });
  }

  // ------------------------------------------------------------- the bar

  function showTrack(t, fresh) {
    el.img.src = `/covers/${t.id}.svg`;
    el.title.textContent = t.title;
    el.artist.textContent = t.artist;
    for (const a of [el.title, el.artist, el.art]) a.setAttribute("href", `/album/${t.id}`);
    $("#bar").style.setProperty("--np-tint", t.tint);
    if (fresh) {
      el.np.classList.remove("swap");
      void el.np.offsetWidth;
      el.np.classList.add("swap");
    }
    showTime(position(), duration());
  }

  let shown = -1;
  function showTime(t, d) {
    shown = Math.floor(t);
    el.elapsed.textContent = fmt(t);
    el.total.textContent = fmt(d);
    el.scrub.setAttribute("aria-valuemax", String(Math.round(d)));
    el.scrub.setAttribute("aria-valuenow", String(Math.floor(t)));
    el.scrub.setAttribute("aria-valuetext", `${fmt(t)} of ${fmt(d)}`);
  }
  function tick() {
    if (P.dragging || document.hidden) return;
    if (Math.floor(audio.currentTime) !== shown) showTime(audio.currentTime, duration());
  }

  // The progress line runs to its end by itself, on the compositor, and is
  // set again whenever playback starts, stops or jumps.
  let runs = [];
  function syncProgress() {
    for (const run of runs) run.cancel();
    runs = [];
    const d = duration();
    const t = position();
    const p = d ? clamp(t / d, 0, 1) : 0;
    const at = `translateX(${(p - 1) * 100}%)`;
    for (const node of [el.fill, el.knob, el.mini]) node.style.transform = at;
    showTime(t, d);
    const moving = P.want && !P.dragging && !audio.paused && audio.readyState >= 3 && d > 0 && !document.hidden;
    if (moving && el.fill.animate) {
      const frames = [{ transform: at }, { transform: "translateX(0%)" }];
      const timing = { duration: Math.max(0, (d - t) * 1000) / (audio.playbackRate || 1), easing: "linear", fill: "forwards" };
      runs = [el.fill, el.knob, el.mini].map((node) => node.animate(frames, timing));
    }
  }
  document.addEventListener("visibilitychange", syncProgress);

  let loadTimer = 0;
  function loadingSoon() {
    clearTimeout(loadTimer);
    loadTimer = setTimeout(() => { if (P.want && (P.switching || audio.readyState < 3)) el.play.classList.add("loading"); }, 350);
  }
  function loading(on) {
    clearTimeout(loadTimer);
    el.play.classList.toggle("loading", !!on);
  }

  function syncUI() {
    const t = current();
    const on = P.want;
    el.play.innerHTML = icon(on ? "pause" : "play");
    el.play.setAttribute("aria-label", on ? "Pause" : "Play");
    document.body.classList.toggle("is-playing", on);
    document.title = on && t ? `${t.title} · ${t.artist} · Drift` : "Drift";
    if (ms) ms.playbackState = on ? "playing" : P.loaded ? "paused" : "none";
    const isLiked = t && liked().includes(t.id);
    el.like.innerHTML = icon(isLiked ? "heartFill" : "heart");
    el.like.setAttribute("aria-pressed", String(!!isLiked));
    el.like.setAttribute("aria-label", isLiked ? "Remove from Liked Tracks" : "Save to Liked Tracks");
    markCurrent();
    renderQueue();
  }

  /** Lights what plays wherever the page shows it. */
  function markCurrent() {
    const id = current() && current().id;
    for (const b of $$("[data-play]")) {
      const on = P.want && b.dataset.play === P.ctx;
      const name = b.dataset.name || "";
      if (b.classList.contains("on") !== on || !b.firstElementChild) {
        b.classList.toggle("on", on);
        b.innerHTML = icon(on ? "pause" : "play");
      }
      b.setAttribute("aria-label", `${on ? "Pause" : "Play"} ${name}`.trim());
    }
    for (const node of $$("[data-key]")) node.classList.toggle("is-current", node.dataset.key === P.ctx);
    for (const row of $$(".track")) {
      const here = row.dataset.id === id;
      row.classList.toggle("is-current", here);
      const b = $(".row-play", row);
      const on = here && P.want;
      b.innerHTML = icon(on ? "pause" : "play");
      b.setAttribute("aria-label", `${on ? "Pause" : "Play"} ${row.dataset.title}`);
    }
  }

  function drawModes() {
    el.shuffle.setAttribute("aria-pressed", String(P.shuffle));
    el.shuffle.title = P.shuffle ? "Shuffle is on" : "Shuffle";
    el.repeat.innerHTML = icon(P.repeat === "one" ? "repeatOne" : "repeat");
    el.repeat.setAttribute("aria-pressed", String(P.repeat !== "off"));
    el.repeat.setAttribute("aria-label", P.repeat === "one" ? "Repeat one" : "Repeat");
    el.repeat.title = { all: "Repeat is on", one: "Repeating this track", off: "Repeat" }[P.repeat];
  }
  el.shuffle.addEventListener("click", () => {
    P.shuffle = !P.shuffle;
    store.set("shuffle", P.shuffle);
    const c = col(P.ctx);
    const id = current() && current().id;
    if (c && id) {
      if (P.shuffle) {
        const rest = P.order.filter((x) => x !== id);
        for (let k = rest.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [rest[k], rest[j]] = [rest[j], rest[k]]; }
        P.order = [id, ...rest];
        P.i = 0;
      } else {
        P.order = c.tracks.slice();
        P.i = Math.max(0, P.order.indexOf(id));
      }
    }
    drawModes();
    renderQueue();
    save();
  });
  el.repeat.addEventListener("click", () => {
    P.repeat = { all: "one", one: "off", off: "all" }[P.repeat] || "all";
    store.set("repeat", P.repeat);
    drawModes();
    renderQueue();
  });
  el.play.addEventListener("click", toggle);
  el.next.addEventListener("click", next);
  el.prev.addEventListener("click", prev);
  el.like.addEventListener("click", () => {
    const t = current();
    const ids = liked();
    const has = ids.includes(t.id);
    store.set("liked", has ? ids.filter((x) => x !== t.id) : [t.id, ...ids]);
    syncUI();
    if (location.pathname === "/liked" || location.pathname === "/library") paint(location.pathname);
  });

  function slider(node, { move, end }) {
    const at = (e) => { const r = node.getBoundingClientRect(); return clamp((e.clientX - r.left) / r.width, 0, 1); };
    node.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      node.focus({ preventScroll: true });
      node.setPointerCapture(e.pointerId);
      node.classList.add("dragging");
      move(at(e));
      const onMove = (ev) => move(at(ev));
      const onUp = (ev) => {
        node.classList.remove("dragging");
        node.removeEventListener("pointermove", onMove);
        node.removeEventListener("pointerup", onUp);
        node.removeEventListener("pointercancel", onUp);
        end(at(ev), ev.type === "pointercancel");
      };
      node.addEventListener("pointermove", onMove);
      node.addEventListener("pointerup", onUp);
      node.addEventListener("pointercancel", onUp);
    });
  }
  slider(el.scrub, {
    move: (p) => { P.dragging = true; P.dragAt = p * duration(); syncProgress(); },
    end: (p, canceled) => { P.dragging = false; if (canceled) syncProgress(); else seek(p * duration()); },
  });
  el.scrub.addEventListener("keydown", (e) => {
    const step = { ArrowLeft: -5, ArrowRight: 5, PageDown: -15, PageUp: 15 }[e.key];
    if (step) { e.preventDefault(); seek(position() + step); } else if (e.key === "Home") { e.preventDefault(); seek(0); }
  });

  function drawVolume() {
    const v = P.muted ? 0 : P.volume;
    const at = `translateX(${(v - 1) * 100}%)`;
    el.volFill.style.transform = at;
    el.volKnob.style.transform = at;
    el.vol.setAttribute("aria-valuenow", String(Math.round(v * 100)));
    el.mute.innerHTML = icon(v === 0 ? "mute" : v < 0.5 ? "volumeLow" : "volume");
    el.mute.setAttribute("aria-label", P.muted ? "Unmute" : "Mute");
  }
  function setVolume(v) {
    P.volume = clamp(v, 0, 1);
    P.muted = false;
    audio.muted = false;
    audio.volume = P.volume;
    store.set("volume", P.volume);
    drawVolume();
  }
  slider(el.vol, { move: setVolume, end: () => {} });
  el.vol.addEventListener("keydown", (e) => {
    const step = { ArrowLeft: -0.05, ArrowDown: -0.05, ArrowRight: 0.05, ArrowUp: 0.05 }[e.key];
    if (step) { e.preventDefault(); setVolume(P.volume + step); }
  });
  el.mute.addEventListener("click", () => {
    if (P.volume === 0) { setVolume(0.6); return; }
    P.muted = !P.muted;
    audio.muted = P.muted;
    drawVolume();
  });

  // ------------------------------------------------------------- the queue

  function renderQueue() {
    if (el.queue.hidden || !P.order.length) return;
    const c = col(P.ctx);
    const later = [];
    for (let k = 1; k < P.order.length; k++) {
      const j = P.i + k;
      if (j >= P.order.length && P.repeat === "off") break;
      later.push(j % P.order.length);
    }
    const row = (j) => {
      const t = C.tracks[P.order[j]];
      return `<button class="q-row${j === P.i ? " is-current" : ""}" type="button" data-q="${j}">
        <img src="/covers/${t.id}.svg" alt="" width="44" height="44">
        <span class="q-words"><span class="q-title">${esc(t.title)}</span><span class="q-artist">${esc(t.artist)}</span></span>
        <span class="q-time">${fmt(t.duration)}</span></button>`;
    };
    el.queueBody.innerHTML = `<div class="q-label">Now playing</div>${row(P.i)}
      <div class="q-label">Next from <a href="${c.href}">${esc(c.title)}</a></div>
      ${later.map(row).join("") || '<p class="res-empty">Nothing after this one.</p>'}`;
  }
  function showQueue(on) {
    el.queue.hidden = !on;
    el.queueBtn.setAttribute("aria-pressed", String(on));
    renderQueue();
  }
  el.queueBtn.addEventListener("click", () => showQueue(el.queue.hidden));
  $("#queue-close").addEventListener("click", () => showQueue(false));
  el.queueBody.addEventListener("click", (e) => {
    const row = e.target.closest("[data-q]");
    if (!row || e.target.closest("a")) return;
    const j = Number(row.dataset.q);
    if (j === P.i) toggle();
    else go(j, true);
  });

  // ------------------------------------------------------------- remembering

  function save() {
    store.set("player", { ctx: P.ctx, order: P.order, i: P.i, t: Math.floor(position()) });
  }
  function remember(key) {
    store.set("recent", [key, ...store.get("recent", []).filter((k) => k !== key)].slice(0, 16));
  }
  window.addEventListener("pagehide", save);

  let toastTimer = 0;
  function toast(text) {
    const node = $("#toast");
    node.textContent = text;
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, 4000);
  }

  // ------------------------------------------------------------- pages

  function playButton(key, name, cls = "card-play") {
    const on = P.want && P.ctx === key;
    return `<button class="${cls}${on ? " on" : ""}" type="button" data-play="${key}" data-name="${esc(name)}" aria-label="${on ? "Pause" : "Play"} ${esc(name)}">${icon(on ? "pause" : "play")}</button>`;
  }
  function art(c, size, cls = "") {
    if (c.kind === "liked") return `<div class="art-liked ${cls}">${icon("heartFill")}</div>`;
    return `<img class="${cls}" src="${c.art}" alt="" width="${size}" height="${size}" decoding="async">`;
  }
  function card(key, sub) {
    const c = col(key);
    return `<article class="card" data-key="${key}">
      <a class="card-link" href="${c.href}" aria-label="${esc(c.title)}"></a>
      <div class="card-art">${art(c, 352)}${playButton(key, c.title)}</div>
      <h3 class="card-title">${esc(c.title)}</h3>
      <p class="card-sub">${esc(sub == null ? c.about : sub)}</p>
    </article>`;
  }
  function feature(key) {
    const c = col(key);
    // A name never breaks across lines; the list breaks between names.
    const artists = [...new Set(c.tracks.map((id) => C.tracks[id].artist))].map((a) => `<span class="name">${esc(a)}</span>`).join(", ");
    return `<article class="feature" data-key="${key}" style="--card-tint:${c.tint}">
      <a class="card-link" href="${c.href}" aria-label="${esc(c.title)}"></a>
      <img class="feature-art" src="${c.art}" alt="" width="216" height="216">
      <div class="feature-body">
        <p class="eyebrow">Station</p>
        <h3>${esc(c.title)}</h3>
        <p class="feature-about">${esc(c.about)}</p>
        <div class="feature-foot">${playButton(key, c.title)}
          <p class="feature-meta"><b>${artists}</b>${c.tracks.length} tracks · ${length(c.tracks)}</p></div>
      </div>
    </article>`;
  }
  const shelf = (title, sub, body, more) => `<section class="shelf">
      <div class="shelf-head"><div><h2>${title}</h2>${sub ? `<p>${sub}</p>` : ""}</div>${more || ""}</div>${body}</section>`;

  function viewHome() {
    const h = new Date().getHours();
    const hello = h >= 5 && h < 12 ? "Good morning" : h >= 12 && h < 18 ? "Good afternoon" : "Good evening";
    const quick = C.home.quick.map((key) => {
      const c = col(key);
      return `<div class="quick-item" data-key="${key}"><a class="card-link" href="${c.href}" aria-label="${esc(c.title)}"></a>
        ${art(c, 64)}<span class="quick-title">${esc(c.title)}</span>${playButton(key, c.title)}</div>`;
    }).join("");
    return {
      tint: "#28325c",
      html: `<h1 class="greeting">${hello}, Mira</h1>
        <div class="quick">${quick}</div>
        ${shelf("Featured stations", "Endless radio, tuned by mood", `<div class="features">${C.home.featured.map((id) => feature("station:" + id)).join("")}</div>`, '<a class="more" href="/stations">Show all</a>')}
        ${shelf("Made for Mira", "Mixes that change as you listen", `<div class="row">${C.home.made_for.map((id) => card("mix:" + id)).join("")}</div>`)}
        ${shelf("New releases", "Fresh singles from artists you follow", `<div class="grid">${C.home.releases.map((id) => card("album:" + id, `Single · ${C.tracks[id].artist}`)).join("")}</div>`)}`,
    };
  }

  function viewStations() {
    return {
      tint: "#3b2f5c",
      html: `<h1 class="page-title">Stations</h1>
        <p class="page-sub">Endless radio, tuned by mood. Press play and let it drift.</p>
        <div class="features">${Object.keys(C.stations).map((id) => feature("station:" + id)).join("")}</div>`,
    };
  }

  function viewLibrary() {
    const filter = store.get("shelf", "all");
    const recent = store.get("recent", []);
    const keep = new Set(saved());
    const items = [
      { key: "liked:all", sub: `Playlist · ${liked().length} tracks`, group: "playlists" },
      ...Object.keys(C.stations).filter((id) => keep.has("station:" + id)).map((id) => ({ key: "station:" + id, sub: "Station · Drift Radio", group: "stations" })),
      ...Object.keys(C.mixes).filter((id) => keep.has("mix:" + id)).map((id) => ({ key: "mix:" + id, sub: "Mix · Made for Mira", group: "mixes" })),
      ...C.home.releases.filter((id) => keep.has("album:" + id)).map((id) => ({ key: "album:" + id, sub: `Single · ${C.tracks[id].artist}`, group: "singles" })),
    ];
    const rank = (key) => { const at = recent.indexOf(key); return at < 0 ? 999 : at; };
    items.sort((a, b) => (a.key === "liked:all" ? -1 : b.key === "liked:all" ? 1 : rank(a.key) - rank(b.key)));
    const shown = items.filter((x) => filter === "all" || x.group === filter);
    const chips = [["all", "All"], ["playlists", "Playlists"], ["stations", "Stations"], ["mixes", "Mixes"], ["singles", "Singles"]]
      .map(([k, label]) => `<button class="chip" type="button" data-shelf="${k}" aria-pressed="${k === filter}">${label}</button>`).join("");
    const rows = shown.map(({ key, sub }) => {
      const c = col(key);
      return `<div class="lib-row" data-key="${key}"><a class="card-link" href="${c.href}" aria-label="${esc(c.title)}"></a>
        ${art(c, 64)}<div><div class="lib-title">${esc(c.title)}</div><div class="lib-sub">${esc(sub)}</div></div>${c.tracks.length ? playButton(key, c.title) : ""}</div>`;
    }).join("");
    return {
      tint: "#2a3046",
      html: `<h1 class="page-title">Your Library</h1><p class="page-sub">Stations, mixes and music you saved.</p>
        <div class="chips">${chips}</div>
        <div class="lib-list">${rows || '<p class="res-empty">Nothing saved here yet.</p>'}</div>`,
    };
  }

  function viewCollection(kind, id) {
    const key = kind === "liked" ? "liked:all" : `${kind}:${id}`;
    const c = col(key);
    if (!c) return null;
    const ids = c.tracks;
    const label = { station: "Station", mix: "Made for Mira", album: "Single", liked: "Playlist" }[kind];
    let meta;
    if (kind === "station") {
      meta = `${MARK}<b>Drift Radio</b><span class="dot">·</span>${esc(c.followers)} followers<span class="dot">·</span>${ids.length} tracks, ${length(ids)}`;
    } else if (kind === "mix") {
      meta = `${MARK}<b>Drift</b><span class="dot">·</span>Made for Mira<span class="dot">·</span>${ids.length} tracks, ${length(ids)}`;
    } else if (kind === "album") {
      const t = C.tracks[id];
      meta = `<img class="mini-face" src="/covers/${id}.svg" alt="" width="24" height="24"><b>${esc(t.artist)}</b><span class="dot">·</span>${t.released.slice(-4)}<span class="dot">·</span>1 track, ${length(ids)}`;
    } else {
      meta = `<span class="avatar avatar-sm">M</span><b>Mira Lindqvist</b><span class="dot">·</span>${ids.length} tracks`;
    }
    const isSaved = kind === "liked" || saved().includes(key);
    const hero = `<section class="hero">
        ${art(c, 232, "hero-art")}
        <div class="hero-text">
          <p class="eyebrow">${label}</p>
          <h1 class="hero-title">${esc(c.title)}</h1>
          ${c.about ? `<p class="hero-about">${esc(c.about)}</p>` : ""}
          <p class="hero-meta">${meta}</p>
        </div>
      </section>`;
    const actions = ids.length ? `<div class="actions">
        ${playButton(key, c.title, "play-xl")}
        ${kind === "liked" ? "" : `<button class="icon-btn" type="button" data-save="${key}" aria-pressed="${isSaved}" aria-label="${isSaved ? "Remove from Your Library" : "Save to Your Library"}">${icon(isSaved ? "added" : "add")}</button>`}
      </div>` : "";
    const list = ids.length ? `<div class="tracks" role="table" aria-label="${esc(c.title)} tracks">
        <div class="tracks-head" role="row"><span role="columnheader" style="text-align:center">#</span><span role="columnheader">Title</span>
          <span class="col-album" role="columnheader">Album</span><span class="col-time" role="columnheader" aria-label="Length">${icon("clock")}</span></div>
        ${ids.map((tid, i) => trackRow(key, tid, i)).join("")}
      </div>` : `<div class="empty"><h2>Songs you like show up here</h2><p>Save one with the heart in the player.</p></div>`;
    let more = "";
    if (kind === "station") {
      more = shelf("More stations", "", `<div class="row">${Object.keys(C.stations).filter((s) => s !== id).map((s) => card("station:" + s)).join("")}</div>`, '<a class="more" href="/stations">Show all</a>');
    } else if (kind === "mix") {
      more = shelf("More made for Mira", "", `<div class="row">${Object.keys(C.mixes).filter((m) => m !== id).map((m) => card("mix:" + m)).join("")}</div>`);
    } else if (kind === "album") {
      const t = C.tracks[id];
      const on = [...Object.keys(C.stations).filter((s) => C.stations[s].tracks.includes(id)).map((s) => "station:" + s),
        ...Object.keys(C.mixes).filter((m) => C.mixes[m].tracks.includes(id)).map((m) => "mix:" + m)].slice(0, 5);
      more = `<p class="release"><b>Released ${esc(t.released)}</b><br>${esc(t.plays)} plays<br>&copy; 2026 ${esc(t.label)}</p>`
        + shelf("Appears on", "", `<div class="row">${on.map((k) => card(k)).join("")}</div>`)
        + shelf("More new releases", "", `<div class="row">${C.home.releases.filter((r) => r !== id).map((r) => card("album:" + r, `Single · ${C.tracks[r].artist}`)).join("")}</div>`);
    }
    return { tint: c.tint, html: hero + actions + list + more };
  }

  function trackRow(key, tid, i) {
    const t = C.tracks[tid];
    return `<div class="track" role="row" data-row="${key}" data-i="${i}" data-id="${tid}" data-title="${esc(t.title)}">
      <div class="track-num" role="cell"><span class="n">${i + 1}</span><span class="eq" aria-hidden="true"><i></i><i></i><i></i></span>
        <button class="row-play" type="button" data-track="${key}:${i}" aria-label="Play ${esc(t.title)}">${icon("play")}</button></div>
      <div class="track-main" role="cell"><img src="/covers/${tid}.svg" alt="" width="40" height="40">
        <div class="track-words"><div class="track-title">${esc(t.title)}</div><a class="track-artist" href="/album/${tid}">${esc(t.artist)}</a></div></div>
      <a class="track-album" role="cell" href="/album/${tid}">${esc(t.album)}</a>
      <div class="track-time" role="cell">${fmt(t.duration)}</div>
    </div>`;
  }

  function viewMissing() {
    return {
      tint: "#2b2f3a",
      html: `<div class="empty missing"><h2>This page drifted off</h2>
        <p>It isn't here anymore, or it never was.</p>
        <a class="chip" href="/">Back to Home</a></div>`,
    };
  }

  const ROUTES = [
    [/^\/$/, () => viewHome()],
    [/^\/stations\/?$/, () => viewStations()],
    [/^\/library\/?$/, () => viewLibrary()],
    [/^\/liked\/?$/, () => viewCollection("liked", "all")],
    [/^\/(station|mix|album)\/([^/]+)\/?$/, (m) => viewCollection(m[1], decodeURIComponent(m[2]))],
  ];
  const view = $("#view");
  const backdrop = $("#backdrop");

  function paint(path, { focus = false, enter = false } = {}) {
    closeSearch();
    let out = null;
    for (const [re, draw] of ROUTES) {
      const m = path.match(re);
      if (m) { out = draw(m); break; }
    }
    out = out || viewMissing();
    view.innerHTML = out.html;
    backdrop.style.setProperty("--tint", out.tint);
    const section = path === "/" ? "home" : /^\/station/.test(path) ? "stations" : /^\/(library|liked)/.test(path) ? "library" : "";
    for (const a of $$(".nav a")) {
      if (a.dataset.nav === section) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    }
    markCurrent();
    if (enter) {
      view.classList.remove("entering");
      void view.offsetWidth;
      view.classList.add("entering");
    }
    if (focus) view.focus({ preventScroll: true });
  }

  function navigate(href) {
    const url = new URL(href, location.href);
    if (url.origin !== location.origin) { location.href = url.href; return; }
    history.replaceState({ ...(history.state || {}), y: window.scrollY }, "");
    if (url.pathname !== location.pathname) history.pushState({ y: 0 }, "", url.pathname + url.search);
    paint(url.pathname, { focus: true, enter: true });
    window.scrollTo(0, 0);
  }
  if ("scrollRestoration" in history) history.scrollRestoration = "manual";
  window.addEventListener("popstate", (e) => {
    paint(location.pathname, { enter: true });
    window.scrollTo(0, (e.state && e.state.y) || 0);
  });

  const routable = (a, e) => !e.defaultPrevented && e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey
    && !a.target && !a.hasAttribute("download") && a.origin === location.origin && !a.pathname.startsWith("/audio/");

  document.addEventListener("click", (e) => {
    const t = e.target;
    const button = t.closest("[data-play]");
    if (button) { e.preventDefault(); playCollection(button.dataset.play); return; }
    const rowButton = t.closest("[data-track]");
    if (rowButton) {
      e.preventDefault();
      const parts = rowButton.dataset.track.split(":");
      playTrack(`${parts[0]}:${parts[1]}`, Number(parts[2]));
      return;
    }
    const keep = t.closest("[data-save]");
    if (keep) {
      const key = keep.dataset.save;
      const list = saved();
      store.set("saved", list.includes(key) ? list.filter((k) => k !== key) : [key, ...list]);
      const on = !list.includes(key);
      keep.innerHTML = icon(on ? "added" : "add");
      keep.setAttribute("aria-pressed", String(on));
      keep.setAttribute("aria-label", on ? "Remove from Your Library" : "Save to Your Library");
      return;
    }
    const chip = t.closest("[data-shelf]");
    if (chip) { store.set("shelf", chip.dataset.shelf); paint("/library"); return; }
    const result = t.closest(".res");
    if (result) { e.preventDefault(); choose(result); return; }
    const a = t.closest("a[href]");
    if (a) {
      if (routable(a, e)) { e.preventDefault(); navigate(a.getAttribute("href")); }
      return;
    }
    const row = t.closest(".track");
    if (row) playTrack(row.dataset.row, Number(row.dataset.i));
  });

  const top = $("#top");
  const onScroll = () => top.classList.toggle("scrolled", window.scrollY > 6);
  window.addEventListener("scroll", onScroll, { passive: true });

  // ------------------------------------------------------------- search

  const input = $("#search");
  const results = $("#results");
  const INDEX = [
    ...Object.values(C.tracks).map((t) => ({ kind: "track", id: t.id, title: t.title, sub: `Track · ${t.artist}`, img: `/covers/${t.id}.svg`, hay: `${t.title} ${t.artist}`.toLowerCase() })),
    ...Object.values(C.tracks).map((t) => ({ kind: "artist", id: t.id, title: t.artist, sub: "Artist", img: `/covers/${t.id}.svg`, round: true, hay: t.artist.toLowerCase() })),
    ...Object.entries(C.stations).map(([id, s]) => ({ kind: "station", id, title: s.title, sub: "Station · Drift Radio", img: `/covers/${id}.svg`, hay: `${s.title} station radio ${s.about}`.toLowerCase() })),
    ...Object.entries(C.mixes).map(([id, m]) => ({ kind: "mix", id, title: m.title, sub: "Mix · Made for Mira", img: `/covers/${id}.svg`, hay: `${m.title} mix ${m.about}`.toLowerCase() })),
  ];
  const GROUPS = [["track", "Tracks"], ["artist", "Artists"], ["station", "Stations"], ["mix", "Mixes"]];
  let hits = [];
  let picked = -1;

  function find(q) {
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return [];
    const found = INDEX.filter((x) => words.every((w) => x.hay.includes(w)));
    const score = (x) => (x.title.toLowerCase().startsWith(words[0]) ? 2 : 0) + (x.title.toLowerCase().includes(words[0]) ? 1 : 0);
    return GROUPS.flatMap(([kind]) => found.filter((x) => x.kind === kind).sort((a, b) => score(b) - score(a)).slice(0, 4));
  }
  function drawResults() {
    const q = input.value.trim();
    if (!q) { closeSearch(false); return; }
    hits = find(q);
    picked = hits.length ? 0 : -1;
    let html = "";
    for (const [kind, label] of GROUPS) {
      const some = hits.filter((x) => x.kind === kind);
      if (!some.length) continue;
      html += `<div class="res-label">${label}</div>` + some.map((x) => {
        const k = hits.indexOf(x);
        return `<div class="res${x.round ? " round" : ""}" role="option" id="res-${k}" data-k="${k}" aria-selected="${k === picked}">
          <img src="${x.img}" alt="" width="40" height="40"><div class="res-text"><div class="res-title">${esc(x.title)}</div><div class="res-sub">${esc(x.sub)}</div></div></div>`;
      }).join("");
    }
    results.innerHTML = html || `<div class="res-empty">Nothing on Drift matches “${esc(q)}”.</div>`;
    results.hidden = false;
    input.setAttribute("aria-expanded", "true");
    input.setAttribute("aria-activedescendant", picked >= 0 ? `res-${picked}` : "");
  }
  function closeSearch(clear = false) {
    results.hidden = true;
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
    if (clear) input.value = "";
  }
  function choose(node) {
    const x = hits[Number(node.dataset.k)];
    if (!x) return;
    closeSearch(true);
    input.blur();
    if (x.kind === "track") {
      const key = home(x.id);
      playTrack(key, col(key).tracks.indexOf(x.id));
    } else if (x.kind === "artist") {
      navigate(`/album/${x.id}`);
    } else {
      navigate(`/${x.kind}/${x.id}`);
    }
  }
  input.addEventListener("input", drawResults);
  input.addEventListener("focus", () => { if (input.value.trim()) drawResults(); });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeSearch(true); input.blur(); return; }
    if (results.hidden || !hits.length) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      picked = (picked + (e.key === "ArrowDown" ? 1 : -1) + hits.length) % hits.length;
      for (const node of $$(".res", results)) node.setAttribute("aria-selected", String(Number(node.dataset.k) === picked));
      input.setAttribute("aria-activedescendant", `res-${picked}`);
      const node = $(`#res-${picked}`);
      if (node) node.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Enter") {
      e.preventDefault();
      const node = $(`#res-${Math.max(0, picked)}`);
      if (node) choose(node);
    }
  });
  document.addEventListener("pointerdown", (e) => {
    if (!e.target.closest(".search")) closeSearch(false);
  });

  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
    if (typing) return;
    if (e.key === "/") { e.preventDefault(); input.focus(); input.select(); return; }
    if (e.key === "Escape" && !el.queue.hidden) { showQueue(false); return; }
    if (e.key === " " && !e.target.closest("button, a, [role=slider]")) { e.preventDefault(); toggle(); }
  });

  // ------------------------------------------------------------- start

  const last = store.get("player", null);
  if (last && col(last.ctx) && Array.isArray(last.order) && last.order.length && last.order.every((id) => C.tracks[id])) {
    P.ctx = last.ctx;
    P.order = last.order;
    P.i = clamp(Number(last.i) || 0, 0, last.order.length - 1);
    P.resume = Math.max(0, Number(last.t) || 0);
  } else {
    P.ctx = DEFAULT;
    P.order = col(DEFAULT).tracks.slice();
    P.i = 0;
  }
  audio.volume = P.volume;
  audio.muted = false;
  showTrack(current(), false);
  drawModes();
  drawVolume();
  paint(location.pathname);
  syncUI();
  syncProgress();
  onScroll();
  requestAnimationFrame(() => requestAnimationFrame(() => document.documentElement.classList.add("ready")));
})();
