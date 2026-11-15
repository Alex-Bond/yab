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

    /// Exercise the real presenter without creating a macOS Space in a unit test.
    private final class NativeFullscreenWindow: NSWindow {
        var toggleCount = 0
        var frontRequests = 0
        var reportsFullscreen = false
        var fullscreenOwners: [(active: Bool, allowsAutomaticPiP: Bool)] = []
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if let page = responder as? ChromiumPage {
                fullscreenOwners.append((page.media.fullscreen, page.media.permitsAutomaticPiP))
            }
            return super.makeFirstResponder(responder)
        }
        override var styleMask: NSWindow.StyleMask {
            get { reportsFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
        override func toggleFullScreen(_ sender: Any?) { toggleCount += 1 }
        override func makeKeyAndOrderFront(_ sender: Any?) { frontRequests += 1 }
    }

    @Test func pageFullscreenReusesAnAlreadyFullscreenBrowserWindow() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), states = States()
        let page = ChromiumPage(tab: tab)
        let window = NativeFullscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.reportsFullscreen = true
        let content = window.contentView!
        let stage = NSView(frame: content.bounds)
        content.addSubview(stage); stage.addSubview(page)
        page.frame = stage.bounds
        defer {
            page.mediaEnded(); page.retire(call: false, pictureInPicture: false); tab.close()
            window.reportsFullscreen = false
            window.close()
        }
        page.stateEvents = states
        for turn in 0..<5 {
            // The stage normally takes its page back during layout.
            if page.superview !== stage { stage.addSubview(page) }
            page.receiveMedia("page.fullscreen", ["fullscreen": .bool(true)])
            #expect(page.media.fullscreen)
            #expect(page.window === window)
            #expect(page.superview === content)
            #expect(window.fullscreenOwners.last?.active == true)
            #expect(window.fullscreenOwners.last?.allowsAutomaticPiP == false)
            #expect(page.frame == content.bounds)
            #expect(window.toggleCount == 0)
            #expect(page.fullscreenState["window"] as? Int == window.windowNumber)
            // Teardown can detach the view before the fullscreen exit arrives.
            if turn == 4 { page.removeFromSuperview() }
            page.receiveMedia("page.fullscreen", ["fullscreen": .bool(false)])
            #expect(!page.media.fullscreen)
            #expect(window.styleMask.contains(.fullScreen))
            #expect(window.toggleCount == 0)
            #expect(window.frontRequests == 0)
        }
        #expect(states.seen.count == 10)
    }

    @Test func fullscreenReturnsTheSamePageToItsLittleWindowHolder() {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        let page = tab.page as! ChromiumPage
        let holder = PageHolder(tab: tab)
        let window = NativeFullscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.reportsFullscreen = true
        window.contentView!.addSubview(holder)
        defer {
            page.mediaEnded(); page.retire(call: false, pictureInPicture: false); tab.close()
            window.reportsFullscreen = false; window.close()
        }
        for _ in 0..<3 {
            page.receiveMedia("page.fullscreen", ["fullscreen": .bool(true)])
            #expect(page.superview === window.contentView)
            holder.setFrameSize(NSSize(width: 640, height: 480))
            page.receiveMedia("page.fullscreen", ["fullscreen": .bool(false)])
            #expect(page.superview === holder)
            #expect(page.frame == holder.bounds)
            #expect(page.autoresizingMask.isEmpty)
            #expect(!page.media.fullscreen)
        }
        // A handoff while fullscreen is exiting must keep its new owner.
        page.receiveMedia("page.fullscreen", ["fullscreen": .bool(true)])
        let destination = NSView(frame: holder.bounds)
        window.contentView!.addSubview(destination)
        destination.addSubview(page)
        page.receiveMedia("page.fullscreen", ["fullscreen": .bool(false)])
        #expect(page.superview === destination)
    }

}
