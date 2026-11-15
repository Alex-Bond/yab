import Foundation

// Keeping an account's store in step with Gmail (docs/mail.md, Sync).
//
// The first time: who the account is and where Gmail's history stands,
// then the newest mail of the inbox and of sent whole, so what you open
// first and the voice drafts are written in are here, then every mail of
// the last thirty days whole, then by its headers every mail of the inbox
// whatever its age and everything else of the last sixty days, newest
// first. It goes by the message, not the thread: most threads are one
// mail, and Gmail charges a message half a thread. A first sync cut short
// (Gmail said slow down, the Mac slept) goes on where it stopped: the
// history id it began at is kept as "boot", and the mail already here isn't
// asked for again. After that only what changed, from Gmail's history; a
// history too old to follow starts again from nothing, and what you did
// that Gmail hasn't heard yet stays in the journal and is laid over what
// comes back. Mail that comes in a thread you muted goes out of the inbox
// as it comes (MailOps.keepMuted), and mail from a sender you blocked into
// Trash (MailOps.keepBlocked). Mail kept before the store had a column for a header
// (MailStore.late) gets it a few messages at a time after each refresh,
// with a tenth of the account's quota at most. Which mail kept by its headers
// carries files is one search (MailSync.markFiles); after each sync the
// newest files are fetched ahead (MailFiles).
//
// A store whose first sync took only sixty days (an older Yab's) gets the
// rest of its inbox the same way, a page of Gmail's list at a time.
//
// Bodies are kept for reading offline (What is kept): every mail of the
// last month, the newest 1,250 threads of each split, everything opened or
// found by a search. What is missing of that comes in the background, a
// share of the quota at a time and not on battery; a body past keeping is
// let go once a day. Older mail is Gmail's to find (`search`): the threads
// a search names that aren't here come by their headers, 25 at a time.
//
// Once a day, and at the first sync after Connect, the addresses the
// account sends as come with their signatures (`keepSendAs`, MailSendAs).

