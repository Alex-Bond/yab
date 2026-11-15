import Foundation
import JavaScriptCore
import QuartzCore
import Testing
@testable import Fast

// A live stream in Yab's own video windows (LiveEdge.swift): the time math,
// the page's reader of a stream's stretch, the floating window's seek over
// it, and YouTube's ad code keeping its hands off a stream. The numbers are
// the ones measured on 2026-10-03 (docs/evidence/launch-repro-2026-10-03):
// on YouTube a live video's length and seekable end run 3526 s past its
// edge.
@MainActor struct LiveEdgeTests {
    // MARK: the math

    @Test func words() {
        #expect(LiveEdge.words(behind: 0) == "Live")
        #expect(LiveEdge.words(behind: 25) == "Live")
        #expect(LiveEdge.words(behind: LiveEdge.near) == "40s behind")
        #expect(LiveEdge.words(behind: 45) == "45s behind")
        #expect(LiveEdge.words(behind: 44.99) == "45s behind")
        #expect(LiveEdge.words(behind: 59.4) == "59s behind")
        #expect(LiveEdge.words(behind: 59.6) == "1m behind")
        #expect(LiveEdge.words(behind: 120) == "2m behind")
        #expect(LiveEdge.words(behind: 300) == "5m behind")
        #expect(LiveEdge.words(behind: 3600) == "1h behind")
        #expect(LiveEdge.words(behind: 3900) == "1h 5m behind")
        #expect(LiveEdge.words(behind: 4320) == "1h 12m behind")
        #expect(LiveEdge.words(behind: .infinity) == "Live")
        #expect(LiveEdge.words(behind: .nan) == "Live")
    }

    @Test func atTheEdgeIsAllTheWay() {
        let window = LiveEdge.Window(start: 43_000, edge: 46_870, time: 46_864)
        #expect(window.behind == 6)
        #expect(window.spans)
        #expect(window.through == 1)
    }

    @Test func behindIsAlongTheStretch() {
        // Two hours kept, five minutes back.
        let window = LiveEdge.Window(start: 1000, edge: 8200, time: 7900)
        #expect(window.behind == 300)
        #expect(abs(window.through - 6900.0 / 7200.0) < 1e-9)
        #expect(LiveEdge.words(behind: window.behind) == "5m behind")
    }

    @Test func aTimePastTheEdgeIsLive() {
        let window = LiveEdge.Window(start: 0, edge: 100, time: 130)
        #expect(window.behind == 0)
        #expect(window.through == 1)
    }

    @Test func noStartMeansNoBar() {
        let window = LiveEdge.Window(start: nil, edge: 50_390, time: 46_864)
        #expect(!window.spans)
        #expect(window.through == 1)
        #expect(window.snapped(0.2) == 1)
        #expect(window.behind(at: 0.2) == 0)
        // A stretch of under a second is none either.
        #expect(!LiveEdge.Window(start: 10, edge: 10.5, time: 10).spans)
    }

    // MARK: variant A, the words

    @Test func theWordsAreTheWayBack() {
        // Five minutes back: the words go to the edge, and so does +15.
        let behind = LiveEdge.Window(start: 0, edge: 3600, time: 3300)
        #expect(LiveEdge.words(behind: behind.behind) == "5m behind")
        #expect(behind.goesLive)
        // At the edge: Live, not a button, and nowhere to step on to.
        let edge = LiveEdge.Window(start: 0, edge: 3600, time: 3590)
        #expect(edge.atEdge)
        #expect(LiveEdge.words(behind: edge.behind) == "Live")
        #expect(!edge.goesLive)
        // Behind a stream that says nothing of its start: no way back.
        #expect(!LiveEdge.Window(start: nil, edge: 3600, time: 3000).goesLive)
    }

    @Test func dragTipSaysWhereItLands() {
        let window = LiveEdge.Window(start: 0, edge: 3600, time: 3600)
        #expect(window.tip(at: 0.5) == "30m behind")
        #expect(window.tip(at: 1 - 1920.0 / 3600) == "32m behind")
        #expect(window.tip(at: 0) == "1h behind")
        // Within 40 s of the edge: Live, and that is where it goes.
        #expect(window.tip(at: 0.995) == "Live")
        #expect(window.snapped(0.995) == 1)
        // The tip doesn't move the words: they are the window's own.
        #expect(LiveEdge.words(behind: window.behind) == "Live")
    }

