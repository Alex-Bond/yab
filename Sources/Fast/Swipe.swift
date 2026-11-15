import AppKit
import Foundation
import WebKit

// Two fingers sideways means back, or forward.
//
// WebKit has a swipe of its own, and it drags the whole page across the window
// with a picture of the last one behind it. This is the other kind: a disc
// comes in from the edge you are pulling from, and past a certain point it is
// armed, a pill that names the page. Let go then, and the page simply goes
// back, one page, however far or fast the fingers went. Let go before, and
// it slips out again. Hold the fingers still a moment with the pill out and
// it grows into a list of the pages behind it, one more for every stretch of
// travel from there, the older pages of a site gathered into one row, then
// the tab this one was opened from, and last the history to search. Nothing
// slides, nothing is kept in memory to slide.
//
// The one hard question is whether a sideways swipe belongs to the page, a
// carousel, a wide table, a map, or is free to mean something. The page is
// asked, on every sideways wheel event, whether anything under the pointer
// could scroll that way. The answer arrives a frame or two after the gesture
// starts, which is before there is anything to show.

enum Swipe {
    enum Axis { case across, down }

    /// Precise deltas alone do not make a gesture: smooth mice can have no phases.
    static func isGesture(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && event.hasPreciseScrollingDeltas
            && (event.phase != [] || event.momentumPhase != [])
    }

    static func isNavigationGesture(_ event: NSEvent, enabled: Bool) -> Bool {
        enabled && isGesture(event) && event.phase != [] && event.momentumPhase == []
    }

    /// A few points of travel show whether the gesture is clearly sideways.
    static func axis(x: CGFloat, y: CGFloat) -> Axis? {
        guard x + y > 6 else { return nil }
        return x > y * 1.3 ? .across : .down
    }

    // Pages bounce at their edges, as Mac users expect (row
    // 1095). Until 0.41 a user style sheet set `overscroll-behavior-y: none`
    // on every page's root to stop it; a page that sets its own
    // `overscroll-behavior` still has it its way.

    /// Measuring only: YAB_SWIPE_LISTEN=early tells the page of every
    /// gesture at its start, as before, for an A/B (evals/page-scroll-lag).
    static let listensEarly = ProcessInfo.processInfo.environment["YAB_SWIPE_LISTEN"] == "early"

