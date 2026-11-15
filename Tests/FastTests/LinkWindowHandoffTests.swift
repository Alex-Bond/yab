import AppKit
import QuartzCore
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct LinkWindowHandoffTests {
    @Test func transferringTheLoadedMiniPageImmediatelyRemovesItsBodyBackdrop() async throws {
        _ = NSApplication.shared
        try #require(BrowserWindows.shared.activeWindow == nil)
        let previousWindow = Links.window
        let windowID = UUID()
        let browser = Browser(windowID: windowID)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                             styleMask: [.titled], backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        shell.contentView = content
        let stage = StageView(frame: content.bounds)
        content.addSubview(stage)
        shell.orderFront(nil)
        Links.window = shell
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            browser.letGo()
            shell.close()
            shell.contentView = nil
            Links.window = previousWindow
            for space in browser.spaces {
                let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString)\(suffix).json"))
            }
        }
        try #require(Links.window === shell)

        let tab = browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        mini = link
        try #require(link.window.isVisible)
        let holder = try #require(page.superview as? PageHolder)
        let html = """
        <!doctype html><title>Mini handoff</title>
        <body style="margin:0;background:#2468ad"><input id="field" value="original"></body>
        """
        let url = try #require(URL(string: "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()))
        page.navigate(to: URLRequest(url: url))
        var loaded = false
        for _ in 0..<200 {
            loaded = (try? await page.run("document.title")) as? String == "Mini handoff"
            if loaded, !page.isLoading, !tab.loading, !tab.isBlank { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(loaded && !page.isLoading && !tab.loading && !tab.isBlank)
        try #require(tab.failure == nil)
        _ = try await page.run("document.getElementById('field').value='edited';window.handoffMarker='retained';true")
        try #require(BrowserWindows.shared.activeWindow == nil)
        try #require(Links.window === shell)

        let miniContent = try #require(link.window.contentView)
        let root = try #require(miniContent.layer)
        // The fixture begins as a real, painted window. A transparent
        // window from the outset would not prove that keeping hides it.
        #expect(root.opacity == 1)
        #expect(link.window.backgroundColor.alphaComponent > 0)
        #expect(link.window.hasShadow)
        #expect(!link.window.ignoresMouseEvents)
        link.keep()
        // Keeping now hides the whole source window immediately. The old
        // bar-only mask belonged to the removed page-flight animation.
        #expect(root.opacity == 0)
        #expect(root.animation(forKey: "opacity") == nil)
        #expect(link.window.backgroundColor.alphaComponent == 0)
        #expect(!link.window.hasShadow)
        #expect(link.window.ignoresMouseEvents)
        for _ in 0..<200 {
            if browser.active === tab { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(browser.active === tab)
        try #require(page.superview === holder)
        try #require(link.window.isVisible)
        // No run-loop turn separates removal from inspection. The source
        // body must disappear when WebKit moves, before polling can close it.
        stage.show(page, of: tab.id)
        #expect(tab.builtPage === page)
        #expect(page.superview === stage)
        #expect(page.frame == stage.bounds)
        #expect(root.opacity == 0)
        #expect(link.window.backgroundColor.alphaComponent == 0)
        #expect(!link.window.hasShadow)
        #expect(link.window.isVisible)

        let state = try await page.run("[document.getElementById('field').value,window.handoffMarker]") as? [String]
        #expect(state == ["edited", "retained"])
        #expect(tab.builtPage === page)
        #expect(page.superview === stage)
        #expect(browser.outside.isEmpty)
    }

    @Test(arguments: [false, true])
    func keepingABlankSmallWindowClosesItWithoutWaitingForAWebStage(usingAnotherStore: Bool) async throws {
        _ = NSApplication.shared
        // Links.window falls back to its own weak reference only without a
        // registered browser window. Never bring an unrelated fixture forward.
        try #require(BrowserWindows.shared.activeWindow == nil)
        let previousWindow = Links.window
        let windowID = UUID()
        let browser = Browser(windowID: windowID)
        let shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                             styleMask: [.titled], backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        // A blank selection shows the address shell, with no WebKit stage
        // available to deliver an attachment or presentation callback.
        shell.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        shell.orderFront(nil)
        Links.window = shell
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            browser.letGo()
            shell.close()
            shell.contentView = nil
            Links.window = previousWindow
            for space in browser.spaces {
                let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString)\(suffix).json"))
            }
        }
        try #require(Links.window === shell)

        let tab: Tab
        if usingAnotherStore {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // This branch exercises a native WK cookie-store mismatch.
            tab = Tab(bench: true, configuration: configuration, factory: .webKitOnly)
        } else {
            tab = browser.blankTab()
        }
        browser.prepare(tab)
        browser.outside.append(tab)
        try #require(tab.isBlank)
        try #require(browser.signsInAgain(tab, in: browser.spaceID) == usingAnotherStore)
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        mini = link
        try #require(link.window.isVisible)
        // Let the normal first-frame prewarming run before keeping it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        try #require(BrowserWindows.shared.activeWindow == nil)
        try #require(Links.window === shell)

        link.keep()
        // Cleanup must happen immediately: a blank browser never gives this
        // page a StageView, so waiting for it would poll indefinitely.
        #expect(!link.window.isVisible)
        #expect(LinkWindow.owning(link.window) == nil)
        #expect(LinkWindow.owning(page: page) == nil)
        #expect(browser.outside.isEmpty)
        let selected = try #require(browser.active)
        #expect(selected.isBlank)
        #expect(!selected.gone)
        #expect(browser.askingNew)
        #expect(browser.tabs.filter { $0 === selected }.count == 1)
        #expect((selected === tab) == !usingAnotherStore)
        #expect(tab.gone == usingAnotherStore)
        #expect(!(selected.builtPage?.superview is StageView))

        link.keep()
        try await Task.sleep(for: .milliseconds(50))
        #expect(browser.active === selected)
        #expect(browser.tabs.filter { $0 === selected }.count == 1)
        #expect(!selected.gone)
        #expect(browser.outside.isEmpty)
        #expect(!link.window.isVisible)
    }

    @Test func fullScreenKeyIsControlCommandFOnly() {
        #expect(LinkWindow.fullScreenKey(code: 3, flags: [.control, .command]))
        #expect(LinkWindow.fullScreenKey(code: 3, flags: [.control, .command, .function]))
        #expect(!LinkWindow.fullScreenKey(code: 3, flags: [.command]))
        #expect(!LinkWindow.fullScreenKey(code: 3, flags: [.control, .command, .shift]))
        #expect(!LinkWindow.fullScreenKey(code: 2, flags: [.control, .command]))
    }

    /// Full screen asked of a small window, by its green light, the View
    /// menu or ⌃⌘F, moves its page into the browser's tabs (#1099), the
    /// very page, and never makes the small window full screen.
    @Test(arguments: ["button", "menu", "key"])
    func fullScreenMovesTheSmallWindowsPageIntoTheTabs(via: String) async throws {
        _ = NSApplication.shared
        try #require(BrowserWindows.shared.activeWindow == nil)
        let previousWindow = Links.window
        let windowID = UUID()
        let browser = Browser(windowID: windowID)
        let shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                             styleMask: [.titled], backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        shell.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        shell.orderFront(nil)
        Links.window = shell
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            browser.letGo()
            shell.close()
            shell.contentView = nil
            Links.window = previousWindow
            for space in browser.spaces {
                let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString)\(suffix).json"))
            }
        }
        let tab = browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        mini = link
        try #require(link.window.isVisible)
        #expect(link.window.collectionBehavior.contains(.fullScreenPrimary))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        switch via {
        case "button":
            let green = try #require(LightsRow.zoomButton(in: link.window))
            green.performClick(nil)
        case "menu":
            NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: link.window, from: nil)
        default:
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: 0, windowNumber: link.window.windowNumber, context: nil,
                characters: "\u{6}", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            #expect(link.take(key))
        }

        #expect(!link.window.styleMask.contains(.fullScreen))
        #expect(!link.window.isVisible)
        #expect(LinkWindow.owning(page: page) == nil)
        #expect(browser.outside.isEmpty)
        #expect(browser.active === tab)
        #expect(browser.tabs.filter { $0 === tab }.count == 1)
        #expect(tab.page === page)
    }
}
