import Foundation

// Bench.agentCommand's verbs (AgentBench) for what the user keeps in Yab:
// bookmarks, tabs laid out for them, and snippets that work in any box.
// Mail's own snippets, with whom they are to and their files, stay with
// mail's tools.

extension Bench {
    static let keptVerbs: [String: AgentHandler] = [
        "agent-bookmarks": { $0.handleAgentBookmarks($1) },
        "agent-bookmark-add": { $0.handleAgentBookmarkAdd($1) },
        "agent-bookmark-delete": { $0.handleAgentBookmarkDelete($1) },
        "agent-bookmark-update": { $0.handleAgentBookmarkUpdate($1) },
        "agent-bookmark-move": { $0.handleAgentBookmarkMove($1) },
        "agent-bookmark-folder-create": { $0.handleAgentBookmarkFolderCreate($1) },
        "agent-lay-out": { $0.handleAgentLayOut($1) },
        "agent-snippets": { $0.handleAgentSnippets($1) },
        "agent-snippet-save": { $0.handleAgentSnippetSave($1) },
        "agent-snippet-delete": { $0.handleAgentSnippetDelete($1) },
    ]

    func handleAgentBookmarks(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.list(c.request, roots: Bookmarks.shared.roots))
    }

    func handleAgentBookmarkAdd(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.add(c.request, to: Bookmarks.shared))
    }

    func handleAgentBookmarkDelete(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.delete(c.request, from: Bookmarks.shared))
    }

    func handleAgentBookmarkUpdate(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.update(c.request, in: Bookmarks.shared))
    }

    func handleAgentBookmarkMove(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.move(c.request, in: Bookmarks.shared))
    }

    func handleAgentBookmarkFolderCreate(_ c: AgentCall) {
        c.agents.touch(c.session, "bookmarks")
        c.answer(AgentBookmarks.createFolder(c.request, in: Bookmarks.shared))
    }

    /// Tabs of the user's own, laid out as asked (Browser.layOut): each
    /// space's favorites, pinned rows in their folders and tabs, asleep.
    /// A tab is a URL, or {url, title, folder}; a folder in a folder is
    /// "Outer › Inner".
    func handleAgentLayOut(_ c: AgentCall) {
        c.agents.touch(c.session, "tabs")
        guard let rows = c.request["spaces"] as? [[String: Any]], !rows.isEmpty else {
            c.answer(["error": "lay_out_tabs needs spaces, each with favorites, pinned or tabs"]); return
        }
        var refused: [String] = []
        func entries(_ key: String, in row: [String: Any]) -> [TabImport.Entry] {
            (row[key] as? [Any] ?? []).compactMap { item -> TabImport.Entry? in
                let tab = item as? [String: Any] ?? ["url": item as? String ?? ""]
                let raw = (tab["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let url = Address.url(from: raw)?.absoluteString ?? raw
                guard var entry = TabImport.entry(url, tab["title"] as? String ?? "") else {
                    refused.append(raw)
                    return nil
                }
                let names = (tab["folder"] as? String ?? "").components(separatedBy: "\u{203A}")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !names.isEmpty {
                    entry.folder = names.joined(separator: " \u{203A} ")
                    entry.path = names.count > 1 ? names : nil
                }
                return entry
            }
        }
        let places = rows.enumerated().map { at, row in
            let name = (row["space"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return TabImport.Place(id: "Agent:\(name.isEmpty ? String(at) : name.lowercased())", name: name,
                                   profile: "Default", shared: true,
                                   pinned: entries("favorites", in: row), kept: entries("pinned", in: row), open: entries("tabs", in: row))
        }
        let said = c.browser.layOut(places).map { space, pinned, tabs, skipped in
            "\(space): \(pinned) favorites, \(tabs) tabs" + (skipped > 0 ? ", \(skipped) there already" : "")
        }
        let bad = refused.isEmpty ? "" : "\nNot web addresses, left out: " + refused.joined(separator: " ")
        c.answer(["text": "Laid out, asleep until the user opens them:\n" + said.joined(separator: "\n") + bad])
    }

    func handleAgentSnippets(_ c: AgentCall) {
        c.agents.touch(c.session, "snippets")
        let list = MailSnippets.shared.ordered.filter { !$0.mailOnly }
        guard !list.isEmpty else {
            c.answer(["text": "No snippets that work everywhere yet. snippet_save keeps one; the user types ; and its name in any box, or ⌘; for the list."]); return
        }
        let lines = list.prefix(100).map { snippet -> String in
            let words = snippet.body.count > 300 ? String(snippet.body.prefix(300)) + "…" : snippet.body
            return "- \"\(snippet.name)\"\(snippet.uses > 0 ? " (used \(snippet.uses)×)" : "")\n<snippet>\n\(words)\n</snippet>"
        }
        c.answer(["text": "The user's snippets, most used first. In any box they type ; and the name; ⌘; lists them.\n" + lines.joined(separator: "\n")])
    }

    func handleAgentSnippetSave(_ c: AgentCall) {
        c.agents.touch(c.session, "snippets")
        let name = (c.request["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = c.request["body"] as? String ?? ""
        guard !name.isEmpty, !body.isEmpty else { c.answer(["error": "snippet_save needs a name and its words"]); return }
        guard name.count <= 60 else { c.answer(["error": "Keep the name short: it is what the user types after ;"]); return }
        let old = MailSnippets.shared.named(name)
        // A mail snippet's own: whom it is to and its subject.
        let fields = ["to", "cc", "bcc", "subject"].reduce(into: [String: String]()) { kept, key in
            if let value = c.request[key] as? String { kept[key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let old, old.mailOnly {
            // Its files stay: only Settings › Snippets takes or adds them.
            var now = old
            now.body = body
            if let to = fields["to"] { now.to = to }
            if let cc = fields["cc"] { now.cc = cc }
            if let bcc = fields["bcc"] { now.bcc = bcc }
            if let subject = fields["subject"] { now.subject = subject }
            MailSnippets.shared.change(now)
            c.answer(["text": "Changed the mail snippet \"\(old.name)\"" + (old.files.isEmpty ? "." : "; its files stay as they were.")])
            return
        }
        let mailish = fields.values.contains { !$0.isEmpty }
        MailSnippets.shared.add(name: name, body: body, to: fields["to"] ?? "", cc: fields["cc"] ?? "", bcc: fields["bcc"] ?? "",
                                subject: fields["subject"] ?? "", mailOnly: mailish)
        let use = mailish ? "a mail snippet, for mail_draft's snippet and ; in mail" : ";\(name) in any box"
        c.answer(["text": old == nil ? "Kept \"\(name)\": \(use)." : "Changed \"\(name)\"."])
    }

    func handleAgentSnippetDelete(_ c: AgentCall) {
        c.agents.touch(c.session, "snippets")
        let name = c.request["name"] as? String ?? ""
        guard let snippet = MailSnippets.shared.named(name) else { c.answer(["error": "No snippet named \(name)"]); return }
        MailSnippets.shared.remove(snippet.id)
        c.answer(["text": "Deleted \"\(snippet.name)\"."])
    }
}
