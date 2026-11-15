// Your camera, microphone and speaker, and your screen while you present.
// The rest of the page reads them from `local` and hears of every change
// through `on(fn)`, with what changed: 'tracks', 'mic', 'camera',
// 'devices' or 'share'.
//
// Muting switches the track off (track.enabled), as calls do, and tells
// the browser too where it can be told (mediaSession.setMicrophoneActive),
// so the browser's own mute and the page's are one switch: muted from the
// browser, the track says so (muted) and the page shows it.

const VIDEO = { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } };
const hearers = new Set();

export const local = {
  audio: null,
  video: null,
  screen: null,
  self: null,          // your camera alone, for your own tiles
  micOn: true,
  camOn: true,
  devices: { audioinput: [], audiooutput: [], videoinput: [] },
  current: { audioinput: '', audiooutput: '', videoinput: '' },
  started: false,
  failed: false,
  leaving: false,
};

// Muted by the browser after the page asked it to: its unmute is ours to take.
const held = { mic: false, camera: false };

export function on(fn) { hearers.add(fn); return () => hearers.delete(fn); }
function tell(what) {
  hearers.forEach((fn) => { try { fn(what); } catch (e) { console.error(e); } });
}

const devicesApi = () => navigator.mediaDevices;
const live = (t) => !!t && t.readyState === 'live';

export function micMuted() { return !live(local.audio) || !local.micOn || local.audio.muted; }
export function cameraOff() { return !live(local.video) || !local.camOn || local.video.muted; }

// ---------------------------------------------------------------- starting

export async function start() {
  local.leaving = false;
  const m = devicesApi();
  if (!m || !m.getUserMedia) {
    local.failed = true;
    local.started = true;
    tell('tracks');
    return false;
  }
  let stream = null;
  try {
    stream = await m.getUserMedia({ audio: true, video: VIDEO });
  } catch (e) {
    // A refusal stands for both; a missing or busy device leaves the other.
    if (!e || e.name !== 'NotAllowedError') {
      for (const want of [{ audio: true }, { video: VIDEO }]) {
        try { stream = await m.getUserMedia(want); break; } catch (_) { /* the next */ }
      }
    }
  }
  local.started = true;
  local.failed = !stream;
  if (stream) {
    const audio = stream.getAudioTracks()[0] || null;
    const video = stream.getVideoTracks()[0] || null;
    if (audio) adopt('audioinput', audio);
    if (video) adopt('videoinput', video);
  }
  tell('tracks');
  await refreshDevices();
  return !!stream;
}

function adopt(kind, track) {
  const mic = kind === 'audioinput';
  const old = mic ? local.audio : local.video;
  track.enabled = mic ? local.micOn : local.camOn;
  if (mic) local.audio = track; else local.video = track;
  watch(kind, track);
  if (old && old !== track) old.stop();
  const id = track.getSettings ? track.getSettings().deviceId : '';
  if (id) local.current[kind] = id;
  if (!mic) local.self = new MediaStream([track]);
  if (mic) connectMeter();
}

function watch(kind, track) {
  const which = kind === 'audioinput' ? 'mic' : 'camera';
  track.addEventListener('mute', () => {
    if (which === 'mic' ? !local.micOn : !local.camOn) held[which] = true;
    // A camera the browser stopped sends nothing: off, so whoever shows
    // this call shows your picture rather than a frozen frame.
    if (which === 'camera') track.enabled = false;
    tell(which);
  });
  track.addEventListener('unmute', () => {
    // The browser let go of a mute the page had asked for: unmuted from
    // the browser's own switch, which the page takes as its own.
    if (held[which]) {
      held[which] = false;
      if (which === 'mic') { local.micOn = true; track.enabled = true; }
      else local.camOn = true;
    }
    if (which === 'camera') track.enabled = local.camOn;
    tell(which);
  });
  track.addEventListener('ended', () => lost(kind, track));
}

// A device unplugged under a live track: the default one in its place.
function lost(kind, track) {
  if (local.leaving) return;
  const current = kind === 'audioinput' ? local.audio : local.video;
  if (current !== track) return;
  tell(kind === 'audioinput' ? 'mic' : 'camera');
  setTimeout(() => {
    if (local.leaving) return;
    acquire(kind).finally(refreshDevices);
  }, 250);
}

