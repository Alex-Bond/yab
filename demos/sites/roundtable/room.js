// The room: before joining, the call, after leaving.
//
// Kept for whoever drives the page:
//   window.startShare()        present your screen (getDisplayMedia), as the Present button does
//   window.remotePresent(id)   someone else presents their deck ('anna', 'jonas', 'elliot'); false stops it
// and in the address: ?join=1 skips the waiting screen, ?present=anna,
// ?panel=chat|people, ?captions=1, ?video=anna,jonas|all|none (whose
// camera is on), ?mic=0 and ?cam=0 to start with them off.

import * as media from './media.js';
import * as people from './people.js';
import * as panel from './panel.js';
import { startDeck } from './deck.js';

const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));
const params = new URLSearchParams(location.search);
const FALLBACK_TITLE = 'Design review · Onboarding v3';

const app = {
  title: FALLBACK_TITLE,
  joined: false,
  captions: false,
  hand: false,
  deck: null,
  pending: null,
  later: [],
};

const el = {
  prejoin: $('#prejoin'),
  call: $('#call'),
  left: $('#left'),
  stage: $('#stage'),
  tiles: $('#tiles'),
  feeds: $('#feeds'),
  preview: $('#preview'),
  previewVideo: $('#preview-video'),
  previewNote: $('#preview-note'),
  meter: $('#preview-meter'),
  presentBar: $('#present-bar'),
  presentButton: $('#present-button'),
  captions: $('#captions'),
  clock: $('#clock'),
  tip: $('#tip'),
  toast: $('#toast'),
};

// ---------------------------------------------------------------- the meeting's name

function setTitle(title) {
  app.title = title;
  document.title = `${title} · Roundtable`;
  $$('[data-title]').forEach((n) => { n.textContent = title; });
}

fetch('/__demo/state.json', { cache: 'no-store' })
  .then((r) => (r.ok ? r.json() : null))
  .then((state) => {
    const title = state && state.meeting && typeof state.meeting.title === 'string' ? state.meeting.title.trim() : '';
    if (title) setTitle(title);
  })
  .catch(() => {});

// ---------------------------------------------------------------- a word for a moment

let toastTimer = 0;
function toast(text) {
  el.toast.textContent = text;
  el.toast.classList.add('is-up');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.toast.classList.remove('is-up'), 2400);
}

// ---------------------------------------------------------------- names on hover

let tipTimer = 0;
let tipFor = null;
function hideTip() {
  clearTimeout(tipTimer);
  tipFor = null;
  el.tip.hidden = true;
}
function showTip(target) {
  if (!target.isConnected || (openPop && openPop.button === target)) return;
  el.tip.textContent = target.dataset.tip;
  if (target.dataset.key) {
    const key = document.createElement('kbd');
    key.textContent = target.dataset.key;
    el.tip.append(key);
  }
  el.tip.hidden = false;
  const r = target.getBoundingClientRect();
  const t = el.tip.getBoundingClientRect();
  const x = Math.max(8, Math.min(innerWidth - t.width - 8, r.left + r.width / 2 - t.width / 2));
  const above = r.top - t.height - 8;
  const y = above > 8 ? above : r.bottom + 8;
  el.tip.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
}
// A control just pressed shows no name until the pointer leaves it.
let tipQuiet = null;
document.addEventListener('pointerover', (e) => {
  const target = e.target.closest ? e.target.closest('[data-tip]') : null;
  if (target === tipFor) return;
  hideTip();
  tipFor = target;
  if (target !== tipQuiet) tipQuiet = null;
  if (target && !tipQuiet) tipTimer = setTimeout(() => showTip(target), 420);
});
document.addEventListener('pointerdown', (e) => {
  hideTip();
  tipQuiet = e.target.closest ? e.target.closest('[data-tip]') : null;
  tipFor = tipQuiet;
}, true);
// A name that changed under the pointer (⌘D over the microphone) is said again.
function retip() {
  if (!el.tip.hidden && tipFor && tipFor.isConnected) showTip(tipFor);
}
// Sound may start with the first click or key anywhere.
const wake = () => { media.wakeAudio(); removeEventListener('pointerdown', wake, true); removeEventListener('keydown', wake, true); };
addEventListener('pointerdown', wake, true);
addEventListener('keydown', wake, true);

// ---------------------------------------------------------------- popovers

