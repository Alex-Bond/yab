import Foundation

/// Which threads a split holds (docs/mail.md, Inbox), by rules until the
/// on-device sorting is in: mail from people that wants you, what you
/// asked that nobody answered, and the rest. Every thread in the inbox is
/// in one, whatever its age; a split is read a page at a time.
public enum MailSplit: String, CaseIterable {
    case needs, waiting, other
    /// Archive: the inbox's threads older than the window (Policy), out of
    /// Needs you and Other, never counted or told. This Mac's alone: Gmail's
    /// inbox keeps them as they are.
    case older

    public static let categories: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    /// Waiting looks at your last word from two days to two weeks ago.
    static let waitsFrom: TimeInterval = 2 * 86_400
    static let waitsTo: TimeInterval = 14 * 86_400

    /// Threads a list reads at a time; more as it is scrolled.
    public static let page = 100

    /// How the inbox is sorted (Settings › Mail): whether Needs you is what
    /// asks you something or all of people's mail, and how far back Needs
    /// you and Other look, older threads of the inbox being Archive.
    public struct Policy: Equatable, Sendable {
        /// What needs you: mail that asks you something (MailSensed.needs),
        /// names a due, or whose reminder came due; false, every person's
        /// mail, as it was before.
        public var asks = true
        /// Days Needs you and Other look back; nil, every age.
        public var days: Int? = 7
        /// Where a kind of mail goes when no split takes it (Settings ›
        /// Mail › Sorting): "needs" or "other" by MailSensed.Kind's raw
        /// value; a kind not in it goes as it asks.
        public var kinds: [String: String] = [:]

        public var window: TimeInterval? { days.map { TimeInterval($0) * 86_400 } }

        static let asksKey = "mail.needs"
        static let daysKey = "mail.window"
        static let kindsKey = "mail.kinds"
        /// The windows Settings offers, 0 for every age.
        public static let windows = [7, 30, 0]

        public static func kept(_ defaults: UserDefaults) -> Policy {
            let days = defaults.object(forKey: daysKey) as? Int ?? 7
            let kinds = (defaults.dictionary(forKey: kindsKey) as? [String: String] ?? [:]).filter { $0.value == "needs" || $0.value == "other" }
            return Policy(asks: defaults.string(forKey: asksKey) != "everyone", days: days > 0 ? days : nil, kinds: kinds)
        }

        public init(asks: Bool = true, days: Int? = 7, kinds: [String: String] = [:]) {
            self.asks = asks
            self.days = days
            self.kinds = kinds
        }

        /// Where a kind goes when no split takes it, set in Sorting: nil,
        /// as it asks.
        public func place(_ kind: MailSensed.Kind?) -> MailSplit? {
            kind.flatMap { kinds[$0.rawValue] }.flatMap(MailSplit.init(rawValue:))
        }

        public func keep(_ defaults: UserDefaults) {
            defaults.set(asks ? "asks" : "everyone", forKey: Policy.asksKey)
            defaults.set(days ?? 0, forKey: Policy.daysKey)
            defaults.set(kinds, forKey: Policy.kindsKey)
        }

        /// The one the lists read, from any thread: set by MailList as
        /// Settings changes it, which also sorts anew (MailSplitSort.policy).
        public static var current: Policy {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var stored = kept(Store.settings)
    }

    /// What the splits sort a thread by, read for a whole inbox at once
    /// without its messages (MailStore.facts).
    public struct Facts: Equatable {
        public let id: String
        public let last: Date
        public let inbox: Bool
        public let bulk: Bool
        public let category: Bool
        /// Every mail of it in Trash or Spam.
        public let gone: Bool
        public let lastIsMine: Bool
        public let doneWaiting: Bool
        /// What MailSense made of it; Skip the inbox reads a new mail's by
        /// the rules before MailSense keeps it.
        public var kind: MailSensed.Kind?
        public let snoozed: Bool
        /// Muted (⇧M): in no list.
        public var muted = false
        /// What ⇧U, ⇧S and ⇧R narrow a list by: unread, starred, a thread
        /// you wrote in.
        public var unread = false
        public var starred = false
        public var replied = false
        /// Its reminder if nobody answers came due (MailFollowups).
        public var fired = false
        /// Who wrote in it but you, "|a@x|b@y|": what a split of people
        /// and domains sorts it by (MailSplitSort).
        public var people = ""
        /// Read by MailSense (rules or the model): whether it asks you
        /// something, and whether it names a due. Unread here yet, it needs
        /// you until it is: nothing hidden before it was understood.
        public var sensed = false
        public var needs = false
        public var due = false

