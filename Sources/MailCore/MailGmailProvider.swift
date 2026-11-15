import Foundation

// Gmail behind the provider seam (docs/mail-providers.md, M1): the calls
// it always made, the same ones in the same order, now reached through
// MailProvider. Yab's model of a mailbox is Gmail's, so nothing is mapped:
// labels are labels, a thread is Gmail's thread.

extension MailGmail: MailProvider {
    public var kind: MailProviderKind { .gmail }
    public var can: MailAbilities { [.labels, .threads, .search, .sendAs, .savesSent, .editLabels] }

    public func who() async throws -> MailIdentity {
        MailIdentity(address: try await profile().address)
    }

    public func unread(in label: String, page: String?) async throws -> (ids: [String], next: String?) {
        let got = try await messages(query: "", labels: [label, "UNREAD"], page: page)
        return (got.ids, got.next)
    }

    /// One edit as Gmail hears it: a thread's own modify, trash or untrash;
    /// a pack by messages/batchModify; messages a thousand at a time.
    public func apply(_ edit: MailEdit, in store: MailStore) async throws {
        switch (edit.target, edit.way) {
        case (.thread(let id), .trash):
            try await trash(thread: id)
        case (.thread(let id), .untrash):
            try await untrash(thread: id)
        case (.thread(let id), _):
            try await modify(thread: id, add: edit.add.sorted(), remove: edit.remove.sorted())
        case (.threads(let ids), _):
            try await tell(ids, add: edit.add, remove: edit.remove, store: store)
        case (.messages(let ids), _):
            try await tell(messages: ids, add: edit.add, remove: edit.remove)
        }
    }

    /// The fewest threads a messages/batchModify (50 units) is worth for:
    /// below it, each thread's own modify (10 units) costs less (Google's
    /// quota table, MailGmail.quota).
    static let batchFrom = 5

    /// The fewest messages a messages/batchModify is worth for, against a
    /// message's own modify (5 units).
    static let batchMessagesFrom = 10

    /// A pack to Gmail: its messages a thousand ids a call, by
    /// messages/batchModify. A thread this Mac may not hold whole (its mail
    /// older than the sync reached) goes by its thread, so that mail is
    /// labeled too; so does a chunk Gmail refuses for a message gone since,
    /// and every thread of a pack too small for a batch to be cheaper.
    private func tell(_ threads: [String], add: Set<String>, remove: Set<String>, store: MailStore) async throws {
        let partial = threads.count < Self.batchFrom ? Set(threads) : store.partial(threads)
        var byThread = threads.filter { partial.contains($0) }
        let size = MailOps.packSize
        for chunk in MailOps.packs(threads.filter { !partial.contains($0) }, in: store) {
            let ids = store.messageIDs(threads: chunk)
            for start in stride(from: 0, to: ids.count, by: size) {
                do {
                    try await batchModify(ids: Array(ids[start..<min(ids.count, start + size)]), add: add.sorted(), remove: remove.sorted())
                } catch MailTrouble.status(let code) where code == 400 || code == 404 {
                    byThread += chunk
                    break
                }
            }
        }
        for thread in byThread {
            do {
                try await modify(thread: thread, add: add.sorted(), remove: remove.sorted())
            } catch MailTrouble.status(404) {
                // Gone from Gmail: nothing to label.
            }
        }
    }

    /// An op on messages to Gmail: a thousand ids a call, by
    /// messages/batchModify; too few for a batch to cost less, and a chunk
    /// Gmail refuses for a message gone since, a message at a time, the
    /// gone ones left.
    private func tell(messages ids: [String], add: Set<String>, remove: Set<String>) async throws {
        func oneByOne(_ chunk: [String]) async throws {
            for id in chunk {
                do {
                    try await modify(message: id, add: add.sorted(), remove: remove.sorted())
                } catch MailTrouble.status(let code) where code == 400 || code == 404 {
                    // Gone from Gmail: nothing to label.
                }
            }
        }
        let size = MailOps.packSize
        for start in stride(from: 0, to: ids.count, by: size) {
            let chunk = Array(ids[start..<min(ids.count, start + size)])
            guard chunk.count >= Self.batchMessagesFrom else {
                try await oneByOne(chunk)
                continue
            }
            do {
                try await batchModify(ids: chunk, add: add.sorted(), remove: remove.sorted())
            } catch MailTrouble.status(let code) where code == 400 || code == 404 {
                try await oneByOne(chunk)
            }
        }
    }
}

extension MailSync: MailSyncing {}
