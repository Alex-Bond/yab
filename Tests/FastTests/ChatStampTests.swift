import Foundation
import Testing
@testable import Fast

struct ChatStampTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let locale = Locale(identifier: "en_US_POSIX")
    /// Thursday, October 15, 2026, 14:09 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_073_340)

    static func item(_ id: String, _ kind: ChatItem.Kind, at: Date) -> ChatItem {
        ChatItem(id: id, kind: kind, text: id, state: .done, began: at, ended: at)
    }

    @Test func firstTurnAndLongGapsAreStamped() {
        let start = Self.now.addingTimeInterval(-3_600)
        let turns = [
            [Self.item("a", .asked, at: start), Self.item("a1", .message, at: start.addingTimeInterval(30))],
            [Self.item("b", .asked, at: start.addingTimeInterval(120))],
            [Self.item("c", .asked, at: start.addingTimeInterval(120 + 15 * 60))],
        ]
        #expect(ChatStamp.at(turns, 0) == start)
        #expect(ChatStamp.at(turns, 1) == nil)
        #expect(ChatStamp.at(turns, 2) == start.addingTimeInterval(120 + 15 * 60))
        #expect(ChatStamp.at(turns, 3) == nil)
    }

    @Test func wordsAsMessagesSaysThem() {
        func words(_ ago: TimeInterval) -> String {
            ChatStamp.words(Self.now.addingTimeInterval(-ago), now: Self.now, calendar: Self.calendar, locale: Self.locale)
        }
        #expect(words(0).hasPrefix("Today "))
        #expect(words(86_400).hasPrefix("Yesterday "))
        #expect(words(3 * 86_400).hasPrefix("Monday "))
        #expect(words(10 * 86_400).hasPrefix("Oct 5"))
        #expect(words(400 * 86_400).contains("2025"))
    }
}
