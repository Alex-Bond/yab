import WebKit

// Video and audio played on pages, for Yab Wrapped: how much of it, and how
// much a faster speed took off. The page counts in Yab's own world, in
// every frame (a player is as often someone else's frame), and says it once
// a minute of play is in, or as the page goes. Only the numbers come over:
// no address, no title. Muted play (a looping background, an ad left
// running) and private windows count nothing.

final class WatchRelay: NSObject, PageScriptReceiving {
    static let name = "yabWatched"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any],
              let content = body["content"] as? Double, content > 0, content < 3_600 else { return }
        let fast = body["fast"] as? Double ?? 0, fastReal = body["fastReal"] as? Double ?? 0
        MainActor.assumeIsolated {
            guard let tab, !tab.shy else { return }
            Self.count(content: content, fast: fast, fastReal: fastReal)
        }
    }

    /// Seconds of media played, and of them those played faster than 1×
    /// with the real seconds they took.
    static func count(content: Double, fast: Double, fastReal: Double, ledger: WrappedLedger = .shared) {
        ledger.add(.videoMinutes, content / 60)
        guard fast > fastReal, fastReal >= 0 else { return }
        ledger.add(.videoFastMinutes, fast / 60)
        ledger.add(.videoSavedMinutes, (fast - fastReal) / 60)
    }

    static let script = """
    (function () {
      var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!h || window.__yabWatched) return;
      window.__yabWatched = true;
      var last = new WeakMap(), sum = { content: 0, fast: 0, fastReal: 0 };
      function media(e) { var v = e.target; return v && (v.tagName === 'VIDEO' || v.tagName === 'AUDIO') ? v : null; }
      function send() {
        if (sum.content < 1) return;
        try { h.postMessage(sum); } catch (e) {}
        sum = { content: 0, fast: 0, fastReal: 0 };
      }
      document.addEventListener('timeupdate', function (e) {
        var v = media(e);
        if (!v) return;
        var t = v.currentTime, was = last.get(v);
        last.set(v, t);
        if (was === undefined || v.paused || v.seeking || v.muted || v.volume === 0) return;
        var d = t - was;
        if (!(d > 0 && d < 5)) return;
        var rate = v.playbackRate || 1;
        sum.content += d;
        if (rate > 1.01) { sum.fast += d; sum.fastReal += d / rate; }
        if (sum.content >= 60) send();
      }, true);
      ['seeked', 'play', 'ratechange', 'loadedmetadata'].forEach(function (k) {
        document.addEventListener(k, function (e) { var v = media(e); if (v) last.set(v, v.currentTime); }, true);
      });
      window.addEventListener('pagehide', send, true);
      document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'hidden') send(); }, true);
    })();
    """
}
