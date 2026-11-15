import Accelerate
import Foundation
import SQLite3

// The mail memory (docs/mail.md, Memory for agents): five years of an
// account's mail as text on this Mac, for agents to search by what it says
// as well as by its words. A file of its own beside the account's store,
// which stays small and quick.
//
// Each mail's own words go in, what it quotes of earlier mail and its
// signature cut, in pieces of about 800 characters that overlap by 100,
// each knowing its thread, mail, date, sender and subject. Over the pieces,
// a word index (FTS5, BM25) and a vector of each (MailEmbed), kept as
// bytes. A question goes to both: its words to the index, its vector
// against every piece's at once (Accelerate, the bytes turned to numbers a
// block at a time), the best 200 of each; the two lists are fused by rank
// (reciprocal rank fusion), and the best pieces come out.
//
// Cyrillic pieces have no vector: they go by their words (MailLemmas), in
// an index of their own, and every word of theirs has a vector of its own,
// read alone. A Cyrillic question goes to that index
// with its words counted twice and, once, the memory's words nearest each
// of them (the five nearest at a cosine of 0.3 or more, the direction all
// the memory's words share taken away), the best by BM25 coming out.
//
// One serial queue owns the file, as MailStore's does. A model's vectors
// are read into memory at the first question, 128 MB for 250,000 pieces,
// and let go a few minutes after the last.

/// A piece of a mail the memory found for a question.
public struct MailMemoryHit: Equatable {
    var chunk: Int64
    public var mail: String
    public var thread: String
    public var at: Date
    public var sender: String
    public var recipients: String
    public var subject: String
    public var start: Int
    public var text: String
    public var score: Double
}

/// How far along a memory is.
public struct MailMemoryProgress: Equatable {
    /// Mails in it, and about how many the last five years hold: 0 until
    /// Gmail's list has said.
    public var mails = 0
    public var about = 0
    public var chunks = 0
    public var vectors = 0
    /// Cyrillic pieces in the index of words, and the words with a vector of their own.
    public var lemmatized = 0
    public var words = 0
    /// Listed in Gmail, not yet read.
    public var waiting = 0
    /// Gmail's list has been read to its end.
    public var listed = false
    public var bytes: Int64 = 0

    public var built: Bool { listed && waiting == 0 }

    public static func + (a: MailMemoryProgress, b: MailMemoryProgress) -> MailMemoryProgress {
        MailMemoryProgress(mails: a.mails + b.mails, about: a.about == 0 || b.about == 0 ? 0 : a.about + b.about, chunks: a.chunks + b.chunks,
                           vectors: a.vectors + b.vectors, lemmatized: a.lemmatized + b.lemmatized, words: a.words + b.words,
                           waiting: a.waiting + b.waiting, listed: a.listed && b.listed, bytes: a.bytes + b.bytes)
    }

    public init(mails: Int = 0, about: Int = 0, chunks: Int = 0, vectors: Int = 0, lemmatized: Int = 0, words: Int = 0,
                waiting: Int = 0, listed: Bool = false, bytes: Int64 = 0) {
        self.mails = mails
        self.about = about
        self.chunks = chunks
        self.vectors = vectors
        self.lemmatized = lemmatized
        self.words = words
        self.waiting = waiting
        self.listed = listed
        self.bytes = bytes
    }
}

public final class MailMemory: @unchecked Sendable {
    public let file: URL
    private let queue: DispatchQueue
    private var connection: SQLiteConnection?
    private var db: OpaquePointer? { connection?.handle }
    /// How far back it reaches.
    static let years = 5
    public static let size = 800, overlap = 100
    /// Most of a mail's own words kept: a long newsletter's tail adds nothing.
    public static let most = 12_000
    /// How many each search hands to the fusion, and RRF's k.
    public static let depth = 200
    public static let k = 60.0
    /// Changes to the file's shape, in order, each applied once: a memory
    /// costs a day of Gmail's quota, so it is never thrown away for a new
    /// column.
    static let migrations: [(Int, String)] = [
        // Cyrillic goes by its words from October 2026: its vectors of the
        // contextual model go, and its pieces are read again by the build.
        (1, """
        DELETE FROM vectors WHERE model LIKE 'Cyrl.%';
        INSERT OR IGNORE INTO todo(id, at) SELECT id, at FROM chunks WHERE id NOT IN (SELECT id FROM vectors);
        UPDATE todo SET blocked = '' WHERE blocked = 'Cyrl';
        """),
    ]
    /// How many of the memory's own words a question's word brings, and
    /// how near they must be.
    public static let nearMost = 5
    public static let near: Float = 0.3

    /// The vectors of each model, while questions are being asked.
    private var vectors: [String: MailVectors] = [:]
    /// The models there are vectors of, once asked.
    private var modelNames: Set<String>?
    private var asked = Date.distantPast
    /// The words Cyrillic pieces are read by, with their vectors read alone,
    /// while questions are being asked: the direction they all share taken
    /// away from each.
    private var lexicon: MailLexicon?

    public init(file: URL) {
        self.file = file
        queue = DispatchQueue(label: "yab.mail.memory.\(file.lastPathComponent)", qos: .utility)
        queue.async { self.open() }
    }

    /// Where an account's memory lives: beside its store.
    public static func file(for account: String) -> URL {
        let store = MailStore.file(for: account)
        return store.deletingLastPathComponent()
            .appendingPathComponent(store.deletingPathExtension().lastPathComponent + ".memory.sqlite")
    }

    /// The memory and its journal, gone.
    public static func delete(_ file: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
    }

    /// Closed: nothing more is read or written.
    public func close() {
        queue.sync {
            connection = nil
            vectors = [:]
            lexicon = nil
        }
    }

