import CryptoKit
import Foundation

// An IMAP account behind the provider seam (docs/mail-providers.md, M3):
// its folders and flags in Yab's model of a mailbox, kept in step by UIDs
// and, where the server has CONDSTORE, MODSEQ, and told of new mail by
// IDLE.
//
// A message is the same message wherever it sits: its id comes from its
// Message-ID, so archiving it (a move to Archive) keeps its row, its body
// and its files here. Where it sits, by folder and UID, is kept beside the
// store (MailIMAPPlaces); one message in two folders (mail to yourself, in
// the inbox and in Sent) is one message with both labels.
//
// Folders are labels: INBOX, Sent, Trash, Junk by SPECIAL-USE (RFC 6154)
// or their usual names, Archive as no label, the person's own folders as
// "Label_f:<path>". A label Yab adds that is no folder (yab/Snoozed, a
// label put on with L in a folder account) is this Mac's alone,
// "Label_local:<name>", never told to the server and kept across syncs.
//
// Threads: IMAP has none to give, so a message's thread is the one its
// References or In-Reply-To name, known here, else the first of them, else
// itself, as Apple Mail threads.

public actor MailIMAPAccount: MailProvider, MailSyncing {
    public nonisolated let setup: MailServerSetup
    public nonisolated let store: MailStore
    nonisolated let password: @Sendable () async throws -> String
    let places: MailIMAPPlaces

    /// Told when something came, a first sync's first screen, and IDLE's news.
    public nonisolated let told: (@Sendable () -> Void)?
    private var main: IMAPClient?
    private var gmailExtensions = false
    private var gmail: Bool { setup.provider == "gmail" }
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var folders: [IMAPFolder] = []
    private var listedAt = Date.distantPast
    private var shownLabels: [String] = []
    private var idling: Task<Void, Never>?
    /// IDLE's own line, closed with the account.
    private var idler: IMAPClient?
    private var closed = false
    /// Messages just sent, read back from what went before the server's
    /// copy is listed (MailOps.readSent).
    private var justSent: [String: (raw: Data, thread: String)] = [:]
    /// Without CONDSTORE: when every flag of a folder was last read.
    private var sweptAt: [String: Date] = [:]

    /// How far back folders other than the inbox are kept; how many of the
    /// inbox's and Sent's newest come whole; the last days whose mail
    /// comes whole.
    public var days = 60
    public var ahead = 200
    public var bodyDays = 30
    var firstPage = 50
    /// A message bigger than this comes by its headers until opened.
    var wholeUnder = 1 << 20

    public static let localPrefix = "Label_local:"
    public static let folderPrefix = "Label_f:"

    public init(setup: MailServerSetup, store: MailStore, password: @escaping @Sendable () async throws -> String,
                told: (@Sendable () -> Void)? = nil) {
        self.setup = setup
        self.store = store
        self.password = password
        self.told = told
        places = MailIMAPPlaces(file: store.file == MailStore.memory ? nil : store.file.path + ".imap")
    }

    public nonisolated var kind: MailProviderKind { .imap }
    public nonisolated var can: MailAbilities {
        var out: MailAbilities = [.push, .editLabels, .search]
        if setup.savesSent { out.insert(.savesSent) }
        return out
    }

    // MARK: - the line

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func unlock() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    /// One step on the account's line, signed in first if it isn't; a line
    /// the server closed is opened again once.
    func on<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        do {
            return try await body(try await client())
        } catch let trouble as MailServerTrouble where trouble == .closed || trouble.hint == "timedOut" {
            await main?.socket.close()
            main = nil
            return try await body(try await client())
        }
    }

    private func client() async throws -> IMAPClient {
        if let main, await main.socket.isOpen { return main }
        let secret = try await password()
        // A line refused at once is tried twice more, a little later each
        // time: a process's first connection can fail while the system is
        // still finding its network path, and a server restarting is back
        // in a moment. A refused password is never tried again here.
        var waits: [UInt64] = [300, 1_000]
        while true {
            do {
                let client = try await Self.connect(setup, password: secret)
                main = client
                gmailExtensions = gmail ? await client.has("X-GM-EXT-1") : false
                return client
            } catch let trouble as MailServerTrouble where !waits.isEmpty && [.tcpRefused, .offline, .closed].contains(trouble) {
                try await Task.sleep(nanoseconds: waits.removeFirst() * 1_000_000)
            }
        }
    }

    /// A line to the server, signed in, with its extensions enabled.
    public static func connect(_ setup: MailServerSetup, password: String) async throws -> IMAPClient {
        let socket = try MailSocket(host: setup.imapHost, port: setup.imapPort, security: setup.imapSecurity)
        let client = IMAPClient(socket: socket)
        do {
            try await client.greet(security: setup.imapSecurity)
            try await client.login(user: setup.imapUser, password: password, auth: setup.imapAuth)
            await client.id()
            await client.enable()
        } catch {
            await socket.close()
            throw error
        }
        return client
    }

    /// The sync's own troubles said as the journal and the center read them.
    static func said(_ error: Error) -> Error {
        guard let trouble = error as? MailServerTrouble else { return error }
        switch trouble {
        case .authRejected, .appPasswordRequired: return MailTrouble.signedOut
        case .offline, .dnsNotFound, .tcpRefused: return MailTrouble.offline(trouble.words)
        default: return trouble
        }
    }

    public func close() async {
        closed = true
        idling?.cancel()
        idling = nil
        // Its read woken: the IDLE line's socket closed under it.
        await idler?.socket.close()
        idler = nil
        if let main { await main.logout() }
        main = nil
    }

    // MARK: - folders

    /// The role a folder plays, by SPECIAL-USE, else by its usual names.
    public static func role(_ folder: IMAPFolder) -> String? {
        if folder.name.uppercased() == "INBOX" { return "inbox" }
        for (attribute, role) in [("\\sent", "sent"), ("\\trash", "trash"), ("\\junk", "junk"), ("\\drafts", "drafts"), ("\\archive", "archive"),
                                  ("\\all", "all"), ("\\flagged", "flagged"), ("\\important", "important")] where folder.attributes.contains(attribute) {
            return role
        }
        let leaf = (folder.shown.split(separator: "/").last.map(String.init) ?? folder.shown).lowercased()
        let top = folder.shown.lowercased()
        let names: [(String, [String])] = [
            ("sent", ["sent", "sent messages", "sent items", "sent mail", "gesendet", "envoyés"]),
            ("trash", ["trash", "deleted messages", "deleted items", "bin", "papierkorb", "corbeille"]),
            ("junk", ["junk", "spam", "bulk mail", "junk e-mail", "junk email"]),
            ("drafts", ["drafts", "draft", "entwürfe", "brouillons"]),
            ("archive", ["archive", "archives"]),
        ]
        // Only at the top, or right under the inbox (INBOX.Sent on Courier).
        guard !top.contains("/") || top.hasPrefix("inbox/") || top.hasPrefix("[gmail]/") || top.hasPrefix("[google mail]/") else { return nil }
        if top.hasPrefix("[gmail]/") || top.hasPrefix("[google mail]/") {
            if leaf == "all mail" { return "all" }
            if leaf == "starred" { return "flagged" }
            if leaf == "important" { return "important" }
        }
        for (role, words) in names where words.contains(leaf) { return role }
        return nil
    }

    /// Yab's label for a folder: a system label, none (Archive), or the
    /// person's own; nil for those it doesn't keep (Drafts, All Mail).
    public static func label(of folder: IMAPFolder) -> String?? {
        switch role(folder) {
        case "inbox": return "INBOX"
        case "sent": return "SENT"
        case "trash": return "TRASH"
        case "junk": return "SPAM"
        case "archive": return .some(nil)
        case "drafts", "all", "flagged", "important": return nil
        default: return folderPrefix + folder.shown
        }
    }

    private func folderLabel(_ folder: IMAPFolder) -> String?? {
        if gmail {
            switch Self.role(folder) {
            case "all": return .some(nil)
            case "flagged": return "STARRED"
            case "important": return "IMPORTANT"
            default: break
            }
        }
        return Self.label(of: folder)
    }

    private func listed(force: Bool = false) async throws -> [IMAPFolder] {
        if !force, !folders.isEmpty, Date().timeIntervalSince(listedAt) < 600 { return folders }
        let unkept = Set(MailKnownProviders.by(id: setup.provider)?.unkept ?? [])
        folders = try await on { try await $0.list() }.filter { $0.selectable && !unkept.contains($0.shown.lowercased()) }
        listedAt = Date()
        return folders
    }

    private func folder(role: String) async throws -> IMAPFolder? {
        try await listed().first { Self.role($0) == role }
    }

    private func folder(label: String) async throws -> IMAPFolder? {
        try await listed().first { (folderLabel($0) ?? nil) == label }
    }

    /// The folders a sync keeps: the inbox first, Sent, then the rest.
    private func synced() async throws -> [IMAPFolder] {
        let all = try await listed().filter { folderLabel($0) != nil }
        // Resolve a new SMTP thread before an unreferenced reply in Inbox
        // can choose its identity. Other syncs still show the inbox first.
        let pendingThread = gmailExtensions && justSent.values.contains { $0.thread.hasPrefix("t") }
        let order = ["inbox": pendingThread ? 1 : 0, "sent": pendingThread ? 0 : 1, "archive": 2, "trash": 3, "junk": 4]
        return all.sorted { (order[Self.role($0) ?? ""] ?? 5, $0.shown) < (order[Self.role($1) ?? ""] ?? 5, $1.shown) }
    }

    /// Archive's folder, made once where the account has none.
    private func archive() async throws -> IMAPFolder {
        if gmail, let all = try await folder(role: "all") { return all }
        if let there = try await folder(role: "archive") { return there }
        let delimiter = folders.first?.delimiter ?? "/"
        _ = delimiter
        try await on { try await $0.create("Archive") }
        return try await listed(force: true).first { Self.role($0) == "archive" } ?? IMAPFolder(name: "Archive", delimiter: "/", attributes: ["\\archive"])
    }

    // MARK: - Gmail's IMAP extensions

    /// Google's IDs are unsigned decimal on the wire, hex in Gmail links.
    static func gmailID(_ value: IMAPValue?) -> String? {
        value?.text.flatMap(UInt64.init).map { String($0, radix: 16) }
    }

    static func gmailLabels(_ value: IMAPValue) -> Set<String> {
        let system = ["\\inbox": "INBOX", "\\sent": "SENT", "\\trash": "TRASH", "\\spam": "SPAM",
                      "\\starred": "STARRED", "\\important": "IMPORTANT", "\\draft": "DRAFT", "\\drafts": "DRAFT"]
        return Set(value.items.compactMap { item in
            guard let name = item.text else { return nil }
            if let label = system[name.lowercased()] { return label }
            return name.hasPrefix("\\") ? nil : Self.folderPrefix + IMAPName.decode(name)
        })
    }

    private func applyGmail(add: Set<String>, remove: Set<String>, ids: [String]) async throws {
        let system = ["INBOX": "\\Inbox", "TRASH": "\\Trash", "SPAM": "\\Spam", "IMPORTANT": "\\Important"]
        func names(_ labels: Set<String>) -> [String] {
            labels.compactMap { label in
                if let name = system[label] { return name }
                if label.hasPrefix(Self.folderPrefix) { return IMAPName.encode(String(label.dropFirst(Self.folderPrefix.count))) }
                return nil
            }.sorted()
        }
        for id in ids {
            let rows = places.rows(id: id).filter { $0.uid > 0 }
            // All Mail survives archiving and removal of a custom label.
            let all = try await folder(role: "all")?.name
            guard let row = rows.first(where: { $0.folder == all }) ?? rows.first else { continue }
            let labels = try await on { client -> IMAPValue? in
                if await client.selected != row.folder { try await client.select(row.folder) }
                // Remove last: removing Inbox can expunge its selected UID.
                for (more, labels) in [(true, names(add)), (false, names(remove))] where !labels.isEmpty {
                    var args: [IMAPClient.Arg] = [.raw(" \(more ? "+" : "-")X-GM-LABELS.SILENT (")]
                    for (index, label) in labels.enumerated() {
                        if index > 0 { args.append(.raw(" ")) }
                        args.append(.quoted(label))
                    }
                    args.append(.raw(")"))
                    _ = try await client.run("UID STORE \(row.uid)", arguments: args)
                }
                return try await client.fetch(String(row.uid), "(UID FLAGS X-GM-LABELS)")[row.uid]?["X-GM-LABELS"]
            }
            let had = places.gmailLabels(id) ?? store.message(id)?.labels ?? []
            let now = labels.map(Self.gmailLabels) ?? had.union(add).subtracting(remove)
            _ = places.gmailLabels(id, now)
            for old in rows where old.label.map(remove.contains) == true {
                _ = places.remove(folder: old.folder, uids: [old.uid])
            }
            // Folder rows catch up on the next sync; authoritative labels
            // already reflect this edit even when its UID was expunged.
            relabel([id])
        }
    }

    // MARK: - ids

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// A message's id: by its Message-ID, else by where it sits.
    static func id(rfc: String, folder: String, validity: Int64, uid: Int64) -> String {
        let bare = rfc.trimmingCharacters(in: .whitespaces).lowercased()
        return bare.isEmpty ? "u" + hash("\(folder)\n\(validity)\n\(uid)") : "i" + hash(bare)
    }

    /// Its thread: the one a message it answers is in, here, else the first
    /// it names, else its own.
    func thread(rfc: String, references: String, inReplyTo: String) -> String {
        let named = MailRFC822.ids(references) + MailRFC822.ids(inReplyTo)
        for one in named.reversed() {
            if let known = places.thread(rfc: one) { return known }
        }
        if let root = named.first { return "t" + Self.hash(root.lowercased()) }
        return "t" + Self.hash(rfc.isEmpty ? UUID().uuidString : rfc.lowercased())
    }

    // MARK: - messages read

    /// IMAP's INTERNALDATE: "17-Jul-1996 02:44:25 -0700".
    static func internalDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return internalFormat.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static let internalFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    /// The labels flags make: UNREAD without \Seen, STARRED with \Flagged.
    static func labels(flags: Set<String>) -> Set<String> {
        var out: Set<String> = []
        if !flags.contains("\\seen") { out.insert("UNREAD") }
        if flags.contains("\\flagged") { out.insert("STARRED") }
        return out
    }

    /// A message's labels from where it sits and its flags, with the ones
    /// this Mac alone keeps.
    func labels(of id: String, kept: Set<String>) -> Set<String> {
        var out = kept.filter { $0.hasPrefix(Self.localPrefix) }
        let rows = places.rows(id: id)
        let serverLabels = gmailExtensions ? places.gmailLabels(id) : nil
        out.formUnion(serverLabels ?? [])
        var seen = false, flagged = false
        for row in rows {
            if serverLabels == nil, let label = row.label { out.insert(label) }
            if row.flags.contains("\\seen") { seen = true }
            if row.flags.contains("\\flagged") { flagged = true }
        }
        if !seen, !rows.isEmpty { out.insert("UNREAD") }
        if flagged { out.insert("STARRED") }
        return out
    }

    /// Messages fetched from one folder, kept: their rows here, their
    /// threads, their labels, the ones this Mac keeps alone kept on.
    private func take(_ fetched: [Int64: [String: IMAPValue]], in folder: IMAPFolder, validity: Int64, full: Bool) -> [MailMessage] {
        let label = folderLabel(folder) ?? nil
        var out: [MailMessage] = []
        var made: [(id: String, raw: Data, thread: String, date: Date?)] = []
        for (uid, attributes) in fetched.sorted(by: { $0.key < $1.key }) {
            let raw = attributes["BODY[]"]?.data ?? attributes["BODY[HEADER]"]?.data ?? Data()
            guard !raw.isEmpty else { continue }
            let flags = Set(attributes["FLAGS"]?.items.compactMap { $0.text?.lowercased() } ?? [])
            let gmailLabels = gmail ? attributes["X-GM-LABELS"].map(Self.gmailLabels) : nil
            // Web drafts can also appear in All Mail. Yab keeps its own
            // drafts, so never turn a server draft into a received message.
            if gmail, flags.contains("\\draft") || gmailLabels?.contains("DRAFT") == true { continue }
            let head = MailRFC822.headers(MailRFC822.split(raw).head)
            func header(_ name: String) -> String { head.first { $0.name.lowercased() == name }?.value ?? "" }
            let rfc = header("message-id")
            // A locally sent message keeps the ID already handed to the
            // outbox, even if IMAP sees it while SMTP is still answering.
            let localID = gmail ? places.message(rfc: rfc).flatMap { $0.hasPrefix("i") ? $0 : nil } : nil
            let id = localID ?? (gmail ? Self.gmailID(attributes["X-GM-MSGID"]) : nil)
                ?? Self.id(rfc: rfc, folder: folder.name, validity: validity, uid: uid)
            let knownThread = places.thread(rfc: rfc)
            let references = (MailRFC822.ids(header("references")) + MailRFC822.ids(header("in-reply-to"))).reversed()
            let localThread = ([knownThread].compactMap { $0 } + references.compactMap { places.thread(rfc: $0) }).first { $0.hasPrefix("t") }
            let threadID = (gmail ? Self.gmailID(attributes["X-GM-THRID"]) : nil).map { places.gmailThread($0, preferred: localThread) }
                ?? knownThread ?? thread(rfc: rfc, references: header("references"), inReplyTo: header("in-reply-to"))
            if let labels = gmailLabels { _ = places.gmailLabels(id, labels) }
            if !rfc.isEmpty { places.remember(rfc: rfc, id: id, thread: threadID, replace: gmail) }
            places.put(folder: folder.name, uid: uid, id: id, label: label, flags: flags)
            // The server's copy of what was just sent is here now: read from it.
            if uid > 0 { justSent[id] = nil }
            made.append((id, raw, threadID, Self.internalDate(attributes["INTERNALDATE"]?.text)))
        }
        let kept = store.labels(of: made.map(\.id))
        for one in made {
            let labels = labels(of: one.id, kept: kept[one.id] ?? [])
            let whole = full && fetched.values.contains { $0["BODY[]"] != nil }
            if let message = MailRFC822.message(one.raw, id: one.id, thread: one.thread, labels: labels, date: one.date, full: whole) {
                out.append(message)
            }
        }
        return out
    }

    /// UIDs fetched and kept, a chunk at a time; the store told every few
    /// chunks on a first sync.
    private func bring(_ uids: [Int64], from folder: IMAPFolder, validity: Int64, full: Bool, size: Int = 100) async throws -> Int {
        var brought = 0
        let items = full ? "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[]" : "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER]"
        // Newest first: what is read first comes first.
        for chunk in IMAPSet.chunks(uids, size: size).reversed() {
            let fetched = try await on { client -> [Int64: [String: IMAPValue]] in
                if await client.selected != folder.name { try await client.select(folder.name) }
                let extra = gmailExtensions ? " X-GM-MSGID X-GM-THRID X-GM-LABELS" : ""
                return try await client.fetch(IMAPSet.string(chunk), "(" + items + extra + ")")
            }
            let messages = take(fetched, in: folder, validity: validity, full: full)
            guard store.put(messages) else { throw MailTrouble.store }
            MailMemory.attached(to: store)?.later(messages)
            brought += messages.count
        }
        return brought
    }

    // MARK: - MailSyncing

    public func set(shownLabels: [String]) { self.shownLabels = shownLabels }

    @discardableResult
    public func sync() async throws -> Bool {
        do {
            return try await syncing()
        } catch {
            throw Self.said(error)
        }
    }

    private func syncing() async throws -> Bool {
        let first = store.value("history") == nil
        if first {
            store.set("me", setup.address)
            store.set("since", String(Date().timeIntervalSince1970 - Double(days) * 86_400))
        }
        let all = try await synced()
        // The column's labels: every folder, and those this Mac keeps alone.
        if first || Date().timeIntervalSince(listedAt) < 1 { _ = try await keepLabels(now: Date(), force: true) }
        var changed = false
        for folder in all {
            changed = try await sync(folder, first: first) || changed
            if first, Self.role(folder) == "inbox" {
                MailOps.layOver(store)
                told?()
            }
        }
        if changed || first {
            MailOps.layOver(store)
            MailOps.keepMuted(store)
            MailOps.keepBlocked(store)
            MailOps.keepAnswered(store)
        }
        if first {
            store.set("history", "imap")
            store.set("inbox", "whole")
            store.set("attachments", "1")
            store.set("pruned", String(Date().timeIntervalSince1970))
        }
        store.set("synced", String(Date().timeIntervalSince1970))
        _ = try? await countLabels(now: Date())
        await keepSendAs(now: Date())
        startIdle()
        return changed || first
    }

    /// One folder in step: what is new, what changed its flags, what went.
    private func sync(_ folder: IMAPFolder, first: Bool) async throws -> Bool {
        let inbox = Self.role(folder) == "inbox", sent = Self.role(folder) == "sent"
        let (selected, condstore) = try await on { client -> (IMAPSelected, Bool) in
            (try await client.select(folder.name), await client.condstore)
        }
        var kept = places.state(folder.name)
        if let was = kept, was.validity != selected.validity {
            // UIDVALIDITY changed: every UID it had means nothing now.
            let orphans = places.drop(folder: folder.name)
            store.remove(messages: orphans)
            kept = nil
        }
        var changed = false
        if kept == nil {
            // The folder from nothing: the inbox whole, the rest of the last
            // sixty days, by their headers; the newest and the last month whole.
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            let uids = try await on { try await $0.search(inbox ? "ALL" : "SINCE " + Self.searchDate(since)) }
            let wholeSince = try await on { try await $0.search("SINCE " + Self.searchDate(Date().addingTimeInterval(-Double(bodyDays) * 86_400))) }
            let newest = Array(uids.suffix(inbox || sent ? ahead : firstPage))
            var whole = Set(newest).union(wholeSince)
            if inbox, first {
                // The first screen: the inbox's newest, whole, at once.
                let head = Array(uids.suffix(firstPage))
                changed = try await bring(head, from: folder, validity: selected.validity, full: true, size: 25) > 0 || changed
                whole.subtract(head)
                MailOps.layOver(store)
                told?()
            }
            let headed = uids.filter { !whole.contains($0) && places.id(folder: folder.name, uid: $0) == nil }
            let bodies = Array(whole).filter { places.id(folder: folder.name, uid: $0) == nil }
            changed = try await bring(bodies, from: folder, validity: selected.validity, full: true, size: 25) > 0 || changed
            changed = try await bring(headed, from: folder, validity: selected.validity, full: false) > 0 || changed
            places.set(folder.name, MailIMAPPlaces.State(validity: selected.validity, next: max(selected.next, (uids.max() ?? 0) + 1),
                                                         modseq: selected.modseq, exists: selected.exists))
            return changed
        }
        guard var state = kept else { return changed }
        // New mail: whole, as it is what is read next.
        var arrived = 0
        if selected.next > state.next || selected.next == 0 {
            let fresh = try await on { try await $0.search("UID \(state.next):*") }.filter { $0 >= state.next }
            if !fresh.isEmpty {
                arrived = fresh.count
                changed = try await bring(fresh, from: folder, validity: selected.validity, full: true, size: 25) > 0 || changed
                state.next = (fresh.max() ?? state.next) + 1
            }
        }
        // Flags changed since: by MODSEQ where the server keeps one, else
        // the last month's every sync and the whole folder's every ten minutes.
        var flagged: [Int64: [String: IMAPValue]] = [:]
        let flagItems = gmailExtensions ? "(UID FLAGS X-GM-LABELS)" : "(UID FLAGS)"
        var sweptAll = false
        if condstore, selected.modseq > 0 {
            if selected.modseq != state.modseq {
                flagged = try await on { try await $0.fetch("1:*", flagItems, changedSince: state.modseq) }
            }
        } else {
            let swept = sweptAt[folder.name] ?? .distantPast
            if Date().timeIntervalSince(swept) > 600 {
                flagged = try await on { try await $0.fetch("1:*", flagItems) }
                sweptAt[folder.name] = Date()
                sweptAll = true
            } else if let low = places.lowest(folder: folder.name, newest: 500) {
                flagged = try await on { try await $0.fetch("\(low):*", flagItems) }
            }
        }
        var relabeled: [String] = []
        for (uid, attributes) in flagged {
            guard let id = places.id(folder: folder.name, uid: uid) else { continue }
            let flags = Set(attributes["FLAGS"]?.items.compactMap { $0.text?.lowercased() } ?? [])
            let changedLabels = gmail && attributes["X-GM-LABELS"].map { places.gmailLabels(id, Self.gmailLabels($0)) } == true
            if places.set(flags: flags, folder: folder.name, uid: uid) || changedLabels { relabeled.append(id) }
        }
        // Gone: what the folder holds asked when its count says some went
        // (or, without CONDSTORE, every ten minutes with the flags).
        if selected.exists < state.exists + Int64(arrived) || sweptAll {
            let there = Set(try await on { try await $0.search("ALL") })
            let gone = places.uids(folder: folder.name).filter { $0 > 0 && !there.contains($0) }
            if !gone.isEmpty {
                let ids = places.remove(folder: folder.name, uids: gone)
                let orphans = ids.filter { places.rows(id: $0).isEmpty }
                store.remove(messages: orphans)
                relabeled += ids.filter { !orphans.contains($0) }
                changed = true
            }
        }
        if !relabeled.isEmpty {
            relabel(Array(Set(relabeled)))
            changed = true
        }
        state.exists = selected.exists
        state.modseq = selected.modseq
        if selected.next > 0 { state.next = max(state.next, selected.next) }
        places.set(folder.name, state)
        return changed
    }

    /// The store's labels of these messages made what their rows say.
    private func relabel(_ ids: [String]) {
        let kept = store.labels(of: ids)
        for id in ids {
            guard let had = kept[id] else { continue }
            let now = labels(of: id, kept: had)
            let add = now.subtracting(had), remove = had.subtracting(now)
            if !add.isEmpty || !remove.isEmpty { store.relabel(message: id, add: add, remove: remove) }
        }
    }

    /// SEARCH's date: "1-Feb-1994".
    static func searchDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d-MMM-yyyy"
        return f.string(from: date)
    }

    public func open(thread id: String) async throws {
        store.opened(id)
        let kept = store.messages(thread: id)
        let wanted = kept.filter { $0.text == nil || ($0.files == nil && $0.attached != false) }
        guard !wanted.isEmpty else { return }
        var got: [MailMessage] = []
        for message in wanted {
            if let whole = try await self.message(message.id, full: true) { got.append(whole) }
        }
        store.put(got)
        MailOps.layOver(store)
    }

    public func prefetch(threads ids: [String]) async {
        for item in store.unbodied(ids) {
            var got: [MailMessage] = []
            for id in item.messages {
                if let whole = try? await message(id, full: true) { got.append(whole) }
            }
            store.put(got)
        }
        MailOps.layOver(store)
    }

    /// A search the server answers from the whole mailbox (UID SEARCH in
    /// each folder it names, or every kept one but Trash and Junk): what
    /// it finds that isn't here comes by its headers, the newest `take`,
    /// kept as brought by a search. The threads it found, newest first;
    /// none when the words hold something IMAP's SEARCH can't say
    /// (has:attachment, a category, size:), and the store answers alone.
    public func search(_ query: MailQuery, take: Int, pages: Int) async throws -> (threads: [String], more: Bool) {
        guard let root = query.root, let asked = IMAPSearch(me: setup.address).read(root) else { return ([], false) }
        let all = try await synced()
        let folders = all.filter { folder in
            let label = folderLabel(folder) ?? nil
            if let wanted = asked.folders { return wanted.contains((label ?? "").lowercased()) }
            return asked.anywhere || (label != "TRASH" && label != "SPAM")
        }
        var found: [(folder: IMAPFolder, uid: Int64)] = []
        for folder in folders {
            let uids = try await on { client -> [Int64] in
                if await client.selected != folder.name { try await client.select(folder.name) }
                return try await client.search(pieces: asked.pieces.isEmpty ? [.raw("ALL")] : asked.pieces)
            }
            found += uids.map { (folder, $0) }
        }
        // Those not here, the newest UIDs of each folder first, by their headers.
        let missing = found.filter { places.id(folder: $0.folder.name, uid: $0.uid) == nil }
        var brought = 0
        for (name, here) in Dictionary(grouping: missing, by: { $0.folder.name }) {
            guard brought < take, let folder = folders.first(where: { $0.name == name }) else { continue }
            let newest = Array(here.map(\.uid).sorted().suffix(take - brought))
            let validity = places.state(name)?.validity ?? 0
            let fetched = try await on { client -> [Int64: [String: IMAPValue]] in
                if await client.selected != folder.name { try await client.select(folder.name) }
                let extra = gmailExtensions ? " X-GM-MSGID X-GM-THRID X-GM-LABELS" : ""
                return try await client.fetch(IMAPSet.string(newest), "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER]" + extra + ")")
            }
            let messages = self.take(fetched, in: folder, validity: validity, full: false)
            store.put(messages, backfilled: true)
            brought += messages.count
        }
        if brought > 0 { MailOps.layOver(store) }
        let ids = found.compactMap { places.id(folder: $0.folder.name, uid: $0.uid) }
        var seen = Set<String>()
        let threads = ids.compactMap { store.message($0) }.sorted { $0.date > $1.date }.map(\.thread).filter { seen.insert($0).inserted }
        return (threads, missing.count > brought)
    }

    @discardableResult
    public func keepLabels(now: Date, force: Bool) async throws -> Bool {
        let last = store.value("labels").flatMap(Double.init) ?? 0
        guard force || now.timeIntervalSince1970 - last >= 600 else { return false }
        let before = store.labels().map { [$0.id, $0.name] }
        store.keepLabels(try await labels())
        store.set("labels", String(now.timeIntervalSince1970))
        return store.labels().map { [$0.id, $0.name] } != before
    }

    @discardableResult
    public func countLabels(now: Date) async throws -> Bool {
        var changed = false
        let known = Dictionary(store.labels().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in shownLabels.prefix(25) where id.hasPrefix(Self.folderPrefix) {
            let got = try await label(id: id)
            if known[id]?.unread != got.unread || known[id]?.threads != got.threads { changed = true }
            store.count(label: id, unread: got.unread ?? 0, threads: got.threads ?? 0, at: now)
        }
        return changed
    }

    public func keepSendAs(now: Date) async {
        if let at = store.value("sendas.at").flatMap(Double.init), now.timeIntervalSince1970 - at < 86_400 { return }
        store.keep(sendAs: (try? await sendAs()) ?? [])
        store.set("sendas.at", String(now.timeIntervalSince1970))
    }

    // MARK: - IDLE

    /// A line of its own on the inbox, idling: new mail tells the center
    /// at once instead of at the next ask. Again after a failure, a little
    /// later each time.
    private func startIdle() {
        guard idling == nil, !closed, let told else { return }
        let setup = setup, password = password
        idling = Task.detached(priority: .utility) { [weak self] in
            var wait: UInt64 = 5
            while !Task.isCancelled {
                do {
                    let client = try await MailIMAPAccount.connect(setup, password: try await password())
                    guard await client.has("IDLE") else {
                        await client.logout()
                        return
                    }
                    try await client.select("INBOX", readOnly: true)
                    guard await self?.idle(on: client) == true else {
                        await client.logout()
                        return
                    }
                    wait = 5
                    while !Task.isCancelled {
                        if try await client.idle(seconds: 25 * 60) { told() }
                    }
                    await client.logout()
                } catch {
                    try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                    wait = min(wait * 2, 300)
                }
            }
        }
    }

    /// IDLE's line kept, so close() can close it; false once closed.
    private func idle(on client: IMAPClient) -> Bool {
        guard !closed else { return false }
        idler = client
        return true
    }

    // MARK: - MailProvider

    public func who() async throws -> MailIdentity { MailIdentity(address: setup.address, name: setup.name) }

    public func labels() async throws -> [MailLabel] {
        var out: [MailLabel] = []
        for folder in try await listed(force: true) {
            guard case let label?? = folderLabel(folder) else { continue }
            if label.hasPrefix(Self.folderPrefix) {
                out.append(MailLabel(id: label, name: String(label.dropFirst(Self.folderPrefix.count)), type: "user"))
            } else {
                out.append(MailLabel(id: label, name: label, type: "system"))
            }
        }
        // Those this Mac keeps alone stay listed, so the store keeps them.
        out += store.labels().filter { $0.id.hasPrefix(Self.localPrefix) }
        return out
    }

    public func label(id: String) async throws -> MailLabel {
        guard let folder = try await folder(label: id) else { throw MailTrouble.status(404) }
        let status = try await on { try await $0.status(folder.name) }
        let name = id.hasPrefix(Self.folderPrefix) ? String(id.dropFirst(Self.folderPrefix.count)) : id
        return MailLabel(id: id, name: name, type: id.hasPrefix("Label_") ? "user" : "system", unread: status.unseen, threads: status.messages)
    }

    /// A label made by Yab itself (yab/Snoozed, yab/Muted): this Mac's alone.
    public func label(named name: String) async throws -> String { Self.localPrefix + name }

    private func serverName(_ shown: String) async throws -> String {
        let delimiter = try await listed().first?.delimiter ?? "/"
        let parts = shown.split(separator: "/").map { IMAPName.encode(String($0)) }
        return parts.joined(separator: delimiter.isEmpty ? "/" : delimiter)
    }

    public func makeLabel(named name: String) async throws -> MailLabel {
        let server = try await serverName(name)
        do {
            try await on { try await $0.create(server) }
        } catch MailServerTrouble.refused(let said) where said.uppercased().contains("ALREADYEXISTS") || said.lowercased().contains("exists") {}
        _ = try await listed(force: true)
        return MailLabel(id: Self.folderPrefix + name, name: name, type: "user")
    }

    public func renameLabel(id: String, to name: String) async throws -> MailLabel {
        guard let folder = try await folder(label: id) else { throw MailTrouble.status(404) }
        let server = try await serverName(name)
        try await on { try await $0.rename(folder.name, to: server) }
        // Its rows' folder now goes by the new name.
        places.rename(folder: folder.name, to: server, label: Self.folderPrefix + name)
        _ = try await listed(force: true)
        return MailLabel(id: Self.folderPrefix + name, name: name, type: "user")
    }

    public func showLabel(id: String, _ shown: String) async throws -> MailLabel {
        store.labels().first { $0.id == id } ?? MailLabel(id: id, name: id)
    }

    public func deleteLabel(id: String) async throws {
        guard id.hasPrefix(Self.folderPrefix), let folder = try await folder(label: id) else { return }
        try await on { try await $0.delete(folder.name) }
        let orphans = places.drop(folder: folder.name)
        store.remove(messages: orphans.filter { places.rows(id: $0).isEmpty })
        _ = try await listed(force: true)
    }

    public func unread(in label: String, page: String?) async throws -> (ids: [String], next: String?) {
        guard let folder = try await folder(label: label) else { return ([], nil) }
        let uids = try await on { client -> [Int64] in
            try await client.select(folder.name)
            return try await client.search("UNSEEN")
        }
        return (uids.compactMap { places.id(folder: folder.name, uid: $0) }, nil)
    }

    public func message(_ id: String, full: Bool) async throws -> MailMessage? {
        if let sent = justSent[id] {
            return MailRFC822.message(sent.raw, id: id, thread: sent.thread, labels: ["SENT"], date: Date(), full: full)
        }
        guard let row = places.rows(id: id).first(where: { $0.uid > 0 }) else { return nil }
        let folders = try await listed()
        guard let folder = folders.first(where: { $0.name == row.folder }) else { return nil }
        let validity = places.state(folder.name)?.validity ?? 0
        let fetched = try await on { client -> [Int64: [String: IMAPValue]] in
            if await client.selected != folder.name { try await client.select(folder.name) }
            let items = full ? "UID FLAGS INTERNALDATE BODY.PEEK[]" : "UID FLAGS INTERNALDATE BODY.PEEK[HEADER]"
            let extra = gmailExtensions ? " X-GM-MSGID X-GM-THRID X-GM-LABELS" : ""
            return try await client.fetch(String(row.uid), "(" + items + extra + ")")
        }
        guard !fetched.isEmpty else { throw MailTrouble.status(404) }
        return take(fetched, in: folder, validity: validity, full: full).first { $0.id == id }
    }

    public func thread(_ id: String, full: Bool) async throws -> [MailMessage] {
        var out: [MailMessage] = []
        for message in store.messages(thread: id) {
            if let got = try await self.message(message.id, full: full) { out.append(got) }
        }
        return out
    }

    public func attachment(message: String, id: String) async throws -> Data {
        if let sent = justSent[message], let data = MailRFC822.part(sent.raw, id: id) { return data }
        guard let row = places.rows(id: message).first(where: { $0.uid > 0 }) else { throw MailTrouble.status(404) }
        let fetched = try await on { client -> [Int64: [String: IMAPValue]] in
            if await client.selected != row.folder { try await client.select(row.folder) }
            return try await client.fetch(String(row.uid), "(UID BODY.PEEK[])")
        }
        guard let raw = fetched[row.uid]?["BODY[]"]?.data, let data = MailRFC822.part(raw, id: id) else { throw MailTrouble.status(404) }
        return data
    }

    /// Labels on and off, as folders and flags: UNREAD and STARRED are
    /// \Seen and \Flagged on every place the message sits; a folder's label
    /// on is a move there, the inbox's off a move to Archive, Trash's or
    /// Junk's off a move back to the inbox. This Mac's own labels stay here.
    public func apply(_ edit: MailEdit, in store: MailStore) async throws {
        do {
            try await applying(edit, in: store)
        } catch {
            throw Self.said(error)
        }
    }

    private func applying(_ edit: MailEdit, in store: MailStore) async throws {
        let ids: [String]
        switch edit.target {
        case .thread(let t): ids = store.messages(thread: t).map(\.id)
        case .threads(let ts): ids = store.messageIDs(threads: ts)
        case .messages(let ms): ids = ms
        }
        guard !ids.isEmpty else { return }
        var add = edit.add, remove = edit.remove
        if edit.way == .trash { add.insert("TRASH") }
        // Flags, on every place.
        var flags: [(flag: String, on: Bool)] = []
        if add.contains("UNREAD") { flags.append(("\\Seen", false)) }
        if remove.contains("UNREAD") { flags.append(("\\Seen", true)) }
        if add.contains("STARRED") { flags.append(("\\Flagged", true)) }
        if remove.contains("STARRED") { flags.append(("\\Flagged", false)) }
        let rows = ids.flatMap { places.rows(id: $0) }.filter { $0.uid > 0 }
        if !flags.isEmpty {
            for (folder, here) in Dictionary(grouping: rows, by: \.folder) {
                let set = IMAPSet.string(here.map(\.uid))
                try await on { client in
                    if await client.selected != folder { try await client.select(folder) }
                    for one in flags { try await client.store(set, add: one.on, flags: [one.flag]) }
                }
                for row in here {
                    var now = row.flags
                    for one in flags { if one.on { now.insert(one.flag.lowercased()) } else { now.remove(one.flag.lowercased()) } }
                    places.set(flags: now, folder: folder, uid: row.uid)
                }
            }
        }
        // Gmail labels are independent memberships. Removing Inbox archives
        // without moving out of any of the person's other labels.
        if gmailExtensions {
            if add.contains("TRASH") { remove.formUnion(["INBOX", "SPAM"]) }
            if add.contains("SPAM") { remove.formUnion(["INBOX", "TRASH"]) }
            try await applyGmail(add: add, remove: remove, ids: ids)
            return
        }
        // Where to: the folder its labels now say.
        add.subtract(["UNREAD", "STARRED", "IMPORTANT"])
        remove.subtract(["UNREAD", "STARRED", "IMPORTANT"])
        add = add.filter { !$0.hasPrefix(Self.localPrefix) && !$0.hasPrefix("CATEGORY_") }
        remove = remove.filter { !$0.hasPrefix(Self.localPrefix) && !$0.hasPrefix("CATEGORY_") }
        guard !add.isEmpty || !remove.isEmpty else { return }
        let target: IMAPFolder?
        var from: Set<String?>
        if add.contains("TRASH") {
            target = try await folder(role: "trash")
            from = Set(rows.map(\.label)).subtracting([Optional("TRASH")])
        } else if add.contains("SPAM") {
            target = try await folder(role: "junk")
            from = Set(rows.map(\.label)).subtracting([Optional("SPAM")])
        } else if let named = add.first(where: { $0.hasPrefix(Self.folderPrefix) }) {
            target = try await folder(label: named)
            from = Set(rows.map(\.label)).subtracting([Optional(named), Optional("SENT")])
        } else if add.contains("INBOX") || remove.contains("TRASH") || remove.contains("SPAM") {
            target = try await folder(role: "inbox")
            from = Set(remove.map { Optional($0) })
            if add.contains("INBOX") { from.formUnion([Optional("TRASH"), Optional("SPAM"), Optional<String>.none]) }
        } else if remove.contains("INBOX") || remove.contains(where: { $0.hasPrefix(Self.folderPrefix) }) {
            target = try await archive()
            from = Set(remove.map { Optional($0) })
        } else {
            return
        }
        guard let target else { throw MailServerTrouble.capabilityMissing("find the folder to move it to") }
        let targetLabel = folderLabel(target) ?? nil
        let moving = rows.filter { from.contains($0.label) && $0.folder != target.name }
        for (folder, here) in Dictionary(grouping: moving, by: \.folder) {
            let uids = here.map(\.uid)
            let mapped = try await on { client -> [Int64: Int64] in
                if await client.selected != folder { try await client.select(folder) }
                return try await client.move(IMAPSet.string(uids), to: target.name)
            }
            _ = places.remove(folder: folder, uids: uids)
            for row in here {
                // Where it is now: its UID there when the server said, else
                // a mark kept until the target's next sync finds it.
                places.put(folder: target.name, uid: mapped[row.uid] ?? -Int64.random(in: 1 ... Int64.max / 2), id: row.id, label: targetLabel,
                           flags: row.flags)
            }
        }
    }

    public func send(raw: String, thread: String) async throws -> (message: String?, thread: String) {
        let data = Data(raw.utf8)
        let head = MailRFC822.headers(MailRFC822.split(data).head)
        func header(_ name: String) -> String { head.first { $0.name.lowercased() == name }?.value ?? "" }
        let from = MailPerson.one(MailMime.words(header("from")))?.address ?? setup.address
        var smtp = MailSMTP(host: setup.smtpHost, port: setup.smtpPort, security: setup.smtpSecurity, user: setup.smtpUser,
                            password: try await password())
        smtp.auth = setup.smtpAuth
        do {
            try await smtp.send(data, from: from.isEmpty ? setup.address : from)
        } catch {
            throw Self.said(error)
        }
        let sentFolder = try? await folder(role: "sent")
        let rfc = header("message-id")
        let knownID = gmail ? places.message(rfc: rfc) : nil
        let id = knownID ?? Self.id(rfc: rfc, folder: "sent", validity: 0, uid: Int64(Date().timeIntervalSince1970))
        let knownThread = gmail ? places.thread(rfc: rfc) : nil
        let threadID = thread.isEmpty ? knownThread ?? self.thread(rfc: rfc, references: header("references"), inReplyTo: header("in-reply-to")) : thread
        if !rfc.isEmpty { places.remember(rfc: rfc, id: id, thread: threadID) }
        justSent[id] = (data, threadID)
        // Sent keeps a copy: put there unless the server does it itself.
        if let sent = sentFolder {
            var uid: Int64?
            if !setup.savesSent {
                uid = try? await on { try await $0.append(sent.name, message: data, flags: ["\\Seen"]) }
            }
            places.put(folder: sent.name, uid: uid ?? -Int64.random(in: 1 ... Int64.max / 2), id: id, label: "SENT", flags: ["\\seen"])
        }
        return (id, threadID)
    }

    public func sentThread(messageID: String) async throws -> String? {
        if let known = places.thread(rfc: messageID) { return known }
        guard let sent = try await folder(role: "sent") else { return nil }
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let found = try await on { client -> [Int64] in
            try await client.select(sent.name)
            return try await client.search("HEADER Message-ID \"\(bare)\"")
        }
        return found.isEmpty ? nil : "t" + Self.hash(messageID.lowercased())
    }

    public func sendAs() async throws -> [MailSendAs] {
        [MailSendAs(address: setup.address.lowercased(), name: setup.name, primary: true, isDefault: true)]
    }
}

