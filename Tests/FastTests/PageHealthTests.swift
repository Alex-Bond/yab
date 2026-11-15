import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageHealthTests {
    private final class Listener: NSObject, PageEvents {
        var finished = false
        var responsiveness: [Bool] = []
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .finished = event { finished = true }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, responsive: Bool) { responsiveness.append(responsive) }
    }

    @Test func processAndCaptureReadsMatchTheEngineAndTheProbeHasNoGesture() async throws {
        let listener = Listener(), view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        page.events = listener
        defer { page.stopLoading(); page.events = nil }
        page.navigate(html: "<title>Page health</title>", base: URL(string: "https://seam.invalid"))
        for _ in 0..<300 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        let pid = try #require(page.contentProcess)
        #expect(pid == Browser.process(of: view) && PageProcessLife.started(pid) != nil)
        #expect(page.gpuProcess == Browser.gpuProcess(of: view))
        #expect(page.captureStatus == PageCaptureStatus(camera: .none, microphone: .none, screen: .none))
        #expect(try await page.run("1", gesture: false) as? Int == 1)
        #expect(try await page.run("navigator.userActivation.isActive", gesture: false) as? Bool == false)
        for state in [WKMediaCaptureState.none, .active, .muted] {
            let status = PageCaptureStatus(camera: PageMediaState(state), microphone: PageMediaState(state), screen: PageMediaState(state))
            #expect(try JSONDecoder().decode(PageCaptureStatus.self, from: JSONEncoder().encode(status)) == status)
        }
        #expect(PageMediaState(WKMediaCaptureState.active) == .active)
        #expect(PageMediaState(WKMediaCaptureState.muted) == .muted)
    }

    @Test func responsivenessUsesTheCurrentWeakListenerAndBrowserRecoversItsTab() async throws {
        let browser = Browser(windowID: UUID()), tab = Tab(shy: true, factory: .webKitOnly)
        // This test invokes WK's private delegate adapter by hand. Its
        // fixture must remain WebKit even in a forced-Chromium test run.
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#health")!)
        defer { browser.close(tab) }
        let view = try #require(tab.webKitOnly("Native WebKit responsiveness fixture")), first = Listener(), next = Listener()
        for _ in 0..<300 where view.contentProcess == nil { try await Task.sleep(for: .milliseconds(20)) }
        _ = try #require(view.contentProcess)
        view.events = first
        view.navigationEvents.webProcessDidBecomeUnresponsive(view)
        view.events = next
        view.navigationEvents.webProcessDidBecomeResponsive(view)
        #expect(first.responsiveness == [false] && next.responsiveness == [true])
        view.events = browser
        view.navigationEvents.webProcessDidBecomeUnresponsive(view)
        #expect(tab.deaf != nil)
        view.navigationEvents.webProcessDidBecomeResponsive(view)
        #expect(tab.deaf == nil && !tab.deafAsked)
        view.events = nil
        view.navigationEvents.webProcessDidBecomeUnresponsive(view)
        #expect(tab.deaf == nil && next.responsiveness == [true])
    }

    @Test func guardedTerminationRefusesADifferentProcessLifetime() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier, born = try #require(PageProcessLife.started(pid))
        #expect(WKWebView.started(pid) == born)
        PageProcessLife.end(pid, born: born &+ 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(child.isRunning)
        PageProcessLife.end(pid, born: born)
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!child.isRunning && child.terminationReason == .uncaughtSignal)
    }
}
