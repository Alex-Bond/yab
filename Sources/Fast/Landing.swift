import WebKit

// A row on a new tab opens the thing itself, and the page comes up at the
// words the row is about: the question asked, the amount, the date. The
// agent that found it hands them over word for word (`quote` in `suggest`).
//
// Not a text fragment in the address: that stays in the bar, in history and
// in a copied link, and a page drawn by script (Gmail, Slack) has nothing to
// match when the fragment is read. yab looks for the words itself, in its
// own world, a few times while the page fills in: case, accents and white
// space set aside. Found, they are scrolled to the middle and marked for a
// moment with the system's highlight, drawn over the page without touching
// its nodes, then let go of. Not found, the page is just the page.

@MainActor
enum Landing {
    /// What the last landing in each tab came to, for the bench: the words,
    /// and whether they were found.
    static var last: [UUID: (quote: String, found: Bool)] = [:]

    static func land(_ tab: Tab, on quote: String, at url: URL) {
        let words = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        last[tab.id] = (words, false)
        // The row's own page: a person gone on to another page of the site
        // before the words came gets no mark there.
        loaded(tab, at: url) { look(tab, for: words, at: Hints.place(url.absoluteString), tries: 0) }
    }

    /// Once the tab has left the new tab for `url`'s site and loaded, or after
    /// eight seconds of waiting, whichever comes first; never if it went
    /// somewhere else.
    static func loaded(_ tab: Tab, at url: URL, then: @escaping () -> Void) {
        Task { @MainActor in
            for _ in 0..<32 {
                try? await Task.sleep(for: .seconds(0.25))
                guard let here = tab.address else { continue }
                guard here.host() == url.host() else { continue }
                if !tab.loading { break }
            }
            guard tab.address?.host() == url.host() else { return }
            then()
        }
    }

    /// A page drawn by script may not have the words yet: again, a little
    /// later, for about six seconds, as long as it is still the page the row
    /// opened. Once you have clicked or typed in it, the words are marked
    /// where they are, and the page isn't moved from under you.
    private static func look(_ tab: Tab, for words: String, at place: String?, tries: Int) {
        guard let web = tab.builtPage, tab.address.map({ Hints.place($0.absoluteString) }) == place else { return }
        let still = !AgentFeed.shared.touchedLately(tab)
        web.call(script, arguments: ["words": words, "mayScroll": still], in: .yab) { result in
            MainActor.assumeIsolated {
                let found = (try? result.get()) as? Bool ?? false
                if found {
                    last[tab.id] = (words, true)
                } else if tries < 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { look(tab, for: words, at: place, tries: tries + 1) }
                }
            }
        }
    }

    /// Folds the page's text the way the words are folded, keeping where
    /// each folded letter came from, finds them (or, for a long passage,
    /// its first fifty letters, or else its longest run of words there),
    /// and marks the range. The mark comes in at
    /// once, holds a second and a half and fades over about half a second.
    static let script = """
    const fold = s => s.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase();
    // White space set aside altogether: an agent reading the page as text
    // glues neighbors ("Northwind$240.00") or splits them where the page
    // doesn't, and either way it is the same words to a person.
    const want = fold(words).replace(/\\s+/g, '').replace(/[.,;:!?…]+$/, '');
    if (!want || !document.body) return false;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const el = node.parentElement;
        if (!el || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(el.tagName)) return NodeFilter.FILTER_REJECT;
        if (!node.data.trim()) return NodeFilter.FILTER_SKIP;
        const box = el.getClientRects();
        return box.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    let text = '';
    const from = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const raw = node.data;
      for (let i = 0; i < raw.length; i++) {
        for (const c of fold(raw[i])) {
          if (/\\s/.test(c)) continue;
          text += c;
          from.push([node, i]);
        }
      }
    }
    let at = text.indexOf(want);
    let length = want.length;
    if (at < 0 && want.length > 50) {
      const head = want.slice(0, 50);
      at = text.indexOf(head);
      length = head.length;
    }
    // Copied from a neighboring page, or put together from two places: the
    // longest run of its words that is here, two words and ten letters at
    // least, so it still means something.
    if (at < 0) {
      const list = fold(words).split(/\\s+/).filter(Boolean).slice(0, 40);
      search: for (let n = list.length - 1; n >= 2; n--) {
        for (let i = 0; i + n <= list.length; i++) {
          const run = list.slice(i, i + n).join('');
          if (run.length < 10) continue;
          const found = text.indexOf(run);
          if (found >= 0) { at = found; length = run.length; break search; }
        }
      }
    }
    if (at < 0) return false;
    const [startNode, startOffset] = from[at];
    const [endNode, endOffset] = from[at + length - 1];
    const range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, Math.min(endOffset + 1, endNode.data.length));
    // A page opened fresh stands at its top: anywhere else, someone has
    // scrolled it, and it is left where it is.
    const moved = scrollY > 24;
    const box = range.getBoundingClientRect();
    const target = startNode.parentElement;
    if (mayScroll && !moved && (box.top < 80 || box.bottom > innerHeight - 80)) target.scrollIntoView({ block: 'center', behavior: 'instant' });
    if (window.CSS && CSS.highlights && window.Highlight) {
      // A sheet made in script, not a <style>: a page whose policy allows
      // no inline styles (GitHub, most banks) would drop that, and the words
      // would be found and never shown.
      const sheet = new CSSStyleSheet();
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      const paint = a => sheet.replaceSync(`::highlight(yab-landing){background-color:rgba(255,204,0,${a})}`);
      paint(0.38);
      CSS.highlights.set('yab-landing', new Highlight(range));
      let a = 0.38;
      setTimeout(() => {
        const fade = setInterval(() => {
          a -= 0.038;
          if (a <= 0) {
            clearInterval(fade);
            CSS.highlights.delete('yab-landing');
            document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
            return;
          }
          paint(a.toFixed(3));
        }, 50);
      }, 1500);
    }
    return true;
    """
}
