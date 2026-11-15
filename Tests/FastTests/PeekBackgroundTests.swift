import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct PeekBackgroundTests {
    @MainActor private final class Scene {
        let browser = Browser(windowID: UUID())
        let front = Tab(shy: true)
        let source = Tab(shy: true)
        let window: NSWindow
        let view = PeekView()

        init(mounted: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            front.restore(url: URL(string: "about:blank")!, title: "Current tab")
            source.restore(url: URL(string: "about:blank")!, title: "Background source")
            browser.lay([front, source])
            browser.activeID = front.id
            if mounted {
                window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
                view.frame = window.contentView!.bounds
                window.contentView!.addSubview(view)
                view.browser = browser
                browser.peekView = view
            }
        }

        func end() {
            browser.hidePeek()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            window.close()
            window.contentView = nil
        }
    }

    @Test func backgroundPeekWaitsForItsSourceAndFollowsTabSwitches() throws {
        let scene = Scene()
        defer { scene.end() }
        let browser = scene.browser
        browser.peek(URL(string: "about:blank")!, from: scene.source)
        let waiting = try #require(scene.source.peek)
        #expect(browser.activeID == scene.front.id)
        #expect(browser.peeking == nil)
        #expect(browser.peekFrom == nil)
        #expect(browser.outside.contains { $0 === waiting })

        browser.activeID = scene.source.id
        #expect(browser.peeking === waiting)
        #expect(browser.peekFrom == scene.source.id)
        browser.activeID = scene.front.id
        #expect(browser.peeking == nil)
        #expect(scene.source.peek === waiting)
        browser.activeID = scene.source.id
        #expect(browser.peeking === waiting)
    }

    @Test func backgroundPeekDoesNotReplaceTheCurrentTabsPeek() throws {
        let scene = Scene()
        defer { scene.end() }
        let browser = scene.browser
        browser.peek(URL(string: "about:blank")!, from: scene.front)
        let shown = try #require(browser.peeking)
        browser.peek(URL(string: "about:blank")!, from: scene.source)
        let waiting = try #require(scene.source.peek)
        #expect(browser.activeID == scene.front.id)
        #expect(browser.peeking === shown)
        #expect(browser.peekFrom == scene.front.id)
        #expect(scene.front.peek === shown)
        #expect(waiting !== shown)
    }

    @Test func backgroundPeekWithoutAMountedSurfaceDoesNotSelectANewTab() throws {
        let scene = Scene(mounted: false)
        defer { scene.end() }
        scene.browser.peek(URL(string: "about:blank")!, from: scene.source)
        let waiting = try #require(scene.source.peek)
        #expect(scene.browser.activeID == scene.front.id)
        #expect(scene.browser.tabs.count == 2)
        #expect(scene.browser.peeking == nil)
        #expect(scene.browser.outside.contains { $0 === waiting })
    }
}
