import Foundation
import MailCore
import SQLite3

// Yab Wrapped's numbers, gathered on this Mac: the ledger (WrappedLedger)
// for what nothing else keeps, and the stores that keep things for long,
// the diary, mail, boosts and invites. Nothing leaves the Mac.

enum WrappedTally {
    /// How far back a Wrapped looks, out of the year's season.
    static let days = 100

    /// In December and the first week of January, the calendar year that is
    /// ending: the Wrapped of the year. Else nil, and the last `days`.
    static func year(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        if m == 12 { return y }
        if m == 1, d <= 7 { return y - 1 }
        return nil
    }

    /// Where the stretch starts.
    static func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        if let y = year(now: now, calendar: calendar), let first = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) { return first }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    @MainActor
    static func gather(now: Date = Date(), done: @escaping @MainActor (WrappedCounts, Date?) -> Void) {
        let since = start(now: now)
        let mail = MailCenter.shared.engines.values.map(\.store.off)
        let chats = Chats.shared.all
        let friends = Invites.shared.friends.filter { $0.state == "joined" && ($0.at ?? now) >= since }.count
        Task.detached(priority: .utility) {
            var c = WrappedCounts()
            c.days = days
            ledger(into: &c, since: since)
            agentsBeforeLedger(chats, into: &c, since: since)
            diary(into: &c, since: since)
            for store in mail {
                c.mailCleared += store.acts(since: since).filter { $0.kind == "archive" }.count
                c.mailUnsubscribes += store.unsubscribedCount(since: since)
            }
            c.boosts = boosts(since: since)
            c.friends = friends
            let first = firstDay()
            await MainActor.run { done(c, first) }
        }
    }

    static func ledger(into c: inout WrappedCounts, since: Date, ledger: WrappedLedger = .shared) {
        func n(_ key: WrappedLedger.Key) -> Double { ledger.sum(key, since: since) }
        c.agentTasks += Int(n(.agentTasks))
        c.agentRunMinutes += n(.agentMinutes)
        c.agentNightTasks += Int(n(.agentNight))
        c.agentNightMinutes += n(.agentNightMinutes)
        c.asks += Int(n(.asks))
        c.askPageWords += Int(n(.askPageWords))
        c.askAnswerWords += Int(n(.askAnswerWords))
        c.mailInboxZeroDays += Int(n(.mailZero))
        c.formFields += Int(n(.formFields))
        c.adsBlocked += Int(n(.ads))
        c.tabsSlept += Int(n(.tabsSlept))
        c.tabsTidied += Int(n(.tabsTidied))
        c.tabJumps += Int(n(.tabJumps))
        c.callsJoined += Int(n(.calls))
        c.codeCalls += Int(n(.codeCalls))
        c.pipMinutes += n(.pipMinutes)
        c.videoMinutes += n(.videoMinutes)
        let fast = n(.videoFastMinutes), saved = n(.videoSavedMinutes)
        if fast > 0, saved > 0, saved < fast {
            c.fastMinutes += fast
            c.fastRate = fast / (fast - saved)
        }
        c.searches += Int(n(.searches))
        c.mostOpen = max(c.mostOpen, Int(ledger.most(.tabsPeak, since: since)))
        let tools = ledger.sums(prefix: "code.tool.", since: since)
        c.codeTopTool = tools.max { $0.value < $1.value }?.key ?? ""
    }

    /// Tasks finished before the ledger began counting, from the chats
    /// still on disk (a week's).
    static func agentsBeforeLedger(_ chats: [Chat], into c: inout WrappedCounts, since: Date) {
        let from = WrappedLedger.shared.started ?? .distantFuture
        for chat in chats where chat.state == "done" && chat.updated >= since && chat.updated < from {
            let minutes = max(0, chat.updated.timeIntervalSince(chat.started) / 60)
            c.agentTasks += 1
            c.agentRunMinutes += minutes
            if Calendar.current.component(.hour, from: chat.updated) < 7 {
                c.agentNightTasks += 1
                c.agentNightMinutes += minutes
            }
        }
    }

    private static func withDiary(_ work: (OpaquePointer) -> Void) {
        let file = Store.file("diary.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        work(db)
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, since: Date, _ each: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    /// Pages read, the busiest hour and the longest run of days, from the diary.
    static func diary(into c: inout WrappedCounts, since: Date) {
        var pages = 0, busiest: (hour: Int, n: Int)?
        var hours = [Int](repeating: 0, count: 24)
        var days: [String] = []
        withDiary { db in
            rows(db, "SELECT COUNT(*) FROM visits WHERE at >= ?", since: since) { pages = Int(sqlite3_column_int64($0, 0)) }
            rows(db, "SELECT CAST(strftime('%H', at, 'unixepoch', 'localtime') AS INTEGER), COUNT(*) FROM visits WHERE at >= ? GROUP BY 1", since: since) {
                let hour = Int(sqlite3_column_int64($0, 0)), n = Int(sqlite3_column_int64($0, 1))
                if n > (busiest?.n ?? 0) { busiest = (hour, n) }
                if (0..<24).contains(hour) { hours[hour] = n }
            }
            rows(db, "SELECT DISTINCT date(at, 'unixepoch', 'localtime') FROM visits WHERE at >= ? ORDER BY 1", since: since) {
                if let text = sqlite3_column_text($0, 0) { days.append(String(cString: text)) }
            }
        }
        c.pagesRead = pages
        c.busiestHour = busiest?.hour
        c.hours = hours
        c.longestStreak = streak(days)
    }

    /// The longest run of consecutive days among "yyyy-MM-dd" days, sorted.
    static func streak(_ days: [String]) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let dates = days.compactMap { f.date(from: $0) }
        var best = 0, run = 0
        var last: Date?
        for d in dates {
            if let last, let next = Calendar.current.date(byAdding: .day, value: 1, to: last), Calendar.current.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            last = d
        }
        return best
    }

    /// Boosts made or kept in the period, each once.
    static func boosts(since: Date) -> Int {
        struct Event: Codable { let at: Date; let boost: String; let action: String }
        guard let data = try? Data(contentsOf: Store.file("boosts/events.json")),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return 0 }
        return Set(events.filter { $0.at >= since && ($0.action == "keep" || $0.action == "enabled") }.map(\.boost)).count
    }

    /// The first day Yab remembers a visit, for the period's name.
    static func firstDay() -> Date? {
        var first: Date?
        withDiary { db in
            rows(db, "SELECT MIN(at) FROM visits WHERE at >= ?", since: .distantPast) {
                let at = sqlite3_column_double($0, 0)
                if at > 0 { first = Date(timeIntervalSince1970: at) }
            }
        }
        return first
    }

    /// "FIRST 41 DAYS" while Yab is younger than the stretch, else "LAST 100
    /// DAYS"; "2026" for the year's.
    static func period(first: Date?, now: Date = Date()) -> String {
        if let y = year(now: now) { return String(y) }
        guard let first else { return "LAST \(days) DAYS" }
        let age = Calendar.current.dateComponents([.day], from: first, to: now).day ?? days
        return age < days ? "FIRST \(max(1, age)) DAYS" : "LAST \(days) DAYS"
    }

    /// Three letters for the score table, from your name.
    static func initials(_ name: String) -> String {
        let letters = name.uppercased().filter { $0.isASCII && $0.isLetter }
        let parts = name.split(separator: " ").compactMap { $0.first }.map { String($0).uppercased() }.filter { $0.first?.isASCII == true }
        let picked = parts.count >= 2 ? parts.joined() + letters.dropFirst(1) : String(letters)
        let three = String(picked.prefix(3))
        return three.isEmpty ? "YOU" : three.padding(toLength: 3, withPad: "A", startingAt: 0)
    }
}

