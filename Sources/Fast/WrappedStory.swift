import Foundation

// Yab Wrapped: what Yab did for you over a stretch of time, and how much
// time it gave back, told as an arcade game. This file is the game's
// rules, kept free of any store so tests can play them: counts in
// (WrappedCounts, gathered by WrappedTally), the story out.
//
// Only what you did is in it. A level shows when its count clears its
// floor; fewer than three levels and there is no Wrapped yet. Time saved
// is counted with careful constants and rounded down, and each level says
// how it was counted. Fun numbers that are not time saved (ads blocked,
// memory freed) are bonus stages and never add to the score.
// docs/wrapped.md has the table.

/// What Yab's stores say happened in the period. Zero where nothing
/// recorded it.
struct WrappedCounts: Equatable {
    var days = 100

    // Agent
    var agentTasks = 0
    /// What the agent judged the tasks would have taken by hand, summed,
    /// when it said; else the tasks' own running time stands in.
    var agentManualMinutes: Double = 0
    var agentRunMinutes: Double = 0
    /// The longest task, its run time and its words.
    var agentLongestMinutes: Double = 0
    var agentLongestTitle = ""
    var agentNightTasks = 0
    var agentNightMinutes: Double = 0

    // ⌘J
    var asks = 0
    /// Words of the pages asked about, and of the answers.
    var askPageWords = 0
    var askAnswerWords = 0

    // Mail
    var mailCleared = 0
    var mailUnsubscribes = 0
    var mailInboxZeroDays = 0

    // Forms
    var formFields = 0

    // Code agents using Yab (yab CLI, MCP)
    var codeCalls = 0
    var codeTopTool = ""
    var codeAgents = 0

    // Video and audio played on pages, and in the small window
    var videoMinutes: Double = 0
    var pipMinutes: Double = 0
    /// Minutes of video watched faster than 1×, and how much faster.
    var fastMinutes: Double = 0
    var fastRate: Double = 1

    // Tabs
    var tabJumps = 0
    var tabsTidied = 0
    var mostOpen = 0

    // Bonus stages
    var searches = 0
    var adsBlocked = 0
    var memoryFreedMB = 0
    var tabsSlept = 0
    var callsJoined = 0
    var phoneTabs = 0
    var pagesRead = 0
    var busiestHour: Int?
    /// Visits by local hour of the day, 0 to 23, for the rhythm screen.
    var hours: [Int] = []
    var longestStreak = 0
    var boosts = 0
    var friends = 0
}

/// The game's constants: how much each thing done is worth. Careful on
/// purpose; docs/wrapped.md explains each.
enum WrappedRate {
    static let readingWordsPerMinute = 250.0
    static let secondsPerMailCleared = 2.0
    static let secondsPerUnsubscribe = 30.0
    static let secondsPerFormField = 3.0
    static let secondsPerTabJump = 3.0
    /// No one task counts for more than this, whatever the agent thought.
    static let agentCapMinutes = 90.0
}

/// One level or bonus stage, ready for the screen.
struct WrappedLevel: Identifiable, Equatable {
    enum Kind: Equatable { case level, bonus }

    let id: String
    let name: String
    let kind: Kind
    let sprite: WrappedSprite
    let ink: WrappedInk
    /// Time saved, whole minutes, rounded down; 0 for a bonus stage.
    let minutes: Int
    /// The number the screen counts up to, and what it counts: for a
    /// level, what was done (tasks, answers); the time back is `score`.
    let big: Int
    let unit: String
    /// One or two lines under it.
    let lines: [String]
    /// How the time was counted, for HOW?
    let how: String

    /// The time back, as a level says it under its count: "~ 18 HOURS BACK".
    var back: String { "~ \(score.value) \(score.unit) BACK" }

    /// Hours to show: whole hours, or minutes under an hour.
    var score: (value: Int, unit: String) {
        minutes >= 60 ? (minutes / 60, minutes / 60 == 1 ? "HOUR" : "HOURS") : (minutes, minutes == 1 ? "MINUTE" : "MINUTES")
    }
}

