import AppKit

/// Look Up on a Chromium page (#1871). AppKit sends `quickLook(with:)` both
/// for a Force Click and for the trackpad's three-finger tap. Its default
/// asks NSTextInputClient for the character under the pointer, which
/// ChromiumPage never knows (`characterIndex(for:)` is NSNotFound), so on
/// both gestures nothing showed. The page itself says the word under the
/// point instead, as WebKit's own view answers it.
enum ChromiumLookUp {
    /// The word around `offset` in `text`: letters, digits, apostrophes and
    /// hyphens, as a dictionary word is. Pure, so it is tested on its own.
    static let wordAt = """
    function (t, i) {
      const w = /[\\p{L}\\p{N}'\\u2019-]/u; let s = i, e = i;
      while (s > 0 && w.test(t[s - 1])) s--;
      while (e < t.length && w.test(t[e])) e++;
      const word = t.slice(s, e).replace(/^['\\u2019-]+|['\\u2019-]+$/g, "");
      return word ? word : null;
    }
    """

    /// The page's word under `point`, in the view's top-left points; `width`
    /// is the view's width, for the page's own CSS pixels. A link is the
    /// peek's (LinkPeek.forcePeek), a field its own: neither answers.
    static func script(at point: CGPoint, width: CGFloat) -> String {
        """
        (() => { const u = innerWidth / \(Double(width)), x = \(Double(point.x)) * u, y = \(Double(point.y)) * u;
          const el = document.elementFromPoint(x, y);
          if (!el || el.closest("a[href], area[href], input, textarea, select, [contenteditable]")) return null;
          const r = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y), n = r && r.startContainer;
          if (!n || n.nodeType !== 3) return null;
          return (\(wordAt))(n.data, r.startOffset); })()
        """
    }

    /// The card as the context menu's Look Up shows it.
    static func definition(_ word: String) -> NSAttributedString {
        NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
    }
}

extension ChromiumPage {
    /// `at` in this view's own (bottom-left) points.
    func lookUp(at: NSPoint) {
        let js = ChromiumLookUp.script(at: CGPoint(x: at.x, y: bounds.height - at.y), width: bounds.width)
        run(js, in: .yab, gesture: false) { [weak self] result in
            guard let self, case .success(let value) = result, let word = value as? String, !word.isEmpty else { return }
            showDefinition(for: ChromiumLookUp.definition(word), at: at)
        }
    }
}
