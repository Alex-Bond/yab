import Foundation
import NaturalLanguage
import WebKit

/// Translate page, its rules and its scripts; PageTranslation does the work.
/// A page is offered when its language is none of the person's: its words
/// decide when there are enough of them and the recognizer is sure, else what
/// the page says of itself (`lang`). The page is translated where it is, its
/// text nodes replaced in Yab's own script world, never its markup, so the
/// layout, links and the page's own scripts stay as they were and Show
/// Original puts every word back.
enum PageTranslate {
    static let world = WKContentWorld.world(name: "yab.phone.translate")

    // MARK: - which language

    /// A language as the decisions compare it: its base code ("pt" for
    /// pt-BR), Chinese with its script, since the two are read apart; nil
    /// for nothing, "und" and the like.
    static func code(_ identifier: String?) -> String? {
        guard let raw = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let id = raw.replacingOccurrences(of: "_", with: "-")
        let language = Locale.Language(identifier: id)
        guard let base = language.languageCode?.identifier.lowercased(), (2...3).contains(base.count),
              base.allSatisfy(\.isLetter), !["und", "mul", "zxx", "mis"].contains(base) else { return nil }
        guard base == "zh" else { return base }
        let script = language.script?.identifier
            ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier ?? "Hans"
        return "zh-" + script
    }

    /// Fewer letters than this and the words say nothing about their language.
    static let fewestLetters = 40
    /// Letters and certainty for the words to overrule what the page says
    /// (a template's lang="en" over a page written in Portuguese).
    static let overruleLetters = 200
    static let overruleCertainty = 0.8

    /// The page's language, from what it says (`declared`) and what its words
    /// are (`hypotheses`, the recognizer's, over `letters` letters).
    static func source(declared: String?, hypotheses: [String: Double], letters: Int) -> String? {
        let said = code(declared)
        let best = hypotheses.max { $0.value < $1.value }
        let heard: String? = best.flatMap { letters >= fewestLetters && $0.value >= 0.6 ? code($0.key) : nil }
        if let heard, let said, heard != said, let best {
            return letters >= overruleLetters && best.value >= overruleCertainty ? heard : said
        }
        return said ?? heard
    }