    @Test func pausedFallsBehindAndForwardWakes() {
        // Paused at the edge: the edge goes on, the time doesn't.
        var window = LiveEdge.Window(start: 0, edge: 3600, time: 3600)
        #expect(!window.goesLive)
        window.edge += 45
        #expect(LiveEdge.words(behind: window.behind) == "45s behind")
        #expect(window.goesLive)
        window.edge += 255
        #expect(LiveEdge.words(behind: window.behind) == "5m behind")
    }

    @Test func noRewindMeansOnlyLive() {
        // A radio, a short HLS window: under half a minute kept.
        let radio = LiveEdge.Window(start: 100, edge: 124, time: 118)
        #expect(!radio.spans)
        #expect(!radio.goesLive)
        #expect(radio.through == 1)
        #expect(LiveEdge.words(behind: radio.behind) == "Live")
        #expect(LiveEdge.Window(start: 100, edge: 130, time: 128).spans)
        // Paused a while, a radio is still only Live: nowhere to go back.
        #expect(LiveEdge.Window(start: nil, edge: 1000, time: 900).words() == "Live")
        #expect(radio.words() == "Live")
        #expect(LiveEdge.Window(start: 0, edge: 3600, time: 3300).words() == "5m behind")
        var tune = Tune(title: "Night Radio", duration: 0, elapsed: 0, stamp: 100, playing: false)
        tune.live = true
        tune.behind = 300
        #expect(tune.words(at: 100) == "Live")
        tune.span = 7200
        #expect(tune.words(at: 100) == "5m behind")
    }

    @Test func subtitleSaysWhatElseGoesOn() {
        #expect(LiveEdge.subtitle(ad: true, muted: true, waiting: false, atEdge: true) == "Ad \u{00B7} muted")
        #expect(LiveEdge.subtitle(ad: true, muted: false, waiting: false, atEdge: true) == "Ad")
        #expect(LiveEdge.subtitle(ad: false, muted: false, waiting: true, atEdge: true) == "Catching up\u{2026}")
        // Waiting behind is a wait, not catching up with the edge.
        #expect(LiveEdge.subtitle(ad: false, muted: false, waiting: true, atEdge: false) == nil)
        #expect(LiveEdge.subtitle(ad: false, muted: true, waiting: false, atEdge: true) == nil)
    }

    @Test func bufferingAtTheEdgeStaysLive() {
        // Twenty seconds stalled on the network at the edge: still Live.
        #expect(LiveEdge.words(behind: 65, waiting: true, wasLive: true) == "Live")
        // Moving again, really behind: it says so.
        #expect(LiveEdge.words(behind: 65, waiting: false, wasLive: true) == "1m behind")
        // A wait that began behind is behind.
        #expect(LiveEdge.words(behind: 300, waiting: true, wasLive: false) == "5m behind")
    }

    @Test func theEndOfTheBarGoesLive() {
        let window = LiveEdge.Window(start: 0, edge: 3600, time: 1800)
        // 1% of an hour is 36 s from the edge: inside `near`, so live.
        #expect(window.snapped(0.99) == 1)
        #expect(window.behind(at: 0.99) == 0)
        #expect(window.snapped(1.4) == 1)
        // Half way: half an hour behind.
        #expect(window.snapped(0.5) == 0.5)
        #expect(window.behind(at: 0.5) == 1800)
        #expect(LiveEdge.words(behind: window.behind(at: 0.5)) == "30m behind")
        #expect(window.snapped(-1) == 0)
        #expect(window.behind(at: 0) == 3600)
    }

    // MARK: the floating window's reading

    @Test func playheadFromALiveAnswer() throws {
        // YouTube at the edge: the length the page gave is gone, and the
        // bar is the stretch it keeps.
        let found: [Any] = [0, true, 46_864.2, 0, 1, 1280, 720, true, false, true, 43_264.2, 46_864.2]
        let head = try #require(Floater.Playhead(found))
        #expect(head.length == 0)
        let live = try #require(head.live)
        #expect(live.start == 43_264.2)
        #expect(live.edge == 46_864.2)
        #expect(head.through == 1)

        let unsaid: [Any] = [0, true, 46_864.2, 0, 1, 1280, 720, true, false, true, -1, 46_870]
        let shown = try #require(Floater.Playhead(unsaid)?.live)
        #expect(shown.start == nil)
        #expect(!shown.spans)
    }

    @Test func playheadSaysAdAndWaiting() throws {
        let ad: [Any] = [0, true, 3, 0, 1, 1280, 720, true, true, true, 43_264.2, 46_864.2, true]
        let head = try #require(Floater.Playhead(ad))
        #expect(head.ad)
        #expect(head.muted)
        #expect(!head.waiting)
        // Meant to play, not moving: fetching.
        let stalled: [Any] = [0, true, 46_864.2, 0, 1, 1280, 720, false, false, true, 43_264.2, 46_870, false]
        let waiting = try #require(Floater.Playhead(stalled))
        #expect(waiting.waiting)
        #expect(!waiting.ad)
        // Paused is not waiting.
        let paused: [Any] = [0, false, 46_864.2, 0, 1, 1280, 720, false, false, true, 43_264.2, 46_870, false]
        #expect(try #require(Floater.Playhead(paused)).waiting == false)
    }

