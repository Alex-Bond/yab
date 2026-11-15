import Foundation

// A live stream, for Yab's own video windows: the floating one (Float.swift)
// and the island (Tune.swift, PlayerBand.swift).
//
// A live stream's media element doesn't say how far it goes the way a
// video does. Safari's own HLS says its length is endless, and some MSE
// players give 1e300; YouTube's manifestless live gives a length about an
// hour past the live edge, and its seekable range runs there too (measured
// 2026-10-03: 3526 s ahead on every stream, in a bare WKWebView as well).
// Taken as a video's length, that put the bar at 54 to 93%, a countdown of
// "−0:58:46", and a click near the end an hour into the future.
//
// So a live stream is told apart, and where it can go is read from what is
// true for it: YouTube's own bar (the class `ytp-live` on its player, and
// the range its slider says it spans), or the seekable range where that is
// the stream's (an endless length), or, failing both, the furthest the
// video has been fetched, which the edge only ever moves on from. The bar
// then runs from the oldest moment the stream keeps to the edge, the right
// end is "live", and the words say Live, or how far behind it you are.
//
// Those words are the way back too: "5m behind" is a button to the edge,
// and Live, there already, is not. A stream that keeps under half a minute
// (a radio, a short HLS window) has nothing to go back into: no bar, no
// steps of 15, only Live. One that stops being live, its broadcast over and
// kept as a recording, has a length again and counts down like any video.

enum LiveEdge {
    /// Closer to the edge than this, in seconds, is live: a stream plays a
    /// few segments behind its newest one on purpose, Safari's HLS three of
    /// them (up to 30 s with 10 s segments).
    static let near: Double = 40

    /// A stretch shorter than this, in seconds, is no stretch to go back
    /// into: a radio's few segments, a short HLS window.
    static let shortest: Double = 30

    /// Where a live stream stands, in the media element's seconds.
    struct Window: Equatable {
        /// The oldest moment it keeps, or nil where nobody says: then it
        /// can only be shown, not gone through.
        var start: Double?
        /// The newest.
        var edge: Double
        /// Where it plays.
        var time: Double

        /// How far it plays behind the edge, never less than nothing.
        var behind: Double { max(0, edge - time) }

        /// There is a stretch to go back into: a bar to draw and seek in.
        var spans: Bool { start.map { edge - $0 >= LiveEdge.shortest } ?? false }

        /// Playing at the edge, near enough: Live.
        var atEdge: Bool { behind < LiveEdge.near }

        /// Behind, with a way back: the words take you to the edge, and
        /// 15 seconds on is somewhere to go. At the edge there is nowhere.
        var goesLive: Bool { spans && !atEdge }

        /// How far along the bar, nought to one: the right end is live.
        var through: Double {
            guard let start, spans else { return 1 }
            if behind < LiveEdge.near { return 1 }
            return min(1, max(0, (time - start) / (edge - start)))
        }

        /// A point along the bar, nought to one, as the place to go: the
        /// edge itself, 1, from a little short of it on, so a click at the
        /// end of the bar goes live rather than a few seconds behind.
        func snapped(_ fraction: Double) -> Double {
            let value = min(1, max(0, fraction))
            guard let start, spans else { return 1 }
            return (1 - value) * (edge - start) < LiveEdge.near ? 1 : value
        }

        /// How far behind the edge a point along the bar is, in seconds.
        func behind(at fraction: Double) -> Double {
            guard let start, spans else { return 0 }
            let value = snapped(fraction)
            return value >= 1 ? 0 : (1 - value) * (edge - start)
        }

        /// The words where a video's length would be: Live, or how far
        /// behind; only Live where there is nothing to go back into, as
        /// a radio's falling behind while paused is no place to be.
        func words(waiting: Bool = false, wasLive: Bool = false) -> String {
            spans ? LiveEdge.words(behind: behind, waiting: waiting, wasLive: wasLive) : "Live"
        }

        /// The words over the pointer while the bar is dragged: how far
        /// behind that point is, Live near the edge.
        func tip(at fraction: Double) -> String {
            LiveEdge.words(behind: behind(at: fraction))
        }
    }

