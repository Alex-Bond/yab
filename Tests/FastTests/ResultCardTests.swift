import AppKit
import Foundation
import SwiftUI
import SyncKit
import Testing
@testable import Fast

// Result cards in the chat (ResultCard, ChatResultCard): the spec a tool
// says on a line of its result, read back the same; the card step it
// becomes, right after the step that made it, once; what `results`,
// calendar_add and the watches put in it; its words; and, with
// YAB_FARM_OUT set, a picture of every kind, light and dark.
@MainActor
struct ResultCardTests {
    static let links = ResultCard(kind: .links, rows: [
        .init(title: "The Case for Slow Websites", url: "https://aeon.co/essays/slow", site: "aeon.co", minutes: 12),
        .init(title: "The Slow Web", url: "https://medium.com/@j/slow-web", site: "medium.com", minutes: 6),
        .init(title: "Small sites I still visit", url: "https://www.reddit.com/r/web/x", site: "reddit.com"),
    ])
    static let table = ResultCard(kind: .table, rows: [
        .init(title: "B&H", url: "https://www.bhphotovideo.com/g", site: "bhphotovideo.com", cells: ["$195.00", "free shipping"]),
        .init(title: "Fellow", url: "https://fellowproducts.com/opus", site: "fellowproducts.com", cells: ["$204.00", "$9 shipping"]),
        .init(title: "Amazon", url: "https://www.amazon.com/dp/1", site: "amazon.com", cells: ["$209.99", "$14.99 shipping"]),
    ], lit: 0)
    static let day = Date(timeIntervalSince1970: 1_793_097_600) // Tue Oct 27 2026, 10:40 UTC
    static var event: ResultCard {
        ResultCard(kind: .event, title: "Coffee with Anna", detail: "with 1 guest", at: day.timeIntervalSince1970,
                   end: day.addingTimeInterval(1800).timeIntervalSince1970, url: "https://calendar.google.com/x")
    }
    static var promise: ResultCard { ResultCard(kind: .promise, title: "Tim", at: day.addingTimeInterval(2 * 86_400).timeIntervalSince1970, ref: "a@b.c|t1") }
    static let watch = ResultCard(kind: .watch, title: "under $180", value: "$195", site: "fellowproducts.com", ref: "w1", url: "https://fellowproducts.com/opus")
    static let routine = ResultCard(kind: .routine, title: "Weekdays at 9:00", detail: "Next: Tue 9:00", ref: "r1")
    static let folder = ResultCard(kind: .folder, title: "Espresso Grinders", rows: [
        .init(title: "Encore ESP | Baratza", url: "https://baratza.com/encore-esp", site: "baratza.com"),
        .init(title: "Opus Conical Burr | Fellow", url: "https://fellowproducts.com/opus", site: "fellowproducts.com"),
    ], ref: "chat1")
    static var all: [ResultCard] { [links, table, event, promise, watch, routine, folder] }

    // MARK: - the spec

    @Test func everyKindReadsBackTheSame() throws {
        for card in Self.all {
            let back = try #require(ResultCard(json: card.json), "\(card.kind)")
            #expect(back == card)
            #expect(card.line.hasPrefix("Card: {"))
            #expect(!card.json.contains("\n"))
        }
        #expect(Set(Self.all.map(\.kind)) == Set(ResultCard.Kind.allCases))
    }

    @Test func aResultsCardsAreItsCardLinesOnly() {
        let words = "Shown under your answer: 3 pages.\n" + Self.links.line + "\nCard: not json\nCard: {\"kind\":\"poster\",\"title\":\"x\"}\n" + Self.watch.line
        #expect(ResultCard.cards(in: words) == [Self.links, Self.watch])
        #expect(ResultCard.without(words) == "Shown under your answer: 3 pages.")
        #expect(ResultCard.cards(in: "Saved: /x.pdf").isEmpty)
    }

    @Test func aCardWithNothingToShowIsNone() {
        #expect(ResultCard(json: ResultCard(kind: .links, rows: []).json) == nil)
        #expect(ResultCard(json: ResultCard(kind: .links, rows: [.init(title: "")]).json) == nil)
        #expect(ResultCard(json: ResultCard(kind: .event).json) == nil)
        #expect(ResultCard(json: ResultCard(kind: .promise).json) != nil)
        let many = ResultCard(kind: .table, rows: (1...12).map { .init(title: "Row \($0)") }, lit: 10)
        let read = ResultCard(json: many.json)
        #expect(read?.rows?.count == ResultCard.mostRows)
        #expect(read?.lit == nil) // past the rows kept
    }

