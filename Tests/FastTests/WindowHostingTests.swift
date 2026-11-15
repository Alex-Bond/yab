import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct WindowHostingTests {
    @Test func measuredPanelsKeepTheirIntrinsicSizeWithoutOwningTheWindow() {
        let host = NSHostingView(rootView: Color.clear.frame(width: 320, height: 180))
        host.sizingOptions = [.intrinsicContentSize]
        let measured = host.fittingSize
        let content = WindowHosting.measured(host)
        #expect(content !== host)
        #expect(content.isFlipped == host.isFlipped)
        #expect(host.fittingSize == measured)
        #expect(host.intrinsicContentSize == measured)
        content.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
        #expect(host.frame == content.bounds)
    }

    @Test func aControllerRootAlsoGivesUpWindowSizing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = NSHostingController(rootView: Color.clear.frame(minWidth: 900))
        window.contentViewController = controller
        WindowHosting.ownFrame(of: window)
        #expect(controller.sizingOptions.isEmpty)
    }

    @Test func fixedPanelHostDoesNotExportSizeConstraints() {
        let host = WindowHosting.host(Color.clear.frame(width: 320, height: 180))
        #expect(host.sizingOptions.isEmpty)
        let content = WindowHosting.content(Color.clear.frame(width: 320, height: 180))
        #expect(content.subviews.count == 1)
        #expect(content.subviews.first?.superview === content)
    }

    @Test func browserStillMeasuresItsFloorWithoutHostSizeProbes() async throws {
        let screen = try #require(TestScreen.screen)
        var measured: [CGSize] = []
        let host = WindowFloorLayout.host(WindowFloorLayout(measured: { measured.append($0) }) {
            Color.clear.frame(minWidth: 800, minHeight: 500)
        })
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20,
                                                  y: screen.visibleFrame.minY + 20,
                                                  width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.sizingOptions.isEmpty)
        #expect(measured.contains(CGSize(width: 800, height: 500)))
    }

    @Test func measuredPanelKeepsItsFrameWhileItsContentAnimates() async throws {
        let screen = try #require(TestScreen.screen)
        let grows = WindowFloorTests.Grows()
        let host = NSHostingView(rootView: WindowFloorTests.Rows(grows: grows, floor: false))
        host.sizingOptions = [.intrinsicContentSize]
        let window = WindowFloorTests.HeldWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                                width: 500, height: 380),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let least = NSSize(width: 320, height: 200)
        window.contentMinSize = least
        window.contentView = WindowHosting.measured(host)
        window.held = window.frame
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        window.asked = 0
        withAnimation(.linear(duration: 0.2)) { grows.big = true }
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.asked == 0)
        #expect(window.frame == window.held)
        #expect(window.contentMinSize == least)
        // Panels can still measure the new content for their own placement.
        #expect(host.fittingSize.width >= 700)
    }
}
