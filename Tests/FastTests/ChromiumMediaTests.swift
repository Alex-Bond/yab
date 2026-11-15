import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumMediaTests {
    private final class States: PageStateEvents {
        var seen: [PageStateChange] = []
        func page(_ page: any PageHandle, changed state: PageStateChange) { seen.append(state) }
    }

    @Test func reportKeepsOnlyTypedBoundedFields() {
        let long = String(repeating: "a", count: 3000)
        let report = ChromiumMediaReport([
            "audible": .bool(true), "playing": .bool(true), "audibleSource": .string("native"),
            "sessionState": .string("playing-and-much-more-than-sixteen"),
            "session": .object(["title": .string(long), "artist": .string("Artist"), "album": .number(4),
                                "artwork": .array([.object(["src": .string("https://example.com/a.png")]),
                                                   .object(["src": .string("javascript:alert(1)")]),
                                                   .object(["src": .string("file:///etc/passwd")]),
                                                   .object(["src": .number(3)])])]),
            "media": .object(["t": .number(12.5), "d": .number(.infinity), "paused": .bool(false),
                              "muted": .bool(true), "loop": .string("yes"), "video": .bool(true)]),
        ])
        #expect(report.audible && report.playing && report.native)
        #expect(report.sessionState.count == 16)
        #expect(report.session?.title.count == 1024)
        #expect(report.session?.artist == "Artist")
        #expect(report.session?.album == "")
        #expect(report.session?.artwork == [URL(string: "https://example.com/a.png")!])
        #expect(report.media?.time == 12.5)
        #expect(report.media?.duration == -1)
        #expect(report.media?.paused == false)
        #expect(report.media?.muted == true)
        #expect(report.media?.loop == false)
        #expect(report.media?.video == true)
    }

    @Test func absentFieldsMeanSilence() {
        let report = ChromiumMediaReport(["audible": .string("true"), "session": .null, "media": .null])
        #expect(!report.audible && !report.playing && !report.native)
        #expect(report.session == nil && report.media == nil)
        #expect(report.sessionState == "none")
    }

    @Test func captureReachesTheSeamAndEndsWithThePage() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), states = States()
        let page = ChromiumPage(tab: tab)
        defer { tab.close() }
        page.stateEvents = states
        page.receiveMedia("media.capture", ["camera": .bool(true), "microphone": .bool(false)])
        #expect(page.captureStatus == PageCaptureStatus(camera: .active, microphone: .none, screen: .none))
        #expect(states.seen == [.camera(.active)])
        page.receiveMedia("media.capture", ["camera": .bool(true), "microphone": .bool(true)])
        #expect(states.seen == [.camera(.active), .microphone(.active)])
        page.mediaEnded()
        #expect(page.captureStatus == PageCaptureStatus(camera: .none, microphone: .none, screen: .none))
        #expect(states.seen.suffix(2) == [.camera(.none), .microphone(.none)])
        page.retire(call: false, pictureInPicture: false)
    }

    @Test func fullscreenNeedsAPageOnScreen() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), states = States()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.stateEvents = states
        page.receiveMedia("page.fullscreen", ["fullscreen": .bool(true)])
        #expect(!page.media.fullscreen)
        #expect(states.seen.isEmpty)
        page.receiveMedia("page.fullscreen", ["fullscreen": .bool(false)])
        #expect(states.seen.isEmpty)
    }
}