    /// What the recognizer makes of a sample of the page's words.
    static func recognize(_ sample: String) -> (hypotheses: [String: Double], letters: Int) {
        let letters = sample.unicodeScalars.reduce(0) { $0 + (CharacterSet.letters.contains($1) ? 1 : 0) }
        guard letters > 0 else { return ([:], 0) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let found = recognizer.languageHypotheses(withMaximum: 3)
        return (Dictionary(found.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: max), letters)
    }

    /// The language a page is translated into: the first of the person's.
    static func target(preferred: [String]) -> String? { preferred.lazy.compactMap(code).first }

    /// Offered when the page's language is none of the person's languages.
    static func offers(source: String?, preferred: [String]) -> Bool {
        guard let source else { return false }
        let mine = Set(preferred.compactMap(code))
        return !mine.isEmpty && !mine.contains(source)
    }

    /// A language's name in the app's words ("Portuguese").
    static func name(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    // MARK: - batches

    /// One text node as the page script found it: its number, its words and
    /// how far it is from the screen (0 on it), so what is read now goes first.
    struct Piece: Equatable, Sendable {
        let id: Int
        let text: String
        let distance: Double
    }

    /// Texts sent together, each once, with the nodes each goes back into.
    struct Batch: Equatable, Sendable {
        var texts: [String] = []
        var nodes: [[Int]] = []
        var letters: Int { texts.reduce(0) { $0 + $1.utf16.count } }
    }

    /// A batch at most this many texts and letters; the first smaller, so
    /// the screen's words come back soonest.
    static let batchTexts = 24
    static let batchLetters = 1600
    static let firstBatchLetters = 600

    /// The page's pieces in batches: what is on screen first, then below it,
    /// then above; the same words once however often the page has them (a
    /// "Reply" under every comment); a text longer than a batch alone.
    static func batches(_ pieces: [Piece], texts maxTexts: Int = batchTexts, letters maxLetters: Int = batchLetters,
                        firstLetters: Int = firstBatchLetters) -> [Batch] {
        // Stable: the page's order among pieces as far from the screen.
        let ordered = pieces.indices.sorted { a, b in
            pieces[a].distance != pieces[b].distance ? pieces[a].distance < pieces[b].distance : a < b
        }.map { pieces[$0] }
        var unique: [String] = []
        var nodes: [String: [Int]] = [:]
        for piece in ordered {
            let words = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            if nodes[words] == nil { unique.append(words) }
            nodes[words, default: []].append(piece.id)
        }
        var out: [Batch] = []
        var batch = Batch()
        var letters = 0
        for words in unique {
            let limit = out.isEmpty ? min(firstLetters, maxLetters) : maxLetters
            let count = words.utf16.count
            if !batch.texts.isEmpty, batch.texts.count >= maxTexts || letters + count > limit {
                out.append(batch)
                batch = Batch()
                letters = 0
            }
            batch.texts.append(words)
            batch.nodes.append(nodes[words] ?? [])
            letters += count
        }
        if !batch.texts.isEmpty { out.append(batch) }
        return out
    }

    // MARK: - the page's side

    /// What the page says of itself and a sample of its words; nothing changes.
    static let probe = setup + "return window.__yabTranslate.probe();"
    /// The text nodes not translated yet, numbered.
    static let collect = setup + "if(window.__yabTranslate.documentID!==expectedDocument)return null; return window.__yabTranslate.collect(target);"
    /// Translations into their nodes: `nodes[i]` take `texts[i]`.
    static let apply = setup + "if(window.__yabTranslate.documentID!==expectedDocument)return -1; return window.__yabTranslate.apply(nodes, texts);"
    /// Every node back to its own words.
    static let restore = setup + "if(window.__yabTranslate.documentID!==expectedDocument)return -1; return window.__yabTranslate.restore();"
    /// The page added words since (a feed, a reply): true once, then false.
    static let changed = setup + "if(window.__yabTranslate.documentID!==expectedDocument)return false; return window.__yabTranslate.changed();"

    private static let setup = #"""
    (function () {
      if (window.__yabTranslate) return;
      // Words in these are code, input or drawing, never prose to translate.
      var SKIP = new Set('SCRIPT STYLE NOSCRIPT TEXTAREA INPUT SELECT OPTION CODE PRE KBD SAMP VAR SVG MATH CANVAS IFRAME OBJECT EMBED TEMPLATE HEAD TITLE'.split(' '));
      var LETTER = /\p{L}/u;
      var LIMIT = 20000;
      var nodes = [], own = [], mine = [], ids = new WeakMap();
      var observer = null, dirty = false, writing = false, lang = null, on = false;

      function accept(node) {
        if (node.nodeType === 1) {
          if (SKIP.has(node.tagName)) return NodeFilter.FILTER_REJECT;
          if (node.getAttribute('translate') === 'no' || (node.classList && node.classList.contains('notranslate'))) return NodeFilter.FILTER_REJECT;
          if (node.isContentEditable) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_SKIP;
        }
        // A lone letter is an initial on a tile, not words.
        var words = node.nodeValue.trim();
        return words.length > 1 && LETTER.test(words) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
      function walk(root, each) {
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode: accept });
        for (var n = walker.nextNode(); n; n = walker.nextNode()) { if (each(n) === false) return; }
      }
      // On screen 0; below it, how far; above it, after what is below.
      function distance(node) {
        var el = node.parentElement;
        if (!el) return 1e9;
        var r = el.getBoundingClientRect(), h = window.innerHeight || 800;
        if (r.width === 0 && r.height === 0) return 1e9;
        if (r.bottom < 0) return h - r.bottom;
        if (r.top > h) return r.top - h;
        return 0;
      }
      function declared() {
        var said = document.documentElement.getAttribute('lang');
        if (!said) {
          var meta = document.querySelector('meta[http-equiv="content-language" i]');
          said = meta ? meta.getAttribute('content') : null;
        }
        return said || null;
      }
      function probe() {
        var root = document.querySelector('main, article, [role="main"]') || document.body;
        var sample = '';
        if (root) walk(root, function (n) { sample += n.nodeValue.trim() + ' '; return sample.length < 1600; });
        return { lang: declared(), sample: sample, documentID: api.documentID, translated: on };
      }
      function watch() {
        if (observer || !document.body) return;
        observer = new MutationObserver(function () { if (!writing) dirty = true; });
        observer.observe(document.body, { childList: true, subtree: true, characterData: true });
      }
      function collect(target) {
        if (!document.body) return [];
        if (!on) { lang = declared(); on = true; }
        if (target) document.documentElement.setAttribute('lang', target);
        watch();
        dirty = false;
        var out = [];
        walk(document.body, function (n) {
          var id = ids.get(n);
          if (id === undefined) {
            if (nodes.length >= LIMIT) return false;
            id = nodes.length; ids.set(n, id); nodes.push(n); own.push(n.nodeValue); mine.push(null);
          } else if (mine[id] !== null && n.nodeValue !== mine[id]) {
            // The page wrote new words over a translation: these are its own now.
            own[id] = n.nodeValue; mine[id] = null;
          } else if (mine[id] !== null) {
            return;
          }
          out.push([id, own[id], distance(n)]);
        });
        return out;
      }
      function apply(groups, texts) {
        var count = 0;
        writing = true;
        for (var g = 0; g < groups.length; g++) {
          for (var k = 0; k < groups[g].length; k++) {
            var id = groups[g][k], n = nodes[id];
            if (!n || !n.isConnected) continue;
            if (n.nodeValue !== own[id] && n.nodeValue !== mine[id]) continue;
            var words = own[id], lead = words.match(/^\s*/)[0], trail = words.match(/\s*$/)[0];
            mine[id] = lead + texts[g] + trail;
            n.nodeValue = mine[id];
            count++;
          }
        }
        observer && observer.takeRecords();
        writing = false;
        return count;
      }
      function restore() {
        var count = 0;
        writing = true;
        for (var id = 0; id < nodes.length; id++) {
          if (mine[id] === null) continue;
          if (nodes[id].nodeValue === mine[id]) { nodes[id].nodeValue = own[id]; count++; }
          mine[id] = null;
        }
        if (observer) { observer.disconnect(); observer = null; }
        writing = false;
        if (on) {
          if (lang === null) document.documentElement.removeAttribute('lang');
          else document.documentElement.setAttribute('lang', lang);
        }
        on = false; dirty = false;
        return count;
      }
      function changed() { var was = dirty; dirty = false; return was; }
      var api = { probe: probe, collect: collect, apply: apply, restore: restore, changed: changed,
                  documentID: String(Date.now()) + ':' + String(Math.random()) };
      window.__yabTranslate = api;
    })();
    """#
}