    @Test func broadcastOverIsARecording() throws {
        // The same stream, over: the page reads it as a video with a
        // length, and the floating window counts down from it.
        let ended: [Any] = [0.7, true, 3528, 5040, 1, 1280, 720, true, false, false, -1, 0, false]
        let head = try #require(Floater.Playhead(ended))
        #expect(head.live == nil)
        #expect(head.length == 5040)
        #expect(head.through == 0.7)
    }

    @Test func playheadForAVideoIsNotLive() throws {
        let old: [Any] = [0.5, true, 60, 120, 1, 1280, 720, true]
        #expect(try #require(Floater.Playhead(old)).live == nil)
        let video: [Any] = [0.5, true, 60, 120, 1, 1280, 720, true, false, false, -1, 0]
        let head = try #require(Floater.Playhead(video))
        #expect(head.live == nil)
        #expect(head.length == 120)
        #expect(head.through == 0.5)
    }

    // MARK: the island's

    @Test func islandLiveTune() {
        var tune = Tune(title: "Sky News", duration: 0, elapsed: 4208, stamp: 100, playing: true)
        tune.live = true
        tune.behind = 300
        tune.span = 7200
        #expect(tune.lag(at: 160) == 300)
        #expect(abs(tune.through(at: 160) - (1 - 300.0 / 7200.0)) < 1e-9)
        // Paused a minute: a minute further behind.
        tune.playing = false
        #expect(tune.lag(at: 160) == 360)
        #expect(LiveEdge.words(behind: tune.lag(at: 160)) == "6m behind")
        // At the edge, or with no stretch known, the whole line.
        tune.playing = true
        tune.behind = 5
        #expect(tune.through(at: 160) == 1)
        tune.behind = 300
        tune.span = 0
        #expect(tune.through(at: 160) == 1)
    }

    @Test func islandLiveStates() {
        var tune = Tune(title: "Sky News", artist: "Sky", duration: 0, elapsed: 4208, stamp: 100, playing: true)
        tune.live = true
        tune.span = 7200
        tune.behind = 300
        #expect(tune.goesLive(at: 100))
        #expect(tune.subtitle == "Sky")
        tune.behind = 5
        #expect(!tune.goesLive(at: 100))
        // Paused at the edge: a minute on, a minute behind, a way back.
        tune.playing = false
        #expect(LiveEdge.words(behind: tune.lag(at: 160)) == "1m behind")
        #expect(tune.goesLive(at: 160))
        tune.playing = true
        // An advert inside it, quieted.
        tune.ad = true
        tune.quiet = true
        #expect(tune.subtitle == "Ad \u{00B7} muted")
        tune.ad = false
        // Fetching at the edge: Live, and catching up.
        tune.catching = true
        tune.behind = 90
        #expect(tune.subtitle == "Catching up\u{2026}")
        #expect(LiveEdge.words(behind: tune.lag(at: 100)) == "Live")
        #expect(!tune.goesLive(at: 100))
        tune.catching = false
        // Keeping nothing to go back into: no line, no way back, Live.
        tune.span = 20
        tune.behind = 0
        #expect(!tune.rewinds)
        #expect(tune.through(at: 100) == 1)
        #expect(!tune.goesLive(at: 100))
        // A video's subtitle is its artist, whatever it says of ads.
        var video = Tune(title: "A film", artist: "Someone", duration: 200, elapsed: 50, stamp: 100, playing: true)
        video.ad = true
        #expect(video.subtitle == "Someone")
        #expect(!video.goesLive(at: 100))
    }

    @Test func islandVideoTuneUnchanged() {
        let tune = Tune(title: "A film", duration: 200, elapsed: 50, stamp: 100, playing: true)
        #expect(tune.lag(at: 110) == 0)
        #expect(abs(tune.through(at: 110) - 60.0 / 200.0) < 1e-9)
    }

    @Test func reachFromThePage() {
        #expect(TuneWatch.reach(nil) == nil)
        #expect(TuneWatch.reach(NSNull()) == nil)
        let both = TuneWatch.reach([NSNumber(value: 10.0), NSNumber(value: 100.0)])
        #expect(both?.start == 10)
        #expect(both?.edge == 100)
        #expect(TuneWatch.reach([NSNumber(value: -1), NSNumber(value: 100.0)])?.start == nil)
    }

