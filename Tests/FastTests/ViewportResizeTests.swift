import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct ViewportResizeTests {
    private func withPage(_ body: @MainActor (StageView, WKWebView) async throws -> Void) async throws {
        let room = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: room, styleMask: .borderless, backing: .buffered, defer: false)
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
        defer { window.close() }
        web.loadHTMLString("<body style='margin:0;min-height:2400px'><input id='draft' value='retained'><script>window.token='same-document'</script></body>", baseURL: nil)
        _ = try await Loaded.until(15) {
            (try? await web.evaluateJavaScript("document.readyState === 'complete' && window.token === 'same-document'")) as? Bool == true
        }
        _ = try await web.evaluateJavaScript("scrollTo(0,220);true")
        _ = try await web.takeSnapshot(configuration: nil)
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        try await body(stage, web)
    }

    /// The shared path handles panels on either side, a bottom inspector,
    /// and both split panes. Its first resize must leave the transaction
    /// that starts the surrounding panel animation free to commit.
    @Test(arguments: ["left", "right", "bottom", "split", "move"])
    func animatedPanelsCommitTheirViewportBeforeRelease(_ side: String) async throws {
        try await withPage { stage, web in
            let before = web.frame.size
            let pace = Reshape.pace
            defer { Reshape.pace = pace }
            Reshape.pace = .arrive
            stage.following = true
            stage.hold(true)
            let target: CGRect = switch side {
            case "left": CGRect(x: 248, y: 8, width: 760, height: 700)
            case "bottom": CGRect(x: 8, y: 248, width: 1000, height: 460)
            case "split": CGRect(x: 518, y: 8, width: 490, height: 700)
            case "move": CGRect(x: 148, y: 8, width: 1000, height: 700)
            default: CGRect(x: 8, y: 8, width: 680, height: 700)
            }
            stage.frame = target
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            #expect(web.frame.size == before)
            let initial = web.frame
            // A second layout of the same bounds must not bypass the
            // coordinator and move the old backing to the final origin.
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            #expect(web.frame == initial)
            #expect(stage.benchGeometry()["following"] as? Bool == true)
            #expect(web.layer?.animation(forKey: "reshape.carry") == nil)
            _ = try await Loaded.until(10) { web.frame != initial }
            #expect(stage.isHeld)
            stage.following = false
            stage.hold(false)
            _ = try await Loaded.until(10) { !stage.isHeld }
            stage.layoutSubtreeIfNeeded()
            #expect(web.frame == stage.bounds)
            #expect(try await web.evaluateJavaScript("innerWidth") as? Double == Double(target.width))
            #expect(try await web.evaluateJavaScript("window.token") as? String == "same-document")
            #expect(try await web.evaluateJavaScript("draft.value") as? String == "retained")
            #expect(try await web.evaluateJavaScript("scrollY") as? Double == 220)
        }
    }

    /// Many pointer updates may overtake a WebKit paint. They must coalesce
    /// to the latest target, including a reversal and the mouse-up target.
    @Test func draggingFinishesAtTheLatestWidthWithoutReplacingTheDocument() async throws {
        try await withPage { stage, web in
            stage.tracking = true
            stage.hold(true)
            let before = web.frame.size
            for width in [900.0, 760, 620, 540] {
                stage.setFrameSize(CGSize(width: width, height: 700))
                stage.needsLayout = true
                stage.layoutSubtreeIfNeeded()
            }
            #expect(web.frame.size == before)
            _ = try await Loaded.until(10) { web.frame.size != before }
            for width in [680.0, 810, 940] {
                stage.setFrameSize(CGSize(width: width, height: 700))
                stage.needsLayout = true
                stage.layoutSubtreeIfNeeded()
            }
            _ = try await Loaded.until(10) {
                web.frame.width == 940 && stage.benchGeometry()["viewportPending"] as? Bool == false
            }
            stage.tracking = false
            stage.hold(false)
            #expect(stage.isHeld)
            // A last SwiftUI layout can follow the release in the same pass.
            stage.setFrameSize(CGSize(width: 960, height: 700))
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            _ = try await Loaded.until(10) { !stage.isHeld }
            stage.layoutSubtreeIfNeeded()
            #expect(web.frame == stage.bounds)
            #expect(try await web.evaluateJavaScript("innerWidth") as? Double == 960)
            #expect(try await web.evaluateJavaScript("window.token") as? String == "same-document")
            #expect(try await web.evaluateJavaScript("draft.value") as? String == "retained")
            #expect(stage.benchGeometry()["following"] as? Bool == false)
        }
    }

    /// The optimized split divider moves a preview outline while SwiftUI
    /// stays in place. It must use the same live viewport and land once.
    @Test func splitPreviewUsesTheSharedViewportAndLands() async throws {
        try await withPage { stage, web in
            let room = stage.frame
            stage.tracking = true
            stage.hold(true)
            let linear = CAMediaTimingFunction(name: .linear)
            for width in [760.0, 620, 680] {
                let target = CGRect(x: 1000 - width, y: 0, width: width, height: 700)
                stage.preview(stage.convert(target, to: nil), duration: 0, timing: linear)
            }
            #expect(stage.frame == room)
            #expect(stage.benchGeometry()["following"] as? Bool == true)
            _ = try await Loaded.until(10) {
                web.frame.width == 680 && stage.benchGeometry()["viewportPending"] as? Bool == false
            }
            #expect(web.frame.minX == 320)
            #expect(try await web.evaluateJavaScript("innerWidth") as? Double == 680)
            stage.frame = CGRect(x: room.minX + 320, y: room.minY, width: 680, height: 700)
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            stage.tracking = false
            stage.hold(false)
            _ = try await Loaded.until(10) { !stage.isHeld }
            stage.layoutSubtreeIfNeeded()
            #expect(stage.previewing == nil)
            #expect(web.frame == stage.bounds)
            #expect(try await web.evaluateJavaScript("window.token") as? String == "same-document")
            #expect(try await web.evaluateJavaScript("draft.value") as? String == "retained")
            #expect(try await web.evaluateJavaScript("scrollY") as? Double == 220)
        }
    }

    /// PiP/fullscreen and another stage may borrow the live web view while
    /// a resize is awaiting paint. The old coordinator must surrender it.
    @Test func lendingThePageCancelsItsPendingViewport() async throws {
        try await withPage { stage, web in
            stage.following = true
            stage.hold(true)
            stage.setFrameSize(CGSize(width: 720, height: 700))
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            _ = try await Loaded.until(10) { web.frame.width < 1000 }
            let receiver = NSView(frame: CGRect(x: 20, y: 20, width: 480, height: 500))
            receiver.wantsLayer = true
            receiver.autoresizesSubviews = false
            stage.superview?.addSubview(receiver)
            stage.away = true
            receiver.addSubview(web)
            web.frame = receiver.bounds
            stage.hold(false)
            _ = try await web.takeSnapshot(configuration: nil)
            #expect(web.superview === receiver)
            #expect(web.frame == receiver.bounds)
            #expect(stage.benchGeometry()["following"] as? Bool == false)
            #expect(try await web.evaluateJavaScript("innerWidth") as? Double == 480)
            #expect(try await web.evaluateJavaScript("window.token") as? String == "same-document")
        }
    }
}