        public init(id: String, last: Date, inbox: Bool, bulk: Bool, category: Bool, gone: Bool, lastIsMine: Bool, doneWaiting: Bool, kind: MailSensed.Kind? = nil, snoozed: Bool, muted: Bool = false, unread: Bool = false, starred: Bool = false, replied: Bool = false, fired: Bool = false, people: String = "", sensed: Bool = false, needs: Bool = false, due: Bool = false) {
            self.id = id
            self.last = last
            self.inbox = inbox
            self.bulk = bulk
            self.category = category
            self.gone = gone
            self.lastIsMine = lastIsMine
            self.doneWaiting = doneWaiting
            self.kind = kind
            self.snoozed = snoozed
            self.muted = muted
            self.unread = unread
            self.starred = starred
            self.replied = replied
            self.fired = fired
            self.people = people
            self.sensed = sensed
            self.needs = needs
            self.due = due
        }
    }

    /// A split's threads in one store, newest first, snoozed ones left out:
    /// the first `limit`, as a list shows them.
    public static func threads(_ split: MailSplit, in store: MailStore, now: Date = MailClock.now, limit: Int = page,
                        policy: Policy = .current) -> [(MailThread, MailSensed?)] {
        let ids = Array(store.facts(now: now).lazy.filter { !$0.snoozed && of($0, now: now, policy: policy) == split }.prefix(limit).map(\.id))
        let sensed = store.sensed(ids)
        return store.threads(ids: ids).map { ($0, sensed[$0.id]) }
    }

    /// How many threads each split holds in one store, snoozed ones left out.
    public static func counts(in store: MailStore, now: Date = MailClock.now, policy: Policy = .current) -> [MailSplit: Int] {
        var out: [MailSplit: Int] = [:]
        for facts in store.facts(now: now) where !facts.snoozed {
            if let split = of(facts, now: now, policy: policy) { out[split, default: 0] += 1 }
        }
        return out
    }

    public static func of(_ thread: MailThread, sensed: MailSensed? = nil, now: Date = MailClock.now, policy: Policy = .current) -> MailSplit? {
        // Muted (⇧M): in none of them, Waiting neither.
        if thread.muted { return nil }
        return of(inbox: thread.labels.contains("INBOX"), bulk: thread.bulk, category: !thread.labels.isDisjoint(with: categories),
                  kind: sensed?.kind, lastIsMine: thread.lastIsMine, doneWaiting: thread.doneWaiting, last: thread.last,
                  fired: thread.followup?.fired != nil, read: sensed.map { ($0.needs, $0.due != nil) }, now: now, policy: policy)
    }

    public static func of(_ facts: Facts, now: Date = MailClock.now, policy: Policy = .current) -> MailSplit? {
        guard !facts.muted, facts.inbox || !facts.gone else { return nil }
        // A reminder is only while your mail is the last (MailThread.followup).
        return of(inbox: facts.inbox, bulk: facts.bulk, category: facts.category, kind: facts.kind, lastIsMine: facts.lastIsMine,
                  doneWaiting: facts.doneWaiting, last: facts.last, fired: facts.fired && facts.lastIsMine,
                  read: facts.sensed ? (facts.needs, facts.due) : nil, now: now, policy: policy)
    }

    /// `read`: what MailSense made of it (asks you something, names a
    /// due), nil while it hasn't read it.
    public static func of(inbox: Bool, bulk: Bool, category: Bool, kind: MailSensed.Kind?, lastIsMine: Bool, doneWaiting: Bool,
                   last: Date, fired: Bool = false, read: (needs: Bool, due: Bool)? = nil, now: Date,
                   policy: Policy = .current) -> MailSplit? {
        let waiting = waitingOrNil(lastIsMine: lastIsMine, doneWaiting: doneWaiting, bulk: bulk, last: last, now: now)
        if inbox {
            // Its reminder came due with nobody answering (MailFollowups):
            // asked for, so it needs you, whatever else it is.
            if fired { return .needs }
            let robot = bulk || category || kind.map { [.code, .list, .promotion, .shipping].contains($0) } == true
            if !robot, lastIsMine, let waiting { return waiting }
            // Older than the window: Archive, quiet, whatever it was.
            if let window = policy.window, now.timeIntervalSince(last) > window { return .older }
            // Its kind set to go somewhere (Sorting): there, but never
            // Needs you while your word is the last.
            if let placed = policy.place(kind) { return placed == .needs && lastIsMine ? .other : placed }
            if robot { return .other }
            guard policy.asks else { return lastIsMine ? waiting ?? .needs : .needs }
            // Your word is the last: nothing waits on you yet.
            if lastIsMine { return .other }
            // Not read yet: it needs you until it is.
            guard let read else { return .needs }
            return read.needs || read.due ? .needs : .other
        }
        return waiting
    }

    /// Yours was the last word, two days to two weeks ago, to people, and
    /// you aren't done waiting on it (E in Waiting, MailStore.stopWaiting):
    /// a thread archived is still found through Sent.
    private static func waitingOrNil(lastIsMine: Bool, doneWaiting: Bool, bulk: Bool, last: Date, now: Date) -> MailSplit? {
        let age = now.timeIntervalSince(last)
        guard lastIsMine, !doneWaiting, !bulk, age > waitsFrom, age < waitsTo else { return nil }
        return .waiting
    }
}