// MARK: - where each message sits

/// Beside the store, `<store>.imap`: each message's places (folder, UID,
/// flags, the label its folder makes), each folder's marks of change, and
/// the Message-IDs met with their threads.
final class MailIMAPPlaces: @unchecked Sendable {
    private let db: SQLiteConnection?
    private let lock = NSLock()

    struct Row: Equatable {
        var folder: String
        var uid: Int64
        var id: String
        var label: String?
        var flags: Set<String>
    }

    struct State: Equatable {
        var validity: Int64
        var next: Int64
        var modseq: Int64
        var exists: Int64
    }

    init(file: String?) {
        db = SQLiteConnection(path: file, name: "imap places")
        db?.exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS places(folder TEXT NOT NULL, uid INTEGER NOT NULL, id TEXT NOT NULL, label TEXT, flags TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(folder, uid));
        CREATE INDEX IF NOT EXISTS places_id ON places(id);
        CREATE TABLE IF NOT EXISTS folders(name TEXT PRIMARY KEY, validity INTEGER, next INTEGER, modseq INTEGER, existing INTEGER);
        CREATE TABLE IF NOT EXISTS rfc(rfc TEXT PRIMARY KEY, id TEXT, thread TEXT);
        CREATE TABLE IF NOT EXISTS gmail_labels(id TEXT PRIMARY KEY, labels TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS gmail_threads(server TEXT PRIMARY KEY, thread TEXT NOT NULL);
        """)
    }

    private func locked<T>(_ body: (SQLiteConnection) -> T?) -> T? {
        guard let db else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return body(db)
    }

    static func flags(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    func put(folder: String, uid: Int64, id: String, label: String?, flags: Set<String>) {
        _ = locked { db in
            // A mark kept for a move, now found where it went.
            db.run("DELETE FROM places WHERE id = ? AND folder = ? AND uid < 0", [id, folder])
            return db.run("INSERT OR REPLACE INTO places(folder, uid, id, label, flags) VALUES(?,?,?,?,?)",
                          [folder, uid, id, label as Any, flags.sorted().joined(separator: " ")])
        }
    }

    func rows(id: String) -> [Row] {
        locked { db in
            db.query("SELECT folder, uid, id, label, flags FROM places WHERE id = ?", [id]).map { r in
                Row(folder: r[0] as? String ?? "", uid: r[1] as? Int64 ?? 0, id: r[2] as? String ?? "", label: r[3] as? String,
                    flags: Self.flags(r[4] as? String ?? ""))
            }
        } ?? []
    }

    func id(folder: String, uid: Int64) -> String? {
        locked { $0.string("SELECT id FROM places WHERE folder = ? AND uid = ?", [folder, uid]) }
    }

    func uids(folder: String) -> [Int64] {
        locked { db in db.query("SELECT uid FROM places WHERE folder = ?", [folder]).compactMap { $0[0] as? Int64 } } ?? []
    }

    func count(folder: String) -> Int {
        Int(locked { $0.int("SELECT count(*) FROM places WHERE folder = ? AND uid > 0", [folder]) } ?? 0)
    }

    /// True when its flags changed.
    @discardableResult
    func set(flags: Set<String>, folder: String, uid: Int64) -> Bool {
        locked { db -> Bool in
            let now = flags.sorted().joined(separator: " ")
            guard let was = db.string("SELECT flags FROM places WHERE folder = ? AND uid = ?", [folder, uid]), was != now else { return false }
            db.run("UPDATE places SET flags = ? WHERE folder = ? AND uid = ?", [now, folder, uid])
            return true
        } ?? false
    }

    /// Rows gone; the ids they were.
    func remove(folder: String, uids: [Int64]) -> [String] {
        locked { db -> [String] in
            var ids: [String] = []
            for uid in uids {
                if let id = db.string("SELECT id FROM places WHERE folder = ? AND uid = ?", [folder, uid]) { ids.append(id) }
                db.run("DELETE FROM places WHERE folder = ? AND uid = ?", [folder, uid])
            }
            return ids
        } ?? []
    }

    /// A folder forgotten (its UIDVALIDITY changed, or it was deleted):
    /// the ids that sat nowhere else.
    func drop(folder: String) -> [String] {
        locked { db -> [String] in
            let ids = db.strings("SELECT DISTINCT id FROM places WHERE folder = ?", [folder])
            db.run("DELETE FROM places WHERE folder = ?", [folder])
            db.run("DELETE FROM folders WHERE name = ?", [folder])
            return ids.filter { db.int("SELECT count(*) FROM places WHERE id = ?", [$0]) == 0 }
        } ?? []
    }

    func rename(folder: String, to: String, label: String) {
        _ = locked { db in
            db.run("UPDATE places SET folder = ?, label = ? WHERE folder = ?", [to, label, folder])
            return db.run("UPDATE folders SET name = ? WHERE name = ?", [to, folder])
        }
    }

    func state(_ folder: String) -> State? {
        locked { db -> State? in
            guard let r = db.query("SELECT validity, next, modseq, existing FROM folders WHERE name = ?", [folder]).first else { return nil }
            return State(validity: r[0] as? Int64 ?? 0, next: r[1] as? Int64 ?? 1, modseq: r[2] as? Int64 ?? 0, exists: r[3] as? Int64 ?? 0)
        } ?? nil
    }

    func set(_ folder: String, _ state: State) {
        _ = locked { db in
            db.run("INSERT OR REPLACE INTO folders(name, validity, next, modseq, existing) VALUES(?,?,?,?,?)",
                   [folder, state.validity, state.next, state.modseq, state.exists])
        }
    }

    func remember(rfc: String, id: String, thread: String, replace: Bool = false) {
        _ = locked { db in
            db.run("INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO rfc(rfc, id, thread) VALUES(?,?,?)", [rfc.lowercased(), id, thread])
        }
    }

    func message(rfc: String) -> String? {
        locked { $0.string("SELECT id FROM rfc WHERE rfc = ?", [rfc.lowercased()]) }
    }

    /// The server's group can adopt the stable identity a new SMTP send
    /// already gave to reminders, read receipts and the outbox on this Mac.
    func gmailThread(_ server: String, preferred: String?) -> String {
        locked { db in
            if let kept = db.string("SELECT thread FROM gmail_threads WHERE server = ?", [server]) { return kept }
            let local = preferred.flatMap { candidate in
                db.string("SELECT server FROM gmail_threads WHERE thread = ?", [candidate]) == nil ? candidate : nil
            }
            let thread = local ?? server
            db.run("INSERT OR IGNORE INTO gmail_threads(server, thread) VALUES(?,?)", [server, thread])
            return thread
        } ?? server
    }

    func gmailLabels(_ id: String) -> Set<String>? {
        guard let text = locked({ $0.string("SELECT labels FROM gmail_labels WHERE id = ?", [id]) }),
              let labels = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { return nil }
        return Set(labels)
    }

    func gmailLabels(_ id: String, _ labels: Set<String>) -> Bool {
        guard gmailLabels(id) != labels, let data = try? JSONEncoder().encode(labels.sorted()) else { return false }
        _ = locked { $0.run("INSERT OR REPLACE INTO gmail_labels(id, labels) VALUES(?,?)", [id, String(decoding: data, as: UTF8.self)]) }
        return true
    }

    func thread(rfc: String) -> String? {
        guard !rfc.isEmpty else { return nil }
        return locked { $0.string("SELECT thread FROM rfc WHERE rfc = ?", [rfc.lowercased()]) }
    }

    /// The lowest of a folder's newest UIDs here: the flags swept each sync without CONDSTORE.
    func lowest(folder: String, newest: Int) -> Int64? {
        locked { $0.int("SELECT uid FROM places WHERE folder = ? AND uid > 0 ORDER BY uid DESC LIMIT 1 OFFSET ?", [folder, newest - 1])
            ?? $0.int("SELECT min(uid) FROM places WHERE folder = ? AND uid > 0", [folder]) }
    }
}

// MARK: - search words

/// Yab's search words (MailQuery, Gmail's own) as IMAP's SEARCH says them
/// (RFC 3501, 6.4.4): words as TEXT or SUBJECT, people as FROM, TO, CC and
/// BCC, is:unread and is:starred as UNSEEN and FLAGGED, dates as SINCE and
/// BEFORE, NOT, OR in pairs, in: and label: as the folders searched. Nil for
/// what SEARCH has no words for (has:attachment, categories, size:), so the
/// store answers alone rather than the server answering something wider.
struct IMAPSearch {
    let me: String

    struct Asked {
        var pieces: [IMAPClient.Arg]
        /// The folders' labels it names, lowercased ("" for Archive); nil, every kept one.
        var folders: Set<String>?
        var anywhere = false
    }

    func read(_ root: MailQuery.Term) -> Asked? {
        var terms: [MailQuery.Term]
        if case .all(let all) = root { terms = all } else { terms = [root] }
        var folders: Set<String>?
        var anywhere = false
        var tokens: [IMAPClient.Arg] = []
        for term in terms {
            switch term {
            case .anywhere:
                anywhere = true
            case .label(let name, let box):
                let low = name.lowercased()
                if box, ["unread", "starred"].contains(low) {
                    tokens += [.raw(low == "unread" ? "UNSEEN" : "FLAGGED")]
                    continue
                }
                let label: String
                if box {
                    guard let system = ["inbox": "INBOX", "sent": "SENT", "trash": "TRASH", "spam": "SPAM", "archive": ""][low] else { return nil }
                    label = system
                } else {
                    guard !name.hasPrefix("CATEGORY_") else { return nil }
                    label = MailIMAPAccount.folderPrefix + name
                }
                // A message sits in one folder: two named is none.
                guard folders == nil else { return nil }
                folders = [label.lowercased()]
                if label == "TRASH" || label == "SPAM" { anywhere = true }
            default:
                guard let more = pieces(term) else { return nil }
                tokens += more
            }
        }
        return Asked(pieces: Self.spaced(tokens), folders: folders, anywhere: anywhere)
    }

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy"
        return f
    }()

    private func day(_ date: Date) -> String { Self.format.string(from: date) }

    func pieces(_ term: MailQuery.Term) -> [IMAPClient.Arg]? {
        switch term {
        case .text(let words, .all, _): return [.raw("TEXT"), .quoted(words)]
        case .text(let words, .subject, _): return [.raw("SUBJECT"), .quoted(words)]
        case .person(let field, let who):
            let name = who.lowercased() == "me" ? me : who
            return [.raw(field.rawValue.uppercased()), .quoted(name)]
        case .flag(let flag):
            switch flag.lowercased() {
            case "unread": return [.raw("UNSEEN")]
            case "read": return [.raw("SEEN")]
            case "starred": return [.raw("FLAGGED")]
            default: return nil
            }
        case .after(let date): return [.raw("SINCE"), .raw(day(date))]
        case .before(let date): return [.raw("BEFORE"), .raw(day(date))]
        case .newer(let count, let unit):
            guard let date = Calendar.current.date(byAdding: unit, value: -count, to: Date()) else { return nil }
            return [.raw("SINCE"), .raw(day(date))]
        case .older(let count, let unit):
            guard let date = Calendar.current.date(byAdding: unit, value: -count, to: Date()) else { return nil }
            return [.raw("BEFORE"), .raw(day(date))]
        case .not(let inner):
            guard let more = pieces(inner) else { return nil }
            return [.raw("NOT"), .raw("(")] + more + [.raw(")")]
        case .all(let terms):
            var out: [IMAPClient.Arg] = [.raw("(")]
            for one in terms {
                guard let more = pieces(one) else { return nil }
                out += more
            }
            return out + [.raw(")")]
        case .any(let terms):
            guard let first = terms.first else { return nil }
            guard let head = pieces(first) else { return nil }
            guard terms.count > 1 else { return head }
            guard let rest = pieces(.any(Array(terms.dropFirst()))) else { return nil }
            return [.raw("OR"), .raw("(")] + head + [.raw(")"), .raw("(")] + rest + [.raw(")")]
        case .label, .has, .anywhere, .other:
            return nil
        }
    }

    /// Words with the spaces between them; none after "(" or before ")".
    static func spaced(_ tokens: [IMAPClient.Arg]) -> [IMAPClient.Arg] {
        var out: [IMAPClient.Arg] = []
        var last = ""
        for token in tokens {
            if case .raw(let word) = token {
                let gap = !out.isEmpty && last != "(" && word != ")"
                out.append(.raw((gap ? " " : "") + word))
                last = word
            } else {
                out.append(token)
                last = "\""
            }
        }
        return out
    }

    /// The pieces as one line, for tests: quoted strings in quotes.
    static func line(_ pieces: [IMAPClient.Arg]) -> String {
        var out = ""
        for piece in pieces {
            switch piece {
            case .raw(let words): out += words
            case .quoted(let text): out += (out.isEmpty || out.hasSuffix(" ") || out.hasSuffix("(") ? "" : " ") + "\"" + text + "\""
            case .literal(let data): out += "{\(data.count)}"
            }
        }
        return out
    }
}
