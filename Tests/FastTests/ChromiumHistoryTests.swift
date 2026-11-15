import Testing
import YabCoreClient
@testable import Fast

struct ChromiumHistoryTests {
    private func entry(_ id: Double, _ url: String, _ title: String = "") -> JSONValue {
        .object(["id": .number(id), "url": .string(url), "title": .string(title)])
    }
    @Test func nativeIDsSurviveDirectionAndNewestFirstPresentation() throws {
        let history = try ChromiumHistorySnapshot(.object([
            "currentIndex": .number(2), "entries": .array([
                entry(41, "https://first.example/"), entry(93, "https://second.example/"),
                entry(108, "https://current.example/"), entry(251, "https://forward.example/")])]))
        #expect(history.pages(back: true).map(\.id) == [93, 41])
        #expect(history.pages(back: false).map(\.id) == [251])
        #expect(history.entries[history.currentIndex].id == 108)
    }
    @Test func emptyHistoryAndTitleFallbackAreValid() throws {
        let empty = try ChromiumHistorySnapshot(.object(["currentIndex": .number(-1), "entries": .array([])]))
        #expect(empty.pages(back: true).isEmpty)
        let single = try ChromiumHistorySnapshot(.object(["currentIndex": .number(0), "entries": .array([entry(7, "https://example.org/", "  ")])]))
        #expect(single.entries[0].named.title == "example.org")
        #expect(single.pages(back: false).isEmpty)
    }
    @Test func invalidOrAmbiguousNativeEntriesAreRefused() {
        let invalid: [JSONValue] = [
            .object(["currentIndex": .number(1), "entries": .array([entry(1, "https://a.example/")])]),
            .object(["currentIndex": .number(0), "entries": .array([entry(1, "https://a.example/"), entry(1, "https://b.example/")])]),
            .object(["currentIndex": .number(0), "entries": .array([entry(1.5, "https://a.example/")])]),
            .object(["currentIndex": .number(0), "entries": .array([entry(1, "/relative")])]),
            .object(["currentIndex": .number(.infinity), "entries": .array([])])
        ]
        for value in invalid { #expect(throws: (any Error).self) { try ChromiumHistorySnapshot(value) } }
    }
}
