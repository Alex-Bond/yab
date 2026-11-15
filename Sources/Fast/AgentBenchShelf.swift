import AppKit
import MailCore
import UniformTypeIdentifiers

// Bench.agentCommand's verbs (AgentBench). Files and Purchases: what came
// to this Mac through Yab and what you pay for, for agents (files_search,
// files_read, purchases). What comes from mail asks as mail's reads do
// (mailAsks); downloads and what you gave sites are History's kind of
// thing and need no card.

extension Bench {
    static let shelfVerbs: [String: AgentHandler] = [
        "agent-files-search": { $0.handleAgentFilesSearch($1) },
        "agent-files-read": { $0.handleAgentFilesReadShowing($1) },
        "agent-purchases": { $0.handleAgentPurchases($1) },
    ]

    /// Whether mail may be read for this call: connected, allowed, and not
    /// a task kept away from mail. Its card is mailAsks'.
    func mayReadMail(_ c: AgentCall) -> Bool {
        let center = MailCenter.shared
        let own = c.session.flatMap { c.agents.session($0) }.map { $0.cli != "external" } ?? false
        return center.connected && (MailCenter.agentsAllowed || own) && !c.agents.offMail(c.session)
    }

    func handleAgentFilesSearch(_ c: AgentCall) {
        let request = c.request
        let from = (request["from"] as? String)?.lowercased()
        let mail = mayReadMail(c) && from != "downloaded"
        if mail, mailAsks(c) { return }
        if let session = c.session { c.agents.touch(session, "files") }
        let shelf = FileShelf.shared
        shelf.refresh()
        let hits = shelf.search(request["query"] as? String ?? "", from: from, loot: c.browser.loot.kept, mail: mail,
                                limit: min(50, max(1, Int(request["limit"] as? Double ?? 20))))
        var text = FileShelf.describe(hits)
        if !mail, from == nil || from == "mail" {
            text += MailCenter.shared.connected ? "" : "\n(No mail account is connected, so mail's files aren't here.)"
        }
        c.answer(["text": text])
    }