    private func open() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = SQLiteConnection(path: file.path, busyTimeout: 0, name: "mail memory", log: MailGmail.log)
        guard connection != nil else { return }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS mails(id TEXT PRIMARY KEY, thread TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS mails_at ON mails(at);
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY, mail TEXT NOT NULL, thread TEXT NOT NULL, at REAL NOT NULL, sender TEXT NOT NULL,
          recipients TEXT NOT NULL, subject TEXT NOT NULL, start INTEGER NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS chunks_mail ON chunks(mail);
        CREATE INDEX IF NOT EXISTS chunks_thread ON chunks(thread);
        CREATE TABLE IF NOT EXISTS vectors(id INTEGER PRIMARY KEY, model TEXT NOT NULL, at REAL NOT NULL, scale REAL NOT NULL, v BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS vectors_model ON vectors(model);
        CREATE TABLE IF NOT EXISTS todo(id INTEGER PRIMARY KEY, at REAL NOT NULL, blocked TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS todo_at ON todo(blocked, at);
        CREATE TABLE IF NOT EXISTS waiting(id TEXT PRIMARY KEY, n INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS waiting_n ON waiting(n);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(subject, sender, text, content='chunks', content_rowid='id',
          tokenize='porter unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS lemmatized(id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS vocabulary(word TEXT PRIMARY KEY, model TEXT NOT NULL DEFAULT '', scale REAL NOT NULL DEFAULT 0, v BLOB);
        """)
        // Cyrillic pieces by their words, the words alone kept (SQLite 3.43,
        // macOS 14); an older SQLite keeps their text too.
        if sqlite3_exec(db, "CREATE VIRTUAL TABLE IF NOT EXISTS lemmas USING fts5(text, content='', contentless_delete=1)", nil, nil, nil) != SQLITE_OK {
            exec("CREATE VIRTUAL TABLE IF NOT EXISTS lemmas USING fts5(text)")
        }
        var schema = Int(meta("schema") ?? "") ?? 0
        for (number, migration) in Self.migrations where number > schema {
            exec("BEGIN")
            guard exec(migration) else { exec("ROLLBACK"); break }
            setMeta("schema", String(number))
            exec("COMMIT")
            schema = number
        }
    }

    // MARK: - meta

    public func value(_ key: String) -> String? { queue.sync { meta(key) } }
    public func set(_ key: String, _ value: String?) {
        queue.sync { if let value { setMeta(key, value) } else { run("DELETE FROM meta WHERE k = ?", [key]) } }
    }

    // MARK: - mails in and out

    /// The earliest a mail may be and still be kept.
    public static func since(_ now: Date = Date()) -> Date { now.addingTimeInterval(-Double(years) * 365.25 * 86_400) }

    /// Mails as the memory keeps them: their own words in pieces. A mail
    /// already here, without its body, in Spam or Trash, or older than five
    /// years stays out. Answers how many came in.
    @discardableResult
    public func keep(_ messages: [MailMessage], now: Date = Date()) -> Int {
        let fresh = Self.keepable(messages, now: now)
        guard !fresh.isEmpty else { return 0 }
        return queue.sync { put(fresh) }
    }

    /// Kept later, off the caller's way: the sync hands over what it stored.
    public func later(_ messages: [MailMessage]) {
        let fresh = Self.keepable(messages, now: Date())
        guard !fresh.isEmpty else { return }
        queue.async { [weak self] in _ = self?.put(fresh) }
    }

    /// Mails gone from Gmail, or put in Spam or Trash there: gone from here.
    public func later(forget ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in self?.drop(ids) }
    }

    public func forget(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync { drop(ids) }
    }

    private static func keepable(_ messages: [MailMessage], now: Date) -> [MailMessage] {
        let since = since(now)
        return messages.filter { $0.text != nil && $0.date >= since && $0.labels.isDisjoint(with: ["SPAM", "TRASH"]) }
    }

    /// On the queue.
    private func put(_ fresh: [MailMessage]) -> Int {
        guard db != nil else { return 0 }
        exec("BEGIN")
        var added = 0
        for message in fresh where int("SELECT count(*) FROM mails WHERE id = ?", [message.id]) == 0 {
            let at = message.date.timeIntervalSince1970
            run("INSERT INTO mails(id, thread, at) VALUES(?,?,?)", [message.id, message.thread, at])
            let sender = message.from.header
            let recipients = (message.to + message.cc).prefix(6).map(\.header).joined(separator: ", ")
            var pieces = Self.pieces(Self.own(message.text ?? ""))
            // Nothing of its own (a forward, a file): its subject still says what it is.
            if pieces.isEmpty { pieces = [(0, "")] }
            for piece in pieces {
                run("""
                INSERT INTO chunks(mail, thread, at, sender, recipients, subject, start, text) VALUES(?,?,?,?,?,?,?,?)
                """, [message.id, message.thread, at, sender, recipients, message.subject, piece.start, piece.text])
                let id = sqlite3_last_insert_rowid(db)
                run("INSERT INTO words(rowid, subject, sender, text) VALUES(?,?,?,?)", [id, message.subject, sender, piece.text])
                // Cyrillic goes by its words, the rest waits for a vector.
                let said = Todo(id: id, subject: message.subject, text: piece.text).said
                if MailLemmas.reads(said) { index(id, said) } else { run("INSERT INTO todo(id, at) VALUES(?,?)", [id, at]) }
            }
            added += 1
        }
        exec("COMMIT")
        return added
    }

    /// On the queue.
    private func drop(_ ids: [String]) {
        guard db != nil else { return }
        exec("BEGIN")
        var gone = false
        for id in ids {
            for row in query("SELECT id, subject, sender, text FROM chunks WHERE mail = ?", [id]) {
                guard let chunk = row[0] as? Int64 else { continue }
                run("INSERT INTO words(words, rowid, subject, sender, text) VALUES('delete', ?, ?, ?, ?)",
                    [chunk, row[1] as? String ?? "", row[2] as? String ?? "", row[3] as? String ?? ""])
                run("DELETE FROM vectors WHERE id = ?", [chunk])
                run("DELETE FROM todo WHERE id = ?", [chunk])
                if int("SELECT count(*) FROM lemmatized WHERE id = ?", [chunk]) == 1 {
                    run("DELETE FROM lemmas WHERE rowid = ?", [chunk])
                    run("DELETE FROM lemmatized WHERE id = ?", [chunk])
                }
                gone = true
            }
            run("DELETE FROM chunks WHERE mail = ?", [id])
            run("DELETE FROM mails WHERE id = ?", [id])
            run("DELETE FROM waiting WHERE id = ?", [id])
        }
        exec("COMMIT")
        // Read again at the next question.
        if gone { vectors = [:] }
    }

    /// Mail older than five years, gone as the years pass.
    public func prune(now: Date = Date()) {
        let old = queue.sync { strings("SELECT id FROM mails WHERE at < ?", [Self.since(now).timeIntervalSince1970]) }
        forget(old)
    }

    /// Which of these mails are here.
    public func known(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            var out = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 500) {
                let part = Array(ids[start..<min(ids.count, start + 500)])
                let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
                out.formUnion(strings("SELECT id FROM mails WHERE id IN (\(marks))", part))
            }
            return out
        }
    }

    // MARK: - mail listed in Gmail, not yet read

    /// Ids listed, in Gmail's order, to be read one by one; mail already
    /// here or already waiting is left out.
    public func wait(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let here = known(ids)
        queue.sync {
            exec("BEGIN")
            var n = int("SELECT coalesce(max(n), 0) FROM waiting", []) ?? 0
            for id in ids where !here.contains(id) {
                n += 1
                run("INSERT OR IGNORE INTO waiting(id, n) VALUES(?,?)", [id, n])
            }
            exec("COMMIT")
        }
    }

    public func waiting(_ limit: Int) -> [String] { queue.sync { strings("SELECT id FROM waiting ORDER BY n LIMIT ?", [limit]) } }

    public func waited(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for id in ids { run("DELETE FROM waiting WHERE id = ?", [id]) }
            exec("COMMIT")
        }
    }

    // MARK: - vectors

    public struct Todo: Equatable {
        public var id: Int64
        public var subject: String
        public var text: String
        /// What a vector is made of: the subject, then the piece.
        public var said: String { subject.isEmpty ? text : subject + "\n" + text }
    }

    /// Pieces still without a vector, newest first, but those whose script
    /// had no model when last tried.
    public func todo(_ limit: Int) -> [Todo] {
        queue.sync {
            query("""
            SELECT t.id, c.subject, c.text FROM todo t JOIN chunks c ON c.id = t.id
            WHERE t.blocked = '' ORDER BY t.at DESC LIMIT ?
            """, [limit]).compactMap { row in
                guard let id = row[0] as? Int64 else { return nil }
                return Todo(id: id, subject: row[1] as? String ?? "", text: row[2] as? String ?? "")
            }
        }
    }

    /// Pieces no model of this Mac can read yet, by the kind they wait for.
    public func block(_ ids: [Int64], kind: String) {
        guard !ids.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for id in ids { run("UPDATE todo SET blocked = ? WHERE id = ?", [kind, id]) }
            exec("COMMIT")
        }
    }

    /// Pieces of a kind that now has a model, tried again.
    public func unblock(kind: String) { queue.sync { run("UPDATE todo SET blocked = '' WHERE blocked = ?", [kind]) } }

    public func blockedKinds() -> [String] { queue.sync { strings("SELECT DISTINCT blocked FROM todo WHERE blocked != ''", []) } }

    /// Vectors made, kept as bytes.
    public func keep(vectors made: [(chunk: Int64, model: String, vector: [Float])]) {
        guard !made.isEmpty else { return }
        queue.sync {
            guard db != nil else { return }
            exec("BEGIN")
            for item in made {
                guard let at = double("SELECT at FROM chunks WHERE id = ?", [item.chunk]) else { continue }
                let (scale, bytes) = MailVector.quantize(item.vector)
                run("INSERT OR REPLACE INTO vectors(id, model, at, scale, v) VALUES(?,?,?,?,?)",
                    [item.chunk, item.model, at, Double(scale), bytes.withUnsafeBufferPointer { Data(buffer: $0) }])
                run("DELETE FROM todo WHERE id = ?", [item.chunk])
                vectors[item.model]?.add(id: item.chunk, at: at, scale: scale, bytes: bytes)
                if modelNames?.contains(item.model) == false { modelNames = nil }
            }
            exec("COMMIT")
        }
    }

    /// The models vectors were made with.
    public func models() -> Set<String> {
        queue.sync {
            if let modelNames { return modelNames }
            let found = Set(strings("SELECT DISTINCT model FROM vectors", []))
            modelNames = found
            return found
        }
    }

    /// A model's vectors, dropped: this Mac reads that script another way
    /// now. Its pieces go back to wait for new ones.
    public func drop(model: String) {
        queue.sync {
            exec("BEGIN")
            run("INSERT OR IGNORE INTO todo(id, at) SELECT id, at FROM vectors WHERE model = ?", [model])
            run("DELETE FROM vectors WHERE model = ?", [model])
            exec("COMMIT")
            vectors[model] = nil
            modelNames = nil
        }
    }

    // MARK: - Cyrillic, by its words

    /// A Cyrillic piece into the index of words, and its words into the
    /// vocabulary, to get a vector of their own. On the queue.
    private func index(_ id: Int64, _ said: String) {
        let words = MailLemmas.read(said)
        run("INSERT INTO lemmas(rowid, text) VALUES(?, ?)", [id, words.joined(separator: " ")])
        run("INSERT OR IGNORE INTO lemmatized(id) VALUES(?)", [id])
        for word in Set(words.filter(MailLemmas.known)) { run("INSERT OR IGNORE INTO vocabulary(word) VALUES(?)", [word]) }
    }

    /// Cyrillic pieces kept before Cyrillic went by its words, read so now.
    public func lemmatize(_ pieces: [Todo]) {
        guard !pieces.isEmpty else { return }
        queue.sync {
            guard db != nil else { return }
            exec("BEGIN")
            for piece in pieces {
                if int("SELECT count(*) FROM lemmatized WHERE id = ?", [piece.id]) == 0 { index(piece.id, piece.said) }
                run("DELETE FROM todo WHERE id = ?", [piece.id])
            }
            exec("COMMIT")
        }
    }

    /// Words of the vocabulary without a vector of this model yet.
    public func unread(words limit: Int, model: String) -> [String] {
        queue.sync { strings("SELECT word FROM vocabulary WHERE model != ? LIMIT ?", [model, limit]) }
    }

    /// Words' own vectors made, as bytes; a word none could be made for is
    /// kept without one, not asked again of this model.
    public func keep(words made: [(word: String, vector: [Float]?)], model: String) {
        guard !made.isEmpty else { return }
        queue.sync {
            guard db != nil else { return }
            exec("BEGIN")
            for item in made {
                if let vector = item.vector {
                    let (scale, bytes) = MailVector.quantize(vector)
                    run("UPDATE vocabulary SET model = ?, scale = ?, v = ? WHERE word = ?",
                        [model, Double(scale), bytes.withUnsafeBufferPointer { Data(buffer: $0) }, item.word])
                } else {
                    run("UPDATE vocabulary SET model = ?, scale = 0, v = NULL WHERE word = ?", [model, item.word])
                }
            }
            exec("COMMIT")
            lexicon = nil
        }
    }

    /// The memory's words nearest each of a question's, by their vectors
    /// read alone: at most `most` for each, at a cosine of `floor` or more,
    /// none of `besides`, nearest first.
    public func nearest(_ vectors: [[Float]], model: String, most: Int = nearMost, floor: Float = near,
                 besides: Set<String> = []) -> [String] {
        queue.sync {
            guard db != nil, let lexicon = loadedWords(model) else { return [] }
            asked = Date()
            var out: [String] = []
            for vector in vectors where vector.count == lexicon.vectors.width {
                let scores = lexicon.vectors.scores(lexicon.centered(vector))
                var taken = 0
                for index in MailVectors.top(scores, most + besides.count, keep: { scores[$0] >= floor }) {
                    let word = lexicon.words[index]
                    guard taken < most, !besides.contains(word) else { continue }
                    taken += 1
                    if !out.contains(word) { out.append(word) }
                }
            }
            release()
            return out
        }
    }

    /// The vocabulary's vectors of a model, read in once, centered.
    private func loadedWords(_ model: String) -> MailLexicon? {
        if let lexicon, lexicon.model == model { return lexicon }
        var words: [String] = [], rows: [(scale: Float, bytes: [Int8])] = []
        guard let statement = prepare("SELECT word, scale, v FROM vocabulary WHERE model = ? AND v IS NOT NULL", [model]) else { return nil }
        while sqlite3_step(statement) == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 0, let blob = sqlite3_column_blob(statement, 2), let text = sqlite3_column_text(statement, 0) else { continue }
            words.append(String(cString: text))
            rows.append((Float(sqlite3_column_double(statement, 1)), Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Int8.self), count: length))))
        }
        sqlite3_finalize(statement)
        guard let width = rows.first?.bytes.count else { return nil }
        let kept = zip(words, rows).filter { $0.1.bytes.count == width }
        lexicon = MailLexicon(model: model, words: kept.map(\.0), rows: kept.map(\.1), width: width)
        return lexicon
    }

    // MARK: - asking

    /// The pieces that answer a question best: its words by BM25, its
    /// vector against every piece's, the two lists fused by rank; or, for
    /// a Cyrillic question, `terms`, its words and the ones nearest them,
    /// each counted `weight` times, in the index of Cyrillic pieces' words.
    /// `from`: a name or an address in the sender; `after`, `before`: dates.
    public func recall(_ question: String, vector: (model: String, values: [Float])? = nil,
                terms: [(word: String, weight: Int)]? = nil, from: String? = nil,
                after: Date? = nil, before: Date? = nil, limit: Int = 20) -> [MailMemoryHit] {
        queue.sync {
            guard db != nil else { return [] }
            asked = Date()
            let low = (after ?? .distantPast).timeIntervalSince1970, high = (before ?? .distantFuture).timeIntervalSince1970
            let sender = from.flatMap(Self.sender)
            if from != nil, sender == nil { return [] }
            var lists: [[Int64]] = []
            if let terms {
                guard let words = Self.match(terms) else { return [] }
                let filter = sender.map { _ in " AND c.id IN (SELECT rowid FROM words WHERE words MATCH ?)" } ?? ""
                lists.append(int64s("""
                SELECT c.id FROM lemmas JOIN chunks c ON c.id = lemmas.rowid
                WHERE lemmas MATCH ? AND c.at >= ? AND c.at < ?\(filter)
                ORDER BY bm25(lemmas) LIMIT ?
                """, [words, low, high] + (sender.map { [$0] } ?? []) + [Self.depth]))
            } else if let words = Self.match(question) {
                let match = sender.map { "(\(words)) AND \($0)" } ?? words
                lists.append(int64s("""
                SELECT c.id FROM words JOIN chunks c ON c.id = words.rowid
                WHERE words MATCH ? AND c.at >= ? AND c.at < ?
                ORDER BY bm25(words, 2.0, 1.0, 1.0) LIMIT ?
                """, [match, low, high, Self.depth]))
            }
            if let vector, let kept = loaded(vector.model) {
                let allowed = sender.map { Set(int64s("SELECT rowid FROM words WHERE words MATCH ?", [$0])) }
                lists.append(kept.nearest(vector.values, depth: Self.depth) { at, id in
                    at >= low && at < high && (allowed?.contains(id) ?? true)
                })
            }
            let best = Self.fuse(lists).prefix(max(1, limit))
            release()
            return best.compactMap { id, score in
                query("SELECT id, mail, thread, at, sender, recipients, subject, start, text FROM chunks WHERE id = ?", [id]).first.map { row in
                    MailMemoryHit(chunk: id, mail: row[1] as? String ?? "", thread: row[2] as? String ?? "",
                                  at: Date(timeIntervalSince1970: row[3] as? Double ?? 0), sender: row[4] as? String ?? "",
                                  recipients: row[5] as? String ?? "", subject: row[6] as? String ?? "",
                                  start: Int(row[7] as? Int64 ?? 0), text: row[8] as? String ?? "", score: score)
                }
            }
        }
    }

    /// A question made ready for the memories: in Cyrillic, its words and
    /// each one's vector read alone.
    public struct Question {
        public let text: String
        public let cyrillic: Bool
        public var words: [String] = []
        public var alone: (model: String, vectors: [[Float]])?
    }

    public static func question(_ text: String, embedder: MailEmbedder?) -> Question {
        guard MailLemmas.reads(text) else { return Question(text: text, cyrillic: false) }
        var question = Question(text: text, cyrillic: true, words: MailLemmas.question(text))
        if let embedder, let model = embedder.wordModel() {
            let vectors = question.words.filter(MailLemmas.known).compactMap { embedder.word($0) }.filter { $0.model == model }
            question.alone = (model, vectors.map(\.vector))
        }
        return question
    }

    /// mail_recall's search of this memory: a Cyrillic question by its
    /// words counted twice and the memory's words nearest them once; any
    /// other by its words and its vector, in the model of its language
    /// among the memory's.
    public func ask(_ question: Question, embedder: MailEmbedder?, from: String? = nil, after: Date? = nil, before: Date? = nil,
             limit: Int = 20) -> [MailMemoryHit] {
        if question.cyrillic {
            guard !question.words.isEmpty else { return [] }
            var terms = question.words.map { (word: $0, weight: 2) }
            if let alone = question.alone, !alone.vectors.isEmpty {
                terms += nearest(alone.vectors, model: alone.model, besides: Set(question.words)).map { (word: $0, weight: 1) }
            }
            return recall(question.text, terms: terms, from: from, after: after, before: before, limit: limit)
        }
        var vector: (model: String, values: [Float])?
        let kinds = Set(models().map(MailVector.kind(of:)))
        if let embedder, !kinds.isEmpty, let model = embedder.model(for: question.text, among: kinds).name,
           let values = embedder.vector(question.text, model: model) {
            vector = (model, values)
        }
        return recall(question.text, vector: vector, from: from, after: after, before: before, limit: limit)
    }

    /// Lists of the same pieces ranked different ways, as one: each piece
    /// scores 1/(k + its rank) in every list it is in.
    static func fuse(_ lists: [[Int64]], k: Double = k) -> [(id: Int64, score: Double)] {
        var score: [Int64: Double] = [:]
        var first: [Int64: Int] = [:]
        var order = 0
        for list in lists {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1 / (k + Double(rank + 1))
                if first[id] == nil { first[id] = order }
                order += 1
            }
        }
        return score.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : first[$0.0, default: 0] < first[$1.0, default: 0] }
    }

    /// A thread's mails as the memory has their words, oldest first: what
    /// mail_read answers for an old thread when Gmail can't be reached.
    public func thread(_ id: String) -> [(mail: String, at: Date, sender: String, recipients: String, subject: String, text: String)] {
        queue.sync {
            var mails: [String: (at: Date, sender: String, recipients: String, subject: String, pieces: [(Int, String)])] = [:]
            for row in query("SELECT mail, at, sender, recipients, subject, start, text FROM chunks WHERE thread = ? ORDER BY at, start", [id]) {
                guard let mail = row[0] as? String else { continue }
                var entry = mails[mail] ?? (Date(timeIntervalSince1970: row[1] as? Double ?? 0), row[2] as? String ?? "",
                                            row[3] as? String ?? "", row[4] as? String ?? "", [])
                entry.pieces.append((Int(row[5] as? Int64 ?? 0), row[6] as? String ?? ""))
                mails[mail] = entry
            }
            return mails.map { ($0.key, $0.value.at, $0.value.sender, $0.value.recipients, $0.value.subject, Self.whole($0.value.pieces)) }
                .sorted { $0.1 < $1.1 }
        }
    }

    public func progress() -> MailMemoryProgress {
        var out = queue.sync { () -> MailMemoryProgress in
            var progress = MailMemoryProgress()
            guard db != nil else { return progress }
            progress.mails = Int(int("SELECT count(*) FROM mails", []) ?? 0)
            progress.chunks = Int(int("SELECT count(*) FROM chunks", []) ?? 0)
            progress.vectors = Int(int("SELECT count(*) FROM vectors", []) ?? 0)
            progress.lemmatized = Int(int("SELECT count(*) FROM lemmatized", []) ?? 0)
            progress.words = Int(int("SELECT count(*) FROM vocabulary WHERE v IS NOT NULL", []) ?? 0)
            progress.waiting = Int(int("SELECT count(*) FROM waiting", []) ?? 0)
            progress.listed = meta("listed") == "done"
            let estimate = Int(meta("estimate") ?? "") ?? 0
            progress.about = progress.listed ? progress.mails + progress.waiting
                : estimate > 0 ? max(estimate, progress.mails + progress.waiting) : 0
            return progress
        }
        out.bytes = ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            sum + ((try? FileManager.default.attributesOfItem(atPath: file.path + suffix)[.size] as? Int64) ?? 0)
        }
        return out
    }

    // MARK: - the vectors in memory

    private func loaded(_ model: String) -> MailVectors? {
        if let kept = vectors[model] { return kept }
        guard db != nil, let statement = prepare("SELECT id, at, scale, v FROM vectors WHERE model = ?", [model]) else { return nil }
        defer { sqlite3_finalize(statement) }
        let count = Int(int("SELECT count(*) FROM vectors WHERE model = ?", [model]) ?? 0)
        var kept: MailVectors?
        while sqlite3_step(statement) == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(statement, 3))
            guard length > 0, let blob = sqlite3_column_blob(statement, 3) else { continue }
            if kept == nil { kept = MailVectors(width: length, capacity: count) }
            guard let kept, kept.width == length else { continue }
            kept.add(id: sqlite3_column_int64(statement, 0), at: sqlite3_column_double(statement, 1),
                     scale: Float(sqlite3_column_double(statement, 2)), bytes: blob.assumingMemoryBound(to: Int8.self))
        }
        vectors[model] = kept
        return kept
    }

    /// The vectors let go a few minutes after the last question.
    private func release() {
        queue.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, Date().timeIntervalSince(asked) >= 175 else { return }
            vectors = [:]
            lexicon = nil
        }
    }

    // MARK: - a mail's own words

    /// A mail's own words: where it quotes the one it answers, from there
    /// on; lines quoted in between ("> …"); its signature, after "-- ", a
    /// phone's "Sent from", or a sign-off with a few short lines under it.
    public static func own(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let quote = quoteStart(lines) { lines = Array(lines[..<quote]) }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        if let signature = signatureStart(lines) { lines = Array(lines[..<signature]) }
        var out: [String] = []
        var blank = 0
        for line in lines {
            let trimmed = line.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blank += 1
                continue
            }
            if !out.isEmpty { out.append(contentsOf: Array(repeating: "", count: min(blank, 1))) }
            blank = 0
            out.append(trimmed)
        }
        return String(out.joined(separator: "\n").prefix(most))
    }

    /// The line where the earlier mail it answers begins: "On … wrote:",
    /// in the languages mail comes in, a date and an address ending in a
    /// colon ("01.10.2026, 14:00, Anna <anna@fold.studio>:"),
    /// "-----Original Message-----", or
    /// Outlook's "From: … Sent: …". A forward's own header is kept: what
    /// was forwarded is new here.
    public static func quoteStart(_ lines: [String]) -> Int? {
        let low = lines.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let headers = ["sent:", "date:", "to:", "subject:"]
        for (n, line) in low.enumerated() {
            if line.contains("forwarded message") || line.hasPrefix("begin forwarded message") {
                return nil
            }
            let said = ["wrote:", "a écrit :", "a écrit:", "escribió:", "ha scritto:", "schreef:", "escreveu:",
                        "пише:"].contains { line.hasSuffix($0) }
            if said, line.count < 240 { return n }
            // "On Mon, Sep 1, 2025 at 10:00 AM Anna <anna@fold.studio>" with "wrote:" on the next line.
            if line.hasPrefix("on "), n + 1 < low.count, low[n + 1].hasSuffix("wrote:"), line.count < 240 { return n }
            // A date and who, the address last before a colon, with no verb;
            // on one line or two.
            if line.count < 240, dated(line) {
                if line.hasSuffix(">:") { return n }
                if n + 1 < low.count, low[n + 1].hasSuffix(">:"), low[n + 1].count < 120 { return n }
            }
            if line.hasPrefix("am "), line.contains("schrieb"), line.hasSuffix(":") { return n }
            if line.hasPrefix("---"), line.contains("original message") { return n }
            if n > 0, line.hasPrefix("from:"),
               low[(n + 1)..<min(low.count, n + 5)].contains(where: { next in headers.contains { next.hasPrefix($0) } }) {
                return n > 0 && low[n - 1].hasPrefix("____") ? n - 1 : n
            }
        }
        return nil
    }

    /// A line that says when, as a quote's header does: a year, or a time.
    private static func dated(_ line: String) -> Bool {
        line.range(of: #"\b(19|20)\d\d\b|\b\d{1,2}:\d\d\b"#, options: .regularExpression) != nil
    }

    public static let signoffs: Set<String> = [
        "best", "best regards", "regards", "kind regards", "warm regards", "warmly", "many thanks", "thanks", "thank you",
        "thanks again", "cheers", "sincerely", "yours", "yours truly", "yours sincerely", "all the best", "best wishes", "thx",
        "talk soon",
        "mit freundlichen grüßen", "viele grüße", "liebe grüße", "cordialement", "bien à vous", "saludos", "un saludo",
    ]

    public static func signatureStart(_ lines: [String]) -> Int? {
        if let dashes = lines.firstIndex(where: { $0 == "-- " || $0.trimmingCharacters(in: .whitespaces) == "--" }), dashes > 0 {
            return dashes
        }
        let devices = ["sent from my ", "sent from mail for", "get outlook for", "sent via ", "sent with ",
                       "envoyé de mon", "von meinem"]
        if let device = lines.indices.first(where: { n in
            n > 0 && lines[n].count < 60 && devices.contains { lines[n].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix($0) }
        }) { return device }
        // A sign-off near the end with no more than a name, a title and a
        // number or two under it.
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        for n in filled.suffix(8) where n > 0 {
            let line = lines[n].trimmingCharacters(in: .whitespaces).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.!:;- "))
            guard signoffs.contains(line) else { continue }
            let under = filled.filter { $0 > n }
            if under.count <= 6, under.allSatisfy({ lines[$0].count <= 80 }) { return n }
        }
        return nil
    }

    /// Pieces of about `size` characters, each beginning with the last
    /// `overlap` or so of the one before, at a word's start. A piece ends
    /// after a paragraph where one ends in its second half, else after a
    /// sentence, else between words. `start`: where it begins, in characters.
    public static func pieces(_ text: String, size: Int = size, overlap: Int = overlap) -> [(start: Int, text: String)] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var out: [(Int, String)] = []
        var start = 0
        while start < chars.count {
            if chars.count - start <= size {
                out.append((start, String(chars[start...])))
                break
            }
            let end = cut(chars, from: start + size / 2, to: start + size)
            out.append((start, String(chars[start..<end])))
            // The next begins `overlap` before this one's end, at a word's start.
            var next = max(start + 1, end - overlap)
            while next < end, !chars[next - 1].isWhitespace { next += 1 }
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            if next >= end { next = end }
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            start = next
        }
        return out
    }

    /// Where a piece between `from` and `to` ends best: after a paragraph,
    /// a sentence, then a word; at `to` when there is no space at all.
    private static func cut(_ chars: [Character], from: Int, to: Int) -> Int {
        let to = min(to, chars.count)
        var sentence: Int?, word: Int?
        var n = to
        while n > from {
            let c = chars[n - 1]
            if c == "\n", n >= 2, chars[n - 2] == "\n" { return n }
            if sentence == nil, n < chars.count, c == "." || c == "!" || c == "?" || c == "…", chars[n].isWhitespace { sentence = n }
            if sentence == nil, c == "\n" { sentence = n }
            if word == nil, c.isWhitespace { word = n }
            n -= 1
        }
        return sentence ?? word ?? to
    }

    /// Pieces put back together: each one's overlap with the one before left out.
    public static func whole(_ pieces: [(Int, String)]) -> String {
        var out = ""
        var end = 0
        for (start, text) in pieces.sorted(by: { $0.0 < $1.0 }) {
            let chars = Array(text)
            let skip = max(0, end - start)
            if skip < chars.count { out += String(chars[skip...]) }
            end = max(end, start + chars.count)
        }
        return out
    }

    // MARK: - a question's words

    /// A question's words, as the word index takes them: any of them, the
    /// ones that mean something. English ones are stemmed by the index
    /// itself (porter); others are matched as written.
    public static func match(_ question: String) -> String? {
        var terms: [String] = []
        for word in question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            guard word.count >= 2 || word.allSatisfy(\.isNumber), !MailFiller.words.contains(word) else { continue }
            let term = "\"\(word)\""
            if !terms.contains(term) { terms.append(term) }
            if terms.count == 16 { break }
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// Cyrillic words for the index of their own: each counted as many
    /// times as its weight says, as BM25 adds a word given twice twice.
    public static func match(_ terms: [(word: String, weight: Int)]) -> String? {
        let said = terms.flatMap { term -> [String] in
            let word = term.word.replacingOccurrences(of: "\"", with: "")
            return word.isEmpty ? [] : Array(repeating: "\"" + word + "\"", count: max(1, term.weight))
        }
        return said.isEmpty ? nil : said.joined(separator: " OR ")
    }

    /// A name or an address as the index finds it in a sender: every word of it.
    public static func sender(_ from: String) -> String? {
        let words = from.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return nil }
        return "sender : (" + words.prefix(6).map { "\"\($0)\"*" }.joined(separator: " AND ") + ")"
    }

    // MARK: - SQL

    private func meta(_ key: String) -> String? { string("SELECT v FROM meta WHERE k = ?", [key]) }
    private func setMeta(_ key: String, _ value: String) { run("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", [key, value]) }

    @discardableResult
    private func exec(_ statement: String) -> Bool { connection?.exec(statement) ?? false }

    /// Its own statement, for a caller that steps and finalizes it.
    private func prepare(_ statement: String, _ args: [Any]) -> OpaquePointer? { connection?.prepare(statement, args) }

    @discardableResult
    private func run(_ statement: String, _ args: [Any]) -> Bool { connection?.run(statement, args) ?? false }

    private func query(_ statement: String, _ args: [Any]) -> [SQLiteRow] { connection?.query(statement, args) ?? [] }

    private func string(_ sql: String, _ args: [Any]) -> String? { query(sql, args).first?.first as? String }
    private func int(_ sql: String, _ args: [Any]) -> Int64? { query(sql, args).first?.first as? Int64 }
    private func double(_ sql: String, _ args: [Any]) -> Double? {
        guard let value = query(sql, args).first?.first else { return nil }
        return (value as? Double) ?? (value as? Int64).map(Double.init)
    }
    private func strings(_ sql: String, _ args: [Any]) -> [String] { query(sql, args).compactMap { $0.first as? String } }
    private func int64s(_ sql: String, _ args: [Any]) -> [Int64] { query(sql, args).compactMap { $0.first as? Int64 } }

    // MARK: - the store a sync feeds

    private static let lock = NSLock()
    private static var live: [String: MailMemory] = [:]

    /// The memory the sync of a store hands its mail to, while there is one.
    public static func attached(to store: MailStore) -> MailMemory? {
        lock.lock()
        defer { lock.unlock() }
        return live[store.file.path]
    }

    public static func attach(_ memory: MailMemory?, to store: MailStore) {
        lock.lock()
        defer { lock.unlock() }
        live[store.file.path] = memory
    }
}

/// A model's vectors in memory: every piece's bytes in one run, with its
/// scale, date and id beside it, compared with a question's all at once.
public final class MailVectors {
    public let width: Int
    public private(set) var ids: [Int64] = []
    public private(set) var at: [Double] = []
    public private(set) var scale: [Float] = []
    public private(set) var bytes: [Int8] = []
    public var count: Int { ids.count }

    init(width: Int, capacity: Int = 0) {
        self.width = width
        ids.reserveCapacity(capacity)
        at.reserveCapacity(capacity)
        scale.reserveCapacity(capacity)
        bytes.reserveCapacity(capacity * width)
    }

    public func add(id: Int64, at date: Double, scale factor: Float, bytes vector: [Int8]) {
        guard vector.count == width else { return }
        ids.append(id)
        at.append(date)
        scale.append(factor)
        bytes.append(contentsOf: vector)
    }

    public func add(id: Int64, at date: Double, scale factor: Float, bytes vector: UnsafePointer<Int8>) {
        ids.append(id)
        at.append(date)
        scale.append(factor)
        bytes.append(contentsOf: UnsafeBufferPointer(start: vector, count: width))
    }

    /// Every piece's cosine with a unit vector: the bytes turned to numbers
    /// a block at a time and multiplied by it, then by each piece's scale.
    public func scores(_ query: [Float]) -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        guard n > 0, query.count == width else { return out }
        let block = 1024
        var floats = [Float](repeating: 0, count: block * width)
        bytes.withUnsafeBufferPointer { source in
            query.withUnsafeBufferPointer { q in
                floats.withUnsafeMutableBufferPointer { f in
                    out.withUnsafeMutableBufferPointer { o in
                        var start = 0
                        while start < n {
                            let rows = min(block, n - start)
                            vDSP_vflt8(source.baseAddress! + start * width, 1, f.baseAddress!, 1, vDSP_Length(rows * width))
                            vDSP_mmul(f.baseAddress!, 1, q.baseAddress!, 1, o.baseAddress! + start, 1,
                                      vDSP_Length(rows), 1, vDSP_Length(width))
                            start += rows
                        }
                    }
                }
            }
        }
        scale.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in vDSP_vmul(o.baseAddress!, 1, s.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(n)) }
        }
        return out
    }

    /// The `depth` pieces nearest a unit vector, nearest first, of those `keep` lets through.
    public func nearest(_ query: [Float], depth: Int, keep: (Double, Int64) -> Bool = { _, _ in true }) -> [Int64] {
        let scores = scores(query)
        return MailVectors.top(scores, depth) { keep(at[$0], ids[$0]) }.map { ids[$0] }
    }

    /// The indices of the `depth` highest scores, highest first, of those
    /// `keep` lets through: a heap with the weakest on top, which most
    /// scores never get past.
    public static func top(_ scores: [Float], _ depth: Int, keep: (Int) -> Bool) -> [Int] {
        guard depth > 0 else { return [] }
        var heap: [(score: Float, index: Int)] = []
        heap.reserveCapacity(depth)
        var floor = -Float.infinity
        scores.withUnsafeBufferPointer { all in
            var index = 0
            let count = all.count
            while index < count {
                let score = all[index]
                if score > floor || heap.count < depth, keep(index) {
                    if heap.count < depth {
                        heap.append((score, index))
                        var child = heap.count - 1
                        while child > 0 {
                            let parent = (child - 1) / 2
                            guard heap[child].score < heap[parent].score else { break }
                            heap.swapAt(child, parent)
                            child = parent
                        }
                    } else {
                        heap[0] = (score, index)
                        var parent = 0
                        while true {
                            let left = parent * 2 + 1, right = left + 1
                            var least = parent
                            if left < depth, heap[left].score < heap[least].score { least = left }
                            if right < depth, heap[right].score < heap[least].score { least = right }
                            if least == parent { break }
                            heap.swapAt(parent, least)
                            parent = least
                        }
                    }
                    if heap.count == depth { floor = heap[0].score }
                }
                index += 1
            }
        }
        return heap.sorted { $0.score > $1.score }.map(\.index)
    }
}

/// The words Cyrillic pieces are read by, each with its vector read alone,
/// in memory while questions are asked: the direction all of them share
/// taken away from each (they sit at a cosine of 0.5 or so to one another
/// as they come), then as bytes, compared with a question's word at once.
public final class MailLexicon {
    public let model: String
    public let words: [String]
    public let vectors: MailVectors
    let mean: [Float]

    init(model: String, words: [String], rows: [(scale: Float, bytes: [Int8])], width: Int) {
        self.model = model
        self.words = words
        var mean = [Float](repeating: 0, count: width)
        var floats = [Float](repeating: 0, count: width)
        let count = Float(max(1, rows.count))
        mean.withUnsafeMutableBufferPointer { m in
            floats.withUnsafeMutableBufferPointer { f in
                for row in rows {
                    vDSP_vflt8(row.bytes, 1, f.baseAddress!, 1, vDSP_Length(width))
                    var scale = row.scale / count
                    vDSP_vsma(f.baseAddress!, 1, &scale, m.baseAddress!, 1, m.baseAddress!, 1, vDSP_Length(width))
                }
            }
        }
        self.mean = mean
        // Each taken back to numbers, the mean taken away, then bytes
        // again, its largest at ±127 and its scale making it unit length.
        let vectors = MailVectors(width: width, capacity: rows.count)
        var bytes = [Int8](repeating: 0, count: width)
        let n = vDSP_Length(width)
        for (index, row) in rows.enumerated() {
            var factor: Float = 0
            floats.withUnsafeMutableBufferPointer { f in
                vDSP_vflt8(row.bytes, 1, f.baseAddress!, 1, n)
                var scale = row.scale
                vDSP_vsmul(f.baseAddress!, 1, &scale, f.baseAddress!, 1, n)
                vDSP_vsub(mean, 1, f.baseAddress!, 1, f.baseAddress!, 1, n)
                var squares: Float = 0, top: Float = 0
                vDSP_svesq(f.baseAddress!, 1, &squares, n)
                vDSP_maxmgv(f.baseAddress!, 1, &top, n)
                bytes.withUnsafeMutableBufferPointer { b in
                    guard squares > 0, top > 0 else { b.update(repeating: 0); return }
                    var up = 127 / top
                    vDSP_vsmul(f.baseAddress!, 1, &up, f.baseAddress!, 1, n)
                    vDSP_vfixr8(f.baseAddress!, 1, b.baseAddress!, 1, n)
                    factor = top / 127 / squares.squareRoot()
                }
            }
            vectors.add(id: Int64(index), at: 0, scale: factor, bytes: bytes)
        }
        self.vectors = vectors
    }

    /// A question's word as the words are kept: the shared direction taken away.
    public func centered(_ vector: [Float]) -> [Float] {
        guard vector.count == mean.count else { return vector }
        return MailVector.unit(zip(vector, mean).map { $0 - $1 })
    }
}