    /// Observe page ownership without cancelling any page events. Replies are
    /// scoped to a native gesture; a final reply drains pending wheel handlers.
    ///
    /// A page that moves a scroller from its wheel handler says so twice:
    /// at once, in the scroller's own scrollLeft, and a frame later, in
    /// the scroll event, which WebKit sends only when it next draws. The
    /// answer waits for neither the clock nor luck: every scroller the page
    /// ever scrolled is read again when the answer goes, and the answer
    /// goes after the 32 ms the wheel handlers have to run and then the
    /// page's next frame, whose scroll events come before it. A busy Mac
    /// that drew late made a page moving a sheet sideways look free, and
    /// the swipe went back in history over it.
    static let watch = """
    (function () {
      if (window.__yabSwipe) return;
      var gesture = null, owned = false, seen = false, pending = [], timer = null;
      var frame = null, closing = false, path = [];
      // Where each scroller was across, and every scroller that ever
      // scrolled, read only at a sideways wheel: held weakly, so a view
      // the page drops goes with everything under it.
      var positions = new WeakMap(), noted = new WeakSet(), known = [], keep = 16;
      function reset(id) {
        clearTimeout(timer);
        if (frame !== null) cancelAnimationFrame(frame);
        gesture = id; owned = false; seen = false; pending = []; timer = null;
        frame = null; closing = false; path = [];
      }
      // A scroller moved across since it was last read claims the gesture.
      function check(el) {
        var now = position(el);
        if (positions.has(el) && positions.get(el) !== now) owned = true;
        positions.set(el, now);
      }
      function checkAll() {
        known.forEach(function(ref) { var el = ref.deref(); if (el) check(el); });
        path.forEach(check);
      }
      function report(final) {
        pending.forEach(function(e) { owned = owned || e.defaultPrevented; });
        pending = [];
        if (seen) checkAll();
        path = [];
        window.webkit.messageHandlers.yabScroll.postMessage({
          side: owned || !seen ? 'taken' : 'free', gesture: gesture, finished: final
        });
      }
      // The wheel handlers have had their time: answer once the page has
      // drawn, so a scroller they moved has sent its scroll event. A page
      // out of sight draws no frames; its scrollers were read above.
      function settle(final) {
        timer = null;
        closing = closing || final;
        if (document.visibilityState !== 'visible') return flush();
        if (frame === null) frame = requestAnimationFrame(function() { frame = null; flush(); });
      }
      function flush() {
        var final = closing;
        closing = false;
        report(final);
      }
      document.addEventListener('visibilitychange', function() {
        if (frame === null || document.visibilityState === 'visible') return;
        cancelAnimationFrame(frame);
        frame = null;
        flush();
      });
      // The wheel is listened to only while fingers go sideways on the
      // trackpad (PageView says begin once a gesture shows its way):
      // a page with a wheel listener has WebKit keep every layer's event
      // region and work it out again on each paint, so a key typed into a
      // heavy page (Teams) took some 3 ms longer to show, every key
      // (feedback #175, evals/teams-lag). The gesture's begin comes before
      // its first wheel; the listeners go once the wheel has been quiet
      // for a while and no answer is owed. A frame's answer is never
      // asked for (only the main frame's counts), so frames never listen.
      var listening = false, quiet = null;
      function listen(on) {
        if (on === listening) return;
        listening = on;
        var change = on ? window.addEventListener : window.removeEventListener;
        change.call(window, 'wheel', wheel, { passive: true, capture: true });
        change.call(window, 'mousewheel', wheel, { passive: true, capture: true });
      }
      function hush() {
        clearTimeout(quiet);
        quiet = setTimeout(function() {
          quiet = null;
          if (timer !== null || frame !== null || pending.length) return hush();
          listen(false);
        }, 2000);
      }
      window.__yabSwipe = {
        begin: function(id) {
          reset(id);
          if (window.top !== window) return;
          listen(true);
          hush();
        },
        finish: function(id) {
          if (id !== gesture) return;
          clearTimeout(timer);
          timer = setTimeout(function() { settle(true); }, 32);
        }
      };
      function blocked(style) {
        return style.overscrollBehaviorX === 'none' || style.overscrollBehaviorX === 'contain';
      }
      function canMove(el, dx, style, root) {
        var max = el.scrollWidth - (root ? window.innerWidth : el.clientWidth);
        var left = root ? window.scrollX : el.scrollLeft;
        if (max <= 1) return false;
        // WebKit uses negative scrollLeft for RTL containers.
        var min = style.direction === 'rtl' ? -max : 0;
        var end = style.direction === 'rtl' ? 0 : max;
        return dx > 0 ? left < end - 1 : left > min + 1;
      }
      function taken(e, dx) {
        var html = document.documentElement, rootStyle = getComputedStyle(html);
        // Anti-bounce CSS on a vertical page is not horizontal scrolling.
        if (blocked(rootStyle) && html.scrollWidth > window.innerWidth + 1) return true;
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          if (!el || el.nodeType !== 1) continue;
          var style = getComputedStyle(el), ox = style.overflowX;
          // Canvas grids can be driven by a separate scrollbar, without
          // either native overflow or preventDefault.
          if (el.tagName === 'CANVAS' || el.getAttribute('role') === 'grid' ||
              el.getAttribute('role') === 'treegrid') return true;
          if (el === html || el === document.body) continue;
          var container = ox === 'auto' || ox === 'scroll';
          if (container && blocked(style) && el.scrollWidth > el.clientWidth + 1) return true;
          // Clipped article wrappers cannot consume a native sideways
          // wheel. Custom scrollers still claim it by preventing the wheel
          // or actually moving scrollLeft, observed below.
          if ((ox === 'auto' || ox === 'scroll') && canMove(el, dx, style, false)) return true;
        }
        var bodyStyle = document.body ? getComputedStyle(document.body) : null;
        var overflow = rootStyle.overflowX === 'visible' && bodyStyle ? bodyStyle.overflowX : rootStyle.overflowX;
        return overflow !== 'hidden' && overflow !== 'clip' && canMove(html, dx, rootStyle, true);
      }
      function scroller(target) {
        return target === document ? document.scrollingElement : target;
      }
      function position(el) {
        var max = Math.max(0, el.scrollWidth - el.clientWidth);
        if (max <= 1) return 0;
        var rtl = getComputedStyle(el).direction === 'rtl';
        // WebKit exposes elastic offsets outside the scrollable range.
        // A bounce at an edge is not page-owned horizontal movement.
        return Math.min(rtl ? 0 : max, Math.max(rtl ? -max : 0, el.scrollLeft));
      }
      function remember(target) {
        var el = scroller(target);
        if (el && el.nodeType === 1) positions.set(el, position(el));
      }
      function note(el) {
        if (noted.has(el)) return;
        noted.add(el);
        // The ones already collected and since dropped let go of.
        if (known.length >= keep) {
          known = known.filter(function(ref) { return ref.deref(); });
          keep = Math.max(16, known.length * 2);
        }
        known.push(new WeakRef(el));
      }
      function wheel(e) {
        var dx = e.type === 'mousewheel' ? -e.wheelDeltaX : e.deltaX;
        var dy = e.type === 'mousewheel' ? -e.wheelDeltaY : e.deltaY;
        hush();
        if (!dx || Math.abs(dx) <= Math.abs(dy || 0)) return;
        // The gesture's first sideways wheel takes where every scroller
        // stands, for the answer to read again.
        if (!seen) known.forEach(function(ref) { var el = ref.deref(); if (el) remember(el); });
        var root = scroller(document);
        if (root && path.indexOf(root) < 0) { remember(root); path.push(root); }
        e.composedPath().forEach(function(el) {
          if (!el || el.nodeType !== 1 || path.indexOf(el) >= 0) return;
          remember(el);
          path.push(el);
        });
        seen = true;
        owned = owned || taken(e, dx);
        pending.push(e);
        // Coalesce modern and legacy handlers, plus scroll events from a
        // sibling scrollbar. No DOM-wide search in the wheel hot path.
        if (timer === null) timer = setTimeout(function() { settle(false); }, 32);
      }
      document.addEventListener('scroll', function(e) {
        var el = scroller(e.target);
        if (!el || el.nodeType !== 1) return;
        // Reading a position lays the page out, and this ran on every
        // scroll event of every page, a feed adding pins as it scrolls
        // among them. With no sideways wheel to answer, the scroller is
        // only noted, and read when one comes.
        note(el);
        if (!pending.length) return;
        var before = positions.has(el) ? positions.get(el) : 0;
        // A sideways gesture can still move a timeline vertically. Only a
        // change in scrollLeft claims it, including a sibling scrollbar.
        if (position(el) !== before) owned = true;
        remember(el);
      }, { passive: true, capture: true });
    })();
    """
}