let openPop = null;
function closePops() {
  if (!openPop) return;
  openPop.pop.hidden = true;
  openPop.button.setAttribute('aria-expanded', 'false');
  openPop = null;
}
function togglePop(button) {
  const pop = document.getElementById(button.dataset.pop);
  if (!pop) return;
  if (openPop && openPop.pop === pop) { closePops(); return; }
  closePops();
  hideTip();
  pop.hidden = false;
  button.setAttribute('aria-expanded', 'true');
  openPop = { pop, button };
}
document.addEventListener('pointerdown', (e) => {
  if (openPop && !openPop.pop.contains(e.target) && !openPop.button.contains(e.target)) closePops();
});
document.addEventListener('click', (e) => {
  const opener = e.target.closest('[data-pop]');
  if (opener) { togglePop(opener); return; }
  // A device picked, in any of its menus, open or not.
  const item = e.target.closest('[role="menuitemradio"][data-device-id]');
  if (item) {
    const menu = item.closest('[role="menu"]');
    const kind = menu && menu.dataset.kind;
    if (!kind) return;
    closePops();
    const id = item.getAttribute('data-device-id');
    const name = media.label(kind, id);
    media.pick(kind, id).catch(() => toast(name ? `Couldn't switch to ${name}` : "Couldn't switch devices"));
  }
});

// Arrows move through a menu, Return picks.
document.addEventListener('keydown', (e) => {
  if (!openPop) return;
  const items = $$('.menu-item, .emoji', openPop.pop);
  if (!items.length) return;
  const at = items.indexOf(document.activeElement);
  if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
    e.preventDefault();
    items[(at + 1) % items.length].focus();
  } else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
    e.preventDefault();
    items[(at - 1 + items.length) % items.length].focus();
  } else if ((e.key === 'Enter' || e.key === ' ') && at >= 0) {
    e.preventDefault();
    items[at].click();
  }
});

// ---------------------------------------------------------------- the switches

function renderSwitches() {
  const muted = media.micMuted();
  const off = media.cameraOff();
  for (const b of $$('[data-mic-toggle]')) {
    const words = muted ? 'Turn on microphone' : 'Turn off microphone';
    b.setAttribute('data-is-muted', String(muted));
    b.setAttribute('aria-pressed', String(muted));
    b.setAttribute('aria-label', words);
    b.dataset.tip = words;
    b.dataset.key = '⌘ D';
    b.querySelector('use').setAttribute('href', muted ? '#i-mic-off' : '#i-mic');
  }
  for (const b of $$('[data-cam-toggle]')) {
    const words = off ? 'Turn on camera' : 'Turn off camera';
    b.setAttribute('data-is-muted', String(off));
    b.setAttribute('aria-pressed', String(off));
    b.setAttribute('aria-label', words);
    b.dataset.tip = words;
    b.dataset.key = '⌘ E';
    b.querySelector('use').setAttribute('href', off ? '#i-cam-off' : '#i-cam');
  }
  renderPreview();
  people.updateSelf();
  panel.renderPeople();
  retip();
}

function renderPreview() {
  const v = el.previewVideo;
  if (!v || !v.isConnected) return;
  const stream = media.local.self;
  if (v.srcObject !== stream) {
    v.srcObject = stream;
    if (stream) v.play().catch(() => {});
  }
  const showing = !media.cameraOff() && !!stream && v.readyState >= 2;
  el.preview.classList.toggle('has-video', showing);
  el.previewNote.textContent = media.local.started ? 'Camera is off' : 'Starting camera';
}
el.previewVideo.addEventListener('loadeddata', renderPreview);
el.previewVideo.addEventListener('playing', renderPreview);

document.addEventListener('click', (e) => {
  if (e.target.closest('[data-mic-toggle]')) { media.wakeAudio(); media.toggleMic(); }
  else if (e.target.closest('[data-cam-toggle]')) media.toggleCamera();
});

// Meet's keys: ⌘D the microphone, ⌘E the camera.
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { closePops(); hideTip(); return; }
  if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return;
  const key = e.key.toLowerCase();
  if (key === 'd') { e.preventDefault(); media.wakeAudio(); media.toggleMic(); }
  else if (key === 'e') { e.preventDefault(); media.toggleCamera(); }
});

// ---------------------------------------------------------------- the devices' menus

