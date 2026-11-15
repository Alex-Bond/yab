import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

// Which Mac work from this iPhone goes to, and what the phone says of a Mac
// that can't start it yet: one place for the rules and the words, read by
// the chat's wait row, the Chats card, Now, the page menu, the toasts,
// the + menu and Settings › Sync (docs/mac-asleep-status.md).

/// What a Mac is doing, as far as this iPhone heard.
public nonisolated enum MacState: Equatable, Sendable {
    /// Heard in the last 150 s and not asleep.
    case up
    /// Said it is going to sleep, at `since`.
    case asleep(since: Date)
    /// Said Yab on it quit, at `since`.
    case closed(since: Date)
    /// Not heard since `since` and said nothing of sleep: no network, a crash.
    case silent(since: Date?)

    public var isUp: Bool { self == .up }

    public var since: Date? {
        switch self {
        case .up: nil
        case let .asleep(since), let .closed(since): since
        case let .silent(since): since
        }
    }

    /// From its last presence and when it was last heard.
    public static func of(presence: SyncPresence?, lastSeen: Date?, now: Date, onlineFor: TimeInterval) -> MacState {
        if let presence, presence.asleep {
            let at = Date(timeIntervalSince1970: presence.at)
            return presence.why == "quit" ? .closed(since: at) : .asleep(since: at)
        }
        if let lastSeen, now.timeIntervalSince(lastSeen) < onlineFor { return .up }
        return .silent(since: lastSeen)
    }
}

public nonisolated enum MacPick {
    /// The Mac new work goes to: the one picked by hand while it can take
    /// it; else the one used last that is up; with none up, the one used
    /// last all the same, and the phone says it waits.
    public static func pick(_ macs: [SyncMac], chosen: String?, can: (SyncMac) -> Bool = { _ in true }) -> SyncMac? {
        let able = macs.filter(can)
        if let chosen, let mac = able.first(where: { $0.id == chosen }) { return mac }
        let used = { (mac: SyncMac) in mac.usedAt ?? mac.lastSeen ?? .distantPast }
        let up = able.filter { $0.state.isUp }
        return (up.isEmpty ? able : up).max { (used($0), $1.name) < (used($1), $0.name) }
    }

    /// Another Mac that is up and can take it, for "Ask on Mac mini".
    public static func other(than id: String, in macs: [SyncMac], can: (SyncMac) -> Bool = { _ in true }) -> SyncMac? {
        let up = macs.filter { $0.id != id && $0.state.isUp && can($0) }
        return up.max { ($0.usedAt ?? .distantPast) < ($1.usedAt ?? .distantPast) }
    }

    /// The hand pick, kept until it leaves the account or another is picked.
    public static let chosenKey = "sync.mac.chosen"
}

public nonisolated enum MacWords {
    /// How long a Mac takes what waits for it before refusing it (ChatCommand,
    /// OpenOnMac and SyncTasks keep 12 hours).
    public static let lifetime: TimeInterval = 12 * 3600
    /// From when the wait row says when it expires.
    public static let expiryShown: TimeInterval = 10 * 3600

    /// "MacBook Pro is asleep"; nil for a Mac that is up.
    public static func headline(_ name: String, _ state: MacState) -> String? {
        switch state {
        case .up: nil
        case .asleep: "\(name) is asleep"
        case .closed: "Yab is closed on \(name)"
        case .silent: "No word from \(name)"
        }
    }

    /// "It starts when it wakes."
    public static func starts(_ state: MacState) -> String {
        switch state {
        case .up: ""
        case .asleep: "It starts when it wakes."
        case .closed: "It starts when Yab opens."
        case .silent: "It starts when it’s back."
        }
    }

    /// "since 18:52", "since yesterday 18:52", "since Tuesday", "since Oct 9".
    public static func since(_ date: Date?, now: Date, calendar: Calendar = .current, short: Bool = false, locale: Locale = .current) -> String {
        guard let date else { return "" }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "since \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return short ? "since yesterday" : "since yesterday \(time)"
        }
        if now.timeIntervalSince(date) < 7 * 86_400 {
            let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(short ? .abbreviated : .wide))
            return "since \(day)"
        }
        return "since " + date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// The wait row under a message: two lines, or nil when the Mac is up
    /// (the dots say it).
    public static func waiting(_ name: String, _ state: MacState, sent: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let head = headline(name, state) else { return nil }
        let since = since(state.since, now: now, calendar: calendar, locale: locale)
        let first = since.isEmpty ? head : "\(head) · \(since)"
        if now.timeIntervalSince(sent) >= expiryShown {
            let ends = sent.addingTimeInterval(lifetime).formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
            return "\(first)\nExpires at \(ends) if it’s still \(still(state))."
        }
        return "\(first)\n\(starts(state))"
    }

    private static func still(_ state: MacState) -> String {
        switch state {
        case .closed: "closed"
        case .silent: "away"
        default: "asleep"
        }
    }

    /// A row's word for a Mac, in Settings › Sync and the + menu's list:
    /// "Up", "Asleep since 18:52", "Yab closed since Tue", "No word since 9:12".
    public static func state(_ state: MacState, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let since = since(state.since, now: now, calendar: calendar, short: true, locale: locale)
        switch state {
        case .up: return "Up"
        case .asleep: return "Asleep \(since)"
        case .closed: return "Yab closed \(since)"
        case .silent: return since.isEmpty ? "No word yet" : "No word \(since)"
        }
    }

    /// The Chats card's line for a chat that waits.
    public static func waitsFor(_ name: String) -> String { "Waits for \(name)" }

    /// Open on Mac's subtitle, one short line: nothing when it is up and the
    /// only Mac. When it will open is the toast's to say (`sentToast`).
    public static func openSubtitle(_ name: String, _ state: MacState, several: Bool) -> String? {
        switch state {
        case .up: return several ? name : nil
        case .asleep: return "\(name) · asleep"
        case .closed: return "\(name) · Yab closed"
        case .silent: return "\(name) · away"
        }
    }

    /// The toast after Open on Mac.
    public static func sentToast(_ name: String, _ state: MacState) -> String {
        switch state {
        case .up: "Sent to \(name)"
        case .asleep: "\(name) is asleep. Opens when it wakes."
        case .closed: "Yab is closed on \(name). Opens when it opens."
        case .silent: "Sent to \(name). Opens when it’s back."
        }
    }

    /// The one line over a new chat's field when its Mac is down.
    public static func beforeSending(_ name: String, _ state: MacState) -> String? {
        guard let head = headline(name, state) else { return nil }
        return "\(head) · \(starts(state).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
    }

    /// An expired send, under its bubble.
    public static func expired(_ name: String) -> String { "Expired before \(name) received it" }

    /// A task refused because Yab on its Mac is closed.
    public static func closedForTasks(_ name: String) -> String { "Open Yab on \(name) to run tasks" }

    /// A task from this iPhone runs only on a Mac that is up now (its
    /// read-only authority is the Mac's word of the moment): why it didn't go.
    public static func taskRefused(_ name: String, _ state: MacState) -> String? {
        switch state {
        case .up: nil
        case .asleep: "\(name) is asleep. Wake it to run tasks"
        case .closed: closedForTasks(name)
        case .silent: "No word from \(name). Tasks need it up"
        }
    }
}
