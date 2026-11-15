import Foundation
import Testing
@testable import Fast

// Halloween 2026: how many days its icons have left and what their plate
// says, and which yab-dress: links from the changelog Yab understands.
struct HalloweenTests {
    static func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func automaticDecorationsAppearOnlyOnHalloween() {
        #expect(!Halloween.isDay(at: Self.day(10, 23)))
        #expect(!Halloween.isDay(at: Self.day(10, 30, hour: 23)))
        #expect(Halloween.isDay(at: Self.day(10, 31, hour: 0)))
        #expect(Halloween.isDay(at: Self.day(10, 31, hour: 23)))
        #expect(!Halloween.isDay(at: Self.day(11, 1, hour: 0)))
    }

    @Test func automaticDecorationsFollowTheLocalDayEachYear() {
        for year in [2026, 2027] {
            var west = Calendar(identifier: .gregorian)
            west.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
            var east = west
            east.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
            let midnight = west.date(from: DateComponents(year: year, month: 10, day: 31))!
            #expect(!Halloween.isDay(at: midnight.addingTimeInterval(-1), using: west))
            #expect(Halloween.isDay(at: midnight, using: west))
            #expect(Halloween.isDay(at: midnight.addingTimeInterval(86400 - 1), using: west))
            #expect(!Halloween.isDay(at: midnight.addingTimeInterval(86400), using: west))
            #expect(Halloween.isDay(at: midnight.addingTimeInterval(-1), using: east))
        }
    }

    @Test func theIconsCountDownToNovemberSecond() {
        #expect(Halloween.daysLeft(at: Self.day(10, 21)) == 12)
        #expect(Halloween.plate(at: Self.day(10, 21)) == "12 days left")
        #expect(Halloween.plate(at: Self.day(11, 1)) == "Leaves tomorrow")
        #expect(Halloween.plate(at: Self.day(11, 2, hour: 23)) == "Last day")
        #expect(Halloween.plate(at: Self.day(11, 3, hour: 0)) == "Halloween 2026")
        #expect(Halloween.note(at: Self.day(11, 3)) == "From Halloween 2026. Yours to keep.")
    }

    @MainActor @Test func theChangelogsLinksAreRead() {
        #expect(Dress.read(URL(string: "yab-dress:icon/halloween-ghost")!) == .icon(.ghost))
        #expect(Dress.read(URL(string: "yab-dress:icon/default")!) == .icon(.original))
        #expect(Dress.read(URL(string: "yab-dress:icon/15-arcade")!) == nil)
        #expect(Dress.read(URL(string: "yab-dress:drawings/halloween?strength=0.45")!) == .drawings(.halloween, strength: 0.45))
        #expect(Dress.read(URL(string: "yab-dress:drawings/none")!) == .drawings(nil, strength: nil))
        #expect(Dress.read(URL(string: "yab-dress:drawings/sharks")!) == nil)
        #expect(Dress.read(URL(string: "https://yetanotherbrowser.com")!) == nil)
    }

    @MainActor @Test func onlyOurSiteDresses() {
        #expect(Dress.ours("yetanotherbrowser.com"))
        #expect(!Dress.ours("evil.example"))
        #expect(!Dress.ours(nil))
    }
}
