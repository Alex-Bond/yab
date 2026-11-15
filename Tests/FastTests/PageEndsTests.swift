import AppKit
import Testing
import WebKit
@testable import Fast

// Why a page's process ended (PageEnd), and which endings make a page that
// keeps crashing (PageEnds): alone three times in a minute, never asked for,
// never in company.
@MainActor
@Suite(.serialized)
struct PageEndsTests {
    /// A PageEnds whose moment passes when the test says.
    @MainActor private final class Moment {
        var now: TimeInterval = 1000
        var waiting: [() -> Void] = []
        lazy var ends = PageEnds(clock: { [unowned self] in now }, later: { [unowned self] _, work in waiting.append(work) })
        func pass() { let work = waiting; waiting = []; work.forEach { $0() } }
    }

    private func ended(_ id: UUID, _ reason: PageEnd? = .crash) -> PageEnds.Ended {
        PageEnds.Ended(tab: nil, id: id, reason: reason)
    }

    @Test func aPageAloneThreeTimesInAMinuteKeepsEnding() {
        let moment = Moment()
        var heard: [[Bool]] = []
        moment.ends.heard = { batch in heard.append(batch.map { $0.again }) }
        let tab = UUID()
        for step in 0..<3 {
            moment.now += 10
            moment.ends.ended(ended(tab, step == 1 ? .memory : .crash))
            moment.pass()
        }
        #expect(heard == [[false], [false], [true]])
    }

    @Test func aMinuteApartIsNotALoop() {
        let moment = Moment()
        let tab = UUID()
        for _ in 0..<5 {
            moment.now += 31
            let settled = moment.ends.settle([ended(tab)])
            #expect(settled.map { $0.again } == [false])
        }
    }

    @Test func pagesEndingTogetherAreNoOnesLoop() {
        let moment = Moment()
        var heard: [[Bool]] = []
        moment.ends.heard = { batch in heard.append(batch.map { $0.again }) }
        let a = UUID(), b = UUID()
        for _ in 0..<4 {
            moment.now += 5
            moment.ends.ended(ended(a))
            moment.ends.ended(ended(b, .memory))
            #expect(moment.waiting.count == 1, "one moment for the pages that end in it")
            moment.pass()
        }
        #expect(heard == Array(repeating: [false, false], count: 4))
        // Nor did the company count toward the next time either ends alone.
        moment.ends.ended(ended(a))
        moment.pass()
        #expect(heard.last == [false])
    }

    @Test func endingsAskedForAreNeverCounted() {
        let moment = Moment()
        let tab = UUID()
        for _ in 0..<5 {
            moment.now += 1
            #expect(moment.ends.settle([ended(tab, .requested)]).map { $0.again } == [false])
        }
        #expect(moment.ends.settle([ended(tab, nil)]).map { $0.again } == [false])
    }

    @Test func reasonsAreWebKitsNumbers() {
        #expect(PageEnd(rawValue: 0) == .memory)
        #expect(PageEnd(rawValue: 1) == .cpu)
        #expect(PageEnd(rawValue: 2) == .requested)
        #expect(PageEnd(rawValue: 3) == .crash)
        #expect(PageEnd(rawValue: 4) == .crashLimit)
        #expect(PageEnd.memory.again == "This page keeps running out of memory")
        #expect(PageEnd.crash.again == "This page keeps crashing")
        #expect(PageEnd.crashLimit.again == "This page keeps crashing")
    }

    @Test func theReasonGoesIntoDiagnosticsAsAWordAndWebKitsNumber() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.record(.webProcessTerminated, reason: .memory)
        log.record(.webProcessTerminated)
        let events = log.events()
        #expect(events.first?.reason == "memory")
        #expect(events.first?.code == 0)
        #expect(events.last?.reason == nil)
        #expect(events.last?.code == nil)
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(text.contains("\"reason\":\"memory\""))
    }

    // Through the browser's engine-neutral end event, three times alone in
    // front, says the page keeps running out of memory; two tabs ending
    // together, however often, say nothing.
    @Test func theBrowserTellsMemoryFromACrashAndForgivesCompany() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let behind = browser.open(URL(string: "about:blank#behind")!, foreground: true)
        let front = browser.open(URL(string: "about:blank#front")!, foreground: true)
        for _ in 0..<100 where front.loading || behind.loading { try await Task.sleep(for: .milliseconds(20)) }
        let frontPage = try #require(front.builtPage), behindPage = try #require(behind.builtPage)

        // Each end settled before the next: on a busy Mac a fixed 250 ms
        // woke before the tenth of a second's gathering had run, and two
        // ends went in one batch, counted once.
        let settled = { () async throws -> Bool in try await Loaded.until(10) { !browser.stuck.ends.gathering } }
        for _ in 0..<4 {
            browser.page(frontPage, ended: .crash)
            browser.page(behindPage, ended: .crash)
            _ = try await settled()
        }
        #expect(front.failure == nil)
        #expect(behind.failure == nil)

        for _ in 0..<3 {
            browser.page(behindPage, ended: .memory)
            _ = try await settled()
        }
        #expect(behind.failure == "This page keeps running out of memory")
        #expect(front.failure == nil)
    }
}
