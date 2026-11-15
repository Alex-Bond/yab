import Foundation
import Testing
@testable import Fast

// Yab Wrapped (WrappedStory, WrappedTally, WrappedLedger, WrappedArcade):
// which levels a player gets, how time saved is counted, and that every
// screen draws in letters the arcade's font has.
@MainActor
struct WrappedTests {
    /// A busy player: every level, every bonus.
    static var rich: WrappedCounts {
        var c = WrappedCounts()
        c.agentTasks = 212; c.agentRunMinutes = 1_200; c.agentNightTasks = 14; c.agentNightMinutes = 372
        c.asks = 640; c.askPageWords = 1_200_000; c.askAnswerWords = 90_000
        c.mailCleared = 6_900; c.mailUnsubscribes = 41; c.mailInboxZeroDays = 23
        c.formFields = 3_900
        c.fastMinutes = 300; c.fastRate = 1.5; c.pipMinutes = 120
        c.videoMinutes = 2_400; c.mostOpen = 87; c.searches = 1_200
        c.tabJumps = 2_000; c.tabsTidied = 2_340
        c.codeCalls = 3_200; c.codeTopTool = "snapshot"; c.codeAgents = 2
        c.adsBlocked = 312_000; c.memoryFreedMB = 9_000; c.tabsSlept = 800
        c.callsJoined = 30; c.phoneTabs = 40; c.longestStreak = 21; c.busiestHour = 23; c.boosts = 3; c.friends = 2
        return c
    }

    @Test func tooLittleIsNoStory() {
        var c = WrappedCounts()
        c.formFields = 3_900          // 195 min
        c.mailCleared = 1_200         // 40 min
        #expect(WrappedStory.make(c, initials: "SER", period: "LAST 100 DAYS") == nil)
        c.tabJumps = 600              // 30 min: the third level
        #expect(WrappedStory.make(c, initials: "SER", period: "LAST 100 DAYS")?.levels.count == 3)
    }

    @Test func aLevelUnderItsFloorIsLeftOut() {
        var c = Self.rich
        c.formFields = 10             // 30 s
        let story = WrappedStory.make(c, initials: "SER", period: "P")!
        #expect(!story.levels.contains { $0.id == "forms" })
    }

