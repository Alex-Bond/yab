"use strict";
(() => {
  const G = globalThis.YabOwnedImage;
  const documents = new Map(), attempts = new Map();
  const bounded = promise => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error("bridge_timeout")), 1800))]);
  const native = message => bounded(browser.runtime.sendNativeMessage(G.native, {v: 1, ...message}));
  const send = (port, message) => { try { port.postMessage({v: 1, ...message}); } catch (_) {} };
  function remove(value, reason, notify = true) {
    if (attempts.get(value.token) !== value) return;
    attempts.delete(value.token); clearTimeout(value.timer);
    if (notify) { send(value.source.port, {command: "failed", token: value.token, reason: G.failure(reason)});
      void native({kind: "failed", token: value.token, reason}).catch(() => {}); }
  }
  async function sourceCurrent(source) {
    if (documents.get(source.sender.documentId) !== source || !source.bridge) return false;
    const top = await bounded(browser.webNavigation.getFrame({tabId: source.sender.tab.id, frameId: 0, documentId: source.sender.documentId}));
    return documents.get(source.sender.documentId) === source && top?.documentId === source.sender.documentId && top.frameId === 0 && top.parentFrameId === -1;
  }
  function live(value) { return attempts.get(value.token) === value && documents.get(value.source.sender.documentId) === value.source && Date.now() <= value.deadline; }
  function nativeFields(value) {
    const sender = value.source.sender;
    return {token: value.token, bridge: value.source.bridge, document: sender.documentId, tab: sender.tab.id, frame: value.frame,
      cookieStore: sender.tab.cookieStoreId, privately: sender.tab.incognito};
  }
  function belongs(value, request) { return value.source.sender.tab.id === request.tabId && value.frame === request.frameId; }
  function requestFields(request) { return {id: request.requestId, url: request.url, method: request.method, type: request.type,
    tab: request.tabId, frame: request.frameId, parentFrame: request.parentFrameId, parentDocument: request.parentDocumentId,
    cookieStore: request.cookieStoreId, privately: request.incognito}; }
  function lineageFailure(value, request) {
    const sender = value.source.sender;
    if (request.method !== "GET") return "request_method";
    if (request.type !== "sub_frame") return "request_type";
    if (G.url(request.url) !== value.target) return "request_url";
    if (!belongs(value, request)) return "request_frame";
    if (request.parentFrameId !== 0) return "request_parent_frame";
    if (request.parentDocumentId !== sender.documentId) return "request_parent_document";
    const expectedStore = G.requestCookieStore(sender.tab);
    if (!expectedStore || request.cookieStoreId !== expectedStore) return "request_cookie_store";
    if (request.incognito !== sender.tab.incognito) return "request_privacy";
    return null;
  }
  const lineage = (value, request) => lineageFailure(value, request) === null;
  browser.runtime.onConnect.addListener(port => {
    if (port.name !== G.port || !G.sender(port.sender)) { port.disconnect(); return; }
    const source = {port, sender: port.sender, bridge: null};
    port.onMessage.addListener(message => {
      if (message?.v !== 1 || !G.sender(port.sender) || message.document !== source.sender.documentId || !G.token(message.bridge)) return;
      if (message.kind === "hello") {
        if (source.bridge) return;
        const old = documents.get(source.sender.documentId);
        if (old && old !== source) old.port.disconnect();
        source.bridge = message.bridge; documents.set(source.sender.documentId, source); return;
      }
      if (documents.get(source.sender.documentId) !== source || source.bridge !== message.bridge || !G.token(message.token)) return;
      if (message.kind === "start") {
        const value = attempts.get(message.token);
        if (!value || value.source !== source || value.started) return;
        value.started = true;
        void (async () => {
          if (!live(value) || !await sourceCurrent(source)) throw new Error("source_changed");
          const results = await bounded(browser.scripting.executeScript({
            target: {tabId: source.sender.tab.id, documentIds: [source.sender.documentId]},
            world: "MAIN", func: globalThis.YabStartOwnedImageFrame, args: [value.token, value.target],
          }));
          if (!live(value) || !await sourceCurrent(source) || !Array.isArray(results) || results.length !== 1 ||
              results[0].frameId !== 0 || results[0].result !== true || results[0].error) throw new Error("source_changed");
        })().catch(() => remove(value, "page_start_refused"));
        return;
      }
      if (message.kind === "cancel") {
        const value = attempts.get(message.token); if (value?.source === source) remove(value, "cancelled", false); return;
      }
      if (message.kind === "delivered") {
        const value = attempts.get(message.token);
        if (value?.source === source && value.stamped) { clearTimeout(value.timer); value.deadline = Infinity; }
        return;
      }
      if (message.kind !== "prepare" || attempts.has(message.token) || !Number.isSafeInteger(message.frame) || message.frame <= 0 || !G.url(message.target)) return;
      let preparePhase = "prepare_source_before";
      void (async () => {
        if (!await sourceCurrent(source)) throw new Error("source_changed");
        preparePhase = "prepare_child";
        const child = await bounded(browser.webNavigation.getFrame({tabId: source.sender.tab.id, frameId: message.frame}));
        if (child?.parentFrameId !== 0 || child.parentDocumentId !== source.sender.documentId) throw new Error("frame_changed");
        preparePhase = "prepare_source_after_child";
        if (!await sourceCurrent(source)) throw new Error("source_changed");
        const value = {token: message.token, source, frame: message.frame, target: G.url(message.target), request: null, stamped: false, started: false,
          deadline: Date.now() + 30000, timer: null};
        preparePhase = "prepare_bind";
        const answer = await native({kind: "bind", ...nativeFields(value)});
        preparePhase = "prepare_bind_reply";
        if (answer?.ok !== true) throw new Error("native_refused");
        preparePhase = "prepare_source_after_bind";
        if (!await sourceCurrent(source)) throw new Error("source_changed");
        preparePhase = "prepare_duplicate";
        if (attempts.has(value.token)) throw new Error("native_refused");
        value.timer = setTimeout(() => remove(value, "request_timeout"), 30000);
        attempts.set(value.token, value); send(port, {command: "go", token: value.token});
      })().catch(() => { send(port, {command: "failed", token: message.token, reason: preparePhase}); void native({kind: "failed", token: message.token, reason: preparePhase}).catch(() => {}); });
    });
    port.onDisconnect.addListener(() => {
      if (documents.get(source.sender.documentId) === source) documents.delete(source.sender.documentId);
      for (const value of attempts.values()) if (value.source === source) remove(value, "bridge_closed");
    });
  });
  // USER_SCRIPT is an untrusted API world even if a future host accidentally shares our ID.
  browser.runtime.onUserScriptConnect?.addListener(port => port.disconnect());
  browser.runtime.onUserScriptMessage?.addListener(() => undefined);
  browser.webRequest.onBeforeRequest.addListener(async request => {
    const value = [...attempts.values()].find(candidate => belongs(candidate, request));
    if (!value) return {};
    let phase = "request_live";
    try {
      if (!live(value) || !value.started) throw new Error("request_refused");
      phase = "request_duplicate";
      if (value.request) throw new Error("request_refused");
      const invalid = lineageFailure(value, request);
      if (invalid) { phase = invalid; throw new Error("request_refused"); }
      phase = "request_source_before";
      if (!await sourceCurrent(value.source)) throw new Error("request_refused");
      phase = "request_native_claim";
      const answer = await native({kind: "claim", ...nativeFields(value), request: requestFields(request)});
      phase = "request_native_reply";
      if (!answer?.ok) throw new Error("native_refused");
      phase = "request_live_after";
      if (!live(value)) throw new Error("native_refused");
      phase = "request_source_after";
      if (!await sourceCurrent(value.source)) throw new Error("native_refused");
      value.request = request.requestId; return {};
    } catch (_) { remove(value, phase); return {cancel: true}; }
  }, {urls: ["http://*/*", "https://*/*"], types: ["sub_frame"]}, ["blocking"]);
  browser.webRequest.onHeadersReceived.addListener(async request => {
    const value = [...attempts.values()].find(candidate => belongs(candidate, request));
    if (!value) return {};
    try {
      const headers = request.responseHeaders;
      const contentType = headers?.find(header => header.name.toLowerCase() === "content-type")?.value;
      if (!live(value) || value.stamped || value.request !== request.requestId || !lineage(value, request) || request.statusCode !== 200 ||
          !G.image(contentType) || !await sourceCurrent(value.source)) throw new Error("unsupported_response");
      const answer = await native({kind: "stamp", ...nativeFields(value), id: request.requestId, url: request.url,
        status: request.statusCode, mime: contentType});
      if (!answer?.ok || !G.token(answer.stamp) || !live(value) || !await sourceCurrent(value.source)) throw new Error("native_refused");
      value.stamped = true;
      return {responseHeaders: [...headers.filter(header => !["content-disposition", G.stamp].includes(header.name.toLowerCase())),
        {name: "Content-Disposition", value: "attachment"}, {name: G.stamp, value: answer.stamp}]};
    } catch (_) { remove(value, "unsupported_response"); return {cancel: true}; }
  }, {urls: ["http://*/*", "https://*/*"], types: ["sub_frame"]}, ["blocking", "responseHeaders"]);
  browser.webRequest.onBeforeRedirect.addListener(request => {
    const value = [...attempts.values()].find(candidate => belongs(candidate, request));
    if (value) remove(value, "redirect_unsupported");
  }, {urls: ["http://*/*", "https://*/*"], types: ["sub_frame"]});
  browser.webRequest.onErrorOccurred.addListener(request => {
    const value = [...attempts.values()].find(candidate => belongs(candidate, request));
    if (value) remove(value, "request_failed");
  }, {urls: ["http://*/*", "https://*/*"], types: ["sub_frame"]});
})();
