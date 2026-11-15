import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

@MainActor
struct VideoOpeningTests {
    private let url = URL(string: "https://video.test/watch")!

    @Test func firstShowNeedsFrontActiveAndABlockedMainVideo() throws {
        let opening = VideoOpening()
        #expect(opening.begin(front: true, active: true) == nil)
        opening.open(url)
        opening.prevented()
        #expect(opening.begin(front: false, active: true) == nil)
        #expect(opening.begin(front: true, active: false) == nil)
        #expect(!opening.shown)
        let ticket = try #require(opening.begin(front: true, active: true))
        #expect(!opening.finish(ticket, front: true, active: true, blockedMainVideo: false))
        let retry = try #require(opening.begin(front: true, active: true))
        #expect(opening.finish(retry, front: true, active: true, blockedMainVideo: true))
        #expect(opening.begin(front: true, active: true) == nil)
        #expect(!opening.finish(retry, front: true, active: true, blockedMainVideo: true))
    }

    @Test func firstShowWaitsForThePagesBlockedPlaybackReport() throws {
        let opening = VideoOpening()
        opening.open(url)
        #expect(opening.begin(front: true, active: true) == nil)
        #expect(opening.shown)
        opening.prevented()
        let ticket = try #require(opening.begin(front: true, active: true))
        #expect(opening.begin(front: true, active: true) == nil)
        #expect(opening.finish(ticket, front: true, active: true, blockedMainVideo: true))
    }

    @Test(arguments: [false, true])
    func hiddenOrInactiveBeforeTheScheduledReadCannotRun(active: Bool) throws {
        let opening = VideoOpening()
        opening.open(url)
        opening.prevented()
        let ticket = try #require(opening.begin(front: true, active: true))
        opening.update(front: !active, active: active)
        #expect(opening.generation != ticket)
        #expect(!opening.finish(ticket, front: true, active: true, blockedMainVideo: true))
        #expect(opening.begin(front: true, active: true) == nil)
    }

    @Test(arguments: [false, true])
    func hiddenOrInactiveWhileThePageAnswersCannotPlay(active: Bool) throws {
        let opening = VideoOpening()
        opening.open(url)
        opening.prevented()
        let ticket = try #require(opening.begin(front: true, active: true))
        #expect(!opening.finish(ticket, front: !active, active: active, blockedMainVideo: true))
        #expect(opening.begin(front: true, active: true) == nil)
    }

    @Test func returningAfterAnUnsuccessfulFirstShowDoesNotRetry() {
        let opening = VideoOpening()
        opening.open(url)
        opening.update(front: true, active: true)
        opening.update(front: false, active: true)
        opening.prevented()
        #expect(opening.begin(front: true, active: true) == nil)
    }

    @Test func cancellationNavigationAndNewLinksInvalidateOldReads() throws {
        let opening = VideoOpening()
        opening.open(url)
        opening.navigationStarted()
        opening.prevented()
        let ticket = try #require(opening.begin(front: true, active: true))
        opening.navigationStarted()
        #expect(!opening.armed)
        opening.open(url)
        opening.prevented()
        #expect(!opening.finish(ticket, front: true, active: true, blockedMainVideo: true))
        opening.going(to: URL(string: "https://video.test/other")!)
        #expect(!opening.armed)
        opening.open(url)
        opening.cancel()
        #expect(opening.begin(front: true, active: true) == nil)
    }

    @Test func navigatingAfterDispatchCancelsPendingPlayback() throws {
        let opening = VideoOpening()
        opening.open(url)
        opening.navigationStarted()
        opening.prevented()
        let ticket = try #require(opening.begin(front: true, active: true))
        #expect(opening.finish(ticket, front: true, active: true, blockedMainVideo: true))
        #expect(opening.going(to: url))
        #expect(opening.generation != ticket && !opening.shown)
    }

    @Test func bothWebKitDelegateRoutesReceiveAutoplayReports() {
        let selector = NSSelectorFromString("_webView:handleAutoplayEvent:withFlags:")
        #expect(WebKitPageEvents.instancesRespond(to: selector))
        #expect(Browser.instancesRespond(to: selector))
    }

    @Test func pageSelectionAndDispatchGuards() throws {
        let context = try #require(JSContext())
        context.setObject(PageScript.load("video-opening"), forKeyedSubscript: "openingScript" as NSString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let checks = try String(contentsOf: root.appendingPathComponent("evals/golden/video_opening.js"), encoding: .utf8)
        context.evaluateScript(checks)
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        #expect((context.objectForKeyedSubscript("videoOpeningChecks")?.toInt32() ?? 0) >= 25)
    }
}