    /// "Live", "45s behind", "2m behind", "1h 5m behind".
    static func words(behind seconds: Double) -> String {
        guard seconds.isFinite, seconds >= near else { return "Live" }
        // Rounded, as 44.99 s read is 45 s meant.
        if seconds.rounded() < 60 { return "\(Int(seconds.rounded()))s behind" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m behind" }
        return minutes % 60 == 0 ? "\(minutes / 60)h behind" : "\(minutes / 60)h \(minutes % 60)m behind"
    }

    /// The widest words take as many points as these, for room kept beside
    /// the bar so it doesn't move as the minutes change.
    static let widest = "00m behind"

    /// The words for where a stream plays while it is being fetched: at
    /// the edge a stall is the network's, not a step back, so it stays
    /// Live for as long as it was Live when the wait began.
    static func words(behind seconds: Double, waiting: Bool, wasLive: Bool) -> String {
        waiting && wasLive ? "Live" : words(behind: seconds)
    }

    /// The line under the title while something besides the stream itself
    /// goes on: an advert inside it, "muted" only if it was, or the stream
    /// catching up at its edge. Nil for the stream as it is.
    static func subtitle(ad: Bool, muted: Bool, waiting: Bool, atEdge: Bool) -> String? {
        if ad { return muted ? "Ad \u{00B7} muted" : "Ad" }
        if waiting, atEdge { return "Catching up\u{2026}" }
        return nil
    }

    /// A function of the page's, `(video) -> true` while an advert plays
    /// in the video's player: YouTube's says so in its class.
    static let advert = """
    function (v) {
      var player = v.closest ? v.closest('.html5-video-player') : null;
      return !!(player && player.classList.contains('ad-showing'));
    }
    """

    /// A function of the page's, `(video) -> [start, edge]` or null for a
    /// video that isn't live, the start -1 where nobody says. It keeps what
    /// it has seen of each video in `window.__yabEdges`, in the world it
    /// runs in, never on the page.
    static let reader = """
    function (v) {
      function last(r) { try { return r && r.length ? r.end(r.length - 1) : NaN; } catch (e) { return NaN; } }
      function first(r) { try { return r && r.length ? r.start(0) : NaN; } catch (e) { return NaN; } }
      function number(el, name) { var n = el ? parseFloat(el.getAttribute(name)) : NaN; return isFinite(n) ? n : NaN; }
      var kept = window.__yabEdges || (window.__yabEdges = new WeakMap());
      var now = Date.now(), t = v.currentTime || 0, d = v.duration, source = v.currentSrc || '';
      var was = kept.get(v);
      if (!was || was.source !== source) {
        was = { source: source, at: now, edge: NaN, mark: null, grew: 0 };
        kept.set(v, was);
      }
      var reach = last(v.seekable);
      var player = v.closest ? v.closest('.html5-video-player') : null;
      var bar = player ? player.querySelector('.ytp-progress-bar') : null;
      var low = number(bar, 'aria-valuemin'), high = number(bar, 'aria-valuemax'), at = number(bar, 'aria-valuenow');
      // YouTube's: its player, or its clock, says live; or its slider
      // spans a stretch nowhere near the video's own length, as a stream's
      // does, the length being the edge and an hour (measured: 43 185 s
      // on the slider, 50 390 s long). Not while an ad shows, whose
      // slider can be the film's.
      var youtube = !!(player && (player.classList.contains('ytp-live') || player.querySelector('.ytp-live, .ytp-live-badge-is-livehead') ||
        (!player.classList.contains('ad-showing') && high > low && at >= low && d > 0 && Math.abs(high - low - d) > 60)));
      var endless = d > 0 && (!isFinite(d) || d >= 1e7);
      // A length the page keeps giving as a video's while the place it can
      // go grows with the clock, twice running: a live stream all the same.
      // Playing on while that place hasn't moved for half a minute, its
      // broadcast is over: a recording now, with a length of its own.
      if (!youtube && !endless && isFinite(reach)) {
        if (!was.mark) was.mark = [now, reach];
        var gone = (now - was.mark[0]) / 1000;
        if (gone >= 4) {
          var grown = reach - was.mark[1];
          if (grown > gone / 2 && grown < gone * 2) { was.grew += 1; was.grewAt = now; }
          else if (was.grew < 2) was.grew = 0;
          was.mark = [now, reach];
        }
        if (was.grew >= 2 && !v.paused && now - was.grewAt > 30000) was.grew = 0;
      }
      if (!youtube && !endless && was.grew < 2) return null;
      var start = NaN, edge = NaN;
      if (youtube) {
        // YouTube's slider spans the stretch the stream keeps, its value
        // where it plays in it: the edge where the two meet.
        if (high > low && at >= low && at <= high + 1) {
          start = t - (at - low);
          // Just after a seek the slider still says where the video was,
          // and the edge read from it would be hours off, past the end
          // YouTube gives (measured: a click to live landed an hour into
          // the future). Where the stretch starts only creeps on, a
          // second a second at most: a jump is a slider behind, and the
          // start seen before holds until it catches up, or for ten
          // seconds, after which the jump is the stream's own.
          var creep = 30 + (now - was.at) / 1000;
          if (isFinite(was.start) && (v.seeking || Math.abs(start - was.start) > creep)) {
            if (!was.odd) was.odd = now;
            if (now - was.odd < 10000) start = was.start;
          } else {
            was.odd = 0;
          }
          if (!v.seeking) was.start = start;
          edge = start + (high - low);
          // Kept from before the video's own first moment: from it on.
          start = Math.max(0, start);
        }
      } else if (isFinite(reach) && reach < 1e7) {
        start = first(v.seekable);
        edge = reach;
      }
      if (!isFinite(edge)) {
        // Nobody says: the furthest fetched, or where it was last seen
        // and the time since, the edge moving on a second a second.
        var since = isFinite(was.edge) ? was.edge + (now - was.at) / 1000 : 0;
        edge = Math.max(since, last(v.buffered) || 0);
      }
      // Paused, the broadcast goes on even where the page stops fetching
      // it and its range stands still: a second further a second.
      if (v.paused && isFinite(was.edge)) edge = Math.max(edge, was.edge + (now - was.at) / 1000);
      edge = Math.max(edge, t);
      was.edge = edge;
      was.at = now;
      if (!(start >= 0 && start <= t + 1 && edge - start > 1)) start = -1;
      return [start, edge];
    }
    """
}
