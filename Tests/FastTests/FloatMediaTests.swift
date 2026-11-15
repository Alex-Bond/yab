import JavaScriptCore
import Testing
@testable import Fast

struct FloatMediaTests {
    /// The same isolated script runs for a floated video in the page or an
    /// iframe. Closing must pause an already playing video without toggling
    /// a paused one back on; the sound button must read the video's mute.
    @MainActor @Test func pauseAndSiteMute() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var window = { addEventListener: function () {} };
            var video = {
              tagName: 'VIDEO', paused: false, muted: true, volume: 0,
              pauses: 0, pause: function () { this.paused = true; this.pauses++; }
            };
            var otherVideo = { tagName: 'VIDEO', muted: false, volume: 0.4 };
            var document = { querySelectorAll: function (selector) {
              return selector === 'video' ? [video, otherVideo] : [];
            } };
            """)
        context.evaluateScript(Isolate.script.source)
        #expect(context.exception == nil)

        context.evaluateScript("window.__yabFloat.pause()")
        #expect(context.evaluateScript("video.paused")?.toBool() == true)
        context.evaluateScript("window.__yabFloat.pause()")
        #expect(context.evaluateScript("video.pauses")?.toInt32() == 1)

        context.evaluateScript("window.__yabFloat.sound(0)")
        #expect(context.evaluateScript("video.muted")?.toBool() == false)
        #expect(context.evaluateScript("video.volume")?.toDouble() == 1)
        context.evaluateScript("window.__yabFloat.sound(0)")
        #expect(context.evaluateScript("video.muted")?.toBool() == true)
        context.evaluateScript("window.__yabFloat.sound(1)")
        #expect(context.evaluateScript("video.muted")?.toBool() == false)
        #expect(context.evaluateScript("otherVideo.muted")?.toBool() == false)
        #expect(context.evaluateScript("otherVideo.volume")?.toDouble() == 0.4)
        #expect(context.exception == nil)
    }
}
