import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageCallTests {
    private func run(_ verb: String, on page: any PageHandle) async -> Any? {
        await withCheckedContinuation { done in
            CallStage.run(verb, on: page) { done.resume(returning: $0) }
        }
    }

    @Test func aTabStageUsesTheNamedWorldAndLoadsOncePerDocument() async throws {
        let view = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        defer { page.stopLoading() }
        await CallStageRunTests.load(view, "<p>A call</p>")
        let start = CallStage.sent, source = CallStage.source.utf8.count
        for _ in 0..<8 { #expect(await run("who", on: page) is [Any]) }
        let sent = CallStage.sent - start
        #expect(sent >= source && sent < source + 8 * 200)
        #expect(try await page.run("window.__yabCall === undefined") as? Bool == true)
        #expect(try await page.run("typeof window.__yabCall.who", in: .named("call")) as? String == "function")
        await CallStageRunTests.load(view, "<p>Another document</p>")
        let before = CallStage.sent
        #expect(await run("who", on: page) is [Any])
        #expect(CallStage.sent - before >= source)
        let again = CallStage.sent
        #expect(await run("news", on: page) is [String: Any])
        #expect(CallStage.sent - again < 200)
    }

    @Test func captureMappingPreservesLegacyValuesAndStoppingAnEmptyPageDoesNotCapture() {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        for state in [WKMediaCaptureState.none, .active, .muted] {
            let copied = PageMediaState(state)
            #expect(copied.webKit == state && copied.rawValue == state.rawValue)
        }
        page.setCameraCapture(.none)
        page.setMicrophoneCapture(.none)
        page.stopDisplayCapture()
        #expect(page.captureStatus == PageCaptureStatus(camera: .none, microphone: .none, screen: .none))
        page.stopLoading()
    }

    @Test func slackControlsStayInTheHuddlePageAndFallbackToTheCallTab() {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "about:blank#call")!, foreground: true)
        let child = browser.open(URL(string: "about:blank#huddle")!, foreground: false)
        defer { browser.close(child); browser.close(tab) }
        let page = tab.page, huddle = child.page
        tab.setAddressOptimistically(URL(string: "https://app.slack.com/client/T/C")!)
        child.setAddressOptimistically(URL(string: "https://app.slack.com/huddle/T/C")!)
        child.opener = tab.id
        #expect(browser.callControls(tab) === huddle)
        child.setAddressOptimistically(URL(string: "https://example.invalid")!)
        #expect(browser.callControls(tab) === page)
    }
}
