import XCTest
@testable import YabPhone

/// #1637: on a profile with a Mac's weeks of history in sync, each letter
/// typed in the field took about a second to show. A keystroke is the words
/// set and what the field works out to draw them (FieldSurface: New Tab's
/// content, the rows, the key and the address written on).
@MainActor
final class FieldTypingSpeedTests: XCTestCase {
    private var app: AppModel!

    override func tearDown() async throws {
        Motion.disabled = false
    }

    override func setUp() async throws {
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"))
        let now = Date().timeIntervalSince1970
        let words = ["design", "review", "pull", "request", "issue", "lisbon", "flights", "notes", "budget", "launch",
                     "weather", "recipe", "invoice", "calendar", "tickets", "hotel", "docs", "api", "release", "music"]
        var synced: [SyncedPlace] = []
        for i in 0..<12_000 {
            let host = "site\(i % 900).example\(i % 7).com"
            let title = (0..<6).map { words[(i * 7 + $0 * 13) % words.count] }.joined(separator: " ") + " · Café \(i)"
            synced.append(SyncedPlace(key: "\(host)/page/\(i)", url: "https://\(host)/page/\(i)", title: title,
                                      last: now - Double(i * 60), typed: i % 11 == 0, device: "mac-1"))
        }
        app.history.adoptSynced(synced, own: "iphone-1")
        app.history.fixtureVisits = (0..<2_000).map { i in
            let host = "visit\(i % 400).example.org"
            return BrowserVisit(url: "https://\(host)/read/\(i)", title: "Visit \(i) " + words[i % words.count],
                                site: "Visit \(i % 400)", icon: host, host: host,
                                visitedAt: Date(timeIntervalSince1970: now - Double(i * 90)), count: 1 + i % 5)
        }
        app.surfaces.openField(.newTab)
        // The places are made once, as the field opening makes them.
        _ = app.history.places
    }

    /// One keystroke: the words, then what the field works out to draw them.
    private func keystroke(_ words: String) {
        app.field.typed(words)
        let content = NewTabContent.make(for: app)
        let rows = app.fieldRows(content: content)
        _ = app.fieldKey(rows: rows)
        _ = app.fieldCompletion(rows: rows)
    }

    func testALetterTypedOverWeeksOfHistoryShowsAtOnce() {
        let phrase = "github pull request review"
        var slowest = 0.0
        var total = 0.0
        for end in phrase.indices {
            let words = String(phrase[...end])
            let start = CFAbsoluteTimeGetCurrent()
            keystroke(words)
            let took = CFAbsoluteTimeGetCurrent() - start
            slowest = max(slowest, took)
            total += took
        }
        let average = total / Double(phrase.count)
        print("FIELD_TYPING average \(Int(average * 1000)) ms, slowest \(Int(slowest * 1000)) ms over \(phrase.count) letters")
        // Was 254 ms a letter on average, 386 ms at worst, in the simulator
        // on a farm Mac (the reporter saw about a second on an iPhone); 25
        // and 33 ms since, on a loaded one.
        XCTAssertLessThan(average, 0.06, "a letter took \(Int(average * 1000)) ms on average")
        XCTAssertLessThan(slowest, 0.1, "the slowest letter took \(Int(slowest * 1000)) ms")
    }
}
