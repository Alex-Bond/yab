import AppKit
import MailCore

// People by what they are to you, not by their name: "my lawyer's mail"
// names nobody, so the field finds the lawyer in the mail. A firm's domain
// ("goodwinlaw.com", "lisaesq.com") or a name with "Esq." says it first;
// signatures in their own mail ("Attorney at Law", "LLP") next. And words
// typed wrong ("lawers") are read as the spell checker would mend them.
// docs/field-requests.md, "Roles and typos".

@MainActor
enum FieldRoles {
    struct Role {
        /// As the field says it: "your lawyer".
        let name: String
        /// The words that ask for it, each matched by its start, so
        /// "lawyer's" and "lawyers" are said too.
        let said: [String]
        /// What an address's domain or a name holds for it.
        let marks: [String]
        /// What their own mail's words hold for it (the word index's
        /// expression).
        let signs: String
    }

    static let all: [Role] = [
        Role(name: "lawyer", said: ["lawyer", "attorney", "solicitor"],
             marks: ["law", "legal", "esq", "attorney", "llp"],
             signs: #"body:(attorney OR esq OR "law firm" OR llp OR "law office" OR "legal counsel" OR "attorney at law")"#),
        Role(name: "accountant", said: ["accountant", "bookkeeper"],
             marks: ["cpa", "accounting", "bookkeep"],
             signs: #"body:(cpa OR "certified public accountant" OR accountant OR bookkeeping)"#),
    ]

    /// Who a role in the words is: its people, the ones the domain or name
    /// says first, a few in all.
    struct Found {
        let role: Role
        let people: [MailDesk.Contact]
        /// The words that said the role, not to be looked up as words.
        let words: Set<String>
    }

    /// The role the words ask for, mended words too ("lawers").
    static func role(in words: [String]) -> (Role, Set<String>)? {
        for role in all {
            let said = Set(words.filter { word in role.said.contains { word.hasPrefix($0) || (word.count >= 5 && $0.hasPrefix(word)) } })
            if !said.isEmpty { return (role, said) }
        }
        return nil
    }

    private static var kept: [String: Found?] = [:]

    /// The role's people for these words, worked out once per words.
    static func find(_ words: [String]) async -> Found? {
        guard let (role, said) = role(in: words) else { return nil }
        let key = role.name
        if let found = kept[key] { return found.map { Found(role: $0.role, people: $0.people, words: said) } }
        let contacts = MailDesk.shared.topContacts(5000)
        let marked = contacts.filter { contact in
            let name = contact.name.lowercased()
            return Self.marked(contact.address, role) || name.hasSuffix("esq") || name.hasSuffix("esq.")
        }
        // Signatures: mail of their own (not bulk), from someone you write
        // with, never a robot's address.
        let stores = MailCenter.shared.engines.values.map(\.store.off)
        let signs = role.signs
        let signed = await Task.detached {
            stores.flatMap { $0.senders(saying: signs, limit: 12) }
        }.value
        let robots = ["no-reply", "noreply", "alerts", "notify", "notifications", "digest", "news", "hello", "hey@", "team", "support", "info@", "billing", "payment"]
        let known = Dictionary(contacts.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        var people = marked
        let firms = Set(marked.compactMap { $0.address.split(separator: "@").last })
        for sender in signed.sorted(by: { $0.threads > $1.threads }) where !robots.contains(where: { sender.address.contains($0) }) {
            guard let contact = known[sender.address], !people.contains(contact) else { continue }
            // With a firm found, only people of a firm; without, whoever signs so.
            if !firms.isEmpty, !firms.contains(sender.address.split(separator: "@").last ?? "") { continue }
            people.append(contact)
        }
        let found = people.isEmpty ? nil : Found(role: role, people: Array(people.sorted { $0.threads > $1.threads }.prefix(4)), words: said)
        kept[key] = .some(found)
        // Mail comes and goes: worked out again a minute on.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            kept[key] = nil
        }
        return found
    }

    /// Whether an address's domain is a firm of the role: a part of it
    /// ending in a mark ("goodwinlaw", "lisaesq") or, for a long mark,
    /// starting with it ("legalzoom"); never a mark inside a word
    /// ("clawconfigkit", "thesquirrel").
    static func marked(_ address: String, _ role: Role) -> Bool {
        guard let domain = address.split(separator: "@").last else { return false }
        let parts = domain.split(whereSeparator: { $0 == "." || $0 == "-" }).dropLast()
        return parts.contains { part in role.marks.contains { part.hasSuffix($0) || ($0.count >= 5 && part.hasPrefix($0)) } }
    }

    /// Words the spell checker reads as typed wrong, each with its mended
    /// form: "lawers" is "lawyers". Never a person's name or a site from
    /// your own: "deel" stays Deel.
    static func mended(_ words: [String]) -> [String: String] {
        let checker = NSSpellChecker.shared
        var out: [String: String] = [:]
        for word in words where word.count >= 4 {
            guard MailDesk.shared.people(matching: word, limit: 1).isEmpty, History.shared.host(named: word) == nil else { continue }
            let language = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? "ru" : "en"
            let range = NSRange(location: 0, length: (word as NSString).length)
            let wrong = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            guard wrong.location != NSNotFound,
                  let fix = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0)?.lowercased(),
                  fix != word, !fix.contains(" ")
            else { continue }
            out[word] = fix
        }
        return out
    }
}
