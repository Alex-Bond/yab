"use strict";
globalThis.YabOwnedImage = Object.freeze({
  id: "yab-owned-image@browser.local",
  native: "yab_owned_image",
  port: "yab-owned-image-document-v1",
  stamp: "x-yab-owned-image",
  token: value => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value),
  randomToken() {
    // getRandomValues also works in an HTTP document; randomUUID is secure-context-only.
    const bytes = crypto.getRandomValues(new Uint8Array(16)); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const value = [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
    return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
  },
  url(value) {
    if (typeof value !== "string" || !value || value.length > 16384) return null;
    try { const url = new URL(value); if (!/^https?:$/.test(url.protocol) || url.username || url.password) return null;
      url.hash = ""; return url.href; } catch (_) { return null; }
  },
  sender(sender) {
    return !!sender && sender.id === this.id && !Object.hasOwn(sender, "userScriptWorldId") &&
      sender.frameId === 0 && this.token(sender.documentId) && Number.isSafeInteger(sender.tab?.id) && sender.tab.id >= 0 &&
      typeof sender.tab.incognito === "boolean" && typeof sender.tab.cookieStoreId === "string" &&
      sender.tab.cookieStoreId.length > 0 && sender.tab.cookieStoreId.length <= 256 && !!this.url(sender.url);
  },
  image(value) { return typeof value === "string" && /^image\/[a-z0-9!#$&^_.+-]+$/i.test(value.split(";", 1)[0].trim()); },
  // Pinned GeckoViewTab.userContextId is unsafeSessionContextId, while webRequest
  // reports originAttributes.userContextId (not geckoViewSessionContextId).
  // Native bind independently checks this tab label against the actual session context.
  requestCookieStore(tab) {
    if (!tab || typeof tab.incognito !== "boolean" || typeof tab.cookieStoreId !== "string" || tab.cookieStoreId.length > 256) return null;
    if (tab.incognito) return tab.cookieStoreId === "firefox-private" ? "firefox-private" : null;
    return tab.cookieStoreId.startsWith("firefox-container-") && tab.cookieStoreId.length > "firefox-container-".length ? "firefox-default" : null;
  },
  // An unrelated DOM mutation may arrive while the document-scoped MAIN call is pending.
  // Security-edge checks after go still require the actual target, never a missing src.
  frameSource(value, edge = false) {
    const raw = value.frame.getAttribute("src");
    if (raw === null) return !value.navigated && !(edge && value.started);
    if (this.url(raw) !== value.target) return false;
    value.navigated = true;
    return true;
  },
  failure(value) {
    return ["prepare_source_before", "prepare_child", "prepare_source_after_child", "prepare_bind", "prepare_bind_reply",
      "prepare_source_after_bind", "prepare_duplicate", "page_start_refused", "request_refused", "unsupported_response", "redirect_unsupported",
      "request_live", "request_duplicate", "request_method", "request_type", "request_url", "request_frame",
      "request_parent_frame", "request_parent_document", "request_cookie_store", "request_privacy", "request_source_before",
      "request_native_claim", "request_native_reply", "request_live_after", "request_source_after",
      "request_failed", "source_changed", "request_timeout", "bridge_closed"].includes(value) ? value : "request_refused";
  },
});
