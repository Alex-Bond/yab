import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// The Mac's Today on a space's page (Settings › Today › Your Mac's Tabs,
/// docs/iphone-mac-tabs.md, direction D): under This iPhone's line, a line
/// for each Mac with tabs of today in the space, its tab in front first.
/// Read from what sync already keeps apart (`SyncMirror.elsewhere`); no
/// records of its own.
struct MacTodayLine: Equatable, Identifiable {
    /// The Mac's device id; "mac" when sync names no Mac yet.
    var id: String
    var name: String
    /// What it is doing; up, or since when it is asleep, closed or silent.
    var state: MacState
    var rows: [MacTodayRow]
}

struct MacTodayRow: Equatable, Identifiable {
    var tab: SyncTab
    /// The tab in front on that Mac.
    var front: Bool
    /// Closed from here while the Mac is down: it closes when it wakes.
    var closing: Bool
    var id: String { tab.id }
}

enum MacToday {
    /// The rows a line shows before "Show all N".
    static let shown = 5

    /// The lines of a space, in the Macs' order (the one used last first).
    /// A tab of today with no `device`, or a Mac's sync no longer lists,
    /// counts as the first Mac's (docs/sync.md, "Today is each device's own").
    /// A Mac with nothing open in the space has no line.
    static func lines(tabs: [SyncTab], macs: [SyncMac], closing: [SyncTab] = [], fallbackName: String = "Your Mac") -> [MacTodayLine] {
        let known = macs.isEmpty ? [SyncMac(id: "mac", name: fallbackName, model: "", online: true, state: .up)] : macs
        var lines = known.map { MacTodayLine(id: $0.id, name: $0.name, state: $0.state, rows: []) }
        func owner(_ tab: SyncTab) -> Int { tab.device.flatMap { d in known.firstIndex { $0.id == d } } ?? 0 }
        let all = tabs.map { ($0, false) } + closing.filter { gone in !tabs.contains { $0.id == gone.id } }.map { ($0, true) }
        for (tab, gone) in all.sorted(by: { RecordShapes.placed($0.0, $1.0) }) {
            let i = owner(tab)
            lines[i].rows.append(MacTodayRow(tab: tab, front: !gone && known[i].front?.tab == tab.id, closing: gone))
        }
        for i in lines.indices {
            // The tab in front there leads, the rest in the Mac's own order.
            if let f = lines[i].rows.firstIndex(where: \.front), f > 0 { lines[i].rows.insert(lines[i].rows.remove(at: f), at: 0) }
        }
        return lines.filter { !$0.rows.isEmpty }
    }

    /// The rows a line shows: the first five, or all of them once asked.
    static func visible(_ line: MacTodayLine, all: Bool) -> (rows: [MacTodayRow], more: Int?) {
        guard !all, line.rows.count > shown else { return (line.rows, nil) }
        return (Array(line.rows.prefix(shown)), line.rows.count)
    }

    /// The words at the end of a Mac's line: when it went down, else how
    /// many tabs while its list is folded, else nothing.
    static func note(_ line: MacTodayLine, folded: Bool, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String? {
        if !line.state.isUp {
            let word: String = switch line.state {
            case .closed: "Yab closed"
            case .silent: "No word"
            default: "Asleep"
            }
            guard let since = line.state.since else { return word }
            return "\(word) · \(at(since, now: now, calendar: calendar, locale: locale))"
        }
        guard folded else { return nil }
        return line.rows.count == 1 ? "1 tab" : "\(line.rows.count) tabs"
    }

    /// A row's second line: its site, or that it is the one in front there.
    static func subtitle(_ row: MacTodayRow, up: Bool, host: String) -> String {
        if row.closing { return "Closes when your Mac wakes" }
        if row.front { return up ? "In front on Mac" : "Was in front on Mac" }
        return host
    }

    /// 8:12 today, else the day.
    static func at(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            // The hour without a leading zero, as a 24-hour clock says it too: 8:12.
            let time = date.formatted(style.hour(.defaultDigits(amPM: .omitted)).minute())
            guard time.count > 1, time.first == "0", time.dropFirst().first?.isNumber == true else { return time }
            return String(time.dropFirst())
        }
        return date.formatted(style.month(.abbreviated).day())
    }
}