async function acquire(kind, id) {
  const m = devicesApi();
  if (!m || !m.getUserMedia) throw new Error('No media devices');
  const exact = id ? { deviceId: { exact: id } } : {};
  const want = kind === 'audioinput' ? { audio: id ? exact : true } : { video: { ...VIDEO, ...exact } };
  let stream;
  try {
    stream = await m.getUserMedia(want);
  } catch (e) {
    // A browser that holds one device of a kind at a time: let go of the
    // one in use and ask again, and take it back if the new one won't come.
    const old = kind === 'audioinput' ? local.audio : local.video;
    if (!id || !live(old)) throw e;
    const was = old.getSettings ? old.getSettings().deviceId : '';
    old.stop();
    try {
      stream = await m.getUserMedia(want);
    } catch (again) {
      const back = was ? { deviceId: { exact: was } } : {};
      const restore = await m.getUserMedia(kind === 'audioinput' ? { audio: was ? back : true } : { video: { ...VIDEO, ...back } });
      const track = kind === 'audioinput' ? restore.getAudioTracks()[0] : restore.getVideoTracks()[0];
      if (track) { adopt(kind, track); tell('tracks'); }
      throw again;
    }
  }
  const track = kind === 'audioinput' ? stream.getAudioTracks()[0] : stream.getVideoTracks()[0];
  if (!track) throw new Error('No track');
  if (local.leaving) { track.stop(); return null; }
  adopt(kind, track);
  local.failed = false;
  tell('tracks');
  return track;
}

// ---------------------------------------------------------------- switches

function session(which, active) {
  const s = navigator.mediaSession;
  const set = s && (which === 'mic' ? s.setMicrophoneActive : s.setCameraActive);
  if (typeof set !== 'function') return;
  try {
    const p = set.call(s, active);
    if (p && typeof p.catch === 'function') p.catch(() => tell(which));
  } catch (_) { /* not here */ }
}

export function setMic(onNow) {
  held.mic = false;
  if (onNow && !live(local.audio)) {
    local.micOn = true;
    acquire('audioinput', local.current.audioinput || undefined)
      .catch(() => acquire('audioinput'))
      .catch(() => { local.micOn = false; tell('mic'); })
      .finally(refreshDevices);
    return;
  }
  local.micOn = onNow;
  if (local.audio) local.audio.enabled = onNow;
  session('mic', onNow);
  tell('mic');
}

export function setCamera(onNow) {
  held.camera = false;
  if (onNow && !live(local.video)) {
    local.camOn = true;
    tell('camera');
    acquire('videoinput', local.current.videoinput || undefined)
      .catch(() => acquire('videoinput'))
      .catch(() => { local.camOn = false; tell('camera'); })
      .finally(refreshDevices);
    return;
  }
  local.camOn = onNow;
  if (local.video) local.video.enabled = onNow;
  session('camera', onNow);
  tell('camera');
}

export function toggleMic() { setMic(micMuted()); }
export function toggleCamera() { setCamera(cameraOff()); }

// ---------------------------------------------------------------- devices

export async function refreshDevices() {
  const m = devicesApi();
  let list = [];
  try { list = m && m.enumerateDevices ? await m.enumerateDevices() : []; } catch (_) { list = []; }
  for (const kind of Object.keys(local.devices)) {
    local.devices[kind] = list.filter((d) => d.kind === kind && d.deviceId);
  }
  for (const [kind, track] of [['audioinput', local.audio], ['videoinput', local.video]]) {
    const id = live(track) && track.getSettings ? track.getSettings().deviceId : '';
    if (id) local.current[kind] = id;
  }
  const speakers = local.devices.audiooutput;
  if (!speakers.some((d) => d.deviceId === local.current.audiooutput)) {
    const fallback = speakers.find((d) => d.deviceId === 'default') || speakers[0];
    local.current.audiooutput = fallback ? fallback.deviceId : '';
  }
  tell('devices');
}

