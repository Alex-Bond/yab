import AppKit
import Network
import SwiftUI
import Testing
import WebKit
@testable import Fast

/// Actual navigation and the already mounted shared Helm, with owned pages only.
@Suite(.serialized) @MainActor
struct PeekNavigationTests {
    private enum Failure: Error { case pageDidNotSettle }

    @MainActor private final class Pages {
        let site: LocalNetworkFixture
        let browser: Browser
        let source: Fast.Tab
        let peek: Fast.Tab
        let window: NSWindow

        init() throws {
            _ = NSApplication.shared
            site = try LocalNetworkFixture()
            for path in ["/source1", "/source2", "/peek1", "/peek2"] {
                site.route(path, .init("<!doctype html><title>\(path)</title><body>Owned \(path)</body>"))
            }
            browser = Browser(windowID: UUID())
            source = browser.open(URL(string: site.root + "/source1")!, foreground: true, shy: true)
            peek = Fast.Tab(shy: true, configuration: Web.configuration(shy: true, store: .nonPersistent()))
            browser.prepare(peek)
            browser.outside.append(peek)
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            window.contentView = content
            for tab in [source, peek] {
                tab.page.frame = NSRect(x: 0, y: 60, width: 700, height: 440)
                tab.page.webKit?.seenOffscreen = true
                content.addSubview(tab.page)
            }
            window.orderFront(nil)
        }

        func url(_ path: String) -> URL { URL(string: site.root + path)! }
        func count(_ path: String) -> Int { site.requests.filter { $0.path == path }.count }
        func showPeek() { browser.peekFrom = source.id; browser.peeking = peek }

        func open(_ tab: Fast.Tab, _ path: String) async throws {
            tab.go(to: url(path))
            try await settled(tab, path)
        }