/// One screen of the story.
enum WrappedScreen: Equatable {
    case coin
    /// When in the day you browse: 24 bars, the peak hour, the streak.
    case rhythm
    case level(WrappedLevel, number: Int, boss: Bool)
    case bonus(WrappedLevel)
    /// CHARACTER SELECT: the cursor runs the types and stops on yours.
    case character
    case score
    case icon
    case again

    var seconds: Double {
        switch self {
        case .coin: return 4
        case .rhythm: return 5
        case .character: return 7.5
        case .level(_, _, let boss): return boss ? 6.5 : 5.5
        case .bonus: return 4.5
        case .score: return 0
        case .icon: return 0
        case .again: return 0
        }
    }
}

struct WrappedStory: Equatable {
    var initials: String
    var period: String
    /// Ranked, the biggest last: it is the boss.
    var levels: [WrappedLevel]
    var bonuses: [WrappedLevel]
    var screens: [WrappedScreen]
    var character: WrappedCharacter
    /// For the rhythm screen.
    var hours: [Int] = []
    var peak: Int?
    var streak = 0

    var minutes: Int { levels.reduce(0) { $0 + $1.minutes } }

    /// The year's Wrapped ("2026"): snow, a garland, a gift for a coin, and
    /// the countdown to the next year at the end.
    var festive: Bool { Int(period) != nil }
    var nextYear: Int { (Int(period) ?? 0) + 1 }

    /// Fewer levels than this and there is no Wrapped yet.
    static let fewest = 3
    static let mostLevels = 7
    static let mostBonuses = 3
    /// A level counts from this many minutes saved.
    static let floorMinutes = 20

