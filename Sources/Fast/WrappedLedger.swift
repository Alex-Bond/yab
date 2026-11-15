import Foundation

// What Yab Wrapped counts that no store keeps: a few numbers a day, on this
// Mac only, in wrapped.json. Most of what Yab does is not written down for
// long (tasks go after a week, calls and blocked ads never were), so the
// places that do it add one here as it happens. Wrapped reads it back with
// the stores that do keep things (the diary, mail, answers, boosts).
//
// Days are local calendar days; a day's numbers are kept 400 days. Adds are
// cheap and may come from any thread; the file is written a few seconds
// after the last one.

final class WrappedLedger: @unchecked Sendable {
    static let shared = WrappedLedger()

    /// The keys, so a typo can't count into nowhere.
    enum Key: String, CaseIterable {
        case agentTasks = "agent.tasks", agentMinutes = "agent.minutes"
        case agentNight = "agent.night", agentNightMinutes = "agent.nightMinutes"
        case asks = "ask.count", askPageWords = "ask.pageWords", askAnswerWords = "ask.answerWords"
        case mailZero = "mail.zero"
        case formFields = "forms.fields"
        case ads = "ads"
        case tabsSlept = "tabs.slept", tabsTidied = "tabs.tidied", tabJumps = "tabs.jumps"
        case calls = "calls"
        case codeCalls = "code.calls"
        case pipMinutes = "pip.minutes"
        /// Video played on pages: minutes of it, minutes of it played
        /// faster than 1×, and the minutes the speed took off (WrappedWatch).
        case videoMinutes = "video.minutes", videoFastMinutes = "video.fastMinutes", videoSavedMinutes = "video.savedMinutes"
        case searches = "searches"
        /// The most tabs open at once in a day: a peak, not a sum.
        case tabsPeak = "tabs.peak"
    }

    private let lock = NSLock()
    private var days: [String: [String: Double]] = [:]
    /// The first day anything was counted.
    private(set) var started: Date?
    private var dirty = false
    private let queue = DispatchQueue(label: "yab.wrapped.ledger", qos: .utility)
    private let file: URL

    init(file: URL = Store.file("wrapped.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            days = saved.days
            started = saved.started
        }
    }

    private struct Saved: Codable {
        var started: Date?
        var days: [String: [String: Double]]
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func add(_ key: Key, _ amount: Double = 1, at date: Date = Date()) {
        add(key.rawValue, amount, at: date)
    }

    /// A free-form key: the code agents' tools, "code.tool.<verb>".
    func add(_ key: String, _ amount: Double = 1, at date: Date = Date()) {
        guard amount > 0 else { return }
        lock.lock()
        days[Self.day(date), default: [:]][key, default: 0] += amount
        if started == nil { started = date }
        let schedule = !dirty
        dirty = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 4) { self.save() } }
    }

    /// A day's highest value, kept if `value` is higher.
    func peak(_ key: Key, _ value: Double, at date: Date = Date()) {
        lock.lock()
        let day = Self.day(date)
        let higher = value > days[day]?[key.rawValue] ?? 0
        if higher { days[day, default: [:]][key.rawValue] = value }
        if started == nil { started = date }
        let schedule = higher && !dirty
        if higher { dirty = true }
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 4) { self.save() } }
    }

    /// The highest of the days since a day.
    func most(_ key: Key, since: Date) -> Double {
        let from = Self.day(since)
        lock.lock(); defer { lock.unlock() }
        return days.filter { $0.key >= from }.compactMap { $0.value[key.rawValue] }.max() ?? 0
    }

    /// The sum since a day, that day included.
    func sum(_ key: Key, since: Date) -> Double { sum(key.rawValue, since: since) }

    func sum(_ key: String, since: Date) -> Double {
        let from = Self.day(since)
        lock.lock(); defer { lock.unlock() }
        return days.reduce(0) { $0 + ($1.key >= from ? $1.value[key] ?? 0 : 0) }
    }

    /// The keys starting with `prefix`, summed since a day.
    func sums(prefix: String, since: Date) -> [String: Double] {
        let from = Self.day(since)
        lock.lock(); defer { lock.unlock() }
        var out: [String: Double] = [:]
        for (day, values) in days where day >= from {
            for (k, v) in values where k.hasPrefix(prefix) { out[String(k.dropFirst(prefix.count)), default: 0] += v }
        }
        return out
    }

    func save() {
        lock.lock()
        dirty = false
        // A day is kept 400 days, a year's Wrapped and some.
        let oldest = Self.day(Date().addingTimeInterval(-400 * 86_400))
        days = days.filter { $0.key >= oldest }
        let saved = Saved(started: started, days: days)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

extension Tab {
    /// The words on the page now, added to what ⌘J read for you (Yab
    /// Wrapped). Asked of the page in Yab's own world; a sleeping or gone
    /// page counts nothing.
    @MainActor func countWordsForWrapped() {
        guard let built = builtPage else { return }
        built.run("document.body ? document.body.innerText.split(/\\s+/).filter(Boolean).length : 0",
                                 in: .yab) { result in
            if case let .success(value) = result, let words = value as? Int, words > 0 {
                WrappedLedger.shared.add(.askPageWords, Double(words))
            }
        }
    }
}