const NONE = {
  audioinput: () => (!media.local.started ? 'Looking for microphones' : media.local.failed ? 'Allow the microphone to choose one' : 'No microphone found'),
  audiooutput: () => 'System default',
  videoinput: () => (!media.local.started ? 'Looking for cameras' : media.local.failed ? 'Allow the camera to choose one' : 'No camera found'),
};
const PLAIN = { audioinput: 'Microphone', audiooutput: 'Speaker', videoinput: 'Camera' };

function renderMenus() {
  for (const menu of $$('[role="menu"][data-kind]')) {
    const kind = menu.dataset.kind;
    const list = media.local.devices[kind];
    const ids = list.map((d) => `${d.deviceId}\u0001${d.label}`).join('\u0002');
    if (menu.dataset.ids !== ids || !menu.firstChild) {
      menu.dataset.ids = ids;
      menu.textContent = '';
      if (!list.length) {
        const empty = document.createElement('div');
        empty.className = 'menu-empty';
        empty.textContent = NONE[kind]();
        menu.append(empty);
      }
      list.forEach((d, i) => {
        const item = document.createElement('div');
        item.className = 'menu-item';
        item.setAttribute('role', 'menuitemradio');
        item.setAttribute('data-device-id', d.deviceId);
        item.setAttribute('aria-checked', 'false');
        item.tabIndex = -1;
        item.innerHTML = '<svg class="icon menu-check" aria-hidden="true"><use href="#i-check"/></svg>';
        const name = document.createElement('span');
        name.className = 'menu-label';
        name.setAttribute('jsname', 'K4r5Ff');
        name.textContent = d.label || `${PLAIN[kind]} ${i + 1}`;
        item.append(name);
        menu.append(item);
      });
    }
    const on = media.checked(kind);
    for (const item of menu.querySelectorAll('[role="menuitemradio"]')) {
      item.setAttribute('aria-checked', String(item.getAttribute('data-device-id') === on));
    }
  }
  for (const b of $$('[data-picker]')) {
    const kind = b.dataset.picker;
    const name = media.label(kind, media.checked(kind)) || (kind === 'audiooutput' ? 'System default' : PLAIN[kind]);
    b.querySelector('.picker-label').textContent = name;
    b.setAttribute('aria-label', `${PLAIN[kind]}: ${name}`);
  }
}

// ---------------------------------------------------------------- the screen

function renderShare() {
  const sharing = !!media.local.screen;
  el.presentBar.hidden = !(sharing && app.joined);
  const b = el.presentButton;
  b.classList.toggle('is-on', sharing);
  b.setAttribute('aria-label', sharing ? 'Stop presenting' : 'Share screen');
  b.dataset.tip = sharing ? 'Stop presenting' : 'Present';
  b.querySelector('use').setAttribute('href', sharing ? '#i-present-stop' : '#i-present');
  if (!app.joined) { retip(); return; }
  if (sharing) {
    stopDeck();
    people.present({ who: people.ME.id, stream: media.local.screen });
  } else if (people.presenting() === people.ME.id) {
    people.unpresent();
  }
  panel.renderPeople();
  retip();
}

function shareFailed(e) {
  if (e && (e.name === 'NotAllowedError' || e.name === 'AbortError')) return;
  toast("Couldn't share your screen");
}

// Present, from a click or from whoever drives the page. getDisplayMedia
// is asked for first, while the click still counts.
function startShare() {
  const asked = media.share();
  if (!app.joined && el.left.hidden) join();
  return asked.then(() => true, (e) => { shareFailed(e); return false; });
}
window.startShare = startShare;

el.presentButton.addEventListener('click', () => {
  if (media.local.screen) { media.stopShare(); return; }
  startShare();
});
$('#stop-present').addEventListener('click', () => media.stopShare());

function stopDeck() {
  if (!app.deck) return;
  const deck = app.deck;
  app.deck = null;
  if (people.presenting() && people.presenting() !== people.ME.id) people.unpresent();
  deck.stop();
  panel.renderPeople();
}

// Someone else shows their deck: their screen, as another person's share.
window.remotePresent = function remotePresent(who = 'anna') {
  if (who === false || who === null || who === 'none') { app.pending = null; stopDeck(); return false; }
  const person = people.PEOPLE.find((p) => p.id === who);
  if (!person) return false;
  if (!app.joined) { app.pending = who; return true; }
  if (media.local.screen) media.stopShare();
  stopDeck();
  app.deck = startDeck(el.feeds);
  people.present({ who: person.id, stream: app.deck.stream });
  panel.renderPeople();
  return true;
};

