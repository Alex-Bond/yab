"use strict";
/** Serialized as fixed APK code into one actual Gecko document, never a privileged page API. */
globalThis.YabStartOwnedImageFrame = function startOwnedImageFrame(token, target) {
  if (window !== top || typeof token !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(token) ||
      typeof target !== "string" || target.length > 16384) return false;
  const url = new URL(target);
  if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.hash) return false;
  const frames = [...document.querySelectorAll("iframe[data-yab-owned-image]")]
    .filter(frame => frame.getAttribute("data-yab-owned-image") === token);
  if (frames.length !== 1) return false;
  const frame = frames[0];
  if (!frame.isConnected || frame.ownerDocument !== document || frame.getAttribute("sandbox") !== "allow-downloads" ||
      frame.hasAttribute("src") || frame.hasAttribute("srcdoc") || frame.hasAttribute("data-yab-owned-started")) return false;
  frame.setAttribute("data-yab-owned-started", token);
  // The MAIN execution global supplies the page principal for this DOM navigation.
  // Its native tab/frame/document and source/profile lease are still checked before any stamp.
  frame.setAttribute("src", target);
  return true;
};