    @Test func itsWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Self.day
        #expect(ResultCard.day(now, now: now, calendar: calendar) == "today")
        #expect(ResultCard.day(now.addingTimeInterval(86_400), now: now, calendar: calendar) == "tomorrow")
        #expect(ResultCard.day(now.addingTimeInterval(2 * 86_400), now: now, calendar: calendar) == "Thursday")
        #expect(ResultCard.day(now.addingTimeInterval(9 * 86_400), now: now, calendar: calendar) == "Nov 5")
        #expect(Self.promise.promise(now: now, calendar: calendar) == "Back in your inbox Thursday if Tim hasn\u{2019}t answered")
        #expect(ResultCard(kind: .promise, title: "Anna").promise() == "Tells you when Anna answers")
        #expect(Self.event.hours(calendar: calendar) == "10:40 \u{2013} 11:10 AM")
        let noon = ResultCard(kind: .event, title: "x", at: now.timeIntervalSince1970 + 3600, end: now.timeIntervalSince1970 + 7200)
        #expect(noon.hours(calendar: calendar) == "11:40 AM \u{2013} 12:40 PM")
        #expect(ResultCard.under(Self.links.rows![0]) == "aeon.co \u{00B7} 12 min")
        #expect(ResultCard.host("https://www.Reddit.com/r/x") == "reddit.com")
        #expect(ChatResultCard.words(Self.watch) == "Watching: under $180, now $195")
    }

    @Test func numbersAreToldFromWords() {
        for cell in ["$195.00", "1,299", "4.5", "-12%", "€ 9", "2.4k"] { #expect(ChatResultCard.numeric(cell), "\(cell)") }
        for cell in ["free shipping", "$9 shipping", "B&H", "", "in stock"] { #expect(!ChatResultCard.numeric(cell), "\(cell)") }
    }

    // MARK: - the step it becomes

    static func claudeTurn(_ tool: String, result: String) -> [ChatItem] {
        var items: [ChatItem] = []
        items.put(ChatItem(id: "q", kind: .asked, text: "Find slow web essays", state: .done))
        items.put(ChatItem(id: "t1", kind: .tool, name: tool))
        items.answered(["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": result]]])
        return items
    }

    @Test func aToolsCardIsAStepRightAfterIt() throws {
        var items = Self.claudeTurn("results", result: "Shown under your answer: 3 pages.\n" + Self.links.line)
        #expect(items.map(\.kind) == [.asked, .tool, .card])
        #expect(items[2].id == "t1.card.0")
        #expect(items[2].name == "links")
        #expect(items[2].resultCard == Self.links)
        // Heard again (a resumed stream), it stays one.
        items.answered(["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": Self.links.line]]])
        #expect(items.filter { $0.kind == .card }.count == 1)
        // The answer after it is still the answer: a card is not work.
        items.put(ChatItem(id: "m", kind: .message, text: "Three good ones.", state: .done))
        #expect(items.last?.kind == .message)
    }

    @Test func anotherServersCardLineIsNotACard() {
        #expect(Self.claudeTurn("github/results", result: Self.links.line).allSatisfy { $0.kind != .card })
        #expect(Self.claudeTurn("results", result: "nothing").allSatisfy { $0.kind != .card })
        // A failed step makes nothing.
        var items: [ChatItem] = [ChatItem(id: "t1", kind: .tool, name: "results")]
        items.answered(["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": Self.links.line])
        #expect(items.allSatisfy { $0.kind != .card })
    }

    @Test func codexsCardComesThroughItsResult() {
        let item: [String: Any] = ["type": "mcpToolCall", "id": "c1", "server": "yab", "tool": "watch_page", "status": "completed",
                                   "arguments": [:], "result": ["content": [["type": "text", "text": "Watching it.\n" + Self.watch.line]]]]
        var items: [ChatItem] = []
        for step in ChatItem.codexSteps(item, done: true) { items.put(step) }
        #expect(items.map(\.kind) == [.tool, .card])
        #expect(items.last?.resultCard == Self.watch)
    }

    @Test func aCardStepSyncsWithItsSpec() throws {
        let step = ChatItem.card(Self.table, id: "x.card.0")
        let synced = SyncChatItem(id: "c/x.card.0", chat: "c", n: 0, kind: step.kind.rawValue, name: step.name, text: step.text, state: "done")
        let back = try #require(SyncChatItem(Record(collection: "chatitem", id: synced.id, fields: synced.fields)))
        #expect(back.kind == "card")
        #expect(ResultCard(json: back.text) == Self.table)
    }

    // MARK: - what the tools put in it

    @Test func resultsMakesItsCard() throws {
        let input: [String: Any] = ["kind": "table", "lit": 1, "rows": [
            ["title": "B&H", "url": "https://www.bhphotovideo.com/g", "cells": ["$195.00", 3]],
            ["title": "Fellow", "url": "https://fellowproducts.com/opus", "cells": ["$204.00"]],
        ]]
        let card = try #require(Mcp.resultsCard(input))
        #expect(card.kind == .table && card.lit == 1)
        #expect(card.rows?[0].site == "bhphotovideo.com")
        #expect(card.rows?[0].cells == ["$195.00", "3"])
        #expect(Mcp.resultsCard(["kind": "poster", "rows": [["title": "x"]]]) == nil)
        #expect(Mcp.resultsCard(["kind": "links", "rows": [["title": " "]]]) == nil)
        let said = try #require(Mcp.byName["results"]).handler("results", ["kind": "links", "rows": [["title": "The Slow Web", "url": "https://medium.com/x", "minutes": 6]]], nil)
        let words = ChatItem.words(said)
        #expect(ResultCard.cards(in: words).first?.rows?.first?.minutes == 6)
    }

    @Test func calendarAddsCardIsTheEventsDay() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let card = try #require(Mcp.eventCard(["title": "Coffee with Anna", "start": "2026-10-28T10:30", "minutes": 30, "guests": ["anna@x.co"]],
                                              url: "https://calendar.google.com/x", zone: zone))
        #expect(card.kind == .event && card.detail == "with 1 guest")
        #expect(card.at == Mcp.localDate("2026-10-28T17:30:00Z")?.timeIntervalSince1970)
        #expect(card.end == card.at.map { $0 + 1800 })
        #expect(Mcp.eventCard(["title": "x"], url: nil) == nil)
        #expect(Mcp.eventCard(["start": "2026-10-28T10:30"], url: nil) == nil)
    }

    // MARK: - pictures

    @Test func pictures() async throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.all.enumerated()), id: \.offset) { _, card in
                    ChatResultCard(browser: nil, card: card)
                }
            }
            .padding(24)
            .frame(width: 400, alignment: .leading)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            if let screen = TestScreen.screen { window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40)) }
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent(dark ? "cards-dark.png" : "cards-light.png"))
        }
    }
}