// ---------------------------------------------------------------- captions

const caption = { now: null, timer: 0, quiet: 0 };
const capAvatar = $('.captions-avatar', el.captions);
const capName = $('.captions-name', el.captions);
const capText = $('.captions-text', el.captions);

people.onTurn(({ person, text, ms }) => {
  caption.now = { person, words: text.split(/\s+/), start: performance.now(), ms };
  if (app.captions) showCaption();
});

function showCaption() {
  clearInterval(caption.timer);
  clearTimeout(caption.quiet);
  const c = caption.now;
  if (!c) return;
  el.captions.hidden = false;
  el.captions.classList.remove('is-quiet');
  if (capAvatar.getAttribute('src') !== c.person.avatar) capAvatar.src = c.person.avatar;
  capName.textContent = c.person.name;
  const each = c.ms / c.words.length;
  const step = () => {
    const said = Math.min(c.words.length, Math.max(1, Math.ceil((performance.now() - c.start) / each)));
    capText.textContent = c.words.slice(0, said).join(' ');
    if (said >= c.words.length) {
      clearInterval(caption.timer);
      caption.quiet = setTimeout(() => el.captions.classList.add('is-quiet'), 2600);
    }
  };
  step();
  caption.timer = setInterval(step, 90);
}

function setCaptions(on) {
  app.captions = on;
  const b = $('#captions-button');
  b.classList.toggle('is-on', on);
  b.setAttribute('aria-pressed', String(on));
  const words = on ? 'Turn off captions' : 'Turn on captions';
  b.setAttribute('aria-label', words);
  b.dataset.tip = words;
  people.setInset(on ? 112 : 0);
  if (on) {
    el.captions.classList.add('is-quiet');
    el.captions.hidden = false;
    if (caption.now && performance.now() - caption.now.start < caption.now.ms + 1500) showCaption();
  } else {
    clearInterval(caption.timer);
    clearTimeout(caption.quiet);
    el.captions.hidden = true;
  }
  retip();
}
$('#captions-button').addEventListener('click', () => setCaptions(!app.captions));

// ---------------------------------------------------------------- hand, reactions, more

function setHand(up) {
  app.hand = up;
  const b = $('#hand-button');
  b.classList.toggle('is-on', up);
  b.setAttribute('aria-pressed', String(up));
  const words = up ? 'Lower hand' : 'Raise hand';
  b.setAttribute('aria-label', words);
  b.dataset.tip = words;
  people.setHand(people.ME.id, up);
  panel.renderPeople({ hand: up });
  retip();
}
$('#hand-button').addEventListener('click', () => setHand(!app.hand));

function react(emoji, who = 'You') {
  const n = document.createElement('div');
  n.className = 'reaction';
  n.style.left = `${4 + Math.random() * 9}%`;
  n.style.setProperty('--sway', `${((Math.random() * 2 - 1) * 26).toFixed(1)}px`);
  const face = document.createElement('span');
  face.className = 'reaction-emoji';
  face.textContent = emoji;
  const name = document.createElement('span');
  name.className = 'reaction-name';
  name.textContent = who;
  n.append(face, name);
  $('#reactions').append(n);
  setTimeout(() => n.remove(), 3600);
}
$('#react-pop').addEventListener('click', (e) => {
  const b = e.target.closest('[data-emoji]');
  if (b) react(b.dataset.emoji);
});

function meetingLink() { return `${location.origin}${location.pathname}`; }
function copyLink() {
  const done = () => toast('Meeting link copied');
  const text = meetingLink();
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, () => { fallbackCopy(text); done(); });
  } else {
    fallbackCopy(text);
    done();
  }
}
function fallbackCopy(text) {
  const area = document.createElement('textarea');
  area.value = text;
  area.style.position = 'fixed';
  area.style.opacity = '0';
  document.body.append(area);
  area.select();
  try { document.execCommand('copy'); } catch (_) { /* nothing more to try */ }
  area.remove();
}
$('#copy-link').addEventListener('click', () => { closePops(); copyLink(); });
$('#add-people').addEventListener('click', copyLink);
$('#full-screen').addEventListener('click', () => {
  closePops();
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(() => {});
});
document.addEventListener('fullscreenchange', () => {
  $('#full-screen-label').textContent = document.fullscreenElement ? 'Exit full screen' : 'Full screen';
});

