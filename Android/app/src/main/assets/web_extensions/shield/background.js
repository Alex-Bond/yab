"use strict";
(() => {
  let policy = null, matcher = null, staged = null, revision = null, native = null;
  const content = new Map();
  const empty = () => ({blocks:[], exceptions:[], important:[], generic:[], unhide:[]});
  function clear() { policy = null; matcher = null; staged = null; revision = null; refresh(); }
  function send(port, value) { try { port.postMessage(value); } catch (_) {} }
  function styles(port, record) {
    const sender = port.sender, page = sender.url, top = sender.frameId === 0 ? sender.url : sender.tab?.url;
    // Frame and Private identity come from Firefox, never a page message.
    const selectors = policy && matcher && YabShield.enabled(policy, top, sender.tab?.incognito === true) ? matcher.selectors(page, top) : [];
    const code = selectors.map(selector => selector + "{display:none!important}").join("\n");
    const epoch = ++record.epoch;
    record.queue = record.queue.then(async () => {
      if (record.css) {
        await browser.scripting.removeCSS({target:record.target, css:record.css, origin:"USER"}); record.css = "";
      }
      if (!record.alive || record.epoch !== epoch || !code) return;
      await browser.scripting.insertCSS({target:record.target, css:code, origin:"USER"}); record.css = code;
    }).catch(error => {
      if (record.alive) send(native, {kind:"capability-error", error:"Native document-scoped Shield stylesheet could not be applied"});
    });
  }
  function refresh() { for (const [port, record] of content) styles(port, record); }
  browser.runtime.onConnect.addListener(port => {
    if (port.name !== "cosmetics" || port.sender.id !== browser.runtime.id || !port.sender.tab) { port.disconnect(); return; }
    if (typeof port.sender.documentId !== "string") { send(native, {kind:"capability-error", error:"Shield requires a native document identity"}); port.disconnect(); return; }
    const record = {alive:true, epoch:0, queue:Promise.resolve(), css:"", target:{tabId:port.sender.tab.id, documentIds:[port.sender.documentId]}};
    content.set(port, record);
    port.onDisconnect.addListener(() => {
      record.alive = false; record.epoch++; content.delete(port);
      record.queue = record.queue.then(() => record.css ? browser.scripting.removeCSS({target:record.target, css:record.css, origin:"USER"}) : undefined).catch(() => {});
    });
    styles(port, record);
  });
  browser.webRequest.onBeforeRequest.addListener(details => {
    if (!policy || !matcher || details.tabId < 0) return {};
    const page = YabShield.topPage(details);
    if (!YabShield.enabled(policy, page, details.incognito === true)) return {};
    const cancel = matcher.cancel({url:details.url, page, type:details.type, thirdParty:details.thirdParty});
    return cancel ? {cancel:true} : {};
  }, {urls:["<all_urls>"]}, ["blocking"]);
  function connect() {
    const port = browser.runtime.connectNative("yab.shield"); native = port;
    port.onDisconnect.addListener(() => { if (native === port) { native = null; clear(); setTimeout(connect, 250); } });
    port.onMessage.addListener(message => {
      if (!message || typeof message !== "object" || typeof message.revision !== "string") return;
      if (message.command === "retire") { if (native === port) clear(); port.disconnect(); return; }
      if (native !== port) return;
      try {
        if (message.command === "popup") {
          if (!policy || !matcher || !browser.publicSuffix?.getDomain) throw Error("Popup policy is not ready");
          const thirdParty = YabShield.popupParty(message.url, message.page, browser.publicSuffix);
          const cancel = YabShield.enabled(policy, message.page, message.privately === true) &&
            matcher.cancel({url:message.url, page:message.page, type:"popup", thirdParty});
          send(port, {kind:"popup", request:message.request, owner:message.owner, allowed:!cancel, evaluated:true});
        } else if (message.command === "begin") staged = {revision:message.revision, expected:message.count, count:0, buckets:empty()};
        else if (message.command === "chunk") {
          if (!staged || staged.revision !== message.revision || !Array.isArray(message.rules) || message.rules.length > 500 || !Object.hasOwn(staged.buckets, message.bucket)) throw Error("Invalid staged rule batch");
          staged.count += message.rules.length; if (staged.count > 600000) throw Error("Rule limit exceeded");
          staged.buckets[message.bucket].push(...message.rules);
        } else if (message.command === "commit") {
          if (!staged || staged.revision !== message.revision || staged.count !== staged.expected || !message.policy) throw Error("Incomplete staged rules");
          if (!browser.scripting?.insertCSS || !browser.scripting?.removeCSS) throw Error("Shield requires native document-scoped user stylesheets");
          if (!browser.publicSuffix?.getDomain) throw Error("Shield popup rules require the native Public Suffix API");
          const next = YabShield.make(staged.buckets);
          matcher = next; policy = message.policy; revision = message.revision; staged = null; refresh();
          send(port, {kind:"configured", revision, popupSupported:true});
        } else if (message.command === "policy") {
          if (!matcher || !message.policy) throw Error("No committed rules");
          policy = message.policy; revision = message.revision; refresh(); send(port, {kind:"configured", revision, popupSupported:true});
        } else if (message.command === "shutdown") { clear(); port.disconnect(); }
      } catch (error) {
        if (message.command === "popup") send(port, {kind:"popup", request:message.request, owner:message.owner, allowed:false, evaluated:false});
        else { staged = null; send(port, {kind:"error", revision:message.revision, error:String(error)}); }
      }
    });
    send(port, {kind:"ready"});
  }
  connect();
})();