public actor MailSync {
    public let store: MailStore
    public let gmail: MailGmail
    /// How far back the first sync reaches for every mail by its headers,
    /// and for every mail whole; how many threads' bodies come ahead in the
    /// inbox and in sent mail.
    public var days = 60
    var bodyDays = 30
    public var ahead = 200
    /// Calls in flight at once; the account's MailPace sets the rate.
    public var width = 4
    /// The first screen after Connect: how many of the inbox's newest
    /// threads come before anything else, and how many calls at once for
    /// them (MailPace lets the first burst through at once).
    var firstPage = 50
    var firstWidth = 12
    /// Told every few seconds while threads come in, so a first sync, a
    /// few minutes at Gmail's pace, shows as it goes.
    public let told: (@Sendable () -> Void)?
    private var toldAt = Date.distantPast
    /// Headers asked for again (MailStore.late): a tenth of the 4,800
    /// units a minute MailPace spends, at 20 a message, never more than a
    /// minute's share at once.
    var latePerMinute = 24
    private var lateAt = Date.distantPast
    /// Bodies kept ahead (`keepAhead`): threads a minute, at 40 a thread a
    /// third of the pace; how many of each split's newest keep theirs.
    var bodiesPerMinute = 40
    var splitBodies = 1_250
    /// Bodies let go at a sync, at most (`prune`).
    var pruneShare = 400
    private var aheadAt = Date()
    /// Each split's newest threads still without their bodies, as last
    /// looked (`keepAhead`): looked at again ten minutes on, not at every
    /// sync, as the look reads a few thousand threads' mail.
    private var headsMissing: [String] = []
    private var headsAt = Date.distantPast
    /// An inbox older than its store's first sync took (`fillInbox`):
    /// messages a minute by their headers, a fifth of the pace.
    var inboxPerMinute = 48
    private var inboxAt = Date()
    /// The Mac runs on power, not its battery: bodies ahead wait for it.
    var plugged: @Sendable () -> Bool = { IOPowerSourcesInfo.now()?.charging ?? true }
    /// Threads fetched ahead of J now (`prefetch`), not asked for twice.
    private var prefetching: Set<String> = []
    /// Label ids met in mail since the labels were last looked at
    /// (`keepLabels`): one not known has Gmail's list asked at once, and
    /// each has its count asked again when it is shown.
    private var labelsMet: Set<String> = []
    /// The labels the column shows (MailLabels), whose counts are asked.
    private var shownLabels: [String] = []
    /// How often Gmail's list of labels is read, and a label's count asked
    /// while nothing in its mail changed.
    static let labelsEvery: TimeInterval = 600
    /// Counts asked at most at once (labels.get, a unit each, MailPace's).
    static let countsAtOnce = 25

    public init(store: MailStore, gmail: MailGmail, told: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.gmail = gmail
        self.told = told
    }

    public func set(plugged: @escaping @Sendable () -> Bool) { self.plugged = plugged }
    public func set(inboxPerMinute: Int) { self.inboxPerMinute = inboxPerMinute }
    public func set(pruneShare: Int) { self.pruneShare = pruneShare }

    /// From nothing, or what changed since last time; then, a share at a
    /// time, the inbox of an older store, the bodies kept ahead, and once
    /// a day those past keeping let go, from the sync after the first on.
    /// False when nothing new came, from Gmail or of the inbox: most asks,
    /// which then change no row here.
    @discardableResult
    public func sync() async throws -> Bool {
        var changed = true, first = false
        if store.value("history") == nil {
            try await bootstrap()
            first = true
        } else {
            do {
                changed = try await refresh()
            } catch MailTrouble.stale {
                store.forgetMail()
                try await bootstrap()
                first = true
            }
        }
        let filled = try await fillInbox()
        if !first {
            try await keepAhead()
            prune()
        }
        // Gmail's labels, and the counts of those shown; a label Gmail
        // doesn't answer for waits for the next sync, unless Gmail said
        // slow down or let Yab go.
        var labeled = false
        do {
            labeled = try await keepLabels()
            labeled = try await countLabels() || labeled
        } catch MailTrouble.limited {
            throw MailTrouble.limited
        } catch MailTrouble.signedOut {
            throw MailTrouble.signedOut
        } catch {
            MailGmail.log.error("labels: \(MailGmail.said(error), privacy: .public)")
        }
        // The mutes Gmail keeps (yab/Muted), once its labels are known here:
        // a first sync learns them only now.
        if first || labeled { MailOps.keepMuted(store) }
        // The newest files fetched ahead, off the sync's way (MailFiles):
        // nothing to do, most times, and nothing walked for it.
        MailFiles.attached(to: store)?.ahead()
        await keepSendAs()
        return changed || filled || labeled
    }

    // MARK: - labels

    public func set(shownLabels: [String]) { self.shownLabels = shownLabels }

    /// Gmail's labels (labels.list, 1 unit) into the store every ten
    /// minutes, and at once when mail carries a label the store doesn't
    /// know (one made in Gmail since); a rename or a label deleted follows
    /// (MailStore.keepLabels). The labels mail changed in since are counted
    /// again when shown. True when the list changed what the store keeps.
    @discardableResult
    public func keepLabels(now: Date = Date(), force: Bool = false) async throws -> Bool {
        let met = labelsMet
        labelsMet = []
        store.staleLabels(met)
        let unknown = met.contains { $0.hasPrefix("Label_") && !store.knowsLabel($0) }
        let last = store.value("labels").flatMap(Double.init) ?? 0
        guard force || unknown || now.timeIntervalSince1970 - last >= Self.labelsEvery || now.timeIntervalSince1970 < last else { return false }
        let before = store.labels().map { [$0.id, $0.name, $0.color, $0.shown] }
        let gone = store.keepLabels(try await gmail.labels())
        store.set("labels", String(now.timeIntervalSince1970))
        return !gone.isEmpty || store.labels().map { [$0.id, $0.name, $0.color, $0.shown] } != before
    }

    /// The counts of the labels the column shows (labels.get, 1 unit each):
    /// those never asked, changed since or asked more than ten minutes ago,
    /// a few at a time, through the account's MailPace. True when a count
    /// came out other than it was.
    @discardableResult
    public func countLabels(now: Date = Date()) async throws -> Bool {
        let wanted = store.uncounted(shownLabels, before: now.addingTimeInterval(-Self.labelsEvery))
        guard !wanted.isEmpty else { return false }
        let was = Dictionary(store.labels().map { ($0.id, [$0.unread, $0.threads]) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for id in wanted.prefix(Self.countsAtOnce) {
            var got = MailLabel(id: id, name: "", unread: 0, threads: 0)
            do {
                got = try await gmail.label(id: id)
            } catch MailTrouble.status(404) {
                // Gone from Gmail: its list says so at the next look.
                store.set("labels", nil)
            }
            store.count(label: id, unread: got.unread ?? 0, threads: got.threads ?? 0, at: now)
            if was[id] != [got.unread ?? 0, got.threads ?? 0] { changed = true }
        }
        return changed
    }

    /// The addresses the account sends as, their names and signatures
    /// (MailSendAs), kept once a day: 1 unit. At the first sync after
    /// Connect, which forgets when they came (MailCenter.add). Gmail not
    /// giving them is asked again ten minutes on, never failing the sync.
    public func keepSendAs(now: Date = Date()) async {
        if let at = store.value("sendas.at").flatMap(Double.init), now.timeIntervalSince1970 - at < 86_400 { return }
        do {
            let all = try await gmail.sendAs()
            if !all.isEmpty { store.keep(sendAs: all) }
            store.set("sendas.at", String(now.timeIntervalSince1970))
        } catch {
            store.set("sendas.at", String(now.timeIntervalSince1970 - 86_400 + 600))
        }
    }

    func bootstrap() async throws {
        let history: String
        let kept = "-in:spam -in:trash"
        // The first screen's list asked beside the account's profile, not
        // after it: a round trip less before the first rows.
        async let head = gmail.messages(query: kept, labels: ["INBOX"], max: 100)
        if let began = store.value("boot") {
            history = began
        } else {
            let (address, now) = try await gmail.profile()
            store.set("me", address)
            store.set("boot", now)
            // Everything since sixty days before the first sync is here from
            // now on: a search reaching before it asks Gmail (MailQuery.reachesPast).
            store.set("since", String(Date().timeIntervalSince1970 - Double(days) * 86_400))
            history = now
        }
        try await firstScreen(try await head)
        var first: [String] = []
        for label in ["INBOX", "SENT"] {
            // The inbox's newest whatever their age; sent mail of the sixty days.
            first += try await gmail.messages(query: label == "SENT" ? "newer_than:\(days)d " + kept : kept, labels: [label], max: ahead).ids
        }
        // The last month whole: bodies kept for reading offline.
        first += try await list("newer_than:\(bodyDays)d " + kept)
        let whole = store.messageIDs(withBodies: true)
        var seen = Set<String>()
        try await fetch(messages: first.filter { !whole.contains($0) && seen.insert($0).inserted }, full: true)
        // The whole inbox, whatever its age, and the rest of sixty days, by
        // their headers, newest first.
        let ids = try await list("(in:inbox OR newer_than:\(days)d) " + kept)
        let here = store.messageIDs()
        try await fetch(messages: ids.filter { !here.contains($0) }, full: false)
        try await markFiles()
        MailOps.layOver(store)
        MailOps.keepMuted(store)
        MailOps.keepBlocked(store)
        MailOps.keepAnswered(store)
        // Threads of the newest whose other mails came by their headers.
        for label in ["INBOX", "SENT"] {
            try await fetch(threads: store.unfetched(label: label, threads: ahead), full: true)
        }
        store.set("history", history)
        store.set("boot", nil)
        store.set("synced", String(Date().timeIntervalSince1970))
        store.set("inbox", "whole")
        // Nothing past keeping yet: the first let go a day on.
        store.set("pruned", String(Date().timeIntervalSince1970))
    }

    /// The first screen after Connect (docs/mail.md, Sync): the inbox's
    /// newest `firstPage` threads, the newest mail of each whole, many calls
    /// at once, and the page told the moment they are in, before the lists
    /// a first sync reads page after page. The rest comes after, newest
    /// first, as it did.
    private func firstScreen(_ head: (ids: [String], threads: [String], next: String?)) async throws {
        var seen = Set<String>(), ids: [String] = []
        for (id, thread) in zip(head.ids, head.threads) where seen.insert(thread).inserted {
            ids.append(id)
            if ids.count == firstPage { break }
        }
        let whole = store.messageIDs(withBodies: true)
        let wanted = ids.filter { !whole.contains($0) }
        guard !wanted.isEmpty else { return }
        // Told once they are all in: the page drawn once, whole, not a row
        // at a time.
        try await fetch(wanted, backfilled: false, quiet: true, width: firstWidth) { gmail, id in
            try await gmail.message(id, full: true).map { [$0] } ?? []
        }
        MailOps.layOver(store)
        toldAt = Date()
        told?()
    }

    /// Every message id a search finds, page after page.
    private func list(_ query: String) async throws -> [String] {
        var ids: [String] = []
        var page: String?
        repeat {
            let got = try await gmail.messages(query: query, page: page)
            ids += got.ids
            page = got.next
        } while page != nil
        return ids
    }

    @discardableResult
    public func refresh() async throws -> Bool {
        guard let since = store.value("history") else {
            try await bootstrap()
            return true
        }
        let (change, next) = try await gmail.history(since: since)
        // Nothing new: nothing written but what older mail still lacks.
        guard !change.added.isEmpty || !change.deleted.isEmpty || !change.labeled.isEmpty || next != since else {
            try await fillHeaders()
            return try await markFilesOnce()
        }
        store.remove(messages: Array(change.deleted))
        // The mail memory forgets them too, and mail put in Spam or Trash.
        let thrown = change.labeled.filter { !$0.add.isDisjoint(with: ["SPAM", "TRASH"]) }.map { $0.message }
        MailMemory.attached(to: store)?.later(forget: Array(change.deleted) + thrown)
        for label in change.labeled where !change.added.contains(label.message) {
            store.relabel(message: label.message, add: label.add, remove: label.remove)
        }
        // Labels put on and taken off, and those of mail read or unread since:
        // their counts are asked again, and one not known has Gmail's list
        // read (keepLabels).
        for label in change.labeled {
            labelsMet.formUnion(label.add.union(label.remove))
            if let message = store.message(label.message) { labelsMet.formUnion(message.labels) }
        }
        // New mail comes whole: it is what is read next.
        try await fetch(threads: Array(change.threads), full: true)
        MailOps.layOver(store)
        // What comes in a muted thread goes out of the inbox as it comes,
        // and what comes from a blocked sender into Trash.
        MailOps.keepMuted(store)
        MailOps.keepBlocked(store)
        // An answer of yours to an invitation waits on nobody.
        MailOps.keepAnswered(store)
        store.set("history", next)
        store.set("synced", String(Date().timeIntervalSince1970))
        try await fillHeaders()
        let marked = try await markFilesOnce()
        return marked || !change.added.isEmpty || !change.deleted.isEmpty || !change.labeled.isEmpty
    }

    /// Headers the store kept no column for when older mail came, asked for
    /// again by the message's headers, newest first, as many as the time
    /// since the last ask allows at `latePerMinute`.
    func fillHeaders(now: Date = Date()) async throws {
        let share = min(Double(latePerMinute), now.timeIntervalSince(lateAt) / 60 * Double(latePerMinute))
        guard share >= 1 else { return }
        let ids = store.unknownHeaders(limit: Int(share))
        guard !ids.isEmpty else { return }
        lateAt = now
        try await fetch(messages: ids, full: false)
        // Any Gmail didn't give (gone since): known to have none.
        store.noHeaders(ids)
        MailOps.layOver(store)
    }

    /// The whole inbox, for a store whose first sync took only its sixty
    /// days (an older Yab's): Gmail's list of the inbox a page at a time,
    /// newest first, and what of each page isn't here by its headers, as
    /// many as the time since the last ask allows at `inboxPerMinute`. The
    /// page it stands at is kept (`inbox.page`), so a restart goes on from
    /// there; not on battery; Gmail saying slow down stops it with the
    /// sync. Done when the last page is here (`inbox` whole). True when
    /// mail came.
    @discardableResult
    func fillInbox(now: Date = Date()) async throws -> Bool {
        guard store.value("inbox") != "whole", plugged() else { return false }
        let share = Int(min(Double(inboxPerMinute), now.timeIntervalSince(inboxAt) / 60 * Double(inboxPerMinute)))
        guard share >= 1 else { return false }
        inboxAt = now
        let got: (ids: [String], threads: [String], next: String?)
        do {
            got = try await gmail.messages(query: "in:inbox -in:spam -in:trash", page: store.value("inbox.page"), max: 500)
        } catch MailTrouble.status(400) {
            // A page Gmail no longer knows: from the first again, what is here skipped.
            store.set("inbox.page", nil)
            return false
        }
        let here = store.known(got.ids)
        let missing = got.ids.filter { !here.contains($0) }
        try await fetch(messages: Array(missing.prefix(share)), full: false)
        MailOps.layOver(store)
        if missing.count <= share {
            if let next = got.next {
                store.set("inbox.page", next)
            } else {
                store.set("inbox", "whole")
                store.set("inbox.page", nil)
                // Which of the inbox that came by its headers carries files.
                try await markFiles()
            }
        }
        return !missing.isEmpty
    }

    /// Bodies of a thread that has none here yet, when it is opened, the
    /// headers it was kept without (a reply needs them now, ⌘U a list's), and the parts
    /// of a body kept before files were, unless Gmail said it has none. A
    /// thread not here at all (named by a search or by an agent) comes
    /// whole. Opened, its bodies stay (MailStore.prune).
    public func open(thread id: String) async throws {
        let kept = store.messages(thread: id)
        store.opened(id)
        if kept.isEmpty || kept.contains(where: { $0.text == nil || $0.replyTo == nil || $0.unsubscribe == nil || ($0.files == nil && $0.attached != false) }) {
            try await fetch(threads: [id], full: true)
            store.noHeaders(kept.map(\.id))
            MailOps.layOver(store)
        }
    }

    // MARK: - search by the server

    /// A search Gmail answers from the whole mailbox (docs/mail.md, Search):
    /// its messages listed, 5 units for up to 500, and of those not here the
    /// newest `take` by their headers, 20 each, kept and marked backfilled,
    /// and which of them carry files, 5 more: 510 units at most. A label it
    /// names by a name the store doesn't know is learned first (1 unit).
    /// Asked again, the next ones not here come. `pages`: how many of
    /// Gmail's pages of 500 it may read for them, 5 units each (a list
    /// beyond the inbox's reads on past what is here already).
    /// The threads it found, all here now, in Gmail's order, newest first,
    /// and whether more were found than came.
    public func search(_ query: MailQuery, take: Int = 25, pages: Int = 1) async throws -> (threads: [String], more: Bool) {
        guard !query.isEmpty else { return ([], false) }
        if query.labelNames.contains(where: { store.labelID(named: $0) == nil }) {
            store.keepLabels(try await gmail.labels())
            store.set("labels", String(Date().timeIntervalSince1970))
        }
        var got = try await gmail.messages(query: query.gmail, max: 500)
        let here = store.known(got.ids)
        var missing = got.ids.filter { !here.contains($0) }
        var read = 1
        while missing.count < take, read < pages, let next = got.next {
            let page = try await gmail.messages(query: query.gmail, page: next, max: 500)
            got = (got.ids + page.ids, got.threads + page.threads, page.next)
            let here = store.known(page.ids)
            missing += page.ids.filter { !here.contains($0) }
            read += 1
        }
        let brought = Array(missing.prefix(take))
        try await fetch(messages: brought, full: false, backfilled: true)
        // Which of them carry files, by their headers unknown: one more list
        // (5 units), Gmail's order the same, so they are among its first 500.
        if !brought.isEmpty {
            let filed = try await gmail.messages(query: "(\(query.gmail)) has:attachment", max: 500).ids
            store.markAttached(Array(Set(filed).intersection(brought)))
        }
        let now = store.known(got.ids)
        var seen = Set<String>(), threads: [String] = []
        for (id, thread) in zip(got.ids, got.threads) where now.contains(id) && seen.insert(thread).inserted {
            threads.append(thread)
        }
        return (threads, missing.count > take || got.next != nil)
    }

    // MARK: - bodies kept

    /// The next threads of a list, whole, while one is read: J lands on a
    /// thread already here. Not marked opened.
    public func prefetch(threads ids: [String]) async {
        let wanted = store.unbodied(ids).filter { !prefetching.contains($0.thread) }
        guard !wanted.isEmpty else { return }
        prefetching.formUnion(wanted.map(\.thread))
        defer { prefetching.subtract(wanted.map(\.thread)) }
        try? await whole(wanted)
        MailOps.layOver(store)
    }

    /// Bodies kept for reading offline, those still missing: every
    /// mail of the last month, received and sent, then each split's newest
    /// `splitBodies` threads, newest first, as many as the time since the
    /// last ask allows at `bodiesPerMinute`; which of the splits' newest
    /// miss theirs is looked at every ten minutes. Not on battery; Gmail
    /// saying slow down stops it with the sync. Nothing to remember to go
    /// on after a restart: what is missing is read from the store.
    public func keepAhead(now: Date = Date()) async throws {
        guard plugged() else { return }
        let share = Int(min(Double(bodiesPerMinute), now.timeIntervalSince(aheadAt) / 60 * Double(bodiesPerMinute)))
        guard share >= 1 else { return }
        var wanted = store.unbodied(since: now.addingTimeInterval(-Double(bodyDays) * 86_400), limit: share)
        if wanted.count < share {
            if now.timeIntervalSince(headsAt) > 600 {
                headsAt = now
                headsMissing = store.unbodied(splitHeads(now: now)).map(\.thread)
            }
            let more = Array(headsMissing.filter { !wanted.contains($0) }.prefix(share - wanted.count))
            headsMissing.removeAll { more.contains($0) }
            wanted += more
        }
        guard !wanted.isEmpty else { return }
        aheadAt = now
        try await whole(store.unbodied(wanted))
        MailOps.layOver(store)
    }

    /// Each split's newest threads whose bodies stay here.
    private func splitHeads(now: Date) -> [String] {
        var counted: [MailSplit: Int] = [:], out: [String] = []
        for facts in store.facts(now: now) where !facts.snoozed {
            guard let split = MailSplit.of(facts, now: now), counted[split, default: 0] < splitBodies else { continue }
            counted[split, default: 0] += 1
            out.append(facts.id)
        }
        return out
    }

    /// Once a day: bodies past keeping let go (MailStore.prune), each
    /// split's newest threads kept, and the newest of Sent, the voice
    /// drafts are written in. `pruneShare` at a sync: more than that (a big
    /// mailbox's first day) goes on at the next, not all at once.
    public func prune(now: Date = Date()) {
        if let last = store.value("pruned").flatMap(Double.init), now.timeIntervalSince1970 - last < 86_400 { return }
        let keep = Set(splitHeads(now: now)).union(store.threads(label: "SENT", limit: ahead).map(\.id))
        let gone = store.prune(keeping: keep, before: now.addingTimeInterval(-Double(bodyDays) * 86_400), limit: pruneShare)
        if gone < pruneShare { store.set("pruned", String(now.timeIntervalSince1970)) }
    }

    /// Threads' missing bodies, each the cheaper way: one message by itself
    /// (20 units), more by their thread (40). Quietly: a body changes no row,
    /// so the lists aren't told as they come.
    private func whole(_ items: [(thread: String, messages: [String])]) async throws {
        try await fetch(messages: items.filter { $0.messages.count == 1 }.flatMap(\.messages), full: true, quiet: true)
        try await fetch(threads: items.filter { $0.messages.count > 1 }.map(\.thread), full: true, quiet: true)
    }

    private func fetch(threads ids: [String], full: Bool, quiet: Bool = false) async throws {
        try await fetch(ids, backfilled: false, quiet: quiet) { gmail, id in try await gmail.thread(id, full: full) }
    }

    private func fetch(messages ids: [String], full: Bool, backfilled: Bool = false, quiet: Bool = false) async throws {
        try await fetch(ids, backfilled: backfilled, quiet: quiet) { gmail, id in try await gmail.message(id, full: full).map { [$0] } ?? [] }
    }

    /// A few at a time (`width`), stored as they come. One gone from Gmail
    /// between the list and the fetch is skipped, not the end of the sync.
    private func fetch(_ ids: [String], backfilled: Bool, quiet: Bool = false, width wide: Int? = nil,
                       _ one: @escaping @Sendable (MailGmail, String) async throws -> [MailMessage]) async throws {
        var rest = ids[...]
        try await withThrowingTaskGroup(of: [MailMessage].self) { group in
            func next() {
                guard let id = rest.popFirst() else { return }
                let gmail = gmail
                group.addTask {
                    do { return try await one(gmail, id) } catch MailTrouble.status(404) { return [] }
                }
            }
            for _ in 0..<(wide ?? width) { next() }
            while let messages = try await group.next() {
                // The store wouldn't take the page: stop here, so the sync
                // comes back for it rather than going on past a hole.
                guard store.put(messages, backfilled: backfilled) else { throw MailTrouble.store }
                for message in messages { labelsMet.formUnion(message.labels) }
                MailMemory.attached(to: store)?.later(messages)
                if !quiet, let told, Date().timeIntervalSince(toldAt) > 2 {
                    toldAt = Date()
                    // What you did while mail came stays done on screen.
                    MailOps.layOver(store)
                    told()
                }
                next()
            }
        }
    }
}
