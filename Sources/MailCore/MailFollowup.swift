import Foundation

// "Remind me if no reply" (docs/mail.md, Reminders if nobody answers): a
// mail of yours that comes back if nobody answers it by a time. Chosen on
// the draft with ⇧⌘H, it becomes a reminder when the mail goes
// (MailOps.send), against that mail's Message-ID. Someone answering ends it;
// another mail of yours in the thread moves it as far on; come due with
// nobody answering, the thread is back in the inbox, unread, in Needs you,
// saying "No reply · 3d". Gmail has no such thing, so this Mac keeps it,
// and wakes it while Yab is open or, closed, through `yab mail flush`
// (MailLater): whichever holds the wake lock (MailLock), never both.

/// A mail of yours that comes back if nobody answers it.
public struct MailFollowup: Equatable {
    public var thread: String
    /// Your mail's Message-ID: an answer is a mail after it.
    public var message: String
    public var until: Date
    /// When your mail went: "No reply · 3d" counts from it.
    public var sent: Date
    /// When it came due and brought the thread back; nil while it waits.
    public var fired: Date?

    public init(thread: String, message: String, until: Date, sent: Date, fired: Date? = nil) {
        self.thread = thread
        self.message = message
        self.until = until
        self.sent = sent
        self.fired = fired
    }
}

public enum MailFollowups {
    // MARK: - said

