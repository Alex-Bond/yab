import WebKit

// WebKit's side of the page seam (PageEngine.swift): PageView, a WKWebView,
// is a PageHandle. Each call goes to the WebKit call Yab made before the
// seam, so nothing a page does changes with it.

extension PageWorld {
    // WebKit can discard an isolated world's state when its last wrapper
    // goes away. A name must keep the same world across separate calls.
    @MainActor private static var worlds: [String: WKContentWorld] = [:]

    /// WebKit's world of the same name, kept for later scripts in it.
    @MainActor var contentWorld: WKContentWorld {
        switch self {
        case .page: return .page
        case .client: return .defaultClient
        case .named(let name):
            if let world = Self.worlds[name] { return world }
            let world = WKContentWorld.world(name: name)
            Self.worlds[name] = world
            return world
        }
    }
}

extension PageFrame {
    init(_ info: WKFrameInfo) {
        self.init(isMain: info.isMainFrame, url: info.request.url, token: info, origin: PageOrigin(info.securityOrigin))
    }

    /// WebKit's own frame, for a page WebKit draws.
    var webKit: WKFrameInfo? { token as? WKFrameInfo }
}

extension PageShot {
    /// nil for WebKit's own defaults: the whole view, after updates.
    var configuration: WKSnapshotConfiguration? {
        guard rect != nil || width != nil || !afterUpdates else { return nil }
        let made = WKSnapshotConfiguration()
        if let rect { made.rect = rect }
        if let width { made.snapshotWidth = NSNumber(value: Double(width)) }
        made.afterScreenUpdates = afterUpdates
        return made
    }
}

extension PageView: PageHandle {
    var engine: PageEngineKind { .webKit }
    var committedURL: URL? { backForwardList.currentItem?.url }
    var historyEntry: PageHistoryEntry? {
        backForwardList.currentItem.map { PageHistoryEntry(url: $0.url, title: $0.title ?? "") }
    }

    var events: (any PageEvents)? {
        get { navigationEvents.listener }
        set {
            navigationEvents.listener = newValue
            if newValue != nil {
                navigationDelegate = navigationEvents
                uiDelegate = navigationEvents
            } else {
                if navigationDelegate === navigationEvents { navigationDelegate = nil }
                if uiDelegate === navigationEvents { uiDelegate = nil }
            }
        }
    }

    /// The adapter forwards remaining private callbacks to the legacy delegate.
    /// Its listener moves with the tab and is weak for both delegate roles.
    func installDelegates(_ delegate: (WKNavigationDelegate & WKUIDelegate)?) {
        events = delegate as? any PageEvents
        if events == nil { navigationDelegate = delegate }
        uiDelegate = events == nil ? delegate : navigationEvents
    }

    func navigate(to request: URLRequest) { load(request) }
    func navigate(html: String, base: URL?) { loadHTMLString(html, baseURL: base) }
    func reload(fromOrigin: Bool) {
        if fromOrigin { reloadFromOrigin() } else { reload() }
    }
    func navigateBack() { goBack() }
    func navigateForward() { goForward() }

    func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) {
        webKitSubframes { done($0.map(PageFrame.init)) }
    }

    func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) {
        takeSnapshot(with: shot.configuration) { image, error in
            MainActor.assumeIsolated { done(image, error) }
        }
    }

    func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let configuration = WKPDFConfiguration()
        if let rect { configuration.rect = rect }
        createPDF(configuration: configuration) { result in
            MainActor.assumeIsolated { done(result) }
        }
    }

    var contentProcess: pid_t? { Browser.process(of: self) }
    var gpuProcess: pid_t? { Browser.gpuProcess(of: self) }
    func setCameraCapture(_ state: PageMediaState) { setCameraCaptureState(state.webKit, completionHandler: nil) }
    func setMicrophoneCapture(_ state: PageMediaState) { setMicrophoneCaptureState(state.webKit, completionHandler: nil) }
    func stopDisplayCapture() { Tab.endScreen(of: self) }
    var captureStatus: PageCaptureStatus {
        PageCaptureStatus(camera: PageMediaState(cameraCaptureState), microphone: PageMediaState(microphoneCaptureState),
                          screen: PageMediaState(Tab.screenState(of: self)))
    }
}

extension PageHandle {
    /// The WebKit view under the seam, for what only WebKit has (its
    /// configuration, private calls, the inspector); nil for a page another
    /// engine draws. Every use is listed in docs/page-engine.md.
    var webKit: PageView? { self as? PageView }
}

