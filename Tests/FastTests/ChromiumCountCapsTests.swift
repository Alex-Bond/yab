import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Counts that grow with how much a person uses Yab are not capped on the
/// client side either (RESULT-yabcore-caps.md): a close of 300 tabs is read,
/// and the cursor cache keeps the recent ones instead of every one ever.
@Suite(.serialized)
@MainActor
struct ChromiumCountCapsTests {
    @Test func closeOutcomeOfThreeHundredTabsIsRead() throws {
        let remotes = (0..<300).map { "tab-\($0)" }
        let value: JSONValue = .object(["complete": .bool(true), "closed": .array(remotes.map(JSONValue.string)),
                                        "retained": .array([]), "unknown": .array([])])
        let outcome = try #require(ChromiumCloseOutcome(value, requested: Set(remotes)))
        #expect(outcome.allClosed && outcome.closed.count == 300)
    }

    @Test func closeOutcomeStillRefusesMoreRowsThanAsked() {
        let value: JSONValue = .object(["complete": .bool(true), "closed": .array([.string("a"), .string("b")]),
                                        "retained": .array([]), "unknown": .array([])])
        #expect(ChromiumCloseOutcome(value, requested: ["a"]) == nil)
    }

    @Test func cursorCacheKeepsTheRecentAndForgetsTheOldest() {
        let picture = NSImage(size: NSSize(width: 4, height: 4))
        for i in 0..<(ChromiumCursors.kept + 200) {
            ChromiumCursors.keep("caps-test-\(i)", NSCursor(image: picture, hotSpot: .zero))
        }
        #expect(ChromiumCursors.count <= ChromiumCursors.kept)
        #expect(ChromiumCursors.cursor("caps-test-0") == nil)
        #expect(ChromiumCursors.cursor("caps-test-\(ChromiumCursors.kept + 199)") != nil)
    }
}
