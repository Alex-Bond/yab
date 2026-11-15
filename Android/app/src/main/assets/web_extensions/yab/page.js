(() => {
  "use strict";
  if (window !== top) return;
  const port = browser.runtime.connectNative("yab");
  let retired = false;
  let reader = null;
  let dirty = false;
  const documentID = String(Date.now()) + ":" + String(Math.random());
  globalThis.__yabHistoryTouchLedgerV1?.attach(port, documentID);
  let answerTarget = null;
  const answerEditable = e => {
    if (!e || e.ownerDocument !== document || !e.isConnected || e.matches(":disabled") || e.readOnly) return false;
    // A form control's contenteditable attribute or ancestor cannot bypass its type.
    if (e instanceof HTMLInputElement) return ["text","search","url","tel"].includes(e.type);
    if (e instanceof HTMLTextAreaElement) return true;
    return e.isContentEditable && !["SELECT","OPTION","BUTTON"].includes(e.tagName);
  };
  const translation = (() => {
    const skip = new Set("SCRIPT STYLE NOSCRIPT TEXTAREA INPUT SELECT OPTION CODE PRE KBD SAMP VAR SVG MATH CANVAS IFRAME OBJECT EMBED TEMPLATE HEAD TITLE".split(" "));
    const ids = new WeakMap(), nodes = new Map();
    let sequence = 0, active = false, target = null, originalLang = null, hadLang = false, observer = null, dirty = false;
    function accept(node) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (skip.has(node.tagName) || node.getAttribute("translate") === "no" || node.classList?.contains("notranslate") || node.isContentEditable) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_SKIP;
      }
      const words = node.nodeValue.trim();
      return words.length > 1 && /\p{L}/u.test(words) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }
    function restore() {
      observer?.disconnect(); observer = null;
      for (const record of nodes.values()) {
        // The site's later edits belong to it, even while a translation is visible.
        if (record.mine !== null && record.node.isConnected && record.node.nodeValue === record.mine) record.node.nodeValue = record.own;
        record.mine = null;
      }
      if (active && document.documentElement.lang === target) {
        if (hadLang) document.documentElement.setAttribute("lang", originalLang);
        else document.documentElement.removeAttribute("lang");
      }
      active = false; target = null; dirty = false;
    }
    function begin(language) {
      if (active && target !== language) restore();
      if (!active) {
        hadLang = document.documentElement.hasAttribute("lang");
        originalLang = document.documentElement.getAttribute("lang");
        active = true;
      }
      target = language;
      document.documentElement.setAttribute("lang", language);
      if (!observer) {
        observer = new MutationObserver(() => { dirty = true; });
        observer.observe(document.documentElement, {childList:true, subtree:true, characterData:true});
      }
    }
    function collect() {
      dirty = false;
      for (const [id, record] of nodes) if (!record.node.isConnected) { ids.delete(record.node); nodes.delete(id); }
      const segments = [], root = document.body;
      if (!root) return segments;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {acceptNode:accept});
      let node, characters = 0;
      while ((node = walker.nextNode())) {
        if (segments.length >= 4000 || characters >= 250000) { dirty = true; break; }
        let id = ids.get(node), record = nodes.get(id);
        if (!record) {
          if (nodes.size >= 20000) break;
          id = String(++sequence); ids.set(node, id);
          record = {node, own:node.nodeValue, mine:null}; nodes.set(id, record);
        } else if (record.mine !== null && node.nodeValue === record.mine) continue;
        else if (node.nodeValue !== record.own) { record.own = node.nodeValue; record.mine = null; }
        characters += record.own.length;
        segments.push({id, text:record.own});
      }
      return segments;
    }
    function apply(segments) {
      for (const segment of segments) {
        const record = nodes.get(segment.id);
        if (!record?.node.isConnected || typeof segment.text !== "string") continue;
        if (record.node.nodeValue !== record.own && record.node.nodeValue !== record.mine) continue;
        record.mine = segment.text; record.node.nodeValue = segment.text;
      }
      // MutationObserver callbacks run later. Drain just these synchronous writes so
      // translated text never becomes a new source or schedules another translation.
      observer?.takeRecords();
    }
    return {begin, collect, apply, restore,
      language:() => active ? originalLang : document.documentElement.lang || document.querySelector('meta[http-equiv="content-language" i]')?.content || null,
      translated:() => active, target:() => target,
      changed:() => { const changed = dirty; dirty = false; return changed; }};
  })();
  const pageText = () => (document.body?.innerText || "").slice(0, 12000);
  // Resource-free Reader copy, following Phone/PageReader. No original DOM node,
  // attribute, active content or resource URL is moved into the reading surface.
  const readerTags = new Set("ARTICLE SECTION DIV P H2 H3 H4 H5 H6 BLOCKQUOTE PRE CODE UL OL LI TABLE THEAD TBODY TFOOT TR TH TD STRONG EM B I U S SMALL SUP SUB BR HR FIGURE FIGCAPTION DL DT DD A SPAN".split(" "));
  const readerBlocked = new Set("SCRIPT STYLE LINK NOSCRIPT FORM NAV ASIDE FOOTER A BUTTON INPUT SELECT TEXTAREA IFRAME FRAME OBJECT EMBED VIDEO AUDIO IMG PICTURE SOURCE TRACK CANVAS SVG MATH TEMPLATE".split(" "));
  const readerAround = /(^|\s)(comments?|reply|replies|sidebar|related|recommend\w*|footer|promo|newsletter|share|social|advert\w*|sponsor\w*)([\s_-]|$)/i;
  // Current Phone's prose scoring is independent of semantic article tags.
  // Keep its text normalization, linked-text subtraction and sibling grouping.
  function readerAroundNode(node) {
    for (let up = node; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
      const tag = up.tagName;
      if (tag === "ASIDE" || tag === "NAV" || tag === "FOOTER" || tag === "A" || tag === "DIALOG") return true;
      const role = up.getAttribute("role");
      if (role === "complementary" || role === "navigation" || role === "dialog" || role === "alertdialog") return true;
      const name = (typeof up.className === "string" ? up.className : "") + " " + (up.id || "");
      if (name.length > 1 && readerAround.test(name)) return true;
    }
    return false;
  }
  function readerVisible(node) {
    for (let up = node; up; up = up.parentElement) {
      const style = getComputedStyle(up);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" || Number.parseFloat(style.opacity) === 0) return false;
    }
    return true;
  }
  function readerMeasure() {
    const paragraphs = document.getElementsByTagName("p"), prose = new Map(), counts = new Map(), kept = [];
    for (let i = 0; i < paragraphs.length; i++) {
      const p = paragraphs[i];
      if (!readerVisible(p)) continue;
      const letters = p.innerText.trim().length;
      if (letters < 25 || readerAroundNode(p)) continue;
      let linked = 0;
      const links = p.getElementsByTagName("a");
      for (let k = 0; k < links.length; k++) linked += links[k].innerText.length;
      const own = letters - linked;
      if (own <= letters / 3) continue;
      kept.push({p, letters, own});
      for (let up = p.parentElement; up && up !== document.documentElement; up = up.parentElement) {
        prose.set(up, (prose.get(up) || 0) + own);
        counts.set(up, (counts.get(up) || 0) + 1);
      }
    }
    return {prose, counts, kept};
  }
  function readerBest() {
    const measured = readerMeasure();
    let top = document.body;
    if (!top || !measured.prose.get(top)) return null;
    for (;;) {
      const whole = measured.prose.get(top);
      let next = null;
      for (let child = top.firstElementChild; child; child = child.nextElementSibling) {
        if ((measured.prose.get(child) || 0) >= whole * 0.8) { next = child; break; }
      }
      if (!next || (measured.counts.get(next) || 0) < 2) break;
      top = next;
    }
    return {el:top, prose:measured.prose.get(top), paragraphs:measured.counts.get(top)};
  }
  function readerReadable() {
    if (readerCurrent()) return true;
    const measured = readerMeasure(), runs = new Map();
    let found = false;
    for (let i = 0; i < measured.kept.length; i++) {
      const paragraph = measured.kept[i];
      let block = paragraph.p;
      while (block.parentElement && measured.counts.get(block.parentElement) === 1) block = block.parentElement;
      if (block.textContent.length > paragraph.letters * 1.3 + 20) continue;
      const run = runs.get(block.parentElement) || {n:0, prose:0};
      run.n++; run.prose += paragraph.own;
      runs.set(block.parentElement, run);
    }
    runs.forEach((run, parent) => {
      if (found || run.n < 3 || run.prose < 1200) return;
      if (parent.checkVisibility && !parent.checkVisibility()) return;
      found = true;
    });
    return found;
  }
  const readerBody = document.body, readerRoot = document.documentElement;
  let readerRetired = false;
  function readerSourceCurrent() {
    if (readerRetired) return false;
    if (document.body !== readerBody || document.documentElement !== readerRoot) { readerRetired = true; return false; }
    return true;
  }
  function readerHidden(node) {
    let depth = 0;
    for (let up = node; up; up = up.parentElement) {
      if (++depth > 128 || up.hidden || up.getAttribute("aria-hidden") === "true") return true;
      const role = up.getAttribute("role");
      const around = (typeof up.className === "string" ? up.className : "") + " " + (up.id || "");
      if (readerBlocked.has(up.tagName) || up.tagName === "DIALOG" ||
          ["complementary", "navigation", "dialog", "alertdialog"].includes(role) || readerAround.test(around)) return true;
      const style = getComputedStyle(up);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" || Number.parseFloat(style.opacity) === 0) return true;
    }
    return false;
  }
  function readerCopy(node, budget, depth = 0) {
    if (++budget.nodes > 20000 || depth > 128) { budget.exhausted = true; return null; }
    if (node.nodeType === Node.TEXT_NODE) {
      budget.letters += node.nodeValue.length;
      if (budget.letters > 400000) { budget.exhausted = true; return null; }
      return document.createTextNode(node.nodeValue);
    }
    if (node.nodeType !== Node.ELEMENT_NODE || readerBlocked.has(node.tagName) || node.tagName === "H1" || readerHidden(node)) return null;
    const clean = document.createElement(readerTags.has(node.tagName) ? node.tagName.toLowerCase() : "div");
    // Current Phone around()/copy() excludes A and its whole subtree before
    // its later href branch. Match that actual behavior, not the dead branch.
    for (let child = node.firstChild; child; child = child.nextSibling) {
      const copy = readerCopy(child, budget, depth + 1);
      if (budget.exhausted) return null;
      if (copy) clean.appendChild(copy);
    }
    return clean;
  }
  function readerCurrent() {
    return readerSourceCurrent() && !!reader && reader.document === document && reader.documentID === documentID &&
      reader.url === location.href && reader.root === document.documentElement && reader.body === document.body && reader.host.isConnected;
  }
  function readerLeave() {
    if (!reader) return false;
    const old = reader, current = readerCurrent(); reader = null;
    old.host.remove();
    // Restore the exact attribute only while it is exactly our applied value.
    // A later zoom/site edit belongs to the page, on live and stale exits alike.
    for (const [node, property, applied, value, priority, before, after] of [
      [old.body, "display", "none", old.display, old.displayPriority, old.bodyStyle, old.appliedBodyStyle],
      [old.root, "overflow", "hidden", old.overflow, old.overflowPriority, old.rootStyle, old.appliedRootStyle]]) {
      if (node.getAttribute("style") === after) {
        if (before === null) node.removeAttribute("style"); else node.setAttribute("style", before);
      } else if (node.style.getPropertyValue(property) === applied && node.style.getPropertyPriority(property) === "important") {
        if (value) node.style.setProperty(property, value, priority); else node.style.removeProperty(property);
      }
    }
    if (current) window.scrollTo({left:old.x, top:old.y, behavior:"instant"});
    return current;
  }
  // Typed presentation values only. The closed shadow keeps these original references;
  // no selector, CSS fragment, URL, font resource or page command comes from this payload.
  const readerFonts = new Set(["", 'ui-serif, "New York", Georgia, serif', "Charter, Georgia, serif",
    '"Iowan Old Style", Georgia, serif', 'Palatino, "Palatino Linotype", Georgia, serif',
    "Athelas, Georgia, serif", "Georgia, serif", "system-ui, sans-serif"]);
  const readerDark = matchMedia("(prefers-color-scheme: dark)");
  let readerLook = {mode:"auto", day:{bg:"#ffffff",ink:"#1d1d1f"}, night:{bg:"#1c1c1e",ink:"#e8e8ea"},
    font:"",weight:400,size:18,line:1.6,letter:0,word:0,width:38,justify:false};
  let readerMargins = 0;
  function readerLuminance(hex) {
    const rgb = parseInt(hex.slice(1), 16);
    const c = [16,8,0].map(shift => { const v=((rgb>>shift)&255)/255;return v<=.04045?v/12.92:Math.pow((v+.055)/1.055,2.4); });
    return c[0]*.2126+c[1]*.7152+c[2]*.0722;
  }
  function readerGround(value) {
    if (!value || typeof value.bg!=="string" || typeof value.ink!=="string" ||
        !/^#[a-f0-9]{6}$/i.test(value.bg) || !/^#[a-f0-9]{6}$/i.test(value.ink)) return null;
    const a=readerLuminance(value.bg),b=readerLuminance(value.ink);
    return (Math.max(a,b)+.05)/(Math.min(a,b)+.05)>=4.5 ? {bg:value.bg,ink:value.ink,dark:a<.179} : null;
  }
  function readerTheme(value, margins) {
    if (!value || typeof value!=="object" || !["auto","light","dark"].includes(value.mode) ||
        !readerFonts.has(value.font) || ![400,500,700].includes(value.weight) ||
        ![14,15,16,17,18,20,22,24,26,28].includes(value.size) || typeof value.justify!=="boolean") return false;
    for (const [number,min,max] of [[value.line,1.3,2.1],[value.letter,-.03,.10],[value.word,0,.4],
        [value.width,26.6,62.4],[margins,-30,30]]) if (typeof number!=="number" || !Number.isFinite(number) || number<min || number>max) return false;
    const day=readerGround(value.day),night=readerGround(value.night);
    if (!day || !night || !Number.isInteger(margins)) return false;
    readerLook={mode:value.mode,day,night,font:value.font,weight:value.weight,size:value.size,line:value.line,
      letter:value.letter,word:value.word,width:value.width,justify:value.justify};
    readerMargins=margins; return true;
  }
  function readerDress() {
    if (!readerCurrent()) { if (reader) readerLeave(); return false; }
    const look=readerLook,ground=look.mode==="dark" || (look.mode==="auto" && readerDark.matches) ? look.night : look.day;
    const style=reader.host.style;
    style.setProperty("--bg",ground.bg);style.setProperty("--ink",ground.ink);
    style.setProperty("--scheme",readerLuminance(ground.bg)<.179?"dark":"light");
    style.setProperty("--f",look.font || reader.face || "ui-serif,Georgia,serif");
    style.setProperty("--s",look.size+"px");style.setProperty("--lh",String(look.line));style.setProperty("--wt",String(look.weight));
    style.setProperty("--ls",look.letter+"em");style.setProperty("--ws",look.word+"em");
    style.setProperty("--al",look.justify?"justify":"left");style.setProperty("--w",look.width+"em");
    style.setProperty("--pad","max(10px, calc(24px + "+(readerMargins*.3)+"vw))");
    reader.prose.classList.toggle("just",look.justify);return true;
  }
  readerDark.addEventListener("change",()=>{if (reader && readerLook.mode==="auto") readerDress();});
  function readerEnter() {
    if (reader) { if (readerCurrent()) return true; readerLeave(); return false; }
    if (!readerSourceCurrent() || !readerReadable()) return false;
    const source = readerBest()?.el, body = document.body, root = document.documentElement;
    if (!source || !body || !root || !body.contains(source) || readerHidden(source)) return false;
    const budget = {nodes:0, letters:0, exhausted:false};
    const copy = readerCopy(source, budget);
    if (!copy || budget.exhausted || copy.textContent.trim().length < 400) return false;
    const title = document.createElement("h1");
    const heading = source.querySelector("h1") || document.querySelector("h1");
    title.textContent = (heading && !readerHidden(heading) ? heading.textContent.trim() : "") || document.title;
    if (budget.letters + title.textContent.length > 400000) return false;
    const prose = document.createElement("article"); prose.append(title, copy);
    const host = document.createElement("div");
    host.style.cssText = "position:fixed!important;inset:0!important;z-index:2147483646!important;display:block!important;overflow:auto!important;background:var(--bg,#ffffff)!important;color:var(--ink,#1d1d1f)!important";
    const shadow = host.attachShadow({mode:"closed"}), style = document.createElement("style");
    style.textContent = ":host{color-scheme:var(--scheme,light)}article{box-sizing:border-box;max-width:var(--w,38em);margin:0 auto;padding:24px var(--pad,24px) 80px;overflow-wrap:break-word;font-family:var(--f,ui-serif,Georgia,serif);font-size:var(--s,18px);line-height:var(--lh,1.6);font-weight:var(--wt,400);letter-spacing:var(--ls,0);word-spacing:var(--ws,0);text-align:var(--al,left)}article.just :is(p,li,blockquote){hyphens:auto}h1{font:700 calc(var(--s,18px)*1.6)/1.18 var(--f,ui-serif,Georgia,serif);letter-spacing:-.015em;margin:0 0 12px;text-align:left}h2,h3,h4,h5,h6{font-family:inherit;font-weight:700;line-height:1.3;margin:1.5em 0 .6em;text-align:left}h2{font-size:1.3em}h3{font-size:1.15em}h4,h5,h6{font-size:1em}p{margin:0 0 1.35em}pre,code{font:14px/1.6 ui-monospace,monospace;letter-spacing:0;word-spacing:0}pre{white-space:pre-wrap;padding:14px;background:color-mix(in srgb,var(--ink,#171717) 6%,transparent);border-radius:8px;text-align:left}blockquote{margin:1.5em 0;padding-left:1em;border-left:2px solid color-mix(in srgb,var(--ink,#171717) 22%,transparent);opacity:.85}table{display:block;overflow:auto;border-collapse:collapse}td,th{padding:6px;border:1px solid color-mix(in srgb,var(--ink,#171717) 18%,transparent)}::selection{background:var(--ink,#171717);color:var(--bg,#fff)}";
    shadow.append(style, prose);
    reader = {document, documentID, url:location.href, body, root, host, prose, style,
      face:getComputedStyle(source.querySelector("p") || source).fontFamily || "",
      bodyStyle:body.getAttribute("style"), rootStyle:root.getAttribute("style"),
      display:body.style.getPropertyValue("display"), displayPriority:body.style.getPropertyPriority("display"),
      overflow:root.style.getPropertyValue("overflow"), overflowPriority:root.style.getPropertyPriority("overflow"),
      x:window.scrollX, y:window.scrollY};
    root.append(host); body.style.setProperty("display", "none", "important");
    root.style.setProperty("overflow", "hidden", "important");
    reader.appliedBodyStyle = body.getAttribute("style"); reader.appliedRootStyle = root.getAttribute("style");
    readerDress();
    window.scrollTo({left:0, top:0, behavior:"instant"});
    return true;
  }
  const report = (proof) => {
    if (reader && !readerCurrent()) readerLeave();
    port.postMessage({kind:"state", documentID, url:location.href, title:document.title,
    declaredIconHref:document.querySelector('link[rel~=icon], link[rel=apple-touch-icon]')?.href?.slice(0,4097) || null,
    readerAvailable: readerSourceCurrent() && readerReadable(), readerEnabled:readerCurrent(),
    safeObservation:true, frameUncertain:!!document.querySelector("iframe,frame"),
    editing:!!document.activeElement?.matches("input,textarea,select,[contenteditable]:not([contenteditable=false])"),
    proof:typeof proof==="string"?proof:null,
    dirty, scrollY:scrollY, playing:[...document.querySelectorAll("audio,video")].some(x=>!x.paused&&!x.ended)});
  };
  port.onMessage.addListener(message => {
    if (retired || !message || typeof message !== "object") return;
    if (message.command === "retire") {
      retired = true; answerTarget = null; port.disconnect(); return;
    }
    if ((message.command?.startsWith("translation-") || message.command?.startsWith("answer-")) && message.expectedDocument !== documentID) {
      port.postMessage({kind:"dom", request:message.request, documentID, ok:false, error:"The page changed"}); return;
    }
    switch (message.command) {
      case "safety": report(message.request); return;
      case "answer-capture": {
        answerTarget = null;
        const e = document.activeElement, token = message.answerToken;
        let ready = false;
        if (typeof token === "string" && /^[a-f0-9-]{36}$/.test(token) && answerEditable(e)) {
          const input = e instanceof HTMLTextAreaElement || e instanceof HTMLInputElement;
          const selection = getSelection();
          answerTarget = {token, e, document, input,
            start:input ? e.selectionStart : null, end:input ? e.selectionEnd : null,
            range:!input && selection?.rangeCount ? selection.getRangeAt(0).cloneRange() : null};
          ready = true;
        }
        port.postMessage({kind:"dom", request:message.request, documentID, ok:true, ready}); return;
      }
      case "answer-revoke": {
        if (answerTarget?.token === message.answerToken) answerTarget = null;
        port.postMessage({kind:"dom", request:message.request, documentID, ok:true}); return;
      }
      case "answer-insert": {
        const t = answerTarget, value = message.answerValue;
        let inserted = false;
        if (t?.token === message.answerToken) {
          answerTarget = null;
          if (t.document === document && answerEditable(t.e) && typeof value === "string" && value.length <= 4096) {
            const e = t.e;
            if (t.input) {
              e.focus();
              e.setRangeText(value, t.start ?? e.value.length, t.end ?? e.value.length, "end");
              e.dispatchEvent(new InputEvent("input", {bubbles:true,inputType:"insertFromPaste",data:value}));
              inserted = true;
            } else if (t.range && e.contains(t.range.commonAncestorContainer)) {
              e.focus(); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(t.range);
              inserted = document.execCommand("insertText", false, value);
            }
          }
        }
        port.postMessage({kind:"dom", request:message.request, documentID, ok:true, inserted}); return;
      }
      case "text": {
        const response = {kind:"text", request:message.request, documentID, url:location.href, title:document.title, text:pageText()};
        if (message.diagnostics === true) {
          const body = document.body;
          // Only fixed, finite numeric geometry is added to the existing owned
          // diagnostic reply. No new command or page evaluation authority.
          const scalar = value => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1000000 ? value : null;
          const scrolling = document.scrollingElement || document.documentElement;
          response.shape = {hasBody:!!body,
            readyState:["loading","interactive","complete"].includes(document.readyState)?document.readyState:"unknown",
            visibility:["visible","hidden","prerender"].includes(document.visibilityState)?document.visibilityState:"unknown",
            innerTextLength:Math.min((body?.innerText || "").length,1000000),
            textContentLength:Math.min((body?.textContent || "").length,1000000),
            clientHeight:scalar(document.documentElement?.clientHeight),
            scrollHeight:scalar(scrolling?.scrollHeight),
            innerHeight:scalar(window.innerHeight), dpr:scalar(window.devicePixelRatio),
            visualViewportHeight:scalar(window.visualViewport?.height)};
        }
        port.postMessage(response); break;
      }
      case "translation-collect": {
        port.postMessage({kind:"dom",request:message.request,documentID,ok:true,title:document.title,language:translation.language(),
          translated:translation.translated(),targetLanguage:translation.target(),segments:translation.collect()});break;
      }
      case "translation-begin": translation.begin(message.target); port.postMessage({kind:"dom",request:message.request,documentID,ok:true});break;
      case "translation-changed": port.postMessage({kind:"dom",request:message.request,documentID,ok:true,changed:translation.changed()});break;
      case "translation-apply": {
        translation.apply(message.segments || []);
        port.postMessage({kind:"dom",request:message.request,documentID,ok:true});break;
      }
      case "translation-original": {
        translation.restore();port.postMessage({kind:"dom",request:message.request,documentID,ok:true});break;
      }
      case "pause": document.querySelectorAll("audio,video").forEach(x=>x.pause()); break;
      case "reader": {
        if (message.expectedDocument !== documentID || message.expectedURL !== location.href || typeof message.enabled !== "boolean") return;
        if (message.enabled && message.look!==undefined && !readerTheme(message.look,message.margins)) return;
        if (message.enabled) readerEnter(); else readerLeave();
        break;
      }
      case "reader-style": {
        if (message.expectedDocument!==documentID || message.expectedURL!==location.href || !readerCurrent()) return;
        if (!readerTheme(message.look,message.margins)) return;
        readerDress();break;
      }
      case "zoom":
        if (message.expectedDocument !== documentID) return;
        document.documentElement.style.zoom=String(Math.max(.5,Math.min(3,Number(message.factor)||1))); break;
      case "dark": {
        document.getElementById("yab-dark-mode")?.remove();
        if (!message.enabled || matchMedia("(prefers-color-scheme: dark)").matches) break;
        const style=document.createElement("style");style.id="yab-dark-mode";
        style.textContent="html{filter:invert(.9) hue-rotate(180deg);background:#eee}img,video,canvas,svg{filter:invert(1) hue-rotate(180deg)}";
        document.documentElement.append(style);break;
      }
    }
    report();
  });
  document.addEventListener("input",()=>{dirty=true;report();},true);
  document.addEventListener("submit",()=>{dirty=false;report();},true);
  document.addEventListener("focusin",()=>report(),true);
  document.addEventListener("focusout",()=>setTimeout(()=>report(),0),true);
  for (const event of ["play","pause","ended"]) document.addEventListener(event,report,true);
  let timer; window.addEventListener("scroll",()=>{clearTimeout(timer);timer=setTimeout(report,120);},{passive:true});
  new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(report,250);}).observe(document.documentElement,{childList:true,subtree:true});
  report();
})();