    /// When a reminder is, as the draft's foot says it: "in 3 days" for a
    /// morning days off, "tomorrow", "at 18:00" today, else "Thu 10:00".
    public static func said(_ until: Date, now: Date = MailClock.now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: until)).day ?? 0
        let morning = calendar.component(.hour, from: until) == 9 && calendar.component(.minute, from: until) == 0
        if days == 0 { return "at " + MailLater.said(until, now: now, calendar: calendar) }
        if morning, days == 1 { return "tomorrow" }
        if morning, days == 7 { return "in a week" }
        if morning, (2...6).contains(days) { return "in \(days) days" }
        return MailLater.said(until, now: now, calendar: calendar)
    }

    /// The draft's foot: "Remind me in 3 days if no reply".
    public static func line(_ until: Date, now: Date = MailClock.now, calendar: Calendar = .current) -> String {
        "Remind me \(said(until, now: now, calendar: calendar)) if no reply"
    }

    /// A thread brought back as its row says it, in words as Waiting's
    /// are: days since your mail by the calendar, so a mail of last night
    /// is a day old this morning. "No reply · 3d", "No reply · today".
    public static func status(sent: Date, now: Date = MailClock.now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: sent), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 0 ? "No reply · today" : "No reply · \(days)d"
    }

    /// A reminder still waiting, as a row says it before its time: "Remind
    /// today", "Remind tomorrow", "Remind in 3d", by the calendar.
    public static func pending(_ until: Date, now: Date = MailClock.now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: until)).day ?? 0
        return days <= 0 ? "Remind today" : days == 1 ? "Remind tomorrow" : "Remind in \(days)d"
    }

    // MARK: - when

    /// A reminder kept as far from a mail that went later: by whole days
    /// when it is days off, its hour kept, so "in 3 days" stays that
    /// morning; by the time itself when it is hours off.
    public static func keep(_ until: Date, from: Date, to: Date, calendar: Calendar = .current) -> Date {
        let late = to.timeIntervalSince(from)
        guard late > 0 else { return until }
        if until.timeIntervalSince(from) < 86_400 { return until.addingTimeInterval(late) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        return days > 0 ? calendar.date(byAdding: .day, value: days, to: until) ?? until : until
    }

    /// How long a send may go after its reminder was chosen and the
    /// reminder still stand as chosen: the undo window, a Gmail slow to
    /// take it. Later (Send Later), it moves with the send.
    public static let grace: TimeInterval = 3600

    /// The reminder of a draft that went at `sent`, as it was chosen, or as
    /// far from the send as it was from the choosing when the send went
    /// later; never at or before the send itself.
    public static func until(_ chosen: Date, set: Date?, sent: Date, calendar: Calendar = .current) -> Date {
        let set = set ?? sent
        var until = sent.timeIntervalSince(set) < grace ? chosen : keep(chosen, from: set, to: sent, calendar: calendar)
        if until <= sent { until = sent.addingTimeInterval(max(60, chosen.timeIntervalSince(set))) }
        return until
    }

    /// `mail_draft`'s `remind_in`: days (3, "3", 0.5), or words ("in 3
    /// days", "friday 10am"); a number of days is that morning. Nil when
    /// it reads as no time ahead.
    public static func remindIn(_ value: Any, now: Date = MailClock.now, calendar: Calendar = .current) -> Date? {
        let days: Double?
        if let number = value as? NSNumber, !(value is Bool) {
            days = number.doubleValue
        } else if let words = (value as? String)?.trimmingCharacters(in: .whitespaces), !words.isEmpty {
            if let number = Double(words) {
                days = number
            } else {
                // "3 days" said without its "in".
                let asked = words.first?.isNumber == true ? "in " + words : words
                return MailLater.parse(asked, now: now, calendar: calendar)
            }
        } else {
            days = nil
        }
        guard let days, days > 0, days <= 365 else { return nil }
        if days < 1 { return now.addingTimeInterval(days * 86_400) }
        return MailLater.at(9, daysAhead: Int(days.rounded()), from: now, calendar: calendar)
    }

    // MARK: - set, moved, ended

    /// A mail that just went (MailOps.send), in `thread`: its draft's
    /// reminder kept against it; without one, a reminder already on the
    /// thread moves as far on, a later mail of yours.
    public static func sent(_ draft: MailDraft, thread: String, at sent: Date, in store: MailStore, calendar: Calendar = .current) {
        guard !thread.isEmpty else { return }
        if let chosen = draft.remind {
            store.follow(MailFollowup(thread: thread, message: draft.messageID,
                                      until: until(chosen, set: draft.remindSet, sent: sent, calendar: calendar), sent: sent))
        } else if var kept = store.followup(thread), kept.message != draft.messageID {
            kept.until = keep(kept.until, from: kept.sent, to: sent, calendar: calendar)
            kept.sent = sent
            kept.message = draft.messageID
            kept.fired = nil
            store.follow(kept)
        }
    }

    /// What a look over the reminders did.
    public struct Change: Equatable {
        /// Come due, brought back: in the inbox, unread.
        public var fired: [String] = []
        /// Answered (or the thread gone, muted, put away, done with).
        public var ended: [String] = []
        /// Moved on by a later mail of yours.
        public var moved: [String] = []
        public var isEmpty: Bool { fired.isEmpty && ended.isEmpty && moved.isEmpty }
    }

    /// Every reminder as the store has the mail now: answered ones end, a
    /// later mail of yours moves one on, one come due brings its thread
    /// back. The app's every half minute and after each sync, `yab mail
    /// flush`'s while it is closed; a thread is brought back by whichever
    /// marks it first (MailStore.fire), so never twice.
    @discardableResult
    public static func check(_ store: MailStore, now: Date = MailClock.now, calendar: Calendar = .current) -> Change {
        var change = Change()
        let mine = Set(([store.me] + store.aliases).map { $0.lowercased() }.filter { !$0.isEmpty })
        let followups = store.followups()
        guard !followups.isEmpty else { return change }
        let snoozed = Set(store.snoozes().map(\.thread))
        for followup in followups {
            let all = store.messages(thread: followup.thread)
            guard !all.isEmpty else {
                // Not here yet (just sent), or gone from Gmail.
                if now.timeIntervalSince(followup.sent) > 2 * 86_400 { store.unfollow(followup.thread); change.ended.append(followup.thread) }
                continue
            }
            let yours = all.first { !followup.message.isEmpty && $0.rfcID == followup.message }
            let after = yours?.date ?? followup.sent
            // Anyone else after your mail: answered.
            if all.contains(where: { !mine.contains($0.from.address.lowercased()) && $0.date > after }) {
                store.unfollow(followup.thread)
                change.ended.append(followup.thread)
                continue
            }
            // Another of yours after it (sent from anywhere): as far on from that one.
            if let later = all.last(where: { mine.contains($0.from.address.lowercased()) && $0.date > after.addingTimeInterval(1)
                                             && $0.rfcID != followup.message }) {
                var moved = followup
                moved.until = keep(followup.until, from: after, to: later.date, calendar: calendar)
                moved.sent = later.date
                moved.message = later.rfcID
                moved.fired = nil
                store.follow(moved)
                change.moved.append(followup.thread)
                continue
            }
            let labels = all.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
            if followup.fired != nil {
                // Brought back, then done with elsewhere (archived on the
                // phone); put off for later (H), it comes back saying so.
                if !labels.contains("INBOX"), !snoozed.contains(followup.thread) {
                    store.unfollow(followup.thread)
                    change.ended.append(followup.thread)
                }
                continue
            }
            guard followup.until <= now else { continue }
            // Come due in Trash or spam, or muted: not brought back from there.
            if !labels.isDisjoint(with: ["TRASH", "SPAM"]) || store.thread(followup.thread)?.muted == true {
                store.unfollow(followup.thread)
                change.ended.append(followup.thread)
                continue
            }
            guard store.fire(followup.thread, at: now) else { continue }
            // Put off for later too: back now, as the reminder said.
            if snoozed.contains(followup.thread), store.takeSnooze(followup.thread) != nil {
                MailOps.act(.unlabel, thread: followup.thread, label: MailOps.snoozed, in: store)
            }
            if !labels.contains("INBOX") { MailOps.act(.unarchive, thread: followup.thread, in: store) }
            MailOps.act(.unread, thread: followup.thread, in: store)
            change.fired.append(followup.thread)
        }
        return change
    }

    /// Your last mail in a thread, a reminder's mail when one is set on
    /// the thread itself (⇧⌘H in a thread you wrote last in).
    public static func last(mineIn thread: String, in store: MailStore) -> MailMessage? {
        let mine = Set(([store.me] + store.aliases).map { $0.lowercased() }.filter { !$0.isEmpty })
        guard let last = store.messages(thread: thread).last, mine.contains(last.from.address.lowercased()) else { return nil }
        return last
    }
}

