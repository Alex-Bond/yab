import Foundation

/// Halloween 2026, from the release that brings it to the end of November 2:
/// four app icons in App Icon that count down and then leave, the update
/// note in costume, and the dress-up block on the release's version page
/// (yetanotherbrowser.com/changelog). The drawings set it brought stays.
/// The concept: work/design/yab-halloween-2026-10-19, artifact EK5pRND6.
enum Halloween {
    /// The first moment it is over: November 3, here.
    static let end: Date = {
        var day = DateComponents()
        day.year = 2026
        day.month = 11
        day.day = 3
        return Calendar.current.date(from: day) ?? .distantPast
    }()

    /// The clock it goes by; a test world sets `halloween.now` to see
    /// another day (bench ui halloween).
    static var now: Date {
        Store.settings.object(forKey: "halloween.now") as? Date ?? Date()
    }

    /// Whether the icons are still here.
    static var on: Bool { now < end }

    /// Automatic decorations appear only on October 31 in the local calendar.
    /// The icon collection has its own availability window above.
    static func isDay(at date: Date = now, using calendar: Calendar = .current) -> Bool {
        let day = calendar.dateComponents([.month, .day], from: date)
        return day.month == 10 && day.day == 31
    }

    /// Whole days left after today: 0 on November 2, 1 the day before.
    static func daysLeft(at date: Date = now) -> Int {
        let calendar = Calendar.current
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: last)).day ?? 0
        return max(0, days)
    }

    /// The plate on an icon in App Icon while it lasts.
    static func plate(at date: Date = now) -> String {
        guard date < end else { return "Halloween 2026" }
        switch daysLeft(at: date) {
        case 0: return "Last day"
        case 1: return "Leaves tomorrow"
        case let days: return "\(days) days left"
        }
    }

    /// The line under its name.
    static func note(at date: Date = now) -> String {
        guard date < end else { return "From Halloween 2026. Yours to keep." }
        switch daysLeft(at: date) {
        case 0: return "Last day. The one you choose is yours to keep."
        case 1: return "Leaves tomorrow. The one you choose is yours to keep."
        default: return "Here until November 2. The one you choose is yours to keep."
        }
    }

    private static let wornKey = "halloween.worn"

    /// The icons put in the Dock while it lasted: each is kept for good.
    static var worn: Set<String> {
        Set(Store.settings.stringArray(forKey: wornKey) ?? [])
    }

    static func wore(_ id: String) {
        var all = worn
        guard all.insert(id).inserted else { return }
        Store.settings.set(all.sorted(), forKey: wornKey)
    }

    private static let dressedKey = "halloween.dressed"

    /// Wore an icon, put something on from the site, or opened What's new
    /// when the note said "dress it up": the note doesn't ask again.
    static var dressed: Bool {
        !worn.isEmpty || Store.settings.bool(forKey: dressedKey)
    }

    static func dressedUp() {
        Store.settings.set(true, forKey: dressedKey)
    }

    /// App Icon has opened on Pumpkin once, the first time after the update.
    static let introducedKey = "halloween.introduced"
    /// App Icon has shown the ones not worn leaving, once, after the end.
    static let goodbyeKey = "halloween.goodbye"
}
