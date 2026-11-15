import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PageHolderTests {
    private func makeTab() -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return Tab(bench: true, configuration: configuration)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0,
                                                  width: content.frame.width, height: content.frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    private func expectSameRect(_ actual: NSRect, _ expected: NSRect) {
        #expect(abs(actual.minX - expected.minX) < 1e-6)
        #expect(abs(actual.minY - expected.minY) < 1e-6)
        #expect(abs(actual.width - expected.width) < 1e-6)
        #expect(abs(actual.height - expected.height) < 1e-6)
    }

    @Test(arguments: [false, true])
    func assigningTheCardFrameImmediatelyFillsItsViewport(usingPropertyAssignment: Bool) {
        let tab = makeTab()
        defer { tab.close() }
        let holder = PageHolder(tab: tab)
        holder.autoresizesSubviews = false
        let target = NSRect(x: 73, y: 41, width: 1100, height: 746)

        if usingPropertyAssignment {
            holder.frame = target
        } else {
            holder.setFrameOrigin(target.origin)
            holder.setFrameSize(target.size)
        }

        // The bridge can assign this frame before scheduling any layout.
        // Its offset in the host must not become an offset inside the card.
        #expect(holder.frame == target)
        #expect(tab.page.superview === holder)
        #expect(tab.page.frame == holder.bounds)
        #expect(tab.page.frame.origin == .zero)
        #expect(tab.page.frame.size == target.size)
    }

    @Test(arguments: [false, true])
    func assigningBoundsCoversTheCardsEntireCoordinateSpace(usingPropertyAssignment: Bool) {
        let tab = makeTab()
        defer { tab.close() }
        let holder = PageHolder(tab: tab)
        holder.autoresizesSubviews = false
        let target = NSRect(x: 17, y: 23, width: 1086, height: 724)

        if usingPropertyAssignment {
            holder.bounds = target
        } else {
            holder.setBoundsOrigin(target.origin)
            holder.setBoundsSize(target.size)
        }

        #expect(abs(holder.bounds.width - target.width) < 1e-6)
        #expect(abs(holder.bounds.height - target.height) < 1e-6)
        if usingPropertyAssignment {
            #expect(abs(holder.bounds.minX - target.minX) < 1e-6)
            #expect(abs(holder.bounds.minY - target.minY) < 1e-6)
        }
        #expect(tab.page.superview === holder)
        // Changing bounds size can scale its existing origin. The page
        // must cover that actual coordinate space, including its offset.
        expectSameRect(tab.page.frame, holder.bounds)
        expectSameRect(tab.page.convert(tab.page.bounds, to: holder), holder.bounds)
    }

    @Test func resizingTheRootHostDoesNotLeaveTheInitialViewportBehind() {
        let tab = makeTab()
        defer { tab.close() }
        let holder = PageHolder(tab: tab)
        holder.autoresizesSubviews = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 640))
        holder.frame = NSRect(x: 20, y: 20, width: 900, height: 600)
        holder.autoresizingMask = [.width, .height]
        host.addSubview(holder)

        // This is AppKit's synchronous resize of the content/hosting view.
        // A child layout pass has not happened when the first frame is drawn.
        host.setFrameSize(NSSize(width: 1120, height: 780))

        #expect(holder.frame == NSRect(x: 20, y: 20, width: 1080, height: 740))
        #expect(tab.page.frame == holder.bounds)
        #expect(tab.page.frame.size == NSSize(width: 1080, height: 740))
    }

    @Test func theWindowBackingsEntireCardIsAlsoTheLoadedPageViewport() async throws {
        let tab = makeTab()
        defer { tab.close() }
        let holder = PageHolder(tab: tab)
        holder.autoresizesSubviews = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860))
        holder.frame = NSRect(x: 31, y: 47, width: 1040, height: 730)
        content.addSubview(holder)
        let window = makeWindow(content: content)
        defer { window.orderOut(nil) }
        tab.page.navigate(html:"""
        <!doctype html><html><head><title>Viewport</title></head>
        <body style="margin:0; background:#2468ad; width:100vw; height:100vh"></body></html>
        """, base: URL(string: "https://holder.test/"))

        #expect(window.backingScaleFactor >= 1)
        for size in [NSSize(width: 1100, height: 746), NSSize(width: 680, height: 438)] {
            holder.setFrameSize(size)
            #expect(tab.page.frame == holder.bounds)
            let cardInWindow = holder.convert(holder.bounds, to: nil)
            let pageInWindow = tab.page.convert(tab.page.bounds, to: nil)
            let cardPixels = window.convertToBacking(cardInWindow)
            let pagePixels = window.convertToBacking(pageInWindow)
            #expect(pagePixels == cardPixels)
            #expect(abs(pagePixels.width - size.width * window.backingScaleFactor) < 0.001)
            #expect(abs(pagePixels.height - size.height * window.backingScaleFactor) < 0.001)

            var viewport: [Int]?
            for _ in 0..<200 {
                viewport = (try? await tab.page.run("document.title === 'Viewport' ? [innerWidth, innerHeight] : null")) as? [Int]
                if viewport == [Int(size.width), Int(size.height)], !tab.page.isLoading { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(viewport == [Int(size.width), Int(size.height)])
        }
    }

    @Test func theSourceCardCannotResizeOrReclaimAPageTransferredToTheStage() {
        let tab = makeTab()
        defer { tab.close() }
        let holder = PageHolder(tab: tab)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860))
        holder.frame = NSRect(x: 17, y: 29, width: 1040, height: 730)
        content.addSubview(holder)
        let window = makeWindow(content: content)
        defer { window.orderOut(nil) }
        let stage = StageView(frame: NSRect(x: 41, y: 53, width: 640, height: 420))
        content.addSubview(stage)
        let web = tab.page
        stage.show(web, of: tab.id)
        let receivingFrame = web.frame
        #expect(web.superview === stage)
        #expect(receivingFrame == stage.bounds)

        holder.frame = NSRect(x: 93, y: 71, width: 1170, height: 814)
        holder.setBoundsSize(NSSize(width: 980, height: 690))
        holder.layoutSubtreeIfNeeded()
        holder.removeFromSuperview()
        let anotherContent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let anotherWindow = makeWindow(content: anotherContent)
        defer { anotherWindow.orderOut(nil) }
        anotherContent.addSubview(holder)
        holder.layoutSubtreeIfNeeded()

        #expect(tab.builtPage === web)
        #expect(web.superview === stage)
        #expect(web.window === window)
        #expect(web.frame == receivingFrame)
        #expect(stage.shows == tab.id)
    }
}