/// Mail's clock: the Mac's, moved on in a test world by the bench
/// (agent-mail-time-shift), so a reminder three days off comes due in a
/// check without three days going by. Kept in the world's settings, so
/// `yab mail flush` keeps the same time as the app.
public enum MailClock {
    public static var shift: TimeInterval = Store.testing ? Store.settings.double(forKey: "mail.time.shift") : 0
    public static var now: Date { Date().addingTimeInterval(shift) }

    /// A test world's clock moved on (or back to the Mac's, `to` 0).
    public static func move(by seconds: TimeInterval? = nil, to: TimeInterval? = nil) {
        guard Store.testing else { return }
        shift = to ?? shift + (seconds ?? 0)
        Store.settings.set(shift, forKey: "mail.time.shift")
    }
}

/// Who wakes what is due (snoozes, reminders): the app, which takes this
/// lock at its first look and keeps it while it runs, or else `yab mail
/// flush`, which takes it for its run. An flock on a file beside the
/// stores: let go by the system when its process ends, however it ends.
public final class MailLock {
    public let file: URL
    private var fd: Int32 = -1

    public init(_ file: URL) { self.file = file }

    deinit { letGo() }

    /// Taken now or before: true. Held by another process: false.
    public func take() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard opened >= 0 else { return false }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        fd = opened
        return true
    }

    public func letGo() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