/// A row of the list a swipe pulled deep shows: a page of the tab's
/// history, several pages of one site in a row, the tab this one was opened
/// from, or the history to search.
struct Stop: Equatable {
    enum Kind: Equatable {
        /// One page.
        case page
        /// Pages of one site one after the other, `count` of them, gone to
        /// at the newest of them, the one you left the site from.
        case run
        /// The tab this one was opened from, past the start of its history.
        case from
        /// The history, to search: letting go opens its panel.
        case search
    }

    var title: String
    var host: String
    var kind: Kind = .page
    var count = 1
    /// For a page or a run, which page of the history that way, nearest
    /// first, letting go takes you to.
    var index = 0
}

/// Where a sideways swipe has got to, for the pill that shows it.
struct Pull: Equatable {
    /// Pulling from the left edge, to go back; otherwise from the right.
    var back: Bool
    /// How far the fingers have come, in points, before any damping.
    var travel: CGFloat
    /// Which row letting go now would take, counted from one: none short of
    /// `Swipe.arm`, the first there, and one more every step past it
    /// (`Swipe.steps`).
    var steps = 0
    /// The rows that way, nearest first (`Swipe.rows`).
    var stops: [Stop] = []
    /// There is nowhere to go that way: shown faintly, never armed.
    var blocked = false
    /// The list is out: the fingers held still with the pill armed
    /// (`Swipe.hold`).
    var listed = false
    /// Let go while armed: the page is on its way, and the pill leaves.
    var going = false
    /// Armed on the way through: the fingers are going quick, so the pill
    /// waits as the disc, and grows (or the list out of the disc) once they
    /// slow. Letting go still takes the first page.
    var passing = false
    /// The fingers are going quick: whatever is given back goes at once,
    /// with no morph to sit through.
    var quick = false

