import AppKit
import SwiftUI
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumViewportResizeTests {
    /// No helper is needed to prove the routing and backpressure: without a
    /// compositor receipt the first viewport must remain in flight. The
    /// real-engine film checks receipt delivery and final release.
    @Test(arguments: ["left", "right", "bottom"])
    func panelsUseTheSharedCoordinatorAndWaitForTheNativeCanvas(_ side: String) async throws {
        let room = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: room, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: room)
        content.wantsLayer = true
        window.contentView = content
        let stage = StageView(frame: CGRect(x: 8, y: 8, width: 1000, height: 700))
        stage.autoresizesSubviews = false
        content.addSubview(stage)
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        stage.show(page, of: tab.id)
        window.orderFront(nil)
        defer {
            page.removeFromSuperview()
            page.retire(call: false, pictureInPicture: false)
            tab.close()
            window.close()
        }
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        let before = page.frame.size
        let pace = Reshape.pace
        defer { Reshape.pace = pace }
        Reshape.pace = .arrive
        stage.following = true
        stage.hold(true)
        stage.frame = switch side {
        case "left": CGRect(x: 248, y: 8, width: 760, height: 700)
        case "bottom": CGRect(x: 8, y: 248, width: 1000, height: 460)
        default: CGRect(x: 8, y: 8, width: 680, height: 700)
        }
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        #expect(page.frame.size == before, "The panel's first transaction must not resize the page")
        #expect(stage.benchGeometry()["following"] as? Bool == true)
        _ = try await Loaded.until(2) { stage.benchGeometry()["viewportPending"] as? Bool == true }
        let pending = page.frame
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        #expect(page.frame == pending, "An unrelated layout cannot bypass the in-flight viewport")
        #expect(stage.isHeld)
        #expect(page.remoteID == nil, "Routing does not start a helper")
        // Lending the page must invalidate the pending callback and link.
        let receiver = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        receiver.autoresizesSubviews = false
        content.addSubview(receiver)
        stage.away = true
        receiver.addSubview(page)
        page.frame = receiver.bounds
        #expect(stage.benchGeometry()["following"] as? Bool == false)
        #expect(page.frame == receiver.bounds)
    }
}
