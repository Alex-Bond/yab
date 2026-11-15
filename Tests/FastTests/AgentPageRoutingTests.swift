import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentPageRoutingTests {
    /// The remote engine has its own producer window. The local view can be
    /// detached while trusted keyboard input must still go to that producer.
    private final class Page: NSView, PageHandle {
        let engine: PageEngineKind
        weak var events: (any PageEvents)?
        weak var stateEvents: (any PageStateEvents)?
        var url: URL? { nil }
        var committedURL: URL? { nil }
        var historyEntry: PageHistoryEntry? { nil }
        var title: String? { nil }
        var isLoading = false
        var estimatedProgress = 0.0
        var canGoBack = false
        var canGoForward = false
        var pageZoom: CGFloat = 1
        var magnification: CGFloat = 1
        var themeColor: NSColor?
        var lastInput: TimeInterval?
        var contentProcess: pid_t? { nil }
        var gpuProcess: pid_t? { nil }
        var captureStatus = PageCaptureStatus(camera: .none, microphone: .none, screen: .none)
        var scripts: [PageWorld] = []
        var text: [String] = []
        var keys: [PageKey] = []

        init(_ engine: PageEngineKind) { self.engine = engine; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func navigate(to request: URLRequest) { }
        func navigate(html: String, base: URL?) { }
        func reload(fromOrigin: Bool) { }
        func stopLoading() { }
        func navigateBack() { }
        func navigateForward() { }
        func retire(call: Bool, pictureInPicture: Bool) { }
        func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) { done([]) }
        func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) { done(nil, nil) }
        func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) { done(.success(Data())) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) { scripts.append(world); done?(.success(0)) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? {
            scripts.append(world); return 0
        }
        func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool { false }
        func agentHover(x: Double, y: Double) -> Bool { false }
        func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func insertAgentText(_ text: String) { self.text.append(text) }
        func sendAgentKeys(_ strokes: [PageKey]) { keys += strokes }
        func setCameraCapture(_ state: PageMediaState) { }
        func setMicrophoneCapture(_ state: PageMediaState) { }
        func stopDisplayCapture() { }
        func killContent() { }
    }

    @Test func detachedChromiumKeepsTrustedInputAndKeyBarrier() async {
        let page = Page(.chromium)
        #expect(page.window == nil)
        AgentPage.insert(page, "Ada 日本語")
        #expect(AgentPage.press(page, "Tab Meta+a Enter") == nil)
        #expect(page.text == ["Ada 日本語"])
        #expect(page.keys.map(\.key) == ["Tab", "a", "Enter"])
        #expect(page.scripts.isEmpty, "Detached Chromium must not synthesize DOM keyboard events")
        let seen = await withCheckedContinuation { continuation in
            AgentPage.keysSeen(page) { continuation.resume(returning: $0) }
        }
        #expect(seen == 0 && page.scripts == [.agent], "The send gate must observe native keys even without a host window")
    }

    @Test func detachedWebKitKeepsItsScriptFallback() {
        let page = Page(.webKit)
        AgentPage.insert(page, "Ada")
        #expect(AgentPage.press(page, "Tab Enter") == nil)
        #expect(page.text.isEmpty && page.keys.isEmpty)
        #expect(page.scripts == [.agent, .agent])
    }

    @Test(arguments: [false, true], ["https://download.example.test/file.csv", "httpx://download.example.test/file.csv", "file:///tmp/fixture.csv", ""])
    func rejectedChromiumURLDownloadPreservesReservation(earlier: Bool, url: String) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let bench = Bench()
        let page = Page(.chromium)
        let factory = PageEngineFactory(kinds: [.webKit, .chromium]) { _, _ in page }
        let tab = Tab(bench: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://download.example.test/page")!, title: "Download fixture")
        browser.lay([tab])
        let previous = (session: "earlier-download", until: Date().addingTimeInterval(60))
        if earlier { AgentFiles.shared.expecting[tab.id] = previous }
        defer {
            AgentFiles.shared.expecting[tab.id] = nil
            if let window = page.window, window.identifier == Bench.roomID { window.close() }
            tab.close()
            browser.lay([])
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        var reply: [String: Any] = [:]
        let request: [String: Any] = ["id": tab.id.uuidString, "session": "rejected-download",
                                      "url": url]
        bench.handleAgentDownload(AgentCall(bench: bench, verb: "agent-download", request: request,
                                            browser: browser, answer: { reply = $0 }))
        let expected = url.isEmpty ? "download needs a ref to click or a url"
            : url.hasPrefix("https://") ? "URL downloads are not available on this page engine yet"
            : "download needs an http(s) url"
        #expect(reply["error"] as? String == expected)
        let remaining = AgentFiles.shared.expecting[tab.id]
        #expect(remaining?.session == (earlier ? previous.session : nil))
        #expect(remaining?.until == (earlier ? previous.until : nil))
    }
}


@Suite(.serialized)
@MainActor
struct AgentPageRoutingTestsNativeDialog {
    @Test func nativeChromiumQuestionsStayWithAskCard() {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let chromium = Tab(bench: true, engine: .chromium, factory: factory)
        let webkit = Tab(bench: true, engine: .webKit)
        defer { chromium.close(); webkit.close() }
        #expect(AgentPage.answers(chromium))
        #expect(!AgentPage.answersDialog(chromium))
        #expect(AgentPage.answersDialog(webkit))
        let browser = Browser(windowID: UUID())
        browser.lay([webkit])
        let feed = AgentFeed.shared, previousBrowser = AgentFeed.shared.browser
        feed.browser = browser
        let task = Agents.shared.attach(name: "Dialog routing fixture")
        task.state = .running
        webkit.agent = task.id
        defer {
            feed.handBack(webkit)
            feed.browser = previousBrowser
            task.state = .attached
            Agents.shared.detach(task.id)
            browser.lay([]); browser.letGo()
        }
        feed.drive(webkit)
        #expect(feed.driving.contains(webkit.id))
        #expect(!AgentPage.answersDialog(webkit))
    }
}
