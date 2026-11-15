import AppKit
import WebKit

/// The main document tells us which *link* is under the native pointer.
/// No message handler, timers, network, or mousemove bridge on every site.
enum LinkCardRules {
    static let dwell: TimeInterval = 0.43
    static let highlight: TimeInterval = 0.13
    static let linger: TimeInterval = 0.08
    static let width: CGFloat = 296
    static let lifetime: TimeInterval = 86_400

    nonisolated static func web(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
            && url.user == nil && url.password == nil
    }

    /// Only the chosen Peek modifier brings a card, on every site.
    nonisolated static func eligible(flags: NSEvent.ModifierFlags, selection: Bool, peekClick: PeekClick = .shift) -> Bool {
        !selection && LinkStatus.clicking(flags) == peekClick.flags
    }

    /// Screen coordinates, not the browser window's bounds. A card may
    /// hang below the browser, and flips only when it meets the screen.
    nonisolated static func place(link: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let width = min(size.width, max(1, screen.width - 16))
        let height = min(size.height, max(1, screen.height - 16))
        let x = min(max(link.minX - 5, screen.minX + 8), screen.maxX - width - 8)
        var y = link.minY - 7 - height
        if y < screen.minY + 8 { y = link.maxY + 7 }
        y = min(max(y, screen.minY + 8), screen.maxY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static let script = #"""
    (() => {
      let caretAt = 0, painted = null;
      // Match Peek's hit test: elementFromPoint on the document stops at a
      // shadow host, and closest() cannot walk out of a shadow root.
      const anchorAt = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        for (; el; el = el.parentNode instanceof ShadowRoot ? el.parentNode.host : el.parentNode) {
          if (el instanceof Element && el.matches('a[href]')) return el;
        }
        return null;
      };
      addEventListener("pointerdown", () => { caretAt = Date.now(); }, true);
      window.__yabLinkCardInfo = (x, y, width, pretend) => {
        const unit = innerWidth / width;
        let a = anchorAt(x * unit, y * unit);
        const host = (pretend || location.hostname).replace(/^www\./, "").toLowerCase();
        // DDG's address is another anchor in the same result: Arc hangs
        // its card from the title instead of from that line of the address.
        if (a && host === "duckduckgo.com") a = a.closest('article, .result')?.querySelector('[data-testid="result-title-a"], a.result__a') || a;
        if (!a || !/^https?:$/.test(a.protocol)) return null;
        const b = a.getBoundingClientRect(), s = getSelection();
        const editing = document.activeElement?.matches('input, textarea, [contenteditable="true"]');
        const selected = editing || (s && (s.type === "Range" || (s.type === "Caret" && s.anchorNode?.nodeType === 3 && !a.contains(s.anchorNode) && Date.now() - caretAt < 60000)));
        return { url: a.href, box: [b.left, b.top, b.width, b.height], unit,
                 selection: !!selected };
      };
      // Coordinates are kept in CSS pixels so the anchor is looked up
      // afresh after layout, not by a generated selector sent to the page.
      window.__yabLinkCardLightAt = (x,y,on) => {
        if (painted) { painted.remove(); painted = null; }
        if (!on) return;
        const a = anchorAt(x,y);
        if (a) {
          const b=a.getBoundingClientRect(), overlay=document.createElement("div");
          overlay.setAttribute("aria-hidden","true");
          Object.assign(overlay.style,{position:"fixed",left:(b.left-2)+"px",top:(b.top-1)+"px",
            width:(b.width+4)+"px",height:(b.height+2)+"px",borderRadius:"4px",pointerEvents:"none",
            background:"rgba(110,110,150,.16)",zIndex:"2147483646"});
          document.documentElement.append(overlay); painted=overlay;
          if (!matchMedia("(prefers-reduced-motion: reduce)").matches) overlay.animate([{opacity:0},{opacity:1}],{duration:100});
        }
      };
    })();
    """#
}
