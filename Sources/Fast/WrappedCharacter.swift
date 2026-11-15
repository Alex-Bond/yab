import Foundation

// Who the player is, for Yab Wrapped's CHARACTER SELECT and the card to
// post: one of a dozen types, read off the same counts as the levels.
// Each type has a floor; its strength is how far past the floor the player
// went. The strongest past its floor wins, the next one past its own is
// "with a dash of", and with no one past a floor the player is THE REGULAR.
// The four strongest are the bars under the name, 1 to 10. Nothing is
// compared with other people: nothing leaves the Mac to compare with.

enum WrappedType: String, CaseIterable, Equatable {
    case delegator, nightOwl, closer, hoarder, sweeper, asker, speedrunner, binger, builder, autopilot, streaker, regular

    /// Three letters for the select grid.
    var code: String {
        switch self {
        case .delegator: return "DEL"
        case .nightOwl: return "OWL"
        case .closer: return "CLS"
        case .hoarder: return "HRD"
        case .sweeper: return "SWP"
        case .asker: return "ASK"
        case .speedrunner: return "SPD"
        case .binger: return "BNG"
        case .builder: return "BLD"
        case .autopilot: return "AUT"
        case .streaker: return "STK"
        case .regular: return "REG"
        }
    }

    var name: String {
        switch self {
        case .delegator: return "THE DELEGATOR"
        case .nightOwl: return "NIGHT OWL"
        case .closer: return "THE CLOSER"
        case .hoarder: return "THE HOARDER"
        case .sweeper: return "THE SWEEPER"
        case .asker: return "THE ASKER"
        case .speedrunner: return "SPEEDRUNNER"
        case .binger: return "THE BINGER"
        case .builder: return "THE BUILDER"
        case .autopilot: return "AUTOPILOT"
        case .streaker: return "THE STREAKER"
        case .regular: return "THE REGULAR"
        }
    }

    /// What its bar is called.
    var stat: String {
        switch self {
        case .delegator: return "AGENT"
        case .nightOwl: return "NIGHT"
        case .closer: return "CALM"
        case .hoarder: return "TABS"
        case .sweeper: return "INBOX"
        case .asker: return "ASK"
        case .speedrunner: return "SPEED"
        case .binger: return "VIDEO"
        case .builder: return "CODE"
        case .autopilot: return "FORMS"
        case .streaker: return "STREAK"
        case .regular: return "DAYS"
        }
    }

    var ink: WrappedInk {
        switch self {
        case .delegator: return .violet
        case .nightOwl, .streaker: return .gold
        case .closer: return .cyan
        case .hoarder, .binger: return .pink
        case .sweeper: return .orange
        case .asker: return .blue
        case .speedrunner: return .red
        case .builder, .autopilot: return .green
        case .regular: return .dim
        }
    }

    /// The player's own number for it, as a line.
    func line(_ c: WrappedCounts) -> String {
        let n = WrappedStory.number
        switch self {
        case .delegator: return "\(n(c.agentTasks)) TASKS HANDED OFF"
        case .nightOwl:
            let hour = c.busiestHour.map { "PEAK \(WrappedStory.hour($0))" } ?? "AFTER DARK"
            return c.agentNightMinutes >= 60 ? "\(hour) · \(Int(c.agentNightMinutes / 60))H OVERNIGHT" : hour
        case .closer: return "NEVER MORE THAN \(c.mostOpen) OPEN"
        case .hoarder: return "\(c.mostOpen) TABS OPEN AT ONCE"
        case .sweeper: return "INBOX ZERO \(c.mailInboxZeroDays) TIMES"
        case .asker: return "\(n(c.askPageWords)) WORDS READ FOR YOU"
        case .speedrunner: return "\(Int(c.fastMinutes)) MIN AT SPEED"
        case .binger: return "\(Int(c.videoMinutes / 60))H OF VIDEO"
        case .builder: return "\(n(c.codeCalls)) CALLS FROM YOUR AGENTS"
        case .autopilot: return "\(n(c.formFields)) FIELDS FILLED"
        case .streaker, .regular: return "\(c.longestStreak) DAYS IN A ROW"
        }
    }

    /// How far past its floor the player went: 1 is the floor.
    func strength(_ c: WrappedCounts, minutesBack: Int) -> Double {
        switch self {
        case .delegator:
            let share = minutesBack > 0 ? c.agentRunMinutes / Double(minutesBack) : 0
            return min(Double(c.agentTasks) / 50, share / 0.4)
        case .nightOwl:
            let late = c.busiestHour.map { $0 >= 22 || $0 < 3 } ?? false
            return max(late ? 1.2 : 0, Double(c.agentNightTasks) / 10)
        case .closer:
            guard c.mostOpen > 0, c.mostOpen <= 12 else { return 0 }
            return Double(c.tabsTidied) / 500
        case .hoarder: return Double(c.mostOpen) / 60
        case .sweeper: return Double(c.mailInboxZeroDays) / 10
        case .asker: return Double(c.asks) / 300
        case .speedrunner:
            guard c.videoMinutes >= 600 else { return 0 }
            return (c.fastMinutes / c.videoMinutes) / 0.5
        case .binger: return c.videoMinutes / 6_000
        case .builder: return Double(c.codeCalls) / 1_000
        case .autopilot: return Double(c.formFields) / 2_000
        case .streaker: return Double(c.longestStreak) / 60
        case .regular: return 0
        }
    }
}

/// The player, as the select screen and the card show them.
struct WrappedCharacter: Equatable {
    let type: WrappedType
    /// The next strongest past its floor, if any.
    let dash: WrappedType?
    let line: String
    /// The four strongest, 1 to 10, the type's first.
    let bars: [(stat: String, value: Int)]

    static func == (a: Self, b: Self) -> Bool {
        a.type == b.type && a.dash == b.dash && a.line == b.line && a.bars.map(\.stat) == b.bars.map(\.stat) && a.bars.map(\.value) == b.bars.map(\.value)
    }

    /// A strength as a bar: the floor is 6, twice it 9, never past 10.
    static func bar(_ s: Double) -> Int { max(1, min(10, Int((3 + 3 * s).rounded()))) }

    static func of(_ c: WrappedCounts, minutesBack: Int) -> WrappedCharacter {
        let ranked = WrappedType.allCases.filter { $0 != .regular }
            .map { ($0, $0.strength(c, minutesBack: minutesBack)) }
            .sorted { $0.1 > $1.1 }
        let past = ranked.filter { $0.1 >= 1 }
        let type = past.first?.0 ?? .regular
        let dash = past.dropFirst().first?.0
        let bars = Array(ranked.prefix(4)).map { (stat: $0.0.stat, value: bar($0.1)) }
        let shown = type == .regular ? [(stat: WrappedType.regular.stat, value: bar(Double(c.longestStreak) / 60))] + bars.prefix(3) : bars
        return WrappedCharacter(type: type, dash: dash, line: type.line(c), bars: Array(shown))
    }
}