    @Test func theBossIsTheBiggestAndComesLast() {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "P")!
        #expect(story.levels.map(\.minutes) == story.levels.map(\.minutes).sorted(by: >))
        let bosses = story.screens.compactMap { if case let .level(l, _, true) = $0 { return l } else { return nil } }
        #expect(bosses.count == 1)
        #expect(bosses.first == story.levels.first)
        guard case let .level(_, _, boss) = story.screens[story.screens.count - 5] else { Issue.record("no level before the character"); return }
        #expect(boss)
        #expect(Array(story.screens.suffix(4)) == [.character, .score, .icon, .again])
        #expect(story.screens.first == .coin)
    }

    @Test func bonusStagesNeverScore() {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "P")!
        #expect(story.bonuses.allSatisfy { $0.minutes == 0 && $0.kind == .bonus })
        #expect(story.bonuses.count <= WrappedStory.mostBonuses)
        #expect(story.minutes == story.levels.reduce(0) { $0 + $1.minutes })
        let shown = story.screens.filter { if case .bonus = $0 { return true } else { return false } }.count
        #expect(shown == story.bonuses.count)
    }

    @Test func atMostSevenLevels() {
        #expect(WrappedStory.make(Self.rich, initials: "SER", period: "P")!.levels.count <= WrappedStory.mostLevels)
    }

    @Test func formulas() {
        let levels = Dictionary(uniqueKeysWithValues: WrappedStory.levelsFor(Self.rich).map { ($0.id, $0) })
        // (1,200,000 - 90,000) / 250 = 4,440 min
        #expect(levels["ask"]?.minutes == 4_440)
        // 6,900 × 2 s + 41 × 30 s = 15,030 s = 250.5 min, down to 250
        #expect(levels["mail"]?.minutes == 250)
        // 3,900 × 3 s = 195 min
        #expect(levels["forms"]?.minutes == 195)
        // 300 min at 1.5× saves a third: 100
        #expect(levels["video"]?.minutes == 100)
        // 2,000 × 3 s = 100 min
        #expect(levels["tabs"]?.minutes == 100)
        // The agent's run time, under its cap.
        #expect(levels["agent"]?.minutes == 1_200)
    }

    @Test func theAgentIsCapped() {
        var c = WrappedCounts()
        c.agentTasks = 2
        c.agentManualMinutes = 10_000
        #expect(WrappedStory.levelsFor(c).first { $0.id == "agent" }?.minutes == 2 * Int(WrappedRate.agentCapMinutes))
    }

    @Test func roundedDownAndShownInHoursOrMinutes() {
        var c = WrappedCounts()
        c.formFields = 1_199          // 59.95 min
        let forms = WrappedStory.levelsFor(c).first { $0.id == "forms" }!
        #expect(forms.minutes == 59)
        #expect(forms.score.unit == "MINUTES")
        c.formFields = 2_420          // 121 min
        let more = WrappedStory.levelsFor(c).first { $0.id == "forms" }!
        #expect(more.score.value == 2)
        #expect(more.score.unit == "HOURS")
        #expect(more.big == 2_420)
        #expect(more.back == "~ 2 HOURS BACK")
    }

    @Test func nothingDoneIsNoLevel() {
        #expect(WrappedStory.levelsFor(WrappedCounts()).isEmpty)
        #expect(WrappedStory.bonusesFor(WrappedCounts()).isEmpty)
    }

    @Test func streakOfDays() {
        #expect(WrappedTally.streak([]) == 0)
        #expect(WrappedTally.streak(["2026-10-01"]) == 1)
        #expect(WrappedTally.streak(["2026-10-01", "2026-10-02", "2026-10-04", "2026-10-05", "2026-10-06"]) == 3)
        #expect(WrappedTally.streak(["2026-09-30", "2026-10-01"]) == 2)
    }

    @Test func initials() {
        #expect(WrappedTally.initials("Samuel") == "SAM")
        #expect(WrappedTally.initials("Sam Rivera").count == 3)
        #expect(WrappedTally.initials("さくら") == "YOU")
        #expect(WrappedTally.initials("Al") == "ALA")
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func period() {
        let now = Self.day(2026, 10, 13)
        #expect(WrappedTally.period(first: now.addingTimeInterval(-41 * 86_400), now: now) == "FIRST 41 DAYS")
        #expect(WrappedTally.period(first: now.addingTimeInterval(-400 * 86_400), now: now) == "LAST 100 DAYS")
        #expect(WrappedTally.period(first: nil, now: now) == "LAST 100 DAYS")
    }

    @Test func ledgerSumsByDay() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = WrappedLedger(file: file)
        let now = Date()
        ledger.add(.formFields, 10, at: now)
        ledger.add(.formFields, 5, at: now.addingTimeInterval(-3 * 86_400))
        ledger.add(.formFields, 7, at: now.addingTimeInterval(-200 * 86_400))
        ledger.add("code.tool.snapshot", 3, at: now)
        ledger.add("code.tool.click", 1, at: now)
        #expect(ledger.sum(.formFields, since: now.addingTimeInterval(-100 * 86_400)) == 15)
        #expect(ledger.sums(prefix: "code.tool.", since: now.addingTimeInterval(-86_400)) == ["snapshot": 3, "click": 1])
        ledger.save()
        let again = WrappedLedger(file: file)
        #expect(again.sum(.formFields, since: now.addingTimeInterval(-100 * 86_400)) == 15)
        #expect(again.started != nil)
    }

    @Test func ledgerFeedsTheCounts() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = WrappedLedger(file: file)
        ledger.add(.agentTasks, 3)
        ledger.add(.agentMinutes, 45)
        ledger.add(.ads, 900)
        ledger.add("code.tool.snapshot", 4)
        ledger.add("code.tool.click", 1)
        var c = WrappedCounts()
        WrappedTally.ledger(into: &c, since: Date().addingTimeInterval(-86_400), ledger: ledger)
        #expect(c.agentTasks == 3)
        #expect(c.agentRunMinutes == 45)
        #expect(c.adsBlocked == 900)
        #expect(c.codeTopTool == "snapshot")
    }

    /// Every letter any screen or card writes is one the font draws.
    @Test func theFontHasEveryLetterWritten() {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "FIRST 41 DAYS")!
        var texts: [String] = ["PLAYER 1", "YAB", "WRAPPED", "PRESS START", "INSERT COIN", "WARNING", "BOSS LEVEL", "LEVEL CLEAR",
                               "BOSS DEFEATED", "BONUS STAGE", "FOR FUN, NOT TIME SAVED", "HIGH SCORE", "HOURS SAVED",
                               "S  SHARE YOUR SCORE", "NEW ICON", "UNLOCKED", "ARCADE", "FOR FINISHING YAB WRAPPED", "W  WEAR IT",
                               "IN YOUR DOCK NOW", "IN APPEARANCE > APP ICON", "CONTINUE?", "R  PLAY AGAIN", "GAME OVER",
                               "THANKS FOR PLAYING", "ESC  CLOSE", "TOP SCORES", "YETANOTHERBROWSER.COM/HI/K7M2QP9X", "KEEP PLAYING",
                               "YOUR RHYTHM", "PEAK", "12A", "6A", "12P", "6P", "21 DAYS IN A ROW", "CHARACTER SELECT", "PLAYER 1 IS",
                               "WITH A DASH OF", "ABOUT", "HOURS BACK", "~37H BACK", "YAB WRAPPED  FIRST 41 DAYS  SER"]
        for type in WrappedType.allCases { texts += [type.name, type.code, type.stat, type.line(Self.rich)] }
        for level in story.levels + story.bonuses + WrappedStory.bonusesFor(Self.rich) {
            texts += [level.name, level.unit, level.how, level.back, String(level.big), WrappedStory.number(level.big)] + level.lines
        }
        let known = Set(WrappedFont.glyphs.keys)
        for text in texts {
            for ch in text.uppercased() { #expect(known.contains(ch), "no letter \(ch) for \(text)") }
        }
    }

    /// Each screen draws, start to end, without falling over, and the card does too.
    @Test func everyScreenDraws() throws {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "P")!
        let grid = try #require(WrappedGrid(width: WrappedArcade.width, height: WrappedArcade.height))
        for i in story.screens.indices {
            for t in [0.0, 0.5, 1.2, 3, 8, 20] {
                WrappedArcade.draw(WrappedFrame(story: story, index: i, t: t, clock: t), on: grid)
                #expect(grid.image != nil)
            }
        }
        WrappedArcade.waiting(have: 1, period: "P", clock: 1, reduce: false, on: grid)
        let card = try #require(WrappedArcade.cardGrid(.init(story: story, showHours: false)))
        #expect(card.width * 10 == card.height * 16)
    }

    /// Lit pixels land inside the grid: nothing on a screen is written off its edge.
    @Test func textFitsTheScreen() {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "FIRST 41 DAYS")!
        for level in story.levels + story.bonuses {
            #expect(WrappedFont.measure(level.name, scale: WrappedArcade.fit(level.name, room: 168, most: 2)) <= 168)
            let digits = WrappedStory.number(level.big)
            #expect(WrappedFont.measure(digits, scale: WrappedArcade.fit(digits, room: 168, most: 6)) <= 168)
            for line in level.lines + [level.how] {
                for wrapped in WrappedFont.wrap(line, columns: 25) { #expect(WrappedFont.measure(wrapped, scale: 1) <= WrappedArcade.width || wrapped.split(separator: " ").count == 1) }
            }
        }
    }

    @Test func arcadeIconIsLockedUntilFinished() {
        let was = Store.settings.object(forKey: Wrapped.finishedKey)
        defer { Store.settings.set(was, forKey: Wrapped.finishedKey) }
        Store.settings.set(false, forKey: Wrapped.finishedKey)
        #expect(!AppIconStyle.arcade.unlocked)
        #expect(!AppIconStyle.choices.contains(.arcade))
        #expect(AppIconStyle.arcade.takes != nil)
        Store.settings.set(true, forKey: Wrapped.finishedKey)
        #expect(AppIconStyle.arcade.unlocked)
        #expect(AppIconStyle.choices.contains(.arcade))
    }

    @Test func theYearInDecemberAndEarlyJanuary() {
        #expect(WrappedTally.year(now: Self.day(2026, 10, 13)) == nil)
        #expect(WrappedTally.year(now: Self.day(2026, 12, 1)) == 2026)
        #expect(WrappedTally.year(now: Self.day(2027, 1, 5)) == 2026)
        #expect(WrappedTally.year(now: Self.day(2027, 1, 20)) == nil)
        #expect(WrappedTally.period(first: Self.day(2026, 9, 1), now: Self.day(2026, 12, 10)) == "2026")
        let start = WrappedTally.start(now: Self.day(2026, 12, 10))
        #expect(Calendar.current.dateComponents([.month, .day], from: start) == DateComponents(month: 1, day: 1))
        let october = WrappedTally.start(now: Self.day(2026, 10, 13))
        #expect(abs(october.timeIntervalSince(Self.day(2026, 10, 13)) + 100 * 86_400) < 1)
    }

    @Test func videoAtSpeedSavesWhatTheSpeedTookOff() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = WrappedLedger(file: file)
        // An hour of a talk, 40 minutes of it at 2×: 20 minutes saved.
        WatchRelay.count(content: 3_600, fast: 2_400, fastReal: 1_200, ledger: ledger)
        // Normal speed only: watched, nothing saved.
        WatchRelay.count(content: 600, fast: 0, fastReal: 0, ledger: ledger)
        var c = WrappedCounts()
        WrappedTally.ledger(into: &c, since: Date().addingTimeInterval(-86_400), ledger: ledger)
        #expect(c.videoMinutes == 70)
        #expect(c.fastMinutes == 40)
        #expect(abs(c.fastRate - 2) < 0.0001)
        #expect(WrappedStory.levelsFor(c).first { $0.id == "video" }?.minutes == 20)
    }

    @Test func peaksKeepTheHighest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrapped-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = WrappedLedger(file: file)
        let now = Date()
        ledger.peak(.tabsPeak, 12, at: now)
        ledger.peak(.tabsPeak, 40, at: now)
        ledger.peak(.tabsPeak, 25, at: now)
        ledger.peak(.tabsPeak, 87, at: now.addingTimeInterval(-5 * 86_400))
        ledger.peak(.tabsPeak, 300, at: now.addingTimeInterval(-300 * 86_400))
        #expect(ledger.most(.tabsPeak, since: now.addingTimeInterval(-86_400)) == 40)
        #expect(ledger.most(.tabsPeak, since: now.addingTimeInterval(-100 * 86_400)) == 87)
        ledger.add(.searches, 3)
        var c = WrappedCounts()
        WrappedTally.ledger(into: &c, since: now.addingTimeInterval(-100 * 86_400), ledger: ledger)
        #expect(c.mostOpen == 87)
        #expect(c.searches == 3)
    }

    @Test func yearlyBonuses() {
        var c = WrappedCounts()
        c.videoMinutes = 2_400; c.fastMinutes = 600; c.fastRate = 1.5
        c.mostOpen = 87
        c.searches = 1_200
        let ids = WrappedStory.bonusesFor(c).map(\.id)
        #expect(ids.contains("binge"))
        #expect(ids.contains("hoard"))
        #expect(ids.contains("searches"))
        #expect(WrappedStory.bonusesFor(c).first { $0.id == "binge" }?.big == 40)
    }

    @Test func momentsAreTheHundredthDayAndTheYear() {
        let now = Self.day(2026, 10, 13)
        let cal = Calendar.current
        let hundred = cal.date(byAdding: .day, value: -100, to: now)!
        #expect(WrappedMoment.current(now: now, first: hundred)?.id == "100-days")
        #expect(WrappedMoment.current(now: now, first: cal.date(byAdding: .day, value: -103, to: now)!)?.id == "100-days")
        #expect(WrappedMoment.current(now: now, first: cal.date(byAdding: .day, value: -104, to: now)!) == nil)
        #expect(WrappedMoment.current(now: now, first: cal.date(byAdding: .day, value: -40, to: now)!) == nil)
        #expect(WrappedMoment.current(now: now, first: nil) == nil)
        let december = Self.day(2026, 12, 2)
        #expect(WrappedMoment.current(now: december, first: hundred) == WrappedMoment(id: "year-2026", title: "Your 2026"))
        #expect(WrappedMoment.current(now: Self.day(2027, 1, 3), first: nil)?.id == "year-2026")
    }

    @Test func theHundredthDayGivesWayToTheYear() {
        let cal = Calendar.current
        // Day 100 on December 20: the year's alone.
        let first = cal.date(byAdding: .day, value: -100, to: Self.day(2026, 12, 20))!
        #expect(WrappedMoment.current(now: Self.day(2026, 12, 20), first: first)?.id == "year-2026")
        // Day 100 on November 15, its days reaching November 18: let go.
        let november = cal.date(byAdding: .day, value: -100, to: Self.day(2026, 11, 15))!
        #expect(WrappedMoment.current(now: Self.day(2026, 11, 15), first: november) == nil)
        // Day 100 on November 10, done by the 13th: asked.
        let early = cal.date(byAdding: .day, value: -100, to: Self.day(2026, 11, 10))!
        #expect(WrappedMoment.current(now: Self.day(2026, 11, 10), first: early)?.id == "100-days")
        // Day 100 on January 20: well clear, asked.
        let january = cal.date(byAdding: .day, value: -100, to: Self.day(2027, 1, 20))!
        #expect(WrappedMoment.current(now: Self.day(2027, 1, 20), first: january)?.id == "100-days")
        #expect(WrappedMoment.season(Self.day(2026, 11, 17)))
        #expect(!WrappedMoment.season(Self.day(2026, 11, 16)))
        #expect(WrappedMoment.season(Self.day(2027, 1, 7)))
        #expect(!WrappedMoment.season(Self.day(2027, 1, 8)))
    }

    @Test func theYearsArcadeDraws() throws {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "2026")!
        #expect(story.festive)
        #expect(story.nextYear == 2027)
        #expect(!WrappedStory.make(Self.rich, initials: "SER", period: "FIRST 41 DAYS")!.festive)
        let grid = try #require(WrappedGrid(width: WrappedArcade.width, height: WrappedArcade.height))
        for i in story.screens.indices {
            for t in [0.0, 1.5, 5, 11, 14] { WrappedArcade.draw(WrappedFrame(story: story, index: i, t: t, clock: t), on: grid) }
        }
        #expect(WrappedArcade.cardGrid(.init(story: story)) != nil)
        let known = Set(WrappedFont.glyphs.keys)
        for text in ["HAPPY NEW YEAR", "INSERT GIFT", "2027 IN", "HAPPY", "2027!", "YAB WRAPPED"] {
            for ch in text { #expect(known.contains(ch)) }
        }
    }

    @Test func theDelegatorIsWhoTheAgentCarries() {
        var c = WrappedCounts()
        c.agentTasks = 120; c.agentRunMinutes = 900
        c.formFields = 600; c.mailCleared = 1_200
        let story = WrappedStory.make(c, initials: "SER", period: "P")
        // Forms 30 min and mail 40 under the floor of 20? both above: three levels.
        let me = WrappedCharacter.of(c, minutesBack: story?.minutes ?? 970)
        #expect(me.type == .delegator)
        #expect(me.line == "120 TASKS HANDED OFF")
        #expect(me.bars.count == 4)
        #expect(me.bars.first?.stat == "AGENT")
    }

    @Test func theStrongestPastItsFloorWinsAndTheNextIsTheDash() {
        // The rich world: the agent is a small share of a big ⌘J year.
        let me = WrappedCharacter.of(Self.rich, minutesBack: WrappedStory.make(Self.rich, initials: "S", period: "P")!.minutes)
        #expect(me.type == .builder)
        #expect(me.dash == .sweeper)
        #expect(me.bars.map(\.value) == me.bars.map(\.value).sorted(by: >))
    }

    @Test func noOnePastAFloorIsTheRegular() {
        var c = WrappedCounts()
        c.tabJumps = 600; c.formFields = 900; c.mailCleared = 1_500; c.longestStreak = 12
        let me = WrappedCharacter.of(c, minutesBack: 120)
        #expect(me.type == .regular)
        #expect(me.dash == nil)
        #expect(me.line == "12 DAYS IN A ROW")
        #expect(me.bars.first?.stat == "DAYS")
    }

    @Test func theCloserKeepsFewOpen() {
        var c = WrappedCounts()
        c.mostOpen = 9; c.tabsTidied = 2_340
        #expect(WrappedCharacter.of(c, minutesBack: 60).type == .closer)
        c.mostOpen = 40
        #expect(WrappedCharacter.of(c, minutesBack: 60).type != .closer)
    }

    @Test func barsRunOneToTen() {
        #expect(WrappedCharacter.bar(0) == 3)
        #expect(WrappedCharacter.bar(1) == 6)
        #expect(WrappedCharacter.bar(2) == 9)
        #expect(WrappedCharacter.bar(40) == 10)
    }

    @Test func theRhythmComesAfterTheCoinWhenThereAreHours() {
        var c = Self.rich
        c.hours = (0..<24).map { $0 }
        let story = WrappedStory.make(c, initials: "SER", period: "P")!
        #expect(story.screens.prefix(2) == [.coin, .rhythm])
        c.hours = []
        #expect(!WrappedStory.make(c, initials: "SER", period: "P")!.screens.contains(.rhythm))
    }

    @Test func thePostSaysTheCharacter() {
        var c = WrappedCounts()
        c.agentTasks = 120; c.agentRunMinutes = 900; c.formFields = 600; c.mailCleared = 1_200
        let story = WrappedStory.make(c, initials: "SER", period: "FIRST 41 DAYS")!
        let model = WrappedModel(story: story, waiting: 3, period: story.period, initials: "SER")
        #expect(model.postText.hasPrefix("I'm The Delegator in Yab Wrapped: 120 tasks handed off. About"))
        model.showHours = false
        #expect(!model.postText.contains("hours back"))
    }

    @Test func soundsAreCuedByTheScreensClock() {
        let story = WrappedStory.make(Self.rich, initials: "SER", period: "P")!
        #expect(WrappedSound.cues(.coin, story: story).map(\.sfx) == [.roll, .coin])
        let select = WrappedArcade.select(story)
        let character = WrappedSound.cues(.character, story: story)
        #expect(character.filter { $0.sfx == .step }.count == select.ticks.count)
        #expect(character.contains { $0.sfx == .land && $0.at == select.land })
        #expect(character.contains { $0.sfx == .dash } == (story.character.dash != nil))
        #expect(character.map(\.at) == character.map(\.at).sorted())
        #expect(WrappedSound.cues(.again, story: story).contains { $0.sfx == .over })
        let year = WrappedStory.make(Self.rich, initials: "SER", period: "2026")!
        #expect(WrappedSound.cues(.again, story: year).contains { $0.sfx == .firework })
    }

    @Test func everySoundIsMadeAndQuietEnough() {
        let synth = WrappedSynth(rate: 44_100)
        for sfx in WrappedSfx.allCases {
            let s = synth.sound(sfx)
            #expect(!s.isEmpty, "\(sfx) is empty")
            #expect(s.allSatisfy { abs($0) <= 1.0001 }, "\(sfx) clips")
            #expect(Double(s.count) / 44_100 < 1.5, "\(sfx) runs long")
        }
    }

    @Test func mutingIsKept() {
        let was = Store.settings.object(forKey: WrappedSound.mutedKey)
        defer { Store.settings.set(was, forKey: WrappedSound.mutedKey) }
        WrappedSound.muted = true
        #expect(Store.settings.bool(forKey: WrappedSound.mutedKey))
        WrappedSound.muted = false
        #expect(!WrappedSound.muted)
    }
}
