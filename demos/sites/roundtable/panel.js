// The side panel: who is on the call, and the call's messages.

import * as media from './media.js';
import * as people from './people.js';

const $ = (s, root = document) => root.querySelector(s);

const el = {
  panel: $('#panel'),
  peoplePage: $('#people-panel'),
  chatPage: $('#chat-panel'),
  peopleList: $('#people-list'),
  chatList: $('#chat-list'),
  chatForm: $('#chat-form'),
  chatInput: $('#chat-input'),
  chatDot: $('#chat-dot'),
  peopleButton: $('#people-button'),
  chatButton: $('#chat-button'),
};

let open = null;
let hand = false;

export function current() { return open; }

export function openPanel(which) {
  if (open === which) { closePanel(); return; }
  open = which;
  el.panel.hidden = false;
  el.peoplePage.hidden = which !== 'people';
  el.chatPage.hidden = which !== 'chat';
  el.peopleButton.setAttribute('aria-pressed', String(which === 'people'));
  el.chatButton.setAttribute('aria-pressed', String(which === 'chat'));
  if (which === 'chat') {
    el.chatDot.hidden = true;
    el.chatList.scrollTop = el.chatList.scrollHeight;
  }
  people.layout();
}

export function closePanel() {
  open = null;
  el.panel.hidden = true;
  el.peopleButton.setAttribute('aria-pressed', 'false');
  el.chatButton.setAttribute('aria-pressed', 'false');
  people.layout();
}

el.peopleButton.addEventListener('click', () => openPanel('people'));
el.chatButton.addEventListener('click', () => openPanel('chat'));
document.querySelectorAll('[data-close-panel]').forEach((b) => b.addEventListener('click', closePanel));

// ---------------------------------------------------------------- people

// Each row: the picture, the name, what they are doing, and their sound:
// bars while they talk, your muted microphone or your raised hand.
export function renderPeople(state = {}) {
  if ('hand' in state) hand = state.hand;
  const list = [people.ME, ...people.PEOPLE];
  if (!el.peopleList.firstChild) {
    for (const p of list) {
      const row = document.createElement('div');
      row.className = 'person';
      row.dataset.person = p.id;
      row.innerHTML = `
        <img class="avatar person-avatar" src="${p.avatar}" alt="" width="36" height="36">
        <div class="person-text"><div class="person-name"></div><div class="person-sub"></div></div>
        <div class="person-state"></div>`;
      $('.person-name', row).textContent = p.self ? `${p.name} (You)` : p.name;
      el.peopleList.append(row);
    }
  }
  const presenter = people.presenting();
  for (const p of list) {
    const row = $(`.person[data-person="${p.id}"]`, el.peopleList);
    if (!row) continue;
    const sub = presenter === p.id ? 'Presenting' : p.self ? 'Meeting host' : '';
    $('.person-sub', row).textContent = sub;
    $('.person-sub', row).hidden = !sub;
    const state = $('.person-state', row);
    let want = 'bars';
    if (p.self && hand) want = 'hand';
    else if (p.self && media.micMuted()) want = 'muted';
    if (state.dataset.showing !== want) {
      state.dataset.showing = want;
      if (want === 'hand') state.innerHTML = '<svg class="icon person-hand"><use href="#i-hand"/></svg>';
      else if (want === 'muted') state.innerHTML = '<svg class="icon"><use href="#i-mic-off"/></svg>';
      else state.innerHTML = `<div class="person-bars lv0" data-bars-for="${p.id}"><i></i><i></i><i></i></div>`;
    }
  }
}

// ---------------------------------------------------------------- chat

const EARLIER = [
  { who: 'anna', ago: 372, text: "Deck for today: Onboarding v3, 14 slides. I'll share my screen in a minute." },
  { who: 'jonas', ago: 318, text: "Can we spend most of the time on the invite step? That's where people drop off." },
  { who: 'elliot', ago: 196, text: 'Left a few notes on slides 6 and 9 about the empty states.' },
];
const LATER = { who: 'anna', after: 28000, text: 'Prototype is updated with the new skip buttons, same link as yesterday.' };
const timeOf = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' });
let lastSender = null;
let lastAt = 0;
let laterTimer = 0;
let laterSent = false;

function addMessage(who, text, at = Date.now()) {
  const person = people.byId(who);
  let msg = el.chatList.lastElementChild;
  if (!(msg && lastSender === who && at - lastAt < 5 * 60 * 1000)) {
    msg = document.createElement('div');
    msg.className = 'msg';
    const head = document.createElement('div');
    head.className = 'msg-head';
    const name = document.createElement('span');
    name.className = 'msg-name';
    name.textContent = !person || person.self ? 'You' : person.name;
    const time = document.createElement('span');
    time.className = 'msg-time';
    time.textContent = timeOf.format(new Date(at));
    head.append(name, time);
    msg.append(head);
    el.chatList.append(msg);
  }
  const line = document.createElement('p');
  line.className = 'msg-text';
  line.textContent = text;
  msg.append(line);
  lastSender = who;
  lastAt = at;
  el.chatList.scrollTop = el.chatList.scrollHeight;
}

const opened = Date.now();
for (const m of EARLIER) addMessage(m.who, m.text, opened - m.ago * 1000);

// One more message a little after you join, once.
export function startLater() {
  clearTimeout(laterTimer);
  if (laterSent) return;
  laterTimer = setTimeout(() => {
    laterSent = true;
    addMessage(LATER.who, LATER.text);
    if (open !== 'chat') el.chatDot.hidden = false;
  }, LATER.after);
}

export function stopLater() { clearTimeout(laterTimer); }

const send = $('.chat-send', el.chatForm);
el.chatInput.addEventListener('input', () => { send.disabled = !el.chatInput.value.trim(); });
el.chatForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const text = el.chatInput.value.trim();
  if (!text) return;
  addMessage(people.ME.id, text);
  el.chatInput.value = '';
  send.disabled = true;
});