// The device a menu ticks: the one in use, else the one named like the
// track, else the first.
export function checked(kind) {
  const list = local.devices[kind];
  if (!list.length) return '';
  const id = local.current[kind];
  if (list.some((d) => d.deviceId === id)) return id;
  const track = kind === 'audioinput' ? local.audio : kind === 'videoinput' ? local.video : null;
  const named = track && list.find((d) => d.label && d.label === track.label);
  return (named || list[0]).deviceId;
}

export function label(kind, id) {
  const d = local.devices[kind].find((x) => x.deviceId === id);
  return d ? d.label : '';
}

// A device picked in a menu: ticked at once, then the track switched.
export async function pick(kind, id) {
  if (!id || checked(kind) === id) return true;
  const was = local.current[kind];
  local.current[kind] = id;
  tell('devices');
  try {
    if (kind === 'audiooutput') await sink(id);
    else await acquire(kind, id);
    tell('devices');
    return true;
  } catch (e) {
    local.current[kind] = was;
    tell('devices');
    throw e;
  }
}

async function sink(id) {
  const target = id === 'default' ? '' : id;
  const players = document.querySelectorAll('audio, video:not(.mirror)');
  for (const el of players) {
    if (typeof el.setSinkId === 'function') {
      try { await el.setSinkId(target); } catch (_) { /* that element can't */ }
    }
  }
}

export function sinkOf(el) {
  const id = local.current.audiooutput;
  if (id && typeof el.setSinkId === 'function') el.setSinkId(id === 'default' ? '' : id).catch(() => {});
}

if (devicesApi() && devicesApi().addEventListener) {
  devicesApi().addEventListener('devicechange', () => { if (local.started) refreshDevices(); });
}

// ---------------------------------------------------------------- the screen

// Called straight from a click: the browser asks for the screen only while
// the click is fresh, so nothing may wait before getDisplayMedia.
export function share() {
  const m = devicesApi();
  if (!m || typeof m.getDisplayMedia !== 'function') return Promise.reject(new Error('Unavailable'));
  let asked;
  try { asked = m.getDisplayMedia({ video: true }); } catch (e) { return Promise.reject(e); }
  return asked.then((stream) => {
    if (local.screen) stopShare(true);
    local.screen = stream;
    const track = stream.getVideoTracks()[0];
    if (track) track.addEventListener('ended', () => { if (local.screen === stream) stopShare(); });
    tell('share');
    return stream;
  });
}

export function stopShare(quiet) {
  const stream = local.screen;
  if (!stream) return;
  local.screen = null;
  stream.getTracks().forEach((t) => t.stop());
  if (!quiet) tell('share');
}

// Leaving: every device let go, so the browser knows the call is over.
export function stopAll() {
  local.leaving = true;
  stopShare(true);
  for (const t of [local.audio, local.video]) if (t) t.stop();
  local.audio = local.video = local.self = null;
  disconnectMeter();
  tell('tracks');
  tell('share');
}

// ---------------------------------------------------------------- your level

let audioCtx = null;
let analyser = null;
let source = null;
let samples = null;

// Sound can only start from a click or a key: called from one.
export function wakeAudio() {
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return;
  if (!audioCtx) {
    try { audioCtx = new AC(); } catch (_) { return; }
    analyser = audioCtx.createAnalyser();
    analyser.fftSize = 512;
    samples = new Float32Array(analyser.fftSize);
  }
  if (audioCtx.state === 'suspended') audioCtx.resume().catch(() => {});
  connectMeter();
}

function connectMeter() {
  if (!audioCtx) return;
  disconnectMeter();
  if (!live(local.audio)) return;
  try {
    source = audioCtx.createMediaStreamSource(new MediaStream([local.audio]));
    source.connect(analyser);
  } catch (_) { source = null; }
}

function disconnectMeter() {
  if (source) { try { source.disconnect(); } catch (_) { /* gone */ } }
  source = null;
}

// Whether your level can be heard at all: sound runs only after a click.
export function metering() { return !!source && !!audioCtx && audioCtx.state === 'running'; }

// 0 to 1: how loud you are now, nothing while muted.
export function micLevel() {
  if (!source || !audioCtx || audioCtx.state !== 'running' || micMuted()) return 0;
  analyser.getFloatTimeDomainData(samples);
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
  const rms = Math.sqrt(sum / samples.length);
  return Math.max(0, Math.min(1, (rms - 0.012) * 9));
}