    /// The story, or nil when not enough happened yet.
    static func make(_ c: WrappedCounts, initials: String, period: String) -> WrappedStory? {
        let levels = Array(levelsFor(c).filter { $0.minutes >= floorMinutes }
            .sorted { $0.minutes > $1.minutes }
            .prefix(mostLevels))
        guard levels.count >= fewest else { return nil }
        let bonuses = Array(bonusesFor(c).prefix(mostBonuses))
        // The smallest first, building to the boss.
        let ordered = Array(levels.reversed())
        var screens: [WrappedScreen] = [.coin]
        if c.hours.count == 24, c.hours.contains(where: { $0 > 0 }) { screens.append(.rhythm) }
        var bonusLeft = bonuses[...]
        for (i, level) in ordered.enumerated() {
            let boss = i == ordered.count - 1
            screens.append(.level(level, number: i + 1, boss: boss))
            // A bonus stage after every second level, none after the boss.
            if !boss, i % 2 == 1, let bonus = bonusLeft.popFirst() { screens.append(.bonus(bonus)) }
        }
        // Any bonus left goes before the boss.
        if !bonusLeft.isEmpty, let bossAt = screens.lastIndex(where: { if case .level(_, _, true) = $0 { return true }; return false }) {
            screens.insert(contentsOf: bonusLeft.map { .bonus($0) }, at: bossAt)
        }
        screens += [.character, .score, .icon, .again]
        let back = levels.reduce(0) { $0 + $1.minutes }
        return WrappedStory(initials: initials, period: period, levels: levels, bonuses: bonuses, screens: screens,
                            character: WrappedCharacter.of(c, minutesBack: back), hours: c.hours, peak: c.busiestHour, streak: c.longestStreak)
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func levelsFor(_ c: WrappedCounts) -> [WrappedLevel] {
        var out: [WrappedLevel] = []

        if c.agentTasks > 0 {
            let manual = c.agentManualMinutes > 0 ? c.agentManualMinutes : c.agentRunMinutes
            let capped = min(manual, Double(c.agentTasks) * WrappedRate.agentCapMinutes)
            var lines: [String] = []
            if c.agentNightTasks > 0 { lines.append("\(c.agentNightTasks) WHILE YOU SLEPT") }
            else if c.agentLongestMinutes >= 5 { lines.append("LONGEST: \(Int(c.agentLongestMinutes)) MIN") }
            out.append(level("agent", "AGENT", .agent, .violet, minutes: capped, count: c.agentTasks, counting: "TASKS HANDED OFF", lines: lines,
                             how: "THE AGENT'S OWN ESTIMATE OF EACH TASK BY HAND, AT MOST \(Int(WrappedRate.agentCapMinutes)) MIN A TASK"))
        }
        if c.asks > 0, c.askPageWords > c.askAnswerWords {
            let minutes = Double(c.askPageWords - c.askAnswerWords) / WrappedRate.readingWordsPerMinute
            out.append(level("ask", "ASK", .ask, .blue, minutes: minutes, count: c.asks, counting: "ANSWERS",
                             lines: ["\(number(c.askPageWords)) WORDS READ FOR YOU"],
                             how: "PAGE WORDS MINUS ANSWER WORDS, AT 250 A MINUTE"))
        }
        if c.mailCleared + c.mailUnsubscribes > 0 {
            let minutes = (Double(c.mailCleared) * WrappedRate.secondsPerMailCleared + Double(c.mailUnsubscribes) * WrappedRate.secondsPerUnsubscribe) / 60
            var lines: [String] = []
            if c.mailInboxZeroDays > 0 { lines.append("INBOX ZERO \(c.mailInboxZeroDays) \(c.mailInboxZeroDays == 1 ? "TIME" : "TIMES")") }
            else if c.mailUnsubscribes > 0 { lines.append("\(number(c.mailUnsubscribes)) UNSUBSCRIBES") }
            out.append(level("mail", "MAIL", .mail, .orange, minutes: minutes, count: c.mailCleared, counting: "MAILS CLEARED", lines: lines,
                             how: "2 S A MAIL CLEARED BY KEYS, 30 S AN UNSUBSCRIBE"))
        }
        if c.formFields > 0 {
            out.append(level("forms", "FORMS", .forms, .green, minutes: Double(c.formFields) * WrappedRate.secondsPerFormField / 60,
                             count: c.formFields, counting: "FIELDS FILLED FOR YOU", lines: [], how: "3 S A FIELD FILLED"))
        }
        if c.fastMinutes > 0, c.fastRate > 1 {
            let saved = c.fastMinutes * (1 - 1 / c.fastRate)
            out.append(level("video", "VIDEO", .video, .pink, minutes: saved, count: Int(c.fastMinutes), counting: "MIN WATCHED FASTER",
                             lines: c.pipMinutes >= 1 ? ["\(Int(c.pipMinutes)) MIN IN PICTURE IN PICTURE"] : [],
                             how: "THE MINUTES A FASTER SPEED TOOK OFF"))
        }
        if c.tabJumps > 0 {
            let lines = c.tabsTidied > 0 ? ["\(number(c.tabsTidied)) TABS TIDIED"] : []
            out.append(level("tabs", "TABS", .tabs, .cyan, minutes: Double(c.tabJumps) * WrappedRate.secondsPerTabJump / 60,
                             count: c.tabJumps, counting: "JUMPS TO AN OPEN TAB", lines: lines, how: "3 S A JUMP TO A TAB ALREADY OPEN"))
        }
        return out
    }

    /// The fun numbers, biggest surprise first.
    static func bonusesFor(_ c: WrappedCounts) -> [WrappedLevel] {
        var out: [WrappedLevel] = []
        if c.codeCalls >= 50 {
            out.append(bonus("code", "CODE AGENTS", .code, .gold, big: c.codeCalls, unit: "CALLS",
                             lines: [c.codeAgents > 1 ? "FROM \(c.codeAgents) AGENTS" : "FROM YOUR CODING AGENT",
                                     c.codeTopTool.isEmpty ? "" : "MOST: \(c.codeTopTool.uppercased())"].filter { !$0.isEmpty }))
        }
        if c.adsBlocked >= 500 {
            out.append(bonus("ads", "INVADERS", .invader, .green, big: c.adsBlocked, unit: "ADS SHOT DOWN", lines: ["NONE OF THEM REACHED YOU"]))
        }
        if c.agentNightTasks >= 3 {
            out.append(bonus("night", "NIGHT SHIFT", .moon, .violet, big: Int(c.agentNightMinutes / 60), unit: c.agentNightMinutes / 60 >= 2 ? "HOURS" : "HOUR",
                             lines: ["YOUR AGENT WORKED WHILE YOU SLEPT", "\(c.agentNightTasks) TASKS BY MORNING"]))
        }
        if c.videoMinutes >= 600 {
            let hours = Int(c.videoMinutes / 60)
            var lines = ["OF VIDEO AND AUDIO"]
            if c.fastMinutes >= 60 { lines.append("\(Int(c.fastMinutes / 60)) H OF IT FASTER") }
            out.append(bonus("binge", "BINGE", .video, .pink, big: hours, unit: hours == 1 ? "HOUR" : "HOURS", lines: lines))
        }
        if c.mostOpen >= 30 {
            out.append(bonus("hoard", "TAB HOARD", .tabs, .cyan, big: c.mostOpen, unit: "TABS OPEN AT ONCE", lines: ["YOUR RECORD DAY"]))
        }
        if c.memoryFreedMB >= 1024 {
            let gb = c.memoryFreedMB / 1024
            out.append(bonus("memory", "SLEEPY TABS", .memory, .cyan, big: gb, unit: "GB OF MEMORY FREED",
                             lines: ["\(number(c.tabsSlept)) TABS PUT TO SLEEP"]))
        }
        if c.callsJoined >= 5 {
            out.append(bonus("calls", "CALLS", .calls, .pink, big: c.callsJoined, unit: "CALLS JOINED", lines: ["FROM YAB, ON TIME"]))
        }
        if c.phoneTabs >= 10 {
            out.append(bonus("phone", "HANDOFF", .phone, .blue, big: c.phoneTabs, unit: "TABS", lines: ["PASSED BETWEEN MAC AND IPHONE"]))
        }
        if c.longestStreak >= 7 {
            out.append(bonus("streak", "STREAK", .heart, .red, big: c.longestStreak, unit: "DAYS IN A ROW",
                             lines: c.busiestHour.map { ["BUSIEST AT \(hour($0))"] } ?? []))
        }
        if c.searches >= 300 {
            out.append(bonus("searches", "SEARCHES", .search, .blue, big: c.searches, unit: "SEARCHES", lines: ["FROM THE FIELD"]))
        }
        if c.boosts >= 1 {
            out.append(bonus("boosts", "BOOSTS", .boosts, .gold, big: c.boosts, unit: c.boosts == 1 ? "BOOST" : "BOOSTS", lines: ["MADE OR USED"]))
        }
        if c.friends >= 1 {
            out.append(bonus("friends", "CO-OP", .friends, .pink, big: c.friends, unit: c.friends == 1 ? "FRIEND JOINED" : "FRIENDS JOINED", lines: ["PLAYER 2 HAS ENTERED"]))
        }
        return out
    }

    static func hour(_ h: Int) -> String {
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? "AM" : "PM")"
    }

    /// A level: the count is what the screen counts up to, what was done;
    /// the minutes, the time it gave back, are said under it, smaller.
    private static func level(_ id: String, _ name: String, _ sprite: WrappedSprite, _ ink: WrappedInk,
                              minutes: Double, count: Int, counting: String, lines: [String], how: String) -> WrappedLevel {
        let m = max(0, Int(minutes.rounded(.down)))
        return WrappedLevel(id: id, name: name, kind: .level, sprite: sprite, ink: ink, minutes: m, big: count,
                            unit: counting, lines: lines, how: how)
    }

    private static func bonus(_ id: String, _ name: String, _ sprite: WrappedSprite, _ ink: WrappedInk,
                              big: Int, unit: String, lines: [String]) -> WrappedLevel {
        WrappedLevel(id: id, name: name, kind: .bonus, sprite: sprite, ink: ink, minutes: 0, big: big, unit: unit, lines: lines, how: "")
    }
}
