import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct PageTransferOwnershipTests {
    @Test func departingStageCannotReclaimATransferredPageOnLayout() {
        _ = NSApplication.shared
        let source = Browser(windowID: UUID()), destination = Browser(windowID: UUID())
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: CGRect(x: -10000, y: 100, width: 800, height: 600),
                     styleMask: .borderless, backing: .buffered, defer: false)
        }
        let stages = windows.map { window -> StageView in
            window.isReleasedWhenClosed = false
            let stage = StageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = stage
            return stage
        }
        let tab = Tab(configuration: Web.configuration(extensions: false), factory: .webKitOnly)
        source.prepare(tab)
        source.lay([tab])
        source.activeID = tab.id
        let page = tab.page
        stages[0].show(page, of: tab.id)
        source.moveOut(tab)
        destination.moveIn(tab)
        stages[1].show(page, of: tab.id)
        // The source still gets layouts while SwiftUI removes its old
        // page host. It must no longer claim the destination's page.
        stages[0].layout()
        #expect(page.superview === stages[1])
        #expect(page.window === windows[1])
        #expect(stages[0].shows == nil)
        source.letGo(); destination.letGo()
        windows.forEach { $0.close() }
    }

    @Test func aLateSourceUpdateCannotReclaimTheTransferredPage() {
        _ = NSApplication.shared
        let source = Browser(windowID: UUID()), destination = Browser(windowID: UUID())
        let browsers = [source, destination]
        let windows = browsers.map { browser -> NSWindow in
            let window = NSWindow(contentRect: CGRect(x: -10000, y: 100, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            BrowserWindows.shared.register(window, for: browser)
            return window
        }
        let stages = windows.map { window -> StageView in
            let stage = StageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = stage
            return stage
        }
        let tab = Tab(configuration: Web.configuration(extensions: false), factory: .webKitOnly)
        source.prepare(tab)
        source.lay([tab])
        source.activeID = tab.id
        let page = tab.page
        stages[0].show(page, of: tab.id)
        source.moveOut(tab)
        destination.moveIn(tab)
        stages[1].show(page, of: tab.id)
        // SwiftUI can finish an update created before moveOut. The same
        // tab id and NSView are no longer a claim for the old window.
        stages[0].show(page, of: tab.id)
        stages[0].layout()
        #expect(page.superview === stages[1])
        #expect(page.window === windows[1])
        #expect(stages[0].shows == nil)
        windows.forEach { $0.close() }
    }

    @Test func arrivalUsesTheSelectionLifecycleToDismissTheField() {
        _ = NSApplication.shared
        let destination = Browser(windowID: UUID())
        let tab = Tab(configuration: Web.configuration(extensions: false), factory: .webKitOnly)
        tab.restore(url: URL(string: "http://127.0.0.1:9/transfer")!, title: "Transferred page")
        destination.editing = true
        #expect(destination.editing)
        destination.moveIn(tab)
        #expect(destination.active === tab)
        #expect(!destination.editing)
        destination.letGo()
    }

    @Test func backgroundArrivalKeepsTheCurrentSelectionAndField() {
        _ = NSApplication.shared
        let destination = Browser(windowID: UUID())
        let current = Tab(), incoming = Tab()
        current.restore(url: URL(string: "http://127.0.0.1:9/current")!, title: "Current")
        incoming.restore(url: URL(string: "http://127.0.0.1:9/incoming")!, title: "Incoming")
        destination.prepare(current)
        destination.lay([current])
        destination.activeID = current.id
        destination.editing = true
        destination.moveIn(incoming, selecting: false)
        #expect(destination.active === current)
        #expect(destination.editing)
        #expect(incoming.builtPage == nil)
        destination.letGo()
    }
}