extension WrappedCounts {
    /// Worlds for the bench and its shots: a busy player, a light one with
    /// just enough for a story, and one too new for it.
    static func demo(_ name: String) -> WrappedCounts {
        var c = WrappedCounts()
        switch name {
        case "rich":
            c.agentTasks = 212; c.agentRunMinutes = 1_080; c.agentLongestMinutes = 47; c.agentNightTasks = 14; c.agentNightMinutes = 372
            c.asks = 640; c.askPageWords = 165_000; c.askAnswerWords = 30_000
            c.mailCleared = 6_900; c.mailUnsubscribes = 41; c.mailInboxZeroDays = 23
            c.formFields = 3_900
            c.fastMinutes = 300; c.fastRate = 1.5; c.pipMinutes = 120; c.videoMinutes = 2_400
            c.mostOpen = 87; c.searches = 1_200
            c.tabJumps = 2_000; c.tabsTidied = 2_340
            c.codeCalls = 3_200; c.codeTopTool = "snapshot"; c.codeAgents = 2
            c.adsBlocked = 312_000; c.memoryFreedMB = 9_000; c.tabsSlept = 800
            c.callsJoined = 30; c.phoneTabs = 40; c.longestStreak = 21; c.busiestHour = 23; c.boosts = 3; c.friends = 2
            c.hours = [9, 4, 2, 1, 0, 0, 1, 3, 8, 14, 18, 20, 16, 15, 19, 22, 21, 17, 12, 14, 19, 26, 24, 31]
        case "light":
            c.mailCleared = 1_500; c.mailInboxZeroDays = 4
            c.formFields = 900
            c.tabJumps = 700
            c.adsBlocked = 18_000
        default:
            c.mailCleared = 400
            c.adsBlocked = 2_000
        }
        return c
    }
}
