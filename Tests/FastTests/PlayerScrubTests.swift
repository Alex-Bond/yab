import AppKit
import JavaScriptCore
import Testing
@testable import Fast

// The island's progress line as a scrubber (PlayerBand.swift, Tune.swift):
// the page's media moved to a point along it, a live stream along the
// stretch it keeps, Spotify by its own progress bar; and the open card's
// corners made by name for a build whose SDK has no corner configuration
// (Xcode 26, as releases are), which 0.0.9 lacked.
@MainActor struct PlayerScrubTests {
    // MARK: the page's side

    /// A page as the seeker sees it: media elements, and Spotify's range.
    static let page = """
    var window = {};
    var sent = [];
    function Event(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); }
    function ranges(list) {
      return { length: list.length, start: function (i) { return list[i][0]; }, end: function (i) { return list[i][1]; } };
    }
    function media(o) {
      var m = {
        tagName: 'AUDIO', currentSrc: 'blob:a', currentTime: o.time, duration: o.duration, paused: !!o.paused,
        seekable: ranges(o.seekable || []), buffered: ranges([]), rough: null,
        closest: function () { return null; }
      };
      if (o.fast) m.fastSeek = function (t) { m.rough = t; };
      return m;
    }
    var all = [], range = null;
    var document = {
      querySelectorAll: function (s) { return s === 'video, audio' ? all : []; },
      querySelector: function (s) {
        if (s === '[data-testid="playback-progressbar"] input[type="range"]') return range;
        return all[0] || null;
      }
    };
    function spotify(max, value) {
      range = { min: '0', max: String(max), value: String(value),
                dispatchEvent: function (e) { sent.push(e.type + (e.bubbles ? '+' : '')); return true; } };
      return range;
    }
    """

    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(PlayerScrubTests.page)
        context.evaluateScript("var seek = \(TuneWatch.seeker);")
        #expect(context.exception == nil)
        return context
    }

    private func number(_ context: JSContext, _ js: String) -> Double {
        context.evaluateScript(js).toDouble()
    }

    @Test func aTrackGoesToThePointAlongIt() throws {
        let context = try context()
        context.evaluateScript("all = [media({ time: 12, duration: 200 })];")
        #expect(context.evaluateScript("seek(0.25, false)").toBool())
        #expect(number(context, "all[0].currentTime") == 50)
        // Past either end, the end.
        context.evaluateScript("seek(1.4, false)")
        #expect(number(context, "all[0].currentTime") == 200)
        context.evaluateScript("seek(-1, false)")
        #expect(number(context, "all[0].currentTime") == 0)
    }

    @Test func aDragSeeksRoughlyWhereTheEngineCan() throws {
        let context = try context()
        context.evaluateScript("all = [media({ time: 12, duration: 200, fast: true })];")
        context.evaluateScript("seek(0.5, true)")
        #expect(number(context, "all[0].rough") == 100)
        #expect(number(context, "all[0].currentTime") == 12)
        // Let go: exactly.
        context.evaluateScript("seek(0.5, false)")
        #expect(number(context, "all[0].currentTime") == 100)
    }

    @Test func thePlayingOneIsMoved() throws {
        let context = try context()
        context.evaluateScript("all = [media({ time: 3, duration: 30, paused: true }), media({ time: 40, duration: 300 })];")
        context.evaluateScript("seek(0.5, false)")
        #expect(number(context, "all[0].currentTime") == 3)
        #expect(number(context, "all[1].currentTime") == 150)
    }

    @Test func nothingToMoveSaysSo() throws {
        let context = try context()
        #expect(!context.evaluateScript("seek(0.5, false)").toBool())
        context.evaluateScript("all = [media({ time: 3, duration: NaN })];")
        #expect(!context.evaluateScript("seek(0.5, false)").toBool())
        #expect(number(context, "all[0].currentTime") == 3)
    }

    @Test func aLiveStreamGoesAlongItsStretch() throws {
        let context = try context()
        // Safari's own HLS: endless, the stretch the seekable range.
        context.evaluateScript("all = [media({ time: 7290, duration: Infinity, seekable: [[100, 7300]] })];")
        context.evaluateScript("seek(0.5, false)")
        #expect(number(context, "all[0].currentTime") == 3700)
        // All the way: its edge.
        context.evaluateScript("seek(1, false)")
        #expect(number(context, "all[0].currentTime") == 7300)
    }

    @Test func spotifyMovesByItsOwnBar() throws {
        let context = try context()
        context.evaluateScript("spotify(137000, 11000);")
        // While the finger holds the line, its bar is left alone.
        #expect(context.evaluateScript("seek(0.5, true)").toBool())
        #expect(context.evaluateScript("range.value").toString() == "11000")
        #expect(context.evaluateScript("sent.length").toInt32() == 0)
        #expect(context.evaluateScript("seek(0.5, false)").toBool())
        #expect(context.evaluateScript("range.value").toString() == "68500")
        #expect(context.evaluateScript("sent.join(',')").toString() == "input+,change+")
    }

    // MARK: the island's side

    @Test func aLineToScrub() {
        #expect(Tune(title: "A film", duration: 200).scrubs)
        #expect(!Tune(title: "No length").scrubs)
        var stream = Tune(title: "Sky News", playing: true)
        stream.live = true
        #expect(!stream.scrubs)
        stream.span = 7200
        #expect(stream.scrubs)
    }

    @Test func aPausedStreamKeepsMore() {
        var stream = Tune(title: "Sky News", elapsed: 0, stamp: 100, playing: false)
        stream.live = true
        stream.span = 7200
        #expect(stream.kept(at: 160) == 7260)
        stream.playing = true
        #expect(stream.kept(at: 160) == 7200)
    }

    // MARK: corners by name

    /// The private radii a configuration resolves to, as macOS 27 says them.
    private func radius(_ configuration: AnyObject, _ corner: String) -> String? {
        let name = NSSelectorFromString(corner)
        guard let object = configuration as? NSObject, object.responds(to: name) else { return nil }
        return object.perform(name).map { String(describing: $0.takeUnretainedValue()) }
    }

    @Test func cornersMadeByNameAreTheConfiguration() throws {
        guard #available(macOS 27.0, *) else {
            #expect(IslandGlass.corners(top: 12, bottom: 20) == nil)
            return
        }
        let made = try #require(IslandGlass.corners(top: 12, bottom: 20))
        #expect((made as? NSObject)?.className == "NSViewCornerConfiguration")
        #expect(radius(made, "_topLeftRadius")?.contains("radius: 12") == true)
        #expect(radius(made, "_topRightRadius")?.contains("radius: 12") == true)
        #expect(radius(made, "_bottomLeftRadius")?.contains("radius: 20") == true)
        #expect(radius(made, "_bottomRightRadius")?.contains("radius: 20") == true)
        #if compiler(>=6.4)
        // The same as the SDK's own, the one a build with Xcode 27 returns.
        let typed: NSViewCornerConfiguration = .uniformEdges(topRadius: .fixed(12), bottomRadius: .fixed(20))
        for corner in ["_topLeftRadius", "_bottomLeftRadius"] {
            #expect(radius(made, corner)?.replacingOccurrences(of: #"0x[0-9a-f]+"#, with: "", options: .regularExpression)
                == radius(typed, corner)?.replacingOccurrences(of: #"0x[0-9a-f]+"#, with: "", options: .regularExpression))
        }
        #endif
    }

    // MARK: the pause mark

    /// No pause bar's corner is more than half the bar: macOS 15's
    /// CoreGraphics asserts on one (CGPathAddRoundedRect), and 0.0.30
    /// crashed there for the compact island's 11 pt play door, its bars
    /// 2.86 wide under a 1.6 corner.
    @Test func pauseBarCornersFitTheirBars() {
        for side in [0, 1, 4, 11, 20] as [CGFloat] {
            for (bar, corner) in BandDoor.pauseBarShapes(side) {
                #expect(corner >= 0)
                #expect(2 * corner <= bar.width + 1e-9, "side \(side)")
                #expect(2 * corner <= bar.height + 1e-9, "side \(side)")
            }
            _ = BandDoor.pauseBars(side)
        }
    }
}
