import AppKit
import QuartzCore
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PeekHandoffTests {
    @Test func keepingTransfersThePageWhileItsPictureIsStillGrowing() async throws {
        let browser = Browser(windowID: UUID())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        // Layer-backed now, as the app's are: its window's content is
        // SwiftUI's hosting view, and its stage is made so by WebStage
        // (`round`) before its first show. Left to AppKit, they get layers
        // at the window's next display, which the other suites in the N-Z
        // shard kept the main thread too busy for.
        content.wantsLayer = true
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let stage = StageView(frame: content.bounds)
        content.addSubview(stage)
        stage.wantsLayer = true
        stage.show(NSView(frame: stage.bounds), of: UUID())
        let peek = PeekView()
        peek.frame = content.bounds
        peek.browser = browser
        content.addSubview(peek)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(bench: true, configuration: configuration)
        browser.stages = [tab.id, nil]
        peek.present(tab, shy: false, instant: true)
        tab.page.navigate(html: "<body style='background:#2468ad'><h1>Peek</h1></body>",
                               base: URL(string: "https://peek.test/"))
        var loaded = false
        for _ in 0..<200 {
            loaded = (try? await tab.page.run("document.querySelector('h1')?.textContent")) as? String == "Peek"
            if loaded, !tab.page.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(loaded)

        var transfers = 0
        var growing = false
        var cover: NSView?
        // What the flight's layer held as the page landed, said if it wasn't growing.
        var held = ""
        let landed = {
            transfers += 1
            // Beside the window's content view, not in it, since ce1f341f:
            // inside SwiftUI's host its layer never reached the window.
            cover = (content.superview ?? content).subviews.first { $0.identifier?.rawValue == "peek-flight" }
            growing = cover?.layer?.sublayers?.first?.animation(forKey: "peek.bounds") != nil
            held = "cover: \(cover != nil), its layer: \(cover?.layer != nil), animations: \(cover?.layer?.sublayers?.map { $0.animationKeys() ?? [] } ?? [])"
            stage.show(tab.page, of: tab.id)
        }
        peek.keep(tab, landed: landed)
        peek.keep(tab, landed: landed)
        for _ in 0..<200 {
            if transfers > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transfers == 1)
        #expect(growing, "\(held)")
        #expect(tab.page.superview === stage)
        try #require(cover != nil)
        for _ in 0..<100 {
            if cover?.superview == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(cover?.superview == nil)
    }

    private func scene() -> (NSWindow, NSView, NSView, CALayer, WKWebView) {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        window.orderFront(nil)
        let holder = NSView(frame: NSRect(x: 50, y: 24, width: 600, height: 452))
        content.addSubview(holder)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: holder.bounds, configuration: configuration)
        holder.addSubview(web)
        let sky = NSView(frame: content.bounds)
        sky.wantsLayer = true
        content.addSubview(sky)
        let card = CALayer()
        card.frame = sky.bounds
        card.backgroundColor = NSColor.blue.cgColor
        sky.layer?.addSublayer(card)
        return (window, content, sky, card, web)
    }

    @Test func slowAttachmentDoesNotExposeTheOldPage() async throws {
        let (window, content, sky, card, web) = scene()
        defer { window.orderOut(nil) }
        let owner = UUID()
        PeekView.uncover(sky, card: card, page: web, owner: owner, window: window,
                         due: CACurrentMediaTime(), cancelled: { false })

        // SwiftUI has not attached the new page yet, even after the old
        // unconditional one-second timeout. Its picture must still cover it.
        try await Task.sleep(for: .milliseconds(1150))
        #expect(sky.superview === content)
        #expect(card.opacity == 1)
        #expect(card.animation(forKey: "peek.opacity") == nil)

        let stage = StageView(frame: content.bounds)
        content.addSubview(stage, positioned: .below, relativeTo: sky)
        stage.show(web, of: owner)
        stage.layoutSubtreeIfNeeded()
        #expect(web.superview === stage)
        #expect(web.frame.size == stage.bounds.size)
        for _ in 0..<100 {
            if sky.superview == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(sky.superview == nil)
        #expect(web.superview === stage)
    }

    @Test func anotherStageCannotReleaseThePicture() async throws {
        let (window, content, sky, card, web) = scene()
        defer { window.orderOut(nil) }
        let owner = UUID()
        let stage = StageView(frame: content.bounds)
        content.addSubview(stage, positioned: .below, relativeTo: sky)
        stage.show(web, of: UUID())
        var cancelled = false
        PeekView.uncover(sky, card: card, page: web, owner: owner, window: window,
                         due: CACurrentMediaTime(), cancelled: { cancelled })
        try await Task.sleep(for: .milliseconds(1150))
        #expect(sky.superview === content)
        #expect(card.opacity == 1)

        // Switching away during the transfer removes the cover instead
        // of leaving an opaque picture over the newly selected tab.
        cancelled = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(sky.superview == nil)
    }
}
