import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fast

// The first day on the stamp (Stamp.swift, StampView.swift): the earliest
// real day wins, anniversaries come round once a full year is up, and with
// YAB_FARM_OUT set, a sheet of the stamp on day one, after a year, after
// five, with no known day, turned over, under the lamp, and small.
@MainActor
struct StampSinceTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func noAnniversaryOnTheFirstDay() {
        #expect(MemberStamp.anniversaries(since: Self.day(2026, 10, 23), now: Self.day(2026, 10, 23, hour: 23), calendar: Self.calendar).isEmpty)
        #expect(MemberStamp.anniversaries(since: Self.day(2026, 10, 23), now: Self.day(2027, 10, 22, hour: 23), calendar: Self.calendar).isEmpty)
    }

    @Test func oneOnTheDayAYearIsUp() {
        let days = MemberStamp.anniversaries(since: Self.day(2026, 10, 23, hour: 20), now: Self.day(2027, 10, 23, hour: 0), calendar: Self.calendar)
        #expect(days == [Self.calendar.startOfDay(for: Self.day(2027, 10, 23))])
    }

    @Test func earlierOnesStay() {
        let days = MemberStamp.anniversaries(since: Self.day(2026, 10, 23), now: Self.day(2031, 11, 1), calendar: Self.calendar)
        #expect(days.count == 5)
        #expect(days.map { Self.calendar.component(.year, from: $0) } == [2027, 2028, 2029, 2030, 2031])
    }

    @Test func leapDayComesRoundOnTheTwentyEighth() {
        let days = MemberStamp.anniversaries(since: Self.day(2028, 2, 29), now: Self.day(2029, 2, 28), calendar: Self.calendar)
        #expect(days.count == 1)
        #expect(Self.calendar.component(.day, from: days[0]) == 28)
    }

    @Test func noDayNoPostmarks() {
        #expect(MemberStamp.anniversaries(since: nil).isEmpty)
    }

    @Test func earliestRealDayWins() {
        let history = Self.day(2026, 9, 2), stamp = Self.day(2026, 10, 15)
        #expect(MemberStamp.earliest(stamp, history) == history)
        #expect(MemberStamp.earliest(nil, stamp) == stamp)
        #expect(MemberStamp.earliest(nil, nil) == nil)
    }

    @Test func impossibleDaysAreLeftOut() {
        let real = Self.day(2026, 10, 1)
        #expect(MemberStamp.earliest(real, Date(timeIntervalSince1970: 0)) == real)
        #expect(MemberStamp.earliest(real, Date().addingTimeInterval(7 * 86_400)) == real)
        #expect(MemberStamp.earliest(nil, Date(timeIntervalSince1970: 1_000)) == nil)
    }

    @Test func printedLikeMailIs() {
        let first = Self.day(2026, 10, 23)
        #expect(Postmark.dateline(first) == "Oct 23, 2026")
        #expect(Postmark.printed(first) == "23 OCT 2026")
    }

    @Test func syncsBetweenMacs() {
        #expect(SyncShapes.syncs("stamp.since"))
    }

    // MARK: - pictures

    private static let note = "Maya,\nnobody sent you.\nyou just showed up.\nreally glad you did"

    private func front(_ width: CGFloat, years: Int?, lamp: Bool = false) -> some View {
        let now = Date()
        let since = years.map { Self.calendar.date(byAdding: .year, value: -$0, to: now)! }
        let scale = width / StampArt.size.width
        return StampArt(number: "42", name: "Maya", note: Self.note, signed: "Sam",
                        lamp: lamp ? CGPoint(x: 230, y: 170) : CGPoint(x: 70, y: 40), through: lamp ? 1 : 0,
                        since: since, anniversaries: MemberStamp.anniversaries(since: since, now: now))
            .scaleEffect(scale)
            .frame(width: width, height: StampArt.size.height * scale)
    }

    private func back(_ width: CGFloat) -> some View {
        let scale = width / StampArt.size.width
        return StampBack(note: Self.note, signed: "Sam", since: Date())
            .scaleEffect(scale)
            .frame(width: width, height: StampArt.size.height * scale)
    }

    private func labeled(_ text: String, _ view: some View) -> some View {
        VStack(spacing: 8) {
            view
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @Test func pictures() throws {
        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let sheet = VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .bottom, spacing: 24) {
                labeled("day one", front(220, years: 0))
                labeled("1 year", front(220, years: 1))
                labeled("5 years", front(220, years: 5))
                labeled("12 years", front(220, years: 12))
                labeled("no known day", front(220, years: nil))
            }
            HStack(alignment: .bottom, spacing: 24) {
                labeled("under the lamp", front(220, years: 0, lamp: true))
                labeled("turned over", back(220))
                labeled("About, 2 years", front(170, years: 2))
                labeled("96 pt", front(96, years: 4))
                labeled("64 pt", front(64, years: 4))
                labeled("40 pt", front(40, years: 4))
            }
        }
        .padding(32)
        .background(Color(white: 0.95))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("stamp-since.png"))
    }
}