    // MARK: the page's reader

    /// A media element as the reader sees it: TimeRanges of its own, a
    /// player around it with classes and a slider.
    static let page = """
    var window = { addEventListener: function () {} };
    function ranges(list) {
      return { length: list.length, start: function (i) { return list[i][0]; }, end: function (i) { return list[i][1]; } };
    }
    function player(classes, slider) {
      return {
        classList: { contains: function (c) { return classes.indexOf(c) >= 0; } },
        querySelector: function (s) {
          if (s !== '.ytp-progress-bar' || !slider) return null;
          return { getAttribute: function (n) { return slider[n] === undefined ? null : String(slider[n]); } };
        }
      };
    }
    function video(o) {
      var p = o.player || null;
      return {
        tagName: 'VIDEO', currentSrc: o.src || 'blob:a', currentTime: o.time, duration: o.duration,
        paused: !!o.paused, playbackRate: 1, readyState: 4, seeking: false, videoWidth: 1280, videoHeight: 720,
        muted: false, volume: 1,
        seekable: ranges(o.seekable || []), buffered: ranges(o.buffered || []),
        closest: function (s) { return s === '.html5-video-player' ? p : null; }
      };
    }
    """

    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(LiveEdgeTests.page)
        context.evaluateScript("var read = \(LiveEdge.reader);")
        #expect(context.exception == nil)
        return context
    }

    private func pair(_ context: JSContext, _ js: String) -> [Double]? {
        let value = context.evaluateScript(js)
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        return (value.toArray() as? [NSNumber])?.map(\.doubleValue)
    }

    @Test func aVideoIsNotLive() throws {
        let context = try context()
        #expect(pair(context, "read(video({ time: 60, duration: 600, seekable: [[0, 600]] }))") == nil)
        // A length not known yet is no stream either.
        #expect(pair(context, "read(video({ time: 0, duration: NaN }))") == nil)
    }

    @Test func youTubeLiveReadsItsSlider() throws {
        let context = try context()
        // At the edge: the slider's value at its maximum, the media's own
        // length and seekable end an hour on.
        let edge = pair(context, """
            read(video({ time: 46864.2, duration: 50390.1, seekable: [[0, 50390.1]], buffered: [[46800, 46870]],
                         player: player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 3600, 'aria-valuenow': 3600 }) }))
            """)
        #expect(edge?.count == 2)
        #expect(abs((edge?[0] ?? 0) - 43_264.2) < 0.01)
        #expect(abs((edge?[1] ?? 0) - 46_864.2) < 0.01)
        // Five minutes back.
        let back = pair(context, """
            read(video({ src: 'blob:b', time: 46564.2, duration: 50390.1, seekable: [[0, 50390.1]], buffered: [[46500, 46600]],
                         player: player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 3600, 'aria-valuenow': 3300 }) }))
            """)
        let window = LiveEdge.Window(start: back?[0], edge: back?[1] ?? 0, time: 46_564.2)
        #expect(abs(window.behind - 300) < 0.01)
        #expect(LiveEdge.words(behind: window.behind) == "5m behind")
        #expect(context.exception == nil)
    }

    @Test func youTubeLiveToldByItsSlider() throws {
        let context = try context()
        // As read on 2026-10-03 from a stream 206 days in: no class says
        // live, the slider counts from the stream's start and spans twelve
        // hours of a video 50 390 s long.
        let found = pair(context, """
            read(video({ time: 46789.99, duration: 50390.001, seekable: [[0, 50390.001]], buffered: [[46790, 46809.999]],
                         player: player([], { 'aria-valuemin': 17824533, 'aria-valuemax': 17867718, 'aria-valuenow': 17867713 }) }))
            """)
        let window = LiveEdge.Window(start: found?[0], edge: found?[1] ?? 0, time: 46_789.99)
        #expect(abs((found?[0] ?? 0) - 3609.99) < 0.01)
        #expect(abs(window.behind - 5) < 0.01)
        #expect(LiveEdge.words(behind: window.behind) == "Live")
        // A video's slider spans its length: not live, even far from its
        // time, as a slider left behind would be.
        #expect(pair(context, """
            read(video({ src: 'blob:v', time: 300, duration: 634.2, seekable: [[0, 634.2]],
                         player: player([], { 'aria-valuemin': 0, 'aria-valuemax': 634, 'aria-valuenow': 120 }) }))
            """) == nil)
        // A slider reaching back before the video's first moment: the bar
        // from that moment, the edge where the slider says.
        let early = pair(context, """
            read(video({ src: 'blob:e', time: 30, duration: Infinity,
                         player: player([], { 'aria-valuemin': 0, 'aria-valuemax': 43185, 'aria-valuenow': 42885 }) }))
            """)
        #expect(early == [0, 330])
        // Nor while an ad shows.
        #expect(pair(context, """
            read(video({ src: 'blob:ad', time: 3, duration: 15, seekable: [[0, 15]],
                         player: player(['ad-showing'], { 'aria-valuemin': 0, 'aria-valuemax': 634, 'aria-valuenow': 0 }) }))
            """) == nil)
    }

    @Test func youTubeLiveWithoutASliderShowsTheEdgeOnly() throws {
        let context = try context()
        // No slider to read: never the hour-ahead length, the furthest
        // fetched instead, and no start to draw a bar from.
        let found = pair(context, """
            read(video({ time: 4208.8, duration: 7735.1, seekable: [[0, 7735.1]], buffered: [[4100, 4212]],
                         player: player(['ytp-live'], null) }))
            """)
        #expect(found?[0] == -1)
        #expect(found?[1] == 4212)
    }

    @Test func endlessStreamUsesItsSeekableRange() throws {
        let context = try context()
        // Safari's own HLS: an endless length, the seekable range the
        // stream's own.
        let found = pair(context, "read(video({ time: 990, duration: Infinity, seekable: [[100, 1010]], buffered: [[980, 1010]] }))")
        #expect(found == [100, 1010])
        // MSE's 1e300 with no range to go by: the furthest fetched.
        let mse = pair(context, "read(video({ src: 'blob:c', time: 50, duration: 1e300, seekable: [[0, 1e300]], buffered: [[40, 58]] }))")
        #expect(mse == [-1, 58])
    }

    @Test func aGrowingRangeIsLive() throws {
        let context = try context()
        // A length given as a video's, while the seekable end grows with
        // the clock: live after it has grown twice running.
        context.evaluateScript("""
            var now = 1000000; Date.now = function () { return now; };
            var v = video({ time: 100, duration: 120, seekable: [[0, 120]], buffered: [[90, 120]] });
            """)
        #expect(pair(context, "read(v)") == nil)
        context.evaluateScript("now += 5000; v.seekable = ranges([[0, 125]]);")
        #expect(pair(context, "read(v)") == nil)
        context.evaluateScript("now += 5000; v.seekable = ranges([[0, 130]]); v.currentTime = 110;")
        #expect(pair(context, "read(v)") == [0, 130])
        // A length that only jumped once is a video's.
        context.evaluateScript("var w = video({ src: 'blob:d', time: 10, duration: 60, seekable: [[0, 30]] });")
        #expect(pair(context, "read(w)") == nil)
        context.evaluateScript("now += 5000; w.seekable = ranges([[0, 600]]);")
        #expect(pair(context, "read(w)") == nil)
        context.evaluateScript("now += 5000;")
        #expect(pair(context, "read(w)") == nil)
    }

    @Test func aGrowingRangeThatStopsIsARecording() throws {
        let context = try context()
        context.evaluateScript("""
            var now = 1000000; Date.now = function () { return now; };
            var v = video({ time: 100, duration: 120, seekable: [[0, 120]] });
            read(v);
            now += 5000; v.seekable = ranges([[0, 125]]); read(v);
            now += 5000; v.seekable = ranges([[0, 130]]); v.currentTime = 110;
            """)
        #expect(pair(context, "read(v)") == [0, 130])
        // Playing on while the end it can go to stands still: twenty
        // seconds is a hiccup, still live.
        context.evaluateScript("now += 20000; v.currentTime = 125;")
        #expect(pair(context, "read(v)") != nil)
        // Over half a minute: the broadcast is over, a video now.
        context.evaluateScript("now += 15000; v.currentTime = 128;")
        #expect(pair(context, "read(v)") == nil)
    }

    @Test func aSliderBehindASeekKeepsTheEdge() throws {
        let context = try context()
        // As on Sky News, 2026-10-03: just after a seek of 9h 30m back the
        // slider still said the edge, and the edge read from it was an
        // hour past YouTube's own end, where a click to live went.
        context.evaluateScript("""
            var now = 1000000; Date.now = function () { return now; };
            var yt = player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 43190, 'aria-valuenow': 43190 });
            var v = video({ time: 46826.5, duration: 50390.1, player: yt });
            """)
        #expect(pair(context, "read(v)") == [3636.5, 46826.5])
        // Sent back; the slider hasn't heard yet.
        context.evaluateScript("now += 500; v.currentTime = 12622.5;")
        #expect(pair(context, "read(v)") == [3636.5, 46826.5])
        // It has: the same stretch, from the slider.
        context.evaluateScript("""
            now += 500; v.closest = function () {
              return player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 43191, 'aria-valuenow': 8986 }); };
            """)
        #expect(pair(context, "read(v)") == [3636.5, 46827.5])
        // A slider that stays apart for over ten seconds is the stream's.
        context.evaluateScript("""
            v.closest = function () { return player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 43191, 'aria-valuenow': 43191 }); };
            now += 2000; read(v); now += 11000;
            """)
        #expect(pair(context, "read(v)") == [0, 12622.5])
    }

    @Test func aPausedStreamFallsBehind() throws {
        let context = try context()
        // Safari's HLS, paused: its range stops where it was, the edge
        // goes on with the clock.
        context.evaluateScript("""
            var now = 1000000; Date.now = function () { return now; };
            var v = video({ time: 1000, duration: Infinity, seekable: [[100, 1010]], paused: true });
            """)
        #expect(pair(context, "read(v)") == [100, 1010])
        context.evaluateScript("now += 60000;")
        #expect(pair(context, "read(v)") == [100, 1070])
        // Playing, the range is the stream's again.
        context.evaluateScript("v.paused = false; v.seekable = ranges([[160, 1072]]);")
        #expect(pair(context, "read(v)") == [160, 1072])
    }

    @Test func advertIsReadFromThePlayer() throws {
        let context = try context()
        context.evaluateScript("var advert = \(LiveEdge.advert);")
        #expect(context.evaluateScript("advert(video({ time: 1, duration: 10, player: player(['ad-showing', 'ytp-live'], null) }))")?.toBool() == true)
        #expect(context.evaluateScript("advert(video({ time: 1, duration: 10, player: player(['ytp-live'], null) }))")?.toBool() == false)
        #expect(context.evaluateScript("advert(video({ time: 1, duration: 10 }))")?.toBool() == false)
    }

    @Test func theEdgeMovesOnWithTheClock() throws {
        let context = try context()
        // Seen at 4212 once; ten seconds later, sent back, the edge is
        // where it was and ten seconds on, not the little fetched since.
        context.evaluateScript("""
            var now = 1000000; Date.now = function () { return now; };
            var v = video({ time: 4208, duration: 7735, buffered: [[4100, 4212]], player: player(['ytp-live'], null) });
            """)
        #expect(pair(context, "read(v)") == [-1, 4212])
        context.evaluateScript("now += 10000; v.currentTime = 3900; v.buffered = ranges([[3890, 3930]]);")
        #expect(pair(context, "read(v)") == [-1, 4222])
    }

    // MARK: the floating window's seek

    private func floated() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(LiveEdgeTests.page)
        context.evaluateScript("""
            var v = video({ time: 46564.2, duration: 50390.1, seekable: [[0, 50390.1]], buffered: [[46500, 46600]],
                            player: player(['ytp-live'], { 'aria-valuemin': 0, 'aria-valuemax': 3600, 'aria-valuenow': 3300 }) });
            var document = { querySelectorAll: function (s) { return s === 'video' ? [v] : []; } };
            """)
        context.evaluateScript(Isolate.script.source)
        #expect(context.exception == nil)
        return context
    }

    @Test func seekStaysInsideTheStretch() throws {
        let context = try floated()
        // The end of the bar: the edge, never the hour-ahead length.
        context.evaluateScript("window.__yabFloat.seek(1)")
        #expect(abs((context.evaluateScript("v.currentTime")?.toDouble() ?? 0) - 46_864.2) < 0.01)
        context.evaluateScript("v.currentTime = 46564.2;")
        context.evaluateScript("window.__yabFloat.seek(0.5)")
        #expect(abs((context.evaluateScript("v.currentTime")?.toDouble() ?? 0) - (43_264.2 + 1800)) < 0.01)
        #expect(context.exception == nil)
    }

    @Test func skipStopsAtTheEdge() throws {
        let context = try floated()
        context.evaluateScript("window.__yabFloat.skip(600)")
        #expect(abs((context.evaluateScript("v.currentTime")?.toDouble() ?? 0) - 46_864.2) < 0.01)
        #expect(context.exception == nil)
    }

    @Test func seekWithoutAStretchGoesNowhere() throws {
        let context = try floated()
        context.evaluateScript("v.closest = function () { return player(['ytp-live'], null); };")
        context.evaluateScript("window.__yabFloat.seek(0.2)")
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 46_564.2)
    }

    // MARK: YouTube's ad code

    /// The page as far as the ad code goes: a player whose class says an
    /// ad shows, and the events it listens for.
    private func adPage(liveClass: Bool, duration: String, time: Double = 46_864, setup: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var heard = {}, windowHeard = {}, tick = null, changed = null, now = 10000;
            Date.now = function () { return now; };
            var window = {
              addEventListener: function (name, f) { windowHeard[name] = f; },
              removeEventListener: function (name) { delete windowHeard[name]; }
            };
            function CustomEvent(name, init) { this.type = name; this.detail = init && init.detail; }
            function EventTarget() {}
            EventTarget.prototype.dispatchEvent = function (event) { if (windowHeard[event.type]) windowHeard[event.type](event); };
            function HTMLVideoElement() {}
            function MutationObserver(f) { this.callback = f; }
            MutationObserver.prototype.observe = function () { changed = this.callback; };
            MutationObserver.prototype.disconnect = function () {};
            function setInterval(f) { tick = f; return 1; }
            function clearInterval() { tick = null; }
            function beat() { if (tick) tick(); }
            var playReenters = false;
            function freshVideo(source, duration, time) {
              var v = Object.create(HTMLVideoElement.prototype);
              v.muted = false; v.playbackRate = 1; v.currentSrc = source; v.currentTime = time;
              v.duration = duration; v.paused = false; v.ended = false; v.readyState = 4; v.plays = 0;
              v.play = function () {
                this.plays++; this.paused = false;
                if (playReenters) heard.playing({ target: this, type: 'playing' });
                return { catch: function () {} };
              };
              return v;
            }
            var v = freshVideo('blob:ad', \(duration), \(time));
            var skipAction = null;
            var skipButton = { disabled: false, offsetParent: {}, clientWidth: 40,
              click: function () { var action = skipAction; skipAction = null; if (action) action(); } };
            var classes = ['ad-showing'\(liveClass ? ", 'ytp-live'" : "")];
            var extraVideos = [];
            var movie = {
              classList: { contains: function (c) { return classes.indexOf(c) >= 0; } },
              querySelectorAll: function (s) { return s === 'video' ? extraVideos.concat([v]) : []; },
              querySelector: function () { return null; }
            };
            var document = {
              getElementById: function (id) { return id === 'movie_player' ? movie : null; },
              querySelectorAll: function () { return skipAction ? [skipButton] : []; },
              addEventListener: function (name, f) { heard[name] = f; },
              removeEventListener: function () {}
            };
            \(setup)
            """)
        context.evaluateScript(YouTube.script)
        #expect(context.exception == nil)
        context.evaluateScript("heard.play({ target: v, type: 'play' })")
        #expect(context.exception == nil)
        return context
    }

    @Test func adOnALiveStreamIsOnlyMuted() throws {
        let context = try adPage(liveClass: true, duration: "50390")
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 46_864)
        // An endless stream is one too, whatever the class.
        let endless = try adPage(liveClass: false, duration: "Infinity")
        #expect(endless.evaluateScript("v.playbackRate")?.toDouble() == 1)
    }

    /// Request 1969: YouTube's player counts an ad run faster than 2.5x,
    /// one sent to its end, and a Skip pressed by script (an untrusted
    /// click) as an abnormality, which brings the "Ad blockers are not
    /// allowed" wall. An ad that gets through is only muted.
    @Test func adOnAVideoIsOnlyMuted() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5, setup: """
            var scriptSkipped = false;
            skipAction = function () { scriptSkipped = true; };
            """)
        context.evaluateScript("beat(); beat(); now += 6000; beat();")
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 5)
        // The Skip button is up and pressable, and left for the person.
        #expect(context.evaluateScript("!scriptSkipped && skipAction !== null")?.toBool() == true)
        // When the ad ends, the sound comes back.
        context.evaluateScript("classes = []; changed();")
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.exception == nil)
    }

    // The Skips below are the person's own (the script never presses one):
    // the player then changes the class, the source or the element.
    @Test func skipClearingAdClassDoesNotSeekOrPlayContent() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5, setup: """
            skipAction = function () {
              classes = []; v.duration = 60; v.currentTime = 10; v.paused = true;
            };
            """)
        #expect(context.evaluateScript("v.muted && skipAction !== null")?.toBool() == true)
        context.evaluateScript("skipButton.click(); changed();")
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 10)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.evaluateScript("v.paused && v.plays === 0")?.toBool() == true)
    }

    @Test func skipReplacingSourceRetiresStaleAdClassAcrossBeats() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5, setup: """
            playReenters = true;
            skipAction = function () {
              v.currentSrc = 'blob:content'; v.duration = 60; v.currentTime = 10;
              v.playbackRate = 1.25; v.muted = false; v.paused = true;
            };
            """)
        context.evaluateScript("skipButton.click(); beat(); beat(); heard.playing({ target: v, type: 'playing' }); beat();")
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 10)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.25)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.evaluateScript("v.paused && v.plays === 0")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test func skipReplacingElementDoesNotEnrollContentWhileClassLags() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5, setup: """
            var previous = v;
            skipAction = function () {
              v = freshVideo('blob:content', 60, 10); v.paused = true;
              v.playbackRate = 1.75;
              heard.playing({ target: v, type: 'playing' });
            };
            """)
        context.evaluateScript("skipButton.click(); beat(); beat();")
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 10)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.75)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.evaluateScript("v.paused && v.plays === 0")?.toBool() == true)
        #expect(context.evaluateScript("previous.muted")?.toBool() == false)
        #expect(context.exception == nil)
    }

    @Test func sourceReplacementRestoresForcedValuesOnlyOnce() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("v.currentSrc = 'blob:content'; v.duration = 60; v.currentTime = 10; v.paused = true; beat();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        context.evaluateScript("v.playbackRate = 1.75; v.muted = true; beat(); beat();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.75)
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        #expect(context.evaluateScript("v.currentTime === 10 && v.paused && v.plays === 0")?.toBool() == true)
    }

    @Test func sourceReplacementPreservesContentRateAndMute() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("v.currentSrc = 'blob:content'; v.playbackRate = 2; v.muted = false; v.paused = true; beat(); beat();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 2)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.evaluateScript("v.paused && v.plays === 0")?.toBool() == true)
    }

    @Test func adEndDoesNotRestoreARateTheLiveFallbackNeverForced() throws {
        let context = try adPage(liveClass: true, duration: "50390")
        context.evaluateScript("v.playbackRate = 2; classes = []; changed();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 2)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 46_864)
    }

    @Test func retiredAdCanRearmOnlyAfterItsLifecycleEnds() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("v.currentSrc = 'blob:content'; beat(); v.playbackRate = 1.5; v.muted = true; classes = []; changed(); beat();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.5)
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        context.evaluateScript("v.muted = false; v.currentSrc = 'blob:next-ad'; v.duration = 30; v.currentTime = 5; classes = ['ad-showing']; changed();")
        // The next ad is enrolled again: muted, neither sped up nor sent on.
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.5)
        #expect(context.evaluateScript("v.currentTime")?.toDouble() == 5)
        context.evaluateScript("classes = []; changed();")
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.5)
        #expect(context.evaluateScript("v.muted")?.toBool() == false)
    }

    @Test func userPauseAfterAdStillWins() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("classes = []; changed(); windowHeard.pointerdown({ isTrusted: true }); v.paused = true; heard.pause({ target: v }); now += 500; beat();")
        #expect(context.evaluateScript("v.paused && v.plays === 0")?.toBool() == true)
    }

    @Test func disablingAfterSourceReplacementDoesNotUndoContentChoices() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("v.currentSrc = 'blob:content'; beat(); v.playbackRate = 1.75; v.muted = true;")
        context.evaluateScript(YouTube.off)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1.75)
        #expect(context.evaluateScript("v.muted")?.toBool() == true)
        #expect(context.exception == nil)
    }


    @Test func prependedContentIsUntouchedBeforeLaterSourceMismatch() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("""
            var content = freshVideo('blob:content', 60, 10);
            content.paused = true; content.playbackRate = 1.25;
            extraVideos = [content]; v.currentSrc = 'blob:old-content'; beat(); beat();
            """)
        #expect(context.evaluateScript("content.currentTime")?.toDouble() == 10)
        #expect(context.evaluateScript("content.playbackRate")?.toDouble() == 1.25)
        #expect(context.evaluateScript("content.muted")?.toBool() == false)
        #expect(context.evaluateScript("content.paused && content.plays === 0")?.toBool() == true)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
    }

    @Test func newVideoRetiresEstablishedAdEvenWhenOldSourceIsUnchanged() throws {
        let context = try adPage(liveClass: false, duration: "30", time: 5)
        context.evaluateScript("var content = freshVideo('blob:content', 60, 10); content.paused = true; extraVideos = [content]; beat(); beat();")
        #expect(context.evaluateScript("content.currentTime")?.toDouble() == 10)
        #expect(context.evaluateScript("content.playbackRate")?.toDouble() == 1)
        #expect(context.evaluateScript("content.muted")?.toBool() == false)
        #expect(context.evaluateScript("content.paused && content.plays === 0")?.toBool() == true)
        #expect(context.evaluateScript("v.playbackRate")?.toDouble() == 1)
    }

}
