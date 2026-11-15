import Foundation

// The seam between Yab's mail and the server an account lives on
// (docs/mail-providers.md, M1). The store, the journal, the splits and the
// agents' tools speak Yab's model of a mailbox, which is Gmail's: labels on
// messages, INBOX, SENT, TRASH, SPAM, UNREAD, STARRED and the person's own.
// A provider takes that model to its server and back: Gmail one to one
// (MailGmail), IMAP by folders and flags (MailIMAPProvider).
//
// Two halves. `MailProvider` is the calls: a thread or a message, a file's
// bytes, labels on and off, a send, the labels themselves. `MailSyncing` is
// how an account's store is kept in step, which differs too much between
// servers to be written once over the calls (Gmail's history id against
// IMAP's UIDs and MODSEQ per folder), so each kind brings its own: Gmail's
// is MailSync, unchanged.

/// The kinds of server an account can live on.
public enum MailProviderKind: String, Sendable, Codable, CaseIterable {
    case gmail, graph, imap, jmap
}

/// What a provider's server can do, where the rest of Yab asks.
public struct MailAbilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A message may carry several labels (Gmail, JMAP); without it the
    /// account files mail in folders, one each (IMAP, Graph).
    public static let labels = MailAbilities(rawValue: 1 << 0)
    /// The server gives threads (Gmail, Graph, JMAP); without it the store
    /// threads by Message-ID, In-Reply-To, References and subject.
    public static let threads = MailAbilities(rawValue: 1 << 1)
    /// The server answers a search of the whole mailbox in Yab's words.
    public static let search = MailAbilities(rawValue: 1 << 2)
    /// The server lists the addresses the account sends as.
    public static let sendAs = MailAbilities(rawValue: 1 << 3)
    /// The server tells of new mail without being asked (IMAP IDLE).
    public static let push = MailAbilities(rawValue: 1 << 4)
    /// The server keeps a copy of sent mail by itself: nothing appended.
    public static let savesSent = MailAbilities(rawValue: 1 << 5)
    /// Labels and folders can be made, renamed and deleted from Yab.
    public static let editLabels = MailAbilities(rawValue: 1 << 6)
}

/// Who an account is, as its server says.
public struct MailIdentity: Equatable, Sendable {
    public var address: String
    public var name: String
    public init(address: String, name: String = "") {
        self.address = address
        self.name = name
    }
}

/// One change the journal sends out (MailOps.flush): labels on and off a
/// thread, a pack of threads, or messages by their ids. `way` keeps
/// Gmail's own calls for Trash where it has them.
public struct MailEdit: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case thread(String)
        case threads([String])
        case messages([String])
    }

    public enum Way: Sendable, Equatable {
        case labels
        /// Into Trash, the thread whole (Gmail's threads.trash).
        case trash
        /// Out of Trash, not back in the inbox by itself.
        case untrash
    }

    public var target: Target
    public var add: Set<String>
    public var remove: Set<String>
    public var way: Way

    public init(_ target: Target, add: Set<String> = [], remove: Set<String> = [], way: Way = .labels) {
        self.target = target
        self.add = add
        self.remove = remove
        self.way = way
    }
}

/// The calls an account's server takes, in Yab's model of a mailbox.
public protocol MailProvider: Sendable {
    var kind: MailProviderKind { get }
    var can: MailAbilities { get }

    /// The account's address and name.
    func who() async throws -> MailIdentity
    /// Its labels or folders in Yab's shape, system ones by Gmail's ids.
    func labels() async throws -> [MailLabel]
    /// One with its counts: threads with it, and of those unread.
    func label(id: String) async throws -> MailLabel
    /// A label's id by its name, made when there is none: yab/Snoozed.
    func label(named name: String) async throws -> String
    func makeLabel(named name: String) async throws -> MailLabel
    func renameLabel(id: String, to name: String) async throws -> MailLabel
    /// "labelShow" or "labelHide" in the server's own list, where it has one.
    func showLabel(id: String, _ shown: String) async throws -> MailLabel
    func deleteLabel(id: String) async throws
    /// The unread messages carrying a label, a page at a time (Mark All Read).
    func unread(in label: String, page: String?) async throws -> (ids: [String], next: String?)

    func thread(_ id: String, full: Bool) async throws -> [MailMessage]
    func message(_ id: String, full: Bool) async throws -> MailMessage?
    /// A file's bytes, by the id its MailFile was given.
    func attachment(message: String, id: String) async throws -> Data

    /// Labels on and off, on the server. `store`: what this Mac holds of
    /// the mail it names, for a provider that needs it (Gmail's batches,
    /// IMAP's folders and UIDs).
    func apply(_ edit: MailEdit, in store: MailStore) async throws
    /// A whole RFC 5322 message out (MailCompose.raw), in its thread; the
    /// message and thread ids the server gave it, as far as it knows them.
    func send(raw: String, thread: String) async throws -> (message: String?, thread: String)
    /// The thread a sent message is in, by its Message-ID, if it went: a
    /// send whose answer was lost is never sent twice.
    func sentThread(messageID: String) async throws -> String?
    /// The addresses the account sends as, their names and signatures.
    func sendAs() async throws -> [MailSendAs]
}

/// How an account's store is kept in step with its server: the whole
/// mailbox the first time, what changed after, a thread when it is opened,
/// a search the server answers. Gmail's is MailSync.
public protocol MailSyncing: AnyObject, Sendable {
    var store: MailStore { get }
    /// From nothing or from where it was; true when something came.
    @discardableResult
    func sync() async throws -> Bool
    func open(thread id: String) async throws
    func prefetch(threads ids: [String]) async
    func search(_ query: MailQuery, take: Int, pages: Int) async throws -> (threads: [String], more: Bool)
    func keepLabels(now: Date, force: Bool) async throws -> Bool
    func countLabels(now: Date) async throws -> Bool
    func set(shownLabels: [String]) async
    func keepSendAs(now: Date) async
}

/// What a provider says when Yab asks it something its server can't do.
public enum MailUnsupported: Error, Equatable {
    /// "This account files mail in folders": a second label on a message.
    case folders
    case notHere(String)
}