// Raw frames remain available for separate WebKit surfaces and consumers
// whose script and selection APIs have not migrated yet.
extension WKWebView {
    /// The page's frames, the main one left out, as WebKit knows them, at
    /// most 40: empty where WebKit doesn't say.
    func webKitSubframes(_ done: @escaping @MainActor ([WKFrameInfo]) -> Void) {
        let name = NSSelectorFromString("_frames:")
        guard responds(to: name) else { done([]); return }
        let block: @convention(block) (AnyObject?) -> Void = { root in
            var infos: [WKFrameInfo] = []
            func walk(_ node: AnyObject, _ depth: Int) {
                guard depth < 8 else { return }
                if let info = node.value(forKey: "info") as? WKFrameInfo, !info.isMainFrame { infos.append(info) }
                for child in node.value(forKey: "childFrames") as? [AnyObject] ?? [] { walk(child, depth + 1) }
            }
            if let root { walk(root, 0) }
            let found = Array(infos.prefix(40))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
        perform(name, with: block)
    }
}

/// A frame of an agent's tab saying it is there (AgentPage.frameScript).
final class FrameRelay: NSObject, WKScriptMessageHandler {
    static let name = "yabAgentFrame"
    static let shared = FrameRelay()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let web = message.webView as? PageView, !message.frameInfo.isMainFrame else { return }
        let frame = AgentPage.Frame(info: PageFrame(message.frameInfo), href: body["href"] as? String ?? "",
                                    w: body["w"] as? Double ?? 0, h: body["h"] as? Double ?? 0)
        MainActor.assumeIsolated { AgentPage.heard(web, frame) }
    }
}