// ---------------------------------------------------------------- the clock

const clockFormat = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' });
let clockTimer = 0;
function tickClock() {
  const words = clockFormat.format(new Date());
  if (el.clock.textContent !== words) el.clock.textContent = words;
}

// ---------------------------------------------------------------- your level, before joining

let meterTimer = 0;
const meterBars = $$('i', el.meter);
function tickMeter() {
  const level = media.micLevel();
  el.meter.classList.toggle('is-live', !media.micMuted() && media.metering());
  const shape = [0.6, 1, 0.75];
  meterBars.forEach((bar, i) => { bar.style.height = `${Math.round(4 + level * 12 * shape[i] * (0.8 + Math.random() * 0.4))}px`; });
}

// ---------------------------------------------------------------- joining and leaving

function videos() {
  const want = (params.get('video') || 'anna,jonas').toLowerCase();
  if (want === 'none') return new Set();
  if (want === 'all') return new Set(people.PEOPLE.map((p) => p.id));
  return new Set(want.split(',').map((s) => s.trim()).filter(Boolean));
}

function enterCall() {
  closePops();
  hideTip();
  clearInterval(meterTimer);
  if (el.prejoin.isConnected) el.prejoin.remove();
  el.left.hidden = true;
  el.call.hidden = false;
  document.body.className = 'is-call';
  people.mount({ stage: el.stage, tiles: el.tiles, feeds: el.feeds, videos: videos() });
  renderSwitches();
  renderMenus();
  renderShare();
  panel.renderPeople();
  tickClock();
  clearInterval(clockTimer);
  clockTimer = setInterval(tickClock, 1000);
  panel.startLater();
  const later = app.later;
  app.later = [];
  later.forEach((fn) => fn());
  if (app.pending) {
    const who = app.pending;
    app.pending = null;
    window.remotePresent(who);
  }
}

function join({ quick = false } = {}) {
  if (app.joined) return;
  app.joined = true;
  media.wakeAudio();
  if (quick || !el.prejoin.isConnected) { enterCall(); return; }
  el.prejoin.classList.add('is-leaving');
  setTimeout(enterCall, 220);
}

function leave() {
  if (!app.joined) return;
  app.joined = false;
  closePops();
  hideTip();
  if (panel.current()) panel.closePanel();
  setCaptions(false);
  if (app.hand) setHand(false);
  stopDeck();
  media.stopAll();
  people.unmount();
  clearInterval(clockTimer);
  panel.stopLater();
  el.call.hidden = true;
  el.left.hidden = false;
  document.body.className = 'is-left';
}

$('#hangup-button').addEventListener('click', leave);
$('#join-now').addEventListener('click', () => join());
$('#join-present').addEventListener('click', () => {
  media.wakeAudio();
  media.share().then(() => join(), shareFailed);
});
$('#rejoin').addEventListener('click', () => {
  media.wakeAudio();
  media.start().finally(() => join({ quick: true }));
});
$('#rate').addEventListener('click', (e) => {
  if (!e.target.closest('.rate-pick')) return;
  $('#rate').innerHTML = '<p>Thanks, that helps us make calls better.</p>';
});

media.on((what) => {
  if (what === 'tracks' || what === 'mic' || what === 'camera') renderSwitches();
  if (what === 'tracks' || what === 'devices') renderMenus();
  if (what === 'share') renderShare();
});

// ---------------------------------------------------------------- start

// ?mic=0 and ?cam=0: the tracks start switched off, and the browser hears so.
if (params.get('mic') === '0') media.local.micOn = false;
if (params.get('cam') === '0') media.local.camOn = false;
function startOff() {
  if (!media.local.micOn) media.setMic(false);
  if (!media.local.camOn) media.setCamera(false);
}

renderSwitches();
renderMenus();
if (params.get('join') === '1') {
  media.start().then(startOff).finally(() => join({ quick: true }));
} else {
  media.start().then(startOff);
  meterTimer = setInterval(tickMeter, 100);
}
if (['anna', 'jonas', 'elliot'].includes(params.get('present'))) window.remotePresent(params.get('present'));
if (params.get('captions') === '1') app.later.push(() => setCaptions(true));
if (['people', 'chat'].includes(params.get('panel'))) app.later.push(() => panel.openPanel(params.get('panel')));
