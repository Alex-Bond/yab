import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct SplitPreviewReleaseTests {
    /// One divider gesture can return to its starting share. SwiftUI then
    /// has no changed frame with which to land the preview. Mouseup still
    /// has to retire the preview and release WebKit's live resize.
    @Test(arguments: [false, true])
    func returningToTheOriginalShareReleasesThePreview(holdBeforeTracking: Bool) async throws {
        let room = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: room, styleMask: .borderless, backing: .buffered, defer: false, screen: TestScreen.screen)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: room)
        content.wantsLayer = true
        window.contentView = content
        let stage = StageView(frame: CGRect(x: 8, y: 8, width: 1000, height: 700))
        stage.autoresizesSubviews = false
        content.addSubview(stage)
        stage.round(12, flatTop: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: stage.bounds, configuration: configuration)
        stage.show(web, of: UUID())
        window.orderFront(nil)
        let linear = CAMediaTimingFunction(name: .linear)
        defer {
            // A failed assertion must not leave a display link running in
            // the next test or retain an invisible WebKit viewport.
            stage.preview(nil, duration: 0, timing: linear)
            stage.hold(false)
            stage.show(nil)
            window.close()
        }
        web.loadHTMLString("<body><input id='draft' value='retained'><script>window.token='before'</script></body>", baseURL: nil)
        let loaded = try await Loaded.until(15) {
            (try? await web.evaluateJavaScript("document.readyState === 'complete' && window.token === 'before'")) as? Bool == true
        }
        try #require(loaded)
        _ = try await web.takeSnapshot(configuration: nil)
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        let original = stage.frame

        stage.tracking = true
        stage.hold(true)
        let narrower = CGRect(x: 240, y: 0, width: 760, height: 700)
        stage.preview(stage.convert(narrower, to: nil), duration: 0, timing: linear)
        let narrowed = try await Loaded.until(10) {
            web.frame.width == 760 && stage.benchGeometry()["viewportPending"] as? Bool == false
        }
        try #require(narrowed)
        #expect(stage.frame == original)

        stage.preview(stage.convert(stage.bounds, to: nil), duration: 0, timing: linear)
        let returned = try await Loaded.until(10) {
            web.frame.size == stage.bounds.size && stage.benchGeometry()["viewportPending"] as? Bool == false
        }
        try #require(returned)
        #expect(stage.frame == original)
        #expect(try await web.evaluateJavaScript("draft.value") as? String == "retained")

        // Match mouseup and SwiftUI's update: the hold ends, and even an
        // unchanged layout may run. There is no new geometry to force it.
        if holdBeforeTracking {
            // WebStage updates the hold before it assigns tracking.
            stage.hold(false)
            stage.tracking = false
        } else {
            stage.tracking = false
            stage.hold(false)
        }
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        let released = try await Loaded.until(3) { !stage.isHeld && stage.previewing == nil }
        #expect(released, "A drag that returns home must clear its preview without a changed stage frame")
        #expect(stage.benchGeometry()["following"] as? Bool == false)
        #expect(web.frame == stage.bounds)

        web.loadHTMLString("<body><button id='current' onclick=\"this.textContent='works'\">Current</button><script>window.token='after'</script></body>", baseURL: nil)
        let navigated = try await Loaded.until(15) {
            (try? await web.evaluateJavaScript("document.readyState === 'complete' && window.token === 'after'")) as? Bool == true
        }
        #expect(navigated)
        #expect(try await web.evaluateJavaScript("current.click();current.textContent") as? String == "works")
        #expect(stage.previewing == nil)
        #expect(!stage.isHeld)
    }
}