    /// Far enough that letting go will do something.
    var armed: Bool { steps > 0 }
    /// The row letting go now would take.
    var stop: Stop? { steps > 0 && steps <= stops.count ? stops[steps - 1] : nil }
}

extension Swipe {
    /// How far the fingers travel before letting go means one page.
    static let arm: CGFloat = 110
    /// And how much further for each of the first few rows after it.
    static let step: CGFloat = 80
    /// Past those, each row comes quicker, so a long history is still in
    /// reach of one pull.
    static let deepStep: CGFloat = 50
    /// Pages shown one by one before the pages of a site are gathered.
    static let named = 4
    /// Rows of gathered pages at most, the rest being the panel's.
    static let deepest = 12
    /// How far the fingers go up or down, while the list is out, for one
    /// row: more than a row is tall, since a trackpad's scroll is quick.
    static let rowPitch: CGFloat = 44

    /// How long the fingers rest with the pill armed for the list of pages
    /// behind to come out. Only a hold brings it: a quick swipe, a long one
    /// or a slow one let go of goes back one page (feedback #346). As long
    /// as macOS's own press and hold, so it never comes by the way.
    static let hold: CFTimeInterval = 0.5
    /// Points the fingers may drift sideways and still be holding.
    static let holdSlop: CGFloat = 8

    /// Fingers going at least this fast (points a second) are on their way:
    /// nothing new grows under them (`Pull.quick`).
    static let passSpeed: CGFloat = 500
    /// Nothing heard from the fingers for this long, they are at rest.
    static let quickRest: CFTimeInterval = 0.06

    /// Where the rows are counted from once a hold has the list out, the
    /// pill's page still the one lit in it: the next is a stretch further.
    static let open: CGFloat = arm + step

    /// The row a pull of `travel` points takes, with `rows` rows that way:
    /// the first from `arm`, still the first when the list comes out at
    /// `open`, then one more every `step`, and past the first few every
    /// `deepStep`.
    static func steps(travel: CGFloat, rows: Int) -> Int {
        guard rows > 0, travel >= arm else { return 0 }
        guard travel >= open else { return 1 }
        let beyond = travel - open
        let slow = CGFloat(named - 1) * step
        let n = beyond < slow ? 1 + Int(beyond / step) : named + Int((beyond - slow) / deepStep)
        return min(n, rows)
    }

    /// The rows for the pages that way, nearest first, as (title, host): the
    /// first few one by one, the rest a row for each run of one site; then
    /// the tab this one was opened from, when there is one and it is still
    /// open, and last the history to search, when there are two pages or more.
    static func rows(_ pages: [(title: String, host: String)], from: String?) -> [Stop] {
        var rows: [Stop] = []
        var index = 0
        // The same page several times in a row, a sign-in a site sent you
        // to again and again, is one page: gone to at the nearest of them.
        func same(_ a: Int, _ b: Int) -> Bool { pages[a].title == pages[b].title && pages[a].host == pages[b].host }
        while index < pages.count, rows.count < named {
            var end = index + 1
            while end < pages.count, same(index, end) { end += 1 }
            rows.append(Stop(title: pages[index].title, host: pages[index].host, index: index))
            index = end
        }
        while index < pages.count, rows.count < named + deepest {
            let host = pages[index].host
            var end = index + 1
            while end < pages.count, !host.isEmpty, pages[end].host == host { end += 1 }
            let count = end - index
            rows.append(Stop(title: pages[index].title, host: host, kind: count > 1 ? .run : .page, count: count, index: index))
            index = end
        }
        // Only with something to look through: one page behind, or none,
        // or the same page again and again, is no history to search.
        let enough = rows.count >= 2
        if let from { rows.append(Stop(title: from, host: "", kind: .from)) }
        if enough { rows.append(Stop(title: "Search History", host: "", kind: .search)) }
        return rows
    }
}
