import AppKit
import Testing
import WebKit
@testable import Fast

/// The small window's back, forward and reload (feedback #74): the
/// browser's own doors beside its lights, and its keys going through them,
/// counted on the window and never on the browser behind it. In the
/// handoff suite, serialized with it: both stand a shell in for Links.window.
extension LinkWindowHandoffTests {
    @Test func blankPageCountsNothing() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let tab = browser.blankTab()
        let steer = HelmSteer()
        steer.back(tab)
        steer.forward(tab)
        steer.reload(tab)
        #expect(steer.backs == 0)
        #expect(steer.forwards == 0)
        #expect(steer.reloads == 0)
    }

    @Test func keysAndDoorsActOnTheSmallWindowsPageOnly() async throws {
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
            DoorList.shared.close(animated: false)
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
        // Off every screen: the doors are laid out all the same.
        link.window.setFrameOrigin(NSPoint(x: -30000, y: 0))

        func settle(on title: String) async throws {
            // Up to 20 s: 3 s was not enough beside a whole test run.
            var there = false, seen: Any?, asks = 0
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                seen = try? await page.run("document.title")
                asks += 1
                there = seen as? String == title
                if there, !page.isLoading, !tab.loading { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            var note = "waiting for \(title): the title \(String(describing: seen)) after \(asks) asks"
            note += ", at \(page.url?.absoluteString ?? "none"), back \(page.canGoBack), forward \(page.canGoForward)"
            note += ", loading \(page.isLoading)/\(tab.loading)"
            note += "; the tab's page \(tab.builtPage === page ? "this one" : "another"), deaf \(tab.deaf != nil)"
            note += ", doors \(link.steer.backs)/\(link.steer.forwards)/\(link.steer.reloads)"
            note += ", small window \(LinkWindow.owning(page: page) === link ? "open" : "gone"), key \(NSApp.keyWindow === link.window)"
            note += "; steps asked again \(tab.stepsAgain), last turns \(tab.stepTrace)"
            note += "; its process \(page.contentProcess.map(String.init) ?? "none"), failure \(tab.failure ?? "none")"
            try #require(there && !page.isLoading && !tab.loading, Comment(rawValue: note))
        }
        func open(_ title: String) async throws {
            let html = "<!doctype html><title>\(title)</title><body>\(title)</body>"
            let url = try #require(URL(string: "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()))
            page.navigate(to: URLRequest(url: url))
            try await settle(on: title)
        }
        func press(_ code: UInt16, _ character: String) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: link.window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            return link.take(event)
        }

        try await open("First")
        try await open("Second")
        for _ in 0..<100 where !tab.canGoBack { try await Task.sleep(for: .milliseconds(10)) }
        try #require(tab.canGoBack && !tab.canGoForward)
        let (backs, forwards, reloads) = (browser.backs, browser.forwards, browser.reloads)

        // Held, back lists the page behind it, in this window.
        link.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(DoorHold.shared.benchOpen(in: link.window))
        DoorList.shared.close(animated: false)

        // ⌘[ and ⌘]: the page goes, and these doors count it.
        #expect(try press(33, "["))
        try await settle(on: "First")
        #expect(link.steer.backs == 1)
        for _ in 0..<100 where !tab.canGoForward { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tab.canGoForward)
        #expect(try press(30, "]"))
        try await settle(on: "Second")
        #expect(link.steer.forwards == 1)
        // ⌘R the same, and ⌘. is the page's stop, not the browser's window.
        #expect(try press(15, "r"))
        #expect(link.steer.reloads == 1)
        try await settle(on: "Second")
        #expect(try press(47, "."))

        // The browser behind never moved: its doors keep still.
        #expect(browser.backs == backs)
        #expect(browser.forwards == forwards)
        #expect(browser.reloads == reloads)
    }
}