    func handleAgentFilesRead(_ c: AgentCall) {
        let id = (c.request["id"] as? String ?? c.request["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { c.answer(["error": "files_read needs an id or a path from files_search"]); return }
        let shelf = FileShelf.shared
        let isMail = id.hasPrefix("mail.")
        if isMail {
            guard mayReadMail(c) else { c.answer(["error": "mail's files can't be read in this task"]); return }
            if mailAsks(c) { return }
        }
        if let session = c.session { c.agents.touch(session, "files") }
        let answer = c.answer
        let loot = c.browser.loot.kept
        Task { @MainActor in answer(await shelf.give(id, loot: loot)) }
    }

    func handleAgentPurchases(_ c: AgentCall) {
        guard MailCenter.shared.connected || Purchases.shared.testing != nil else {
            c.answer(["error": "no mail account is connected in yab: purchases are read from receipts in mail"]); return
        }
        guard mayReadMail(c) || Purchases.shared.testing != nil else { c.answer(["error": "mail can't be read in this task, and purchases come from it"]); return }
        if mailAsks(c) { return }
        if let session = c.session { c.agents.touch(session, "purchases") }
        let kind = c.request["kind"] as? String ?? "subscriptions"
        let query = c.request["query"] as? String ?? ""
        let book = Purchases.shared
        let answer = c.answer
        // Read now when it never was: a first call waits for the mail.
        if book.version == 0 {
            book.refresh(force: true)
            func wait(_ left: Int) {
                if book.version > 0 || left == 0 { answer(["text": book.describe(kind: kind, query: query)]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wait(left - 1) }
            }
            wait(80)
            return
        }
        book.refresh()
        answer(["text": book.describe(kind: kind, query: query)])
    }
}

extension FileShelf {
    /// One file of Files, as an agent is told of it.
    struct Hit {
        let id: String
        let name: String
        let source: String
        let date: Date
        let size: Int
        let path: String?
        /// The words around what was looked for, when found inside it.
        let line: String?
    }

    /// What Files lists, newest first, kept to `from` (downloaded, mail,
    /// sent) and to the words, which are looked for in the names, where
    /// each came from and the words inside.
    func search(_ query: String, from: String?, loot: [Keep], mail: Bool, limit: Int) -> [Hit] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var all: [Hit] = []
        if from == nil || from == "downloaded" {
            for keep in loot {
                let source = "Downloaded from " + (keep.page?.host() ?? keep.from) + (keep.pageTitle.map { " · " + $0 } ?? "")
                all.append(Hit(id: keep.path, name: keep.name, source: source, date: keep.date,
                               size: Int(keep.stillThere ? PlacePreview.size(keep.path) : 0), path: keep.stillThere ? keep.path : nil, line: nil))
            }
        }
        if mail {
            for one in self.mail where from == nil || (from == "mail" && !one.sent) || (from == "sent" && one.sent) {
                let inline = one.file?.drawn == true ? " (inline in the mail)" : ""
                all.append(Hit(id: one.id, name: one.name, source: (one.sent ? "" : "From ") + one.said + (one.subject.map { ", “\($0)”" } ?? "") + inline,
                               date: one.date, size: one.size, path: one.path, line: nil))
            }
        }
        if from == nil || from == "sent" {
            for one in sentFiles { all.append(Hit(id: one.path ?? one.id, name: one.name, source: one.said, date: one.date, size: one.size, path: one.path, line: nil)) }
        }
        var out: [Hit] = []
        for hit in all.sorted(by: { $0.date > $1.date }) {
            if terms.isEmpty { out.append(hit) } else {
                let said = (hit.name + " " + hit.source).lowercased()
                if terms.allSatisfy({ said.contains($0) }) {
                    out.append(hit)
                } else if let path = hit.path, let line = found(path, terms: terms) {
                    out.append(Hit(id: hit.id, name: hit.name, source: hit.source, date: hit.date, size: hit.size, path: hit.path, line: line))
                }
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func describe(_ hits: [Hit]) -> String {
        guard !hits.isEmpty else { return "No files found." }
        let day = DateFormatter()
        day.dateFormat = "MMM d, yyyy"
        day.locale = Locale(identifier: "en_US")
        return hits.enumerated().map { index, hit in
            var line = "\(index + 1). \(hit.name) · \(hit.source) · \(day.string(from: hit.date))"
            if hit.size > 0 { line += " · " + ByteCountFormatter.string(fromByteCount: Int64(hit.size), countStyle: .file) }
            line += "\n   id: \(hit.id)"
            line += hit.path.map { "\n   path: \($0)" } ?? "\n   (not on this Mac yet: files_read fetches it and gives its path)"
            if let words = hit.line { line += "\n   inside: \(words)" }
            return line
        }.joined(separator: "\n") + "\n(Give a path to upload or to mail_draft's files; files_read gives a file's path and its words.)"
    }

    /// files_read: a file of Files by its id or path, as an agent is given
    /// it: its path on this Mac (a mail's fetched first), and its words
    /// when it has some, a picture's read in it. A video, a sound or
    /// anything else wordless answers its path alone.
    func give(_ id: String, loot: [Keep]) async -> [String: Any] {
        guard let (url, name) = await locate(id, loot: loot) else {
            return ["error": "\(id) isn't in Files: give an id or path files_search listed"]
        }
        var words = await Task.detached(priority: .userInitiated) { FileShelf.read(url) }.value
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if words == nil, type.conforms(to: .image) { words = await MailAgent.pictureWords(url) }
        return MailAgent.given(url, head: "File \(name).", words: words)
    }

    /// A file of Files by its id or path, on this Mac: a mail's fetched
    /// first. Nil for anything Files doesn't list.
    func locate(_ id: String, loot: [Keep]) async -> (URL, String)? {
        if let one = mail.first(where: { $0.id == id || $0.path == id }) {
            guard let url = await fetch(one) else { return nil }
            return (url, one.name)
        }
        let path = (id as NSString).expandingTildeInPath
        if let keep = loot.first(where: { $0.path == path }), keep.stillThere { return (keep.url, keep.name) }
        if let one = uploads.first(where: { $0.path == path }), FileManager.default.fileExists(atPath: path) {
            return (URL(fileURLWithPath: path), one.name)
        }
        return nil
    }
}
