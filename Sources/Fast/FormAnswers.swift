import Foundation

// What you answered, question by question: "What are you working on?" on
// one Luma event is the same question on the next, and every event is on
// lu.ma. Kept on their own, with nothing asked: a form sent with a person's
// own press keeps its new answers once the page shows it went through.
// Never from a private tab, never a box of money, a bank account, an id or
// a secret (FormRules.forbidden), a card's or the address's. The morning
// look goes over what came in since (`form_answers`) and drops what was
// written for that one form; until it has, a long answer isn't filled.
//
// Plain JSON in the browser's own folder, beside the profile. A question
// is known by its words made plain: lower case, no punctuation, no "*" or
// "(optional)", so "What are you working on? *" and "what are you working
// on" are one.

enum FormAnswers {
    struct Said: Codable, Equatable {
        var question: String
        var answer: String
        var site: String
        var at: Date
        /// Kept on its own and not looked over yet. Nil once the look kept
        /// it, and for answers kept before (a person ticked those).
        var fresh: Bool? = nil

        /// Short and steady, for an agent to name it by.
        var id: String {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in (site + "|" + question).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return String(String(hash, radix: 16).prefix(8))
        }

        /// Whether a form may be filled with it: a long one kept on its own
        /// reads as written for that one form until the look keeps it.
        var usable: Bool { fresh != true || answer.count <= FormAnswers.oneOff }
    }

    /// Every answer kept, newest last.
    struct Book: Equatable {
        var said: [Said] = []

        /// The newest answer to this question on this site, a line long at
        /// most. Never from another site, and never a longer one: a brief
        /// written for one freelancer went into the form for the next, and a
        /// "Message" to a bank is nobody else's. A longer answer is still
        /// kept, for the person or an agent to read (`form_answers`).
        func answer(to label: String, site: String) -> String? {
            let q = FormAnswers.normal(label)
            guard q.count >= 3 else { return nil }
            return said.last { $0.question == q && $0.site == site && $0.usable && $0.answer.count <= FormAnswers.line }?.answer
        }

        /// Questions kept, for the Mac's model to match a new one against.
        var questions: [String] { Array(Set(said.filter(\.usable).map(\.question))).sorted() }
    }

    static var file: URL { Store.file("answers.json") }
    /// The longest answer that goes into a box again: a line. Longer reads
    /// as written for that one form.
    static let line = 140
    /// Past this many, the oldest go.
    static let limit = 400

    nonisolated(unsafe) private static var cached: (Book, Date?)?

    static func load() -> Book {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let cached, cached.1 == stamp { return cached.0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let said = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([Said].self, from: $0) } ?? []
        let book = Book(said: said)
        cached = (book, stamp)
        return book
    }

    static func save(_ book: Book) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(book.said.suffix(limit))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        cached = nil
    }

    /// Answers a sent form held, kept over the ones before for the same
    /// question on the same site. Fresh: kept on their own, for the
    /// morning look to go over.
    static func keep(_ pairs: [(question: String, answer: String)], site: String, fresh: Bool = false) {
        var book = load()
        var changed = false
        for (question, answer) in pairs {
            let q = normal(question), a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 3, !a.isEmpty, a.count <= 4000 else { continue }
            book.said.removeAll { $0.question == q && $0.site == site }
            book.said.append(Said(question: q, answer: a, site: site, at: Date(), fresh: fresh ? true : nil))
            changed = true
        }
        if changed { save(book) }
    }

    /// Kept on their own and not looked over yet, oldest first.
    static func unchecked() -> [Said] { load().said.filter { $0.fresh == true } }

    /// The morning look's word on fresh answers: those in drop go, those in
    /// keep stay for good. Says how many of each it found.
    @discardableResult
    static func review(drop: Set<String>, keep: Set<String>) -> (dropped: Int, kept: Int) {
        var book = load()
        let before = book.said.count
        book.said.removeAll { drop.contains($0.id) }
        var kept = 0
        for n in book.said.indices where book.said[n].fresh == true && keep.contains(book.said[n].id) {
            book.said[n].fresh = nil
            kept += 1
        }
        let dropped = before - book.said.count
        if dropped + kept > 0 { save(book) }
        return (dropped, kept)
    }

    /// Longer than this, an answer reads as written for that one form: kept
    /// on its own, it isn't filled until the look keeps it.
    static let oneOff = 140

    /// An answer a sent form held that isn't kept yet, or is kept with
    /// other words.
    struct Fresh: Equatable, Identifiable {
        /// The question's plain words.
        var question: String
        /// As the page put it.
        var label: String
        var answer: String
        var id: String { question }
    }

    /// What of a sent form is worth keeping: not the address's
    /// boxes or a card's (the Wallet asks about those), not money, a bank
    /// account, an id or a secret, not what the profile already says, and
    /// not an answer given here before in the same words. One per
    /// question, the last box's.
    static func fresh(_ sent: [(field: FormField, answer: String)], book: Book, profile: Profile, site: String) -> [Fresh] {
        var out: [Fresh] = []
        for (field, raw) in sent {
            let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let q = normal(field.label)
            guard q.count >= 3, !a.isEmpty, a.count <= 4000 else { continue }
            if field.type == "password" || field.type == "hidden" || field.type == "checkbox" || field.type == "file" { continue }
            if FormRules.walletKinds.contains(field.kind) || FormRules.forbidden(field) != nil { continue }
            if book.answer(to: field.label, site: site) == a { continue }
            // What the profile would put in this box is the profile's.
            var empty = field
            empty.empty = true
            let step = FormRules.step(empty, profile: profile, answers: Book(), site: site, hasAddress: false, known: [:])
            if case .profile = step.source, step.value == a { continue }
            if case .yours(let why) = step.source, why != "none", why != "choice", why != "words" { continue }
            out.removeAll { $0.question == q }
            out.append(Fresh(question: q, label: field.label, answer: a))
        }
        return out
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
        cached = nil
    }

    /// A question's words made plain.
    static func normal(_ text: String) -> String {
        var t = text.lowercased()
        for noise in ["(optional)", "(required)", "optional", "required"] {
            t = t.replacingOccurrences(of: noise, with: " ")
        }
        let kept = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