// Native event dispatch and WebKit's person/agent distinction stay here.
extension WKWebView {
    /// A mouse press and release at a point in the web view's CSS pixels;
    /// `flags` held with it (a test's ⌘-click on a link).
    func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool {
        guard let window = self.window else { return false }
        let zoom = self.pageZoom * self.magnification
        let local = NSPoint(x: x * zoom, y: self.isFlipped ? y * zoom : self.bounds.height - y * zoom)
        let at = self.convert(local, to: nil)
        let uptime = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: flags, timestamp: uptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: pressure
            )
        }
        if let moved = event(.mouseMoved, 0) { self.mouseMoved(with: moved) }
        guard let down = event(.leftMouseDown, 1), let up = event(.leftMouseUp, 0) else { return false }
        PageView.agentActing = true
        defer { PageView.agentActing = false }
        self.mouseDown(with: down)
        self.mouseUp(with: up)
        return true
    }

    /// The pointer brought to a point and left there: what opens on hover
    /// opens.
    func agentHover(x: Double, y: Double) -> Bool {
        guard let window = self.window else { return false }
        let zoom = self.pageZoom * self.magnification
        let local = NSPoint(x: x * zoom, y: self.isFlipped ? y * zoom : self.bounds.height - y * zoom)
        let at = self.convert(local, to: nil)
        guard let moved = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return false }
        PageView.agentActing = true
        defer { PageView.agentActing = false }
        agentPointer(moved)
        return true
    }

    /// A pointer move, where WebKit takes it: from the tracking area's
    /// owner, not the view (a move handed to the view goes nowhere).
    private func agentPointer(_ event: NSEvent) {
        let owners = self.trackingAreas.compactMap { $0.owner as? NSResponder }
        if let owner = owners.first(where: { $0 !== self }) ?? owners.first { owner.mouseMoved(with: event) } else { self.mouseMoved(with: event) }
    }

    /// A press at one point, the pointer carried to another in steps, and
    /// let go there: a drag as a hand makes it, which sortable lists,
    /// sliders and HTML drag and drop all hear. Spread over a quarter of a
    /// second, so a page that waits for movement sees some.
    func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) {
        guard let window = self.window else { done(false); return }
        let zoom = self.pageZoom * self.magnification
        func at(_ p: CGPoint) -> NSPoint {
            self.convert(NSPoint(x: p.x * zoom, y: self.isFlipped ? p.y * zoom : self.bounds.height - p.y * zoom), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ p: CGPoint, _ pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        let steps = 12
        func send(_ e: NSEvent?) {
            guard let e else { return }
            PageView.agentActing = true
            defer { PageView.agentActing = false }
            switch e.type {
            case .leftMouseDown: self.mouseDown(with: e)
            case .leftMouseUp: self.mouseUp(with: e)
            case .leftMouseDragged: self.mouseDragged(with: e)
            default: agentPointer(e)
            }
        }
        send(event(.mouseMoved, from, 0))
        send(event(.leftMouseDown, from, 1))
        func step(_ i: Int) {
            if i > steps {
                send(event(.leftMouseUp, to, 0))
                done(true)
                return
            }
            let t = Double(i) / Double(steps)
            send(event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { step(1) }
    }

    /// Words into whatever has focus, a field in another site's frame
    /// included, the way an input method puts them there: one insertion,
    /// not a key per letter.
    func insertAgentText(_ text: String) {
        self.window?.makeFirstResponder(self)
        PageView.agentActing = true
        defer { PageView.agentActing = false }
        self.insertText(text)
    }

    /// Strokes to a page in a window, as real key events.
    func sendAgentKeys(_ strokes: [PageKey]) {
        guard let window = self.window else { return }
        window.makeFirstResponder(self)
        for stroke in strokes {
            let flags = stroke.flags
            let characters = stroke.characters
            let plain = flags.contains(.shift) ? characters.uppercased() : characters
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: flags.contains(.command) ? characters : plain,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: stroke.code
                ) else { continue }
                PageView.agentActing = true
                defer { PageView.agentActing = false }
                if type == .keyDown {
                    // ⌘-chords go the way the menu bar would send them.
                    if flags.contains(.command), self.performKeyEquivalent(with: event) { continue }
                    self.keyDown(with: event)
                } else {
                    self.keyUp(with: event)
                }
            }
        }
    }
}

// Registration and separate WebKit fixtures still need concrete worlds.
// Ordinary agent scripts use PageWorld through PageHandle.
extension AgentPage {
    static var world: WKContentWorld { PageWorld.agent.contentWorld }
    static var evalWorld: WKContentWorld { PageWorld.agentEval.contentWorld }
}

extension WKWebView {
    /// Separate manager popups are still raw WebKit surfaces. Keep their
    /// native/script key path here until their lifecycle has a page handle.
    func webKitAgentPress(_ keys: String) -> String? {
        let strokes: [PageKey]
        switch AgentPage.strokes(keys) {
        case .success(let read): strokes = read
        case .failure(let trouble): return trouble.said
        }
        if window != nil { sendAgentKeys(strokes) }
        else { callAsyncJavaScript(AgentPage.keysScript, arguments: ["strokes": strokes.map(\.json)], in: nil, in: PageWorld.agent.contentWorld) { _ in } }
        return nil
    }
}

// Temporary configuration extension points for action policy. The browser
// receives only copied action values; these operations still depend on
// WebKit's stores, rule lists and internal-page script registration.
extension PageHandle {
    var webKitPolicyHeld: Bool {
        guard #available(macOS 15.4, *), let web = webKit else { return false }
        return ContentWarm.holds(web)
    }

    var webKitIsArtifact: Bool { webKit?.configuration.websiteDataStore === ArtifactPages.store }

    func webKitApplySiteAgent(for url: URL) -> Bool {
        guard let web = webKit else { return false }
        return SiteAgent.apply(web, for: url)
    }

    func webKitTuneShield(for host: String?, watching: Bool) {
        guard let web = webKit else { return }
        Shield.shared.tune(web.configuration.userContentController, for: host, watching: watching)
    }

    func webKitFitDiary(to url: URL) {
        guard let web = webKit else { return }
        DiaryPage.fit(web.configuration.userContentController, to: url)
    }

    func webKitSeedFrameGrant(_ url: URL, reply: @escaping @MainActor (Bool) -> Void) {
        guard let web = webKit else { reply(false); return }
        FrameGrants.seed(url, in: web.configuration.websiteDataStore) { reply(true) }
    }
}

extension PageMediaState {
    init(_ state: WKMediaCaptureState) {
        switch state {
        case .none: self = .none
        case .active: self = .active
        case .muted: self = .muted
        @unknown default: self = .none
        }
    }
}

// Script-only WebKit surfaces share the same endpoint without becoming tabs.
extension WKWebView: PageScriptTarget {
    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                  done: (@MainActor (Result<Any?, Error>) -> Void)?) {
        guard frame == nil || frame?.webKit?.webView === self else {
            done?(.failure(PageEngineError.foreignFrame))
            return
        }
        let info = frame?.webKit
        let world = world.contentWorld
        switch script {
        case .expression(let js) where gesture:
            evaluateJavaScript(js, in: info, in: world, completionHandler: done.map { done in
                { result in MainActor.assumeIsolated { done(result.map { $0 as Any? }) } }
            })
        case .function(let body, let arguments) where gesture:
            callAsyncJavaScript(body, arguments: arguments, in: info, in: world, completionHandler: done.map { done in
                { result in MainActor.assumeIsolated { done(result.map { $0 as Any? }) } }
            })
        case .expression(let js):
            evaluateQuietly(js, in: info, in: world, done: done)
        case .function(let body, let arguments):
            callAsyncQuietly(body, arguments: arguments, in: info, in: world, done: done)
        }
    }

    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? {
        try await withCheckedThrowingContinuation { answer in
            evaluate(script, in: world, frame: frame, gesture: gesture) { answer.resume(with: $0) }
        }
    }
}
