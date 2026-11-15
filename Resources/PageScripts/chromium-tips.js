// A page's tooltips on a Chromium tab: CEF tells only an offscreen view of them.
// The nearest title="" over the pointer, or an SVG <title>, as the browser reads it.
(function () {
  const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.yabPageTip;
  if (!handler) return;
  let said = "";
  const read = (start) => {
    for (let node = start; node && node.nodeType === 1; node = node.parentElement) {
      if (node.namespaceURI === "http://www.w3.org/2000/svg") {
        const title = node.querySelector(":scope > title");
        if (title) return title.textContent;
      }
      const words = node.getAttribute("title");
      if (words !== null) return words;
    }
    return "";
  };
  const tell = (words) => {
    if (words === said) return;
    said = words;
    handler.postMessage({ words });
  };
  document.addEventListener("mouseover", (event) => tell(read(event.target)), true);
  document.addEventListener("mouseleave", () => tell(""), true);
  document.addEventListener("mousedown", () => tell(""), true);
})();
