import AppKit
import Testing
@testable import Fast

/// Drive the real Browser policy/start entry points with recording engines.
/// The removed eight-second watchdog used to stop and replay the WebKit GET.
@MainActor @Suite(.serialized)
struct QuietLoadEngineTests {
    private final class Page: NSView, PageHandle {
        let engine: PageEngineKind
        weak var events: (any PageEvents)?
        weak var stateEvents: (any PageStateEvents)?
        var url: URL?
        var committedURL: URL? { historyEntry?.url }
        var historyEntry: PageHistoryEntry?
        var title: String?
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
        var requests: [URLRequest] = []
        var retired = false
        var stops = 0
        var reloads = 0
        var backs = 0
        var forwards = 0

        init(_ kind: PageEngineKind) { engine = kind; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func emit(_ state: PageStateChange) { stateEvents?.page(self, changed: state) }
        func navigate(to request: URLRequest) { requests.append(request) }
        func navigate(html: String, base: URL?) { }
        func reload(fromOrigin: Bool) { reloads += 1 }
        func stopLoading() { stops += 1 }
        func navigateBack() { backs += 1 }
        func navigateForward() { forwards += 1 }
        func retire(call: Bool, pictureInPicture: Bool) {
            retired = true
            stateEvents = nil
            events = nil
            removeFromSuperview()
        }
        func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) { done([]) }
        func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) { done(nil, PageShotFailed()) }
        func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) { done(.failure(PageShotFailed())) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) { done?(.success(nil)) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? { nil }
        func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool { false }
        func agentHover(x: Double, y: Double) -> Bool { false }
        func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func insertAgentText(_ text: String) { }
        func sendAgentKeys(_ strokes: [PageKey]) { }
        func setCameraCapture(_ state: PageMediaState) { }
        func setMicrophoneCapture(_ state: PageMediaState) { }
        func stopDisplayCapture() { }
        func killContent() { }
    }

    @Test func silentNavigationsAreNotStoppedOrReplayedAfterEightSeconds() async throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        // A public literal avoids DNS and local-network policy probes.
        let url = URL(string: "https://1.1.1.1/quiet-load-fixture")!
        let pages = [Page(.chromium), Page(.webKit)]
        let action = PageAction(request: URLRequest(url: url), kind: .other, targetIsMainFrame: true,
                                source: nil, modifierFlags: [], buttonNumber: 0,
                                shouldPerformDownload: false, userInitiated: true)
        defer {
            for page in pages {
                browser.page(page, navigation: .failed(nil, NSError(domain: "fixture", code: 1), provisional: true))
            }
        }
        for page in pages {
            page.url = url; page.isLoading = true
            var replied = false, allowed = false
            browser.page(page, decide: action) { policy in replied = true; allowed = policy == .allow }
            #expect(replied && allowed)
            browser.page(page, navigation: .started(PageNavigation()))
        }
        try await Task.sleep(for: .seconds(8.5))
        for page in pages {
            #expect(page.requests.isEmpty)
            #expect(page.stops == 0)
            #expect(page.reloads == 0)
            #expect(page.isLoading)
        }
    }
}
