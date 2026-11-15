import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct TaskLineDismissTests {
    private func fixture(_ body: (Browser, Fast.Tab) async throws -> Void) async throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let oldBrowser = Agents.shared.browser
        let oldReady = Agents.assumedInTests, oldConnected = Agents.connectedInTests
        let oldAI = browser.prefs.aiUse, oldPlace = browser.prefs.askOpens
        Agents.shared.browser = browser
        Agents.assumedInTests = false
        Agents.connectedInTests = true
        browser.prefs.aiUse = .on
        browser.prefs.askOpens = .line
        let tab = Tab(bench: true, engine: .webKit)
        tab.restore(url: URL(string: "https://cmdj.example.test/")!, title: "Page")
        browser.lay([tab])
        browser.activeID = tab.id
        defer {
            TaskLine.shared.close()
            browser.prefs.aiUse = oldAI
            browser.prefs.askOpens = oldPlace
            Agents.shared.browser = oldBrowser
            Agents.assumedInTests = oldReady
            Agents.connectedInTests = oldConnected
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.letGo()
        }
        try await body(browser, tab)
    }

    private func key(_ code: UInt16 = 53, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code))
    }

    @Test func escapeUsesTheComposedSelectionRouteAndCancelsTheLocalAnswer() async throws {
        try await fixture { browser, tab in
            let line = TaskLine.shared
            line.open(on: tab)
            try #require(line.tab == tab.id)
            #expect(browser.selectionCommands.stage == .closed)
            #expect(!browser.selectionCommands.take(try key(flags: .command), on: tab))
            #expect(!browser.selectionCommands.take(try key(), on: Tab(bench: true)))
            #expect(!browser.selectionCommands.take(try key(36), on: tab))
            #expect(line.tab == tab.id)
            line.words = "What is here?"
            line.askHere(on: tab)
            #expect(line.answering)
            #expect(browser.selectionCommands.take(try key(), on: tab))
            #expect(line.tab == nil && !line.answering && line.answer.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            #expect(line.tab == nil && line.answer.isEmpty)
            #expect(!browser.selectionCommands.take(try key(), on: tab))
            line.open(on: tab)
            #expect(browser.selectionCommands.take(try key(), on: tab))
            #expect(line.tab == nil)
        }
    }

    /// Keep real app dispatch and the mounted line's zones without entering
    /// a text control's nested mouse-tracking loop from the test runner.
    /// Actual page/control interaction is covered by the ready-app probe.
    private final class ClickSurface: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    @Test func actualLineKeepsInsideClicksAndDismissesOutsideInItsOwnWindow() async throws {
        try await fixture { _, tab in
            let line = TaskLine.shared
            let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 900, height: 650),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let other = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 100, height: 100),
                                 styleMask: .borderless, backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close(); other.close() }
            let root = ClickSurface(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
            window.contentView = root
            other.contentView = ClickSurface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let page = tab.page
            page.frame = root.bounds
            root.addSubview(page)
            line.open(on: tab)
            let host = NSHostingView(rootView: TaskLineView(tab: tab))
            host.frame = CGRect(x: 180, y: 20, width: 480, height: 220)
            root.addSubview(host)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            @MainActor func zones(_ view: NSView) -> [NSView] {
                (view is ClickZone.Zone ? [view] : []) + view.subviews.flatMap { zones($0) }
            }
            let zone = try #require(zones(host).first { $0.bounds.width >= 400 })
            let inside = zone.convert(CGPoint(x: zone.bounds.midX, y: zone.bounds.midY), to: nil)
            @MainActor func click(_ point: CGPoint, in target: NSWindow) throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: target.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                }
            }
            try click(inside, in: window)
            try await Task.sleep(for: .milliseconds(50))
            #expect(line.tab == tab.id)
            try click(CGPoint(x: 10, y: 10), in: other)
            try await Task.sleep(for: .milliseconds(50))
            #expect(line.tab == tab.id)
            line.words = "What is here?"
            line.askHere(on: tab)
            try click(CGPoint(x: 800, y: 600), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(line.tab == nil && !line.answering && line.answer.isEmpty)
        }
    }
}