        func settled(_ tab: Fast.Tab, _ path: String) async throws {
            for _ in 0..<500 {
                if tab.page.url == url(path), !tab.page.isLoading, !tab.loading,
                   (try? await tab.page.run("document.title")) as? String == path { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure.pageDidNotSettle
        }

        func end() {
            DoorList.shared.close(animated: false)
            browser.peeking = nil
            browser.peekFrom = nil
            for tab in browser.tabs + browser.outside { tab.builtPage?.stopLoading() }
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            window.close(); window.contentView = nil
            site.stop()
            if let id = browser.windowID {
                for space in browser.spaces {
                    let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
                }
            }
        }
    }

    private func until(_ ready: () -> Bool) async throws -> Bool {
        for _ in 0..<250 {
            if ready() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return ready()
    }

    private func mark(_ tab: Fast.Tab, _ value: String) async throws {
        _ = try await tab.page.call("window.ownedMarker = value; return true", arguments: ["value": value], in: .page)
    }

    private func marker(_ tab: Fast.Tab) async throws -> String {
        try await tab.page.run("window.ownedMarker || ''") as? String ?? ""
    }

    private func reloadMenu(_ pages: Pages, tab: Fast.Tab, own: Bool = false) throws {
        let menu = HelmMore.make(pages.browser, tab: tab, own: own)
        let item = try #require(menu.items.first)
        try #require(item.title == "Reload" && item.isEnabled)
        menu.performActionForItem(at: 0)
    }

    @Test func nativeReloadMenuTargetsPeek() async throws {
        let pages = try Pages(); defer { pages.end() }
        try await pages.settled(pages.source, "/source1")
        try await pages.open(pages.peek, "/peek1")
        pages.showPeek()
        try await mark(pages.source, "source-retained")
        try await mark(pages.peek, "peek-before-reload")
        let sourceLoads = pages.count("/source1"), peekLoads = pages.count("/peek1")
        try reloadMenu(pages, tab: pages.source)
        let reached = try await until { pages.count("/peek1") > peekLoads }
        try #require(reached, "Default Reload must reload the Peek document")
        try await pages.settled(pages.peek, "/peek1")
        #expect(pages.count("/source1") == sourceLoads)
        #expect(try await marker(pages.peek) == "")
        #expect(try await marker(pages.source) == "source-retained")
        #expect(pages.browser.active === pages.source)
    }

    @Test func backAndForwardTargetPeek() async throws {
        let pages = try Pages(); defer { pages.end() }
        try await pages.settled(pages.source, "/source1")
        try await pages.open(pages.source, "/source2")
        try await pages.open(pages.peek, "/peek1")
        try await pages.open(pages.peek, "/peek2")
        try #require(pages.source.canGoBack && pages.peek.canGoBack)
        pages.showPeek()
        pages.browser.back()
        let back = try await until { pages.peek.page.url == pages.url("/peek1") && !pages.peek.loading }
        try #require(back, "Default Back must navigate the Peek history")
        try await pages.settled(pages.peek, "/peek1")
        #expect(pages.source.page.url == pages.url("/source2"))
        try #require(pages.peek.canGoForward)
        pages.browser.forward()
        try await pages.settled(pages.peek, "/peek2")
        #expect(pages.source.page.url == pages.url("/source2"))
        #expect(pages.browser.active === pages.source)
    }

    @Test func explicitAndNoPeekTargetsStayOnSource() async throws {
        let pages = try Pages(); defer { pages.end() }
        try await pages.settled(pages.source, "/source1")
        try await pages.open(pages.source, "/source2")
        try await pages.open(pages.peek, "/peek1")
        try await pages.open(pages.peek, "/peek2")
        pages.showPeek()
        try await mark(pages.peek, "peek-retained")
        let peekLoads = pages.count("/peek2"), sourceLoads = pages.count("/source2")
        try reloadMenu(pages, tab: pages.source, own: true)
        let explicitReload = try await until { pages.count("/source2") > sourceLoads }
        try #require(explicitReload)
        try await pages.settled(pages.source, "/source2")
        #expect(pages.count("/peek2") == peekLoads)
        #expect(try await marker(pages.peek) == "peek-retained")
        pages.browser.back(pages.source)
        try await pages.settled(pages.source, "/source1")
        pages.browser.forward(pages.source)
        try await pages.settled(pages.source, "/source2")
        #expect(pages.peek.page.url == pages.url("/peek2"))
        pages.browser.peeking = nil
        pages.browser.peekFrom = nil
        let before = pages.count("/source2")
        try reloadMenu(pages, tab: pages.source)
        let ordinaryReload = try await until { pages.count("/source2") > before }
        try #require(ordinaryReload)
        try await pages.settled(pages.source, "/source2")
        pages.browser.back()
        try await pages.settled(pages.source, "/source1")
        pages.browser.forward()
        try await pages.settled(pages.source, "/source2")
        #expect(pages.browser.active === pages.source)
    }

    private func spots(_ root: NSView) -> [DoorHold.Spot] {
        (root as? DoorHold.Spot).map { [$0] } ?? root.subviews.flatMap { spots($0) }
    }

    @Test func mountedHelmFollowsPeekAcrossOpenAndClose() async throws {
        let pages = try Pages(); defer { pages.end() }
        try await pages.settled(pages.source, "/source1")
        try await pages.open(pages.peek, "/peek1")
        try await pages.open(pages.peek, "/peek2")
        let host = NSHostingView(rootView: Helm(browser: pages.browser, reads: false))
        host.frame = NSRect(x: 0, y: 0, width: 150, height: 40)
        try #require(pages.window.contentView).addSubview(host)
        let mounted = try await until { !spots(host).isEmpty }
        try #require(mounted)
        #expect(!spots(host).contains { $0.name == "arrow.left" && $0.open != nil })
        pages.showPeek()
        let follows = try await until { spots(host).contains { $0.name == "arrow.left" && $0.open != nil } }
        try #require(follows, "Mounted Helm must observe the Peek history")
        try #require(DoorHold.shared.benchOpen(in: pages.window))
        // Chromium reads its native history over IPC after the hold is
        // admitted. Require the actual Peek row, with the same deadline as
        // the mounted control, rather than inspecting the still-empty list.
        let populated = try await until { DoorList.shared.stops.contains { $0.title == "/peek1" } }
        #expect(populated)
        #expect(!DoorList.shared.stops.contains { $0.title == "/source1" })
        DoorList.shared.close(animated: false)
        let held = try HeldReply(); defer { held.end() }
        pages.peek.go(to: held.url)
        let loading = try await until { pages.peek.loadingShown }
        try #require(loading)
        let stopping = try await until { !spots(host).contains { $0.name == "arrow.clockwise" } }
        try #require(stopping, "Mounted Helm must show the Peek loading state")
        let stop = HelmMore.make(pages.browser, tab: pages.peek, own: false)
        try #require(stop.items.first?.title == "Stop")
        stop.performActionForItem(at: 0)
        let stopped = try await until { !pages.peek.loading && !pages.peek.page.isLoading }
        try #require(stopped)
        pages.browser.peeking = nil
        pages.browser.peekFrom = nil
        let restored = try await until {
            !spots(host).contains { $0.name == "arrow.left" && $0.open != nil }
                && spots(host).contains { $0.name == "arrow.clockwise" }
        }
        #expect(restored)
        #expect(pages.browser.active === pages.source)
    }
}

/// A real unfinished HTTP document keeps WebKit loading until Stop is used.
private final class HeldReply: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "peek-navigation-held")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/held")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 999999\r\nConnection: close\r\n\r\n<title>Held</title>"
                connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
    }
    func end() {
        listener.cancel()
        lock.lock(); let old = connections; connections.removeAll(); lock.unlock()
        old.forEach { $0.cancel() }
    }
}
