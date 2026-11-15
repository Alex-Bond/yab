/* yab: a page's sound started by an extension's script in the page's own world (ExtensionShims.audio) */
(() => {
  // Chrome lets an AudioContext start once its page has had a click or a
  // key (sticky activation); WebKit, with Yab's sound kept from playing by
  // itself (mediaTypesRequiringUserActionForPlayback .audio), only inside
  // one. Transpose makes its context as it reaches the page, after the
  // click that started the video, and asks it to resume when the video
  // plays: in Yab it stayed suspended for good, the popup said "Start
  // playback" over a playing video, pitch did nothing (feedback #271).
  // This goes before only a script of an extension's that runs in a
  // page's own world and makes an AudioContext: a context made after it
  // that is suspended though its own code never suspended it starts with
  // the page's next click or key, inside it, as WebKit allows. Nothing
  // else of the page's changes.
  if (typeof window === "undefined" || typeof window.AudioContext !== "function") return;
  const mark = Symbol.for("yab.extension-audio");
  if (window[mark]) return;
  try { Object.defineProperty(window, mark, { value: true }); } catch (e) { return; }
  const Native = window.AudioContext;
  const proto = Native.prototype;
  const resume = proto.resume, suspend = proto.suspend;
  if (typeof resume !== "function") return;
  const waiting = new Set(), held = new WeakSet();
  const watch = (context) => {
    if (held.has(context) || context.state !== "suspended") return;
    if (!waiting.has(context)) {
      waiting.add(context);
      try { context.addEventListener("statechange", () => { if (context.state !== "suspended") waiting.delete(context); }); } catch (e) {}
    }
    listen();
  };
  const own = (target, name, value) => {
    try { Object.defineProperty(target, name, { value, configurable: true, writable: true }); } catch (e) {}
  };
  own(proto, "resume", function () {
    held.delete(this);
    const promise = resume.apply(this, arguments);
    if (this instanceof Native) watch(this);
    return promise;
  });
  if (typeof suspend === "function") {
    own(proto, "suspend", function () {
      held.add(this);
      waiting.delete(this);
      return suspend.apply(this, arguments);
    });
  }
  const Made = new Proxy(Native, {
    construct(target, args, newTarget) {
      const context = Reflect.construct(target, args, newTarget === Made ? target : newTarget);
      watch(context);
      return context;
    }
  });
  const webkit = window.webkitAudioContext === Native;
  own(window, "AudioContext", Made);
  if (webkit) own(window, "webkitAudioContext", Made);
  // The page's next click or key, before its own listeners: every context
  // still waiting is resumed inside it.
  const kinds = ["pointerdown", "mousedown", "keydown", "touchend", "click"];
  let listening = false;
  const press = (event) => {
    if (!event.isTrusted) return;
    for (const context of [...waiting]) {
      waiting.delete(context);
      if (context.state === "suspended" && !held.has(context)) {
        try { resume.call(context).catch(() => {}); } catch (e) {}
      }
    }
    if (!waiting.size) {
      listening = false;
      for (const kind of kinds) window.removeEventListener(kind, press, true);
    }
  };
  const listen = () => {
    if (listening || !waiting.size) return;
    listening = true;
    for (const kind of kinds) window.addEventListener(kind, press, { capture: true, passive: true });
  };
})();
