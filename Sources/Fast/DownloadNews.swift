import Foundation

/// Only the notification in Now is acknowledged. Files and transfers keep
/// their own lifetime; a later arrival can announce itself again.
@MainActor
enum DownloadNews {
    static let doneKey = "field.downloads.doneThrough"

    static func detail(now: Date, started: [Date], kept: [Keep], defaults: UserDefaults = Store.settings) -> String? {
        let through = defaults.double(forKey: doneKey)
        let going = started.filter { $0.timeIntervalSince1970 > through }.count
        if going > 0 { return "\(going) downloading" }
        guard let last = kept.max(by: { $0.date < $1.date }),
              last.date.timeIntervalSince1970 > through, now.timeIntervalSince(last.date) < 600 else { return nil }
        return last.name
    }

    static func finish(now: Date = Date(), defaults: UserDefaults = Store.settings) {
        defaults.set(max(defaults.double(forKey: doneKey), now.timeIntervalSince1970), forKey: doneKey)
    }
}
