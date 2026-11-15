import AppKit
import Testing
import WebKit
@testable import Fast

/// Feedback #346: a swipe back pulled far went into the tab's history list
/// instead of back. Now letting go always goes one page, quick or slow,
/// short or long, and the list comes out only for fingers held still with
/// the pill armed (`Swipe.hold`). Native scroll events with their phases,
/// timed as a trackpad sends them, into a page with two pages behind it.
@Suite(.serialized)
@MainActor
struct SwipeHoldTests {
    /// Pages served in the test itself: page N for holdtest://pages/N.
    private final class Pages: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let n = task.request.url?.lastPathComponent ?? "0"
            let body = Data("<!doctype html><title>Page \(n)</title><p>Page \(n)".utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
            task.didReceive(body)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    /// A page with pages 1 and 2 behind it, the tab it came from past them.
    private func page() async throws -> PageView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(Pages(), forURLScheme: "holdtest")
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.swipeTrackingEnabled = { true }
        for n in 1...3 {
            web.load(URLRequest(url: URL(string: "holdtest://pages/\(n)")!))
            for _ in 0..<300 {
                if web.title == "Page \(n)", !web.isLoading, web.backForwardList.backList.count == n - 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try #require(web.backForwardList.backList.count == 2, "history: \(web.backForwardList.backList.map(\.url))")
        return web
    }

    private func wheel(x: Int32, y: Int32 = 0, phase: Int64) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9)
        return try #require(NSEvent(cgEvent: event))
    }

    private struct Seen {
        var listed = false
        var froms = 0
        var searches = 0
    }

    /// Fingers down, `travel` points back over `seconds` a frame at a time,
    /// still for `hold`, `down` points down after it, then lifted; the page
    /// says the swipe is free. What the pill showed, and where it went.
    private func swipe(_ web: PageView, travel: Int, seconds: Double, hold: Double = 0,
                       further: Int = 0, down: Int = 0) async throws -> Seen {
        var seen = Seen()
        web.fromTitle = { "Previous tab" }
        web.onFrom = { seen.froms += 1 }
        web.onHistory = { _ in seen.searches += 1 }
        web.onPull = { pull in if pull?.listed == true { seen.listed = true } }
        web.scrollWheel(with: try wheel(x: 0, phase: 1))
        let frames = max(2, Int(seconds * 60))
        var sent = 0
        for frame in 1...frames {
            let due = travel * frame / frames
            web.scrollWheel(with: try wheel(x: Int32(due - sent), phase: 2))
            sent = due
            if frame == 1 { web.answer(free: true, gesture: web.swipeGesture) }
            try await Task.sleep(for: .milliseconds(16))
        }
        if hold > 0 { try await Task.sleep(for: .seconds(hold)) }
        for _ in 0..<(further / 10) {
            web.scrollWheel(with: try wheel(x: 10, phase: 2))
            try await Task.sleep(for: .milliseconds(16))
        }
        for _ in 0..<(down / 4) {
            // Down the list: wheel1 negative, as fingers going down send on
            // a Mac set to scroll naturally.
            web.scrollWheel(with: try wheel(x: 0, y: -4, phase: 2))
            try await Task.sleep(for: .milliseconds(16))
        }
        web.scrollWheel(with: try wheel(x: 0, phase: 4))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        for _ in 0..<100 {
            if !web.isLoading, web.url?.lastPathComponent != "3" || seen.froms + seen.searches > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))
        return seen
    }

    @Test func quickSwipeGoesBackOnePage() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 220, seconds: 0.1)
        #expect(!seen.listed)
        #expect(seen.froms == 0 && seen.searches == 0)
        #expect(web.url?.lastPathComponent == "2")
    }

    @Test func quickLongSwipeStillGoesOnePage() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 700, seconds: 0.18)
        #expect(!seen.listed)
        #expect(seen.froms == 0 && seen.searches == 0)
        #expect(web.url?.lastPathComponent == "2")
    }

    /// The case of #346: pulled on well past where the list once came out,
    /// slowly, and let go without stopping.
    @Test func longSlowSwipeGoesOnePageNotIntoHistory() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 700, seconds: 1.2)
        #expect(!seen.listed)
        #expect(seen.froms == 0 && seen.searches == 0)
        #expect(web.url?.lastPathComponent == "2")
    }

    @Test func shortSwipeGoesNowhere() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 40, seconds: 0.3)
        #expect(!seen.listed)
        #expect(web.url?.lastPathComponent == "3")
    }

    @Test func holdBringsTheListOnThePillsPage() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 250, seconds: 0.3, hold: 0.7)
        #expect(seen.listed)
        // Let go at once on the list: still the page the pill named.
        #expect(seen.froms == 0 && seen.searches == 0)
        #expect(web.url?.lastPathComponent == "2")
    }

    @Test func aLongPullHeldStartsTheListAtItsTop() async throws {
        let web = try await page()
        // Far enough that the old rule would have lit a deep row at once.
        let seen = try await swipe(web, travel: 600, seconds: 0.6, hold: 0.7)
        #expect(seen.listed)
        #expect(seen.froms == 0 && seen.searches == 0)
        #expect(web.url?.lastPathComponent == "2")
    }

    @Test func heldThenPulledFurtherGoesDeeper() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 250, seconds: 0.3, hold: 0.7, further: 90)
        #expect(seen.listed)
        #expect(web.url?.lastPathComponent == "1")
    }

    @Test func heldThenDownPicksARow() async throws {
        let web = try await page()
        // Rows: page 2, page 1, the tab it came from, history to search.
        let seen = try await swipe(web, travel: 250, seconds: 0.3, hold: 0.7, down: 92)
        #expect(seen.listed)
        #expect(seen.froms == 1)
        #expect(web.url?.lastPathComponent == "3")
    }

    @Test func pauseShortOfTheHoldIsStillJustBack() async throws {
        let web = try await page()
        let seen = try await swipe(web, travel: 250, seconds: 0.3, hold: 0.25)
        #expect(!seen.listed)
        #expect(web.url?.lastPathComponent == "2")
    }
}
